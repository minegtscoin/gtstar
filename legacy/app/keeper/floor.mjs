// GTStar Floor bot: when GTS trades on Cetus below the floor (reserve / supply), it buys from the pool
// and burns what it bought through the reserve, all in one transaction and with no capital of its own:
// flash_swap hands over the GTS first, redeem pays the floor price for it, and the pool is repaid from that.
// It buys only up to the price where one more GTS would cost more than the floor (pool fee included), so it
// never loses on a trade: the transaction aborts unless it clears at least MIN_PROFIT.
// Redeeming at the floor leaves the floor unchanged, and the profit goes into the reserve, so the floor rises.
// While its own balance is under KEEP it keeps the profit instead, to pay its gas.
// Signs with FLOOR_KEY; off when unset.
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const TOKEN = "0x39019f183d8d19df19bd7c3e14fed735c7a1b11e2aa02669eba1089602394c3e";
const GTS = `${TOKEN}::gts::GTS`, SUI = "0x2::sui::SUI";
const MARKET = "0x7492d608ea92b2274bd83be39ac17ebb0f3fed42e4b7a638c17ebf8743e6ebcf"; // Cetus Pool<GTS, SUI>
const CETUS_PKG = "0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084";
const CETUS_CFG = "0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f";
const POOL_T = [GTS, SUI];
const MIN_PROFIT = BigInt(process.env.FLOOR_MIN_PROFIT_MIST || 10_000_000); // 0.01 SUI, well above the gas
const KEEP = BigInt(process.env.FLOOR_KEEP_MIST || 500_000_000);            // 0.5 SUI kept for gas
const EDGE = 0.998;              // buy up to 0.2% under break-even, so rounding never turns a trade into a loss
const CHECK_MS = 10_000;
const Q64 = 2 ** 64;

export function makeFloor(client, CFG, log) {
  const key = process.env.FLOOR_KEY;
  if (!key) return null;
  const signer = Ed25519Keypair.fromSecretKey(key);
  const me = signer.toSuiAddress();
  let last = 0;

  // Called by the keeper loop. Returns true when it sent a transaction.
  async function tick() {
    if (Date.now() - last < CHECK_MS) return false;
    last = Date.now();
    const r = await client.query({
      query: `query($o:SuiAddress!){t:object(address:"${CFG.treasury}"){asMoveObject{contents{json}}} p:object(address:"${MARKET}"){asMoveObject{contents{json}}} address(address:$o){balance(coinType:"${SUI}"){totalBalance}}}`,
      variables: { o: me },
    });
    const t = r.data.t.asMoveObject.contents.json, p = r.data.p.asMoveObject.contents.json;
    const floor = Number(t.vault) / Number(t.cap.total_supply.value);
    const fee = Number(p.fee_rate) / 1e6;
    const s0 = Number(BigInt(p.current_sqrt_price)) / Q64;
    const st = Math.sqrt(floor * (1 - fee) * EDGE); // the pool price the buying stops at
    if (!(s0 < st)) return false;
    // Estimate inside the current liquidity range; the on-chain guard below is what actually protects it.
    const L = Number(p.liquidity) / 1e9;
    const suiIn = L * (st - s0) / (1 - fee), gtsOut = L * (1 / s0 - 1 / st);
    if (gtsOut * floor - suiIn < Number(MIN_PROFIT) / 1e9) return false;

    const bal = BigInt(r.data.address?.balance?.totalBalance || 0);
    const tx = new Transaction();
    tx.setSender(me);
    const [gts, suiLeft, receipt] = tx.moveCall({ target: `${CETUS_PKG}::pool::flash_swap`, typeArguments: POOL_T, arguments: [
      tx.object(CETUS_CFG), tx.object(MARKET), tx.pure.bool(false), tx.pure.bool(true),
      tx.pure.u64(BigInt(Math.ceil(suiIn * 2 * 1e9))), // more than needed: the price limit is what stops it
      tx.pure.u128(BigInt(Math.floor(st * Q64))), tx.object.clock()] });
    tx.moveCall({ target: "0x2::balance::destroy_zero", typeArguments: [SUI], arguments: [suiLeft] });
    const gtsCoin = tx.moveCall({ target: "0x2::coin::from_balance", typeArguments: [GTS], arguments: [gts] });
    const [out] = tx.moveCall({ target: `${TOKEN}::gts::redeem`, arguments: [tx.object(CFG.treasury), gtsCoin] });
    const pay = tx.moveCall({ target: `${CETUS_PKG}::pool::swap_pay_amount`, typeArguments: POOL_T, arguments: [receipt] });
    const [payCoin] = tx.splitCoins(out, [pay]);
    const payBal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: [SUI], arguments: [payCoin] });
    const noGts = tx.moveCall({ target: "0x2::balance::zero", typeArguments: [GTS] });
    tx.moveCall({ target: `${CETUS_PKG}::pool::repay_flash_swap`, typeArguments: POOL_T, arguments: [tx.object(CETUS_CFG), tx.object(MARKET), noGts, payBal, receipt] });
    // Guard: aborts the whole transaction unless at least MIN_PROFIT is left after repaying the pool.
    const [min] = tx.splitCoins(out, [MIN_PROFIT]);
    tx.mergeCoins(out, [min]);
    if (bal < KEEP) tx.transferObjects([out], me);
    else tx.moveCall({ target: `${TOKEN}::gts::vault_add`, arguments: [tx.object(CFG.treasury), tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: [SUI], arguments: [out] })] });

    const res = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const x = res.Transaction || res.FailedTransaction;
    log.push(`floor buy ~${gtsOut.toFixed(2)} GTS at ${(s0 * s0).toFixed(4)} < ${floor.toFixed(4)} ${x.status.success ? "ok" : "failed"} ${x.digest}`);
    await client.waitForTransaction({ digest: x.digest });
    return true;
  }
  return { tick };
}
