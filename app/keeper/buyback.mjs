// Buyback (game v7): 1% of every losing pot is saved in the game. Once it reaches MIN, the keeper takes it,
// buys GTS on the Cetus GTS/SUI pool and burns it, all in one transaction: buyback_take hands out the SUI with
// a receipt that only buyback_burn (which burns the GTS) can close, so the SUI can only leave as burned GTS.
// Each buy moves the pool price at most MAX_IMPACT; SUI it could not spend under that limit goes back to the game.
const CETUS_PKG = "0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084";
const CETUS_CFG = "0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f";
const MARKET = "0x0628902c5acd5b5755c9b1a6494e925d0c5327177486b5e3b25d0e9b0211de71"; // Cetus Pool<GTS, SUI>
const SUI = "0x2::sui::SUI";
const MIN = BigInt(process.env.BUYBACK_MIN_MIST || 50_000_000); // 0.05 SUI, so gas stays a small part of it
const MAX_IMPACT = 0.02;
const MAX_SQRT = 79226673515401279992447579055n;

export function makeBuyback(client, CFG, log, run) {
  const GTS = `${CFG.origin}::gts::GTS`, POOL_T = [GTS, SUI];
  const T = f => `${CFG.package}::${f}`;

  let tried = false; // one attempt per keeper run, so a failing buy never loops on gas
  // Called by the keeper loop with the board. Returns true when it sent a transaction.
  async function tick(b) {
    if (tried || BigInt(b.buyback || 0) < MIN) return false;
    tried = true;
    const p = (await client.query({ query: `{object(address:"${MARKET}"){asMoveObject{contents{json}}}}` })).data.object.asMoveObject.contents.json;
    // Buying GTS raises the pool price (SUI per GTS = sqrt_price^2), so the limit sits above the current sqrt price.
    const s0 = BigInt(p.current_sqrt_price);
    let limit = s0 * BigInt(Math.round(Math.sqrt(1 + MAX_IMPACT) * 1e9)) / 1_000_000_000n;
    if (limit > MAX_SQRT) limit = MAX_SQRT;
    await run(`buyback ${Number(b.buyback) / 1e9} SUI`, tx => {
      const [sui, receipt] = tx.moveCall({ target: T("game::buyback_take"), arguments: [tx.object(CFG.board)] });
      const amt = tx.moveCall({ target: "0x2::coin::value", typeArguments: [SUI], arguments: [sui] });
      const [gts, suiLeft, flash] = tx.moveCall({ target: `${CETUS_PKG}::pool::flash_swap`, typeArguments: POOL_T, arguments: [
        tx.object(CETUS_CFG), tx.object(MARKET), tx.pure.bool(false), tx.pure.bool(true), amt, tx.pure.u128(limit), tx.object.clock()] });
      tx.moveCall({ target: "0x2::balance::destroy_zero", typeArguments: [SUI], arguments: [suiLeft] });
      const pay = tx.moveCall({ target: `${CETUS_PKG}::pool::swap_pay_amount`, typeArguments: POOL_T, arguments: [flash] });
      const [payCoin] = tx.splitCoins(sui, [pay]);
      const payBal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: [SUI], arguments: [payCoin] });
      const noGts = tx.moveCall({ target: "0x2::balance::zero", typeArguments: [GTS] });
      tx.moveCall({ target: `${CETUS_PKG}::pool::repay_flash_swap`, typeArguments: POOL_T, arguments: [tx.object(CETUS_CFG), tx.object(MARKET), noGts, payBal, flash] });
      const gtsCoin = tx.moveCall({ target: "0x2::coin::from_balance", typeArguments: [GTS], arguments: [gts] });
      tx.moveCall({ target: T("game::buyback_burn"), arguments: [tx.object(CFG.board), tx.object(CFG.treasury), receipt, gtsCoin, sui] });
    });
    return true;
  }
  return { tick };
}
