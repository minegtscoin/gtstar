// Buyback and burn: 3% of every losing pot is saved in the game. Once it reaches MIN, the keeper takes it and buys GTS
// on the Cetus GTS/SUI pool, all in one transaction: buyback_take hands out the SUI with a receipt that only
// buyback_burn_v2 closes, and buyback_burn_v2 burns the GTS for good, so the SUI can only leave as burned GTS.
// Liquidity: 2% of every losing pot is saved in the game. Once it reaches LIQ_MIN, the keeper takes it, buys GTS
// with 49% of it, and adds that GTS with the matching SUI to the same pool as a new full-range position, all in one
// transaction: liquidity_take hands out the SUI with a receipt that only liquidity_lock closes, and liquidity_lock
// locks the position in the game for good. SUI not used goes back to the game, GTS not used is burned with the next buyback.
// The buyback has no price limit: all the saved SUI buys GTS every time. The liquidity buy moves the pool price at
// most MAX_IMPACT; SUI it could not spend under that limit goes back to the game.
const CETUS_PKG = "0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084";
const CETUS_CFG = "0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f";
const CETUS_POSITION = "0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb::position::Position";
const MARKET = "0x0628902c5acd5b5755c9b1a6494e925d0c5327177486b5e3b25d0e9b0211de71"; // Cetus Pool<GTS, SUI>
const SUI = "0x2::sui::SUI";
const MIN = BigInt(process.env.BUYBACK_MIN_MIST || 10_000_000); // 0.01 SUI: smaller, more frequent buys
const LIQ_MIN = BigInt(process.env.LIQUIDITY_MIN_MIST || 100_000_000); // 0.1 SUI: a new position costs more gas
const MAX_IMPACT = 0.02;
const MAX_SQRT = 79226673515401279992447579055n;
// Full range for tick spacing 200: ticks -443600..443600 (u32 bits for the lower one).
const TICK_LO = 2 ** 32 - 443_600, TICK_HI = 443_600;

export function makeBuyback(client, CFG, log, run) {
  const GTS = `${CFG.origin}::gts::GTS`, POOL_T = [GTS, SUI];
  const T = f => `${CFG.package}::${f}`;

  // Price limit for buying GTS: buying raises the pool price (SUI per GTS = sqrt_price^2), so it sits above it.
  async function limit() {
    const p = (await client.query({ query: `{object(address:"${MARKET}"){asMoveObject{contents{json}}}}` })).data.object.asMoveObject.contents.json;
    const s0 = BigInt(p.current_sqrt_price);
    const l = s0 * BigInt(Math.round(Math.sqrt(1 + MAX_IMPACT) * 1e9)) / 1_000_000_000n;
    return l > MAX_SQRT ? MAX_SQRT : l;
  }

  // Swap `amt` SUI (a u64 argument) out of `sui` for GTS. Returns the GTS as a Balance.
  function buy(tx, sui, amt, lim) {
    const [gts, suiLeft, flash] = tx.moveCall({ target: `${CETUS_PKG}::pool::flash_swap`, typeArguments: POOL_T, arguments: [
      tx.object(CETUS_CFG), tx.object(MARKET), tx.pure.bool(false), tx.pure.bool(true), amt, tx.pure.u128(lim), tx.object.clock()] });
    tx.moveCall({ target: "0x2::balance::destroy_zero", typeArguments: [SUI], arguments: [suiLeft] });
    const pay = tx.moveCall({ target: `${CETUS_PKG}::pool::swap_pay_amount`, typeArguments: POOL_T, arguments: [flash] });
    const [payCoin] = tx.splitCoins(sui, [pay]);
    const payBal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: [SUI], arguments: [payCoin] });
    const noGts = tx.moveCall({ target: "0x2::balance::zero", typeArguments: [GTS] });
    tx.moveCall({ target: `${CETUS_PKG}::pool::repay_flash_swap`, typeArguments: POOL_T, arguments: [tx.object(CETUS_CFG), tx.object(MARKET), noGts, payBal, flash] });
    return gts;
  }

  // SUI saved for liquidity (a dynamic field on the Board, from the upgrade that added it).
  async function liquidity() {
    if (!CFG.liqPkg) return 0n;
    const q = `{b:object(address:"${CFG.board}"){dynamicField(name:{type:"${CFG.liqPkg}::game::LiquidityKey",bcs:"AA=="}){value{... on MoveValue{json}}}}}`;
    const v = (await client.query({ query: q })).data.b?.dynamicField?.value?.json;
    return BigInt(v?.value ?? v ?? 0);
  }

  let tried = false, liqTried = false; // one attempt each per keeper run, so a failing one never loops on gas
  // Called by the keeper loop with the board. Returns true when it sent a transaction.
  async function tick(b) {
    if (!tried && BigInt(b.buyback || 0) >= MIN) {
      tried = true;
      const lim = MAX_SQRT; // no price limit: the whole saved SUI always buys GTS, whatever the price
      await run(`buyback ${Number(b.buyback) / 1e9} SUI`, tx => {
        const [sui, receipt] = tx.moveCall({ target: T("game::buyback_take"), arguments: [tx.object(CFG.board)] });
        const amt = tx.moveCall({ target: "0x2::coin::value", typeArguments: [SUI], arguments: [sui] });
        const gts = buy(tx, sui, amt, lim);
        const gtsCoin = tx.moveCall({ target: "0x2::coin::from_balance", typeArguments: [GTS], arguments: [gts] });
        tx.moveCall({ target: T("game::buyback_burn_v2"), arguments: [tx.object(CFG.board), tx.object(CFG.treasury), receipt, gtsCoin, sui] });
      });
      return true;
    }
    if (!liqTried) {
      liqTried = true;
      const l = await liquidity();
      if (l < LIQ_MIN) return false;
      const lim = await limit();
      // 49% buys GTS, so the SUI side (worth about what was spent) always fits in the 51% left.
      const half = l * 49n / 100n;
      await run(`liquidity ${Number(l) / 1e9} SUI`, tx => {
        const [sui, receipt] = tx.moveCall({ target: T("game::liquidity_take"), arguments: [tx.object(CFG.board)] });
        const gts = buy(tx, sui, tx.pure.u64(half), lim);
        const pos = tx.moveCall({ target: `${CETUS_PKG}::pool::open_position`, typeArguments: POOL_T,
          arguments: [tx.object(CETUS_CFG), tx.object(MARKET), tx.pure.u32(TICK_LO), tx.pure.u32(TICK_HI)] });
        const gtsAmt = tx.moveCall({ target: "0x2::balance::value", typeArguments: [GTS], arguments: [gts] });
        const r = tx.moveCall({ target: `${CETUS_PKG}::pool::add_liquidity_fix_coin`, typeArguments: POOL_T,
          arguments: [tx.object(CETUS_CFG), tx.object(MARKET), pos, gtsAmt, tx.pure.bool(true), tx.object.clock()] });
        const [payA, payB] = tx.moveCall({ target: `${CETUS_PKG}::pool::add_liquidity_pay_amount`, typeArguments: POOL_T, arguments: [r] });
        const gtsPay = tx.moveCall({ target: "0x2::balance::split", typeArguments: [GTS], arguments: [gts, payA] });
        const [suiPay] = tx.splitCoins(sui, [payB]);
        const suiPayBal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: [SUI], arguments: [suiPay] });
        tx.moveCall({ target: `${CETUS_PKG}::pool::repay_add_liquidity`, typeArguments: POOL_T,
          arguments: [tx.object(CETUS_CFG), tx.object(MARKET), gtsPay, suiPayBal, r] });
        const gtsLeft = tx.moveCall({ target: "0x2::coin::from_balance", typeArguments: [GTS], arguments: [gts] });
        tx.moveCall({ target: T("game::liquidity_lock"), typeArguments: [CETUS_POSITION], arguments: [tx.object(CFG.board), receipt, pos, sui, gtsLeft] });
      });
      return true;
    }
    return false;
  }
  return { tick };
}
