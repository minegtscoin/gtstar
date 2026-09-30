// GTStar Market Maker: one small buy order and one small sell order for GTS on the DeepBook GTS/SUI book,
// around the Cetus GTS/SUI price (SPREAD below and above it), replaced every INTERVAL_MS (~0.001 SUI of gas a round).
// Orders are post-only and never trade against the bot's own orders. They expire after two intervals,
// so nothing stale stays on the book if the bot stops.
// Setup runs by itself once the wallet is funded: with 500 DEEP in the wallet it opens the GTS/SUI book
// (the DeepBook fee, spent once), then it opens a BalanceManager (the bot's trading account on DeepBook).
// Every round it moves GTS from the wallet, and SUI above GAS_KEEP, into that account.
// Signs with MM_KEY; off when unset. State: <BOTS_DIR>/.mm-state.json.
import fs from "fs";
import path from "path";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction, coinWithBalance } from "@mysten/sui/transactions";

const DB = "0x0e735f8c93a95722efd73521aca7a7652c0bb71ed1daf41b26dfd7d1ff71f748"; // DeepBook v3 package (mainnet)
const REGISTRY = "0xaf16199a2dff736e9f07a845f23c5da6df6f756eddb631aed9d24a93efc4549d";
const DEEP = "0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP";
const POOL_FEE = 500_000_000n; // 500 DEEP
const CETUS_POOL = "0x0628902c5acd5b5755c9b1a6494e925d0c5327177486b5e3b25d0e9b0211de71"; // Cetus Pool<GTS, SUI>
const SUI = "0x2::sui::SUI";
// Book settings, fixed once the book is open. Prices are SUI per GTS x 1e9 (both coins have 9 decimals).
const TICK = 10_000n; // price step 0.00001 SUI
const LOT = 1_000_000n; // size step 0.001 GTS
const MIN_SIZE = 10_000_000n; // smallest order 0.01 GTS
const INTERVAL_MS = Number(process.env.MM_INTERVAL_MS || 40 * 60_000);
const SPREAD = Number(process.env.MM_SPREAD || 0.02); // each order 2% from the Cetus price
const ORDER = BigInt(process.env.MM_ORDER_MIST || 100_000_000); // each order worth 0.1 SUI
const GAS_KEEP = 1_000_000_000n; // SUI kept in the wallet for gas
const STOP = 50_000_000n; // stops below 0.05 SUI of gas
const POST_ONLY = 3, CANCEL_TAKER = 1;

export function makeMM(client, CFG, log, dir) {
  const key = process.env.MM_KEY;
  if (!key) return null;
  const signer = Ed25519Keypair.fromSecretKey(key);
  const me = signer.toSuiAddress();
  const GTS = `${CFG.origin}::gts::GTS`, T = [GTS, SUI];
  const file = path.join(dir, ".mm-state.json");
  const state = (() => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return {}; } })();
  const save = () => fs.writeFileSync(file, JSON.stringify(state));
  let checked = false; // setup and funding checks run once per keeper run

  async function wallet() {
    const r = await client.query({
      query: `query($o:SuiAddress!){address(address:$o){s:balance(coinType:"${SUI}"){totalBalance} g:balance(coinType:"${GTS}"){totalBalance} d:balance(coinType:"${DEEP}"){totalBalance}}}`,
      variables: { o: me },
    });
    const a = r.data.address;
    return { sui: BigInt(a?.s?.totalBalance || 0), gts: BigInt(a?.g?.totalBalance || 0), deep: BigInt(a?.d?.totalBalance || 0) };
  }
  async function send(label, tx) {
    tx.setSender(me);
    const r0 = await client.signAndExecuteTransaction({ transaction: tx, signer, include: { effects: true, objectTypes: true } });
    const res = r0.Transaction || r0.FailedTransaction;
    log.push(`mm ${label} ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
    return res;
  }
  const created = (res, re) => res.effects.changedObjects.find(o => o.idOperation === "Created" && re.test(res.objectTypes[o.objectId] || ""))?.objectId;
  const u64 = b => new DataView(Uint8Array.from(b).buffer).getBigUint64(0, true);

  // Cetus price, SUI per GTS x 1e9 (coin a is GTS, coin b is SUI).
  async function mid() {
    const p = (await client.query({ query: `{object(address:"${CETUS_POOL}"){asMoveObject{contents{json}}}}` })).data.object.asMoveObject.contents.json;
    const s = BigInt(p.current_sqrt_price);
    return s * s * 1_000_000_000n >> 128n;
  }
  // What the account holds once its orders are cancelled (a simulation, nothing is signed).
  async function held() {
    const tx = new Transaction();
    tx.setSender(me);
    const proof = tx.moveCall({ target: `${DB}::balance_manager::generate_proof_as_owner`, arguments: [tx.object(state.bm)] });
    tx.moveCall({ target: `${DB}::pool::cancel_all_orders`, typeArguments: T, arguments: [tx.object(state.pool), tx.object(state.bm), proof, tx.object.clock()] });
    tx.moveCall({ target: `${DB}::balance_manager::balance`, typeArguments: [GTS], arguments: [tx.object(state.bm)] });
    tx.moveCall({ target: `${DB}::balance_manager::balance`, typeArguments: [SUI], arguments: [tx.object(state.bm)] });
    const r = await client.simulateTransaction({ transaction: tx, include: { commandResults: true } });
    if (r.FailedTransaction) throw new Error(`mm simulation failed: ${JSON.stringify(r.FailedTransaction.status)}`);
    return { gts: u64(r.commandResults[2].returnValues[0].bcs), sui: u64(r.commandResults[3].returnValues[0].bcs) };
  }

  // Returns true when it sent a transaction.
  return async function tick() {
    const now = Date.now();
    if (state.pool && state.bm && now - (state.last || 0) < INTERVAL_MS) return false;
    if (checked) return false;
    checked = true;
    const w = await wallet();
    if (w.sui < STOP) { log.push(`mm low balance ${Number(w.sui) / 1e9} SUI`); return false; }

    if (!state.pool) {
      if (w.deep < POOL_FEE) return false;
      const tx = new Transaction();
      tx.moveCall({ target: `${DB}::pool::create_permissionless_pool`, typeArguments: T, arguments: [
        tx.object(REGISTRY), tx.pure.u64(TICK), tx.pure.u64(LOT), tx.pure.u64(MIN_SIZE), coinWithBalance({ type: DEEP, balance: POOL_FEE })] });
      const res = await send("open book", tx);
      if (res.status.success) { state.pool = created(res, /^0x[0-9a-f]+::pool::Pool</); save(); log.push(`mm book ${state.pool}`); }
      return true;
    }
    if (!state.bm) {
      const tx = new Transaction();
      const bm = tx.moveCall({ target: `${DB}::balance_manager::new` });
      tx.moveCall({ target: "0x2::transfer::public_share_object", typeArguments: [`${DB}::balance_manager::BalanceManager`], arguments: [bm] });
      const res = await send("open account", tx);
      if (res.status.success) { state.bm = created(res, /::balance_manager::BalanceManager$/); save(); log.push(`mm account ${state.bm}`); }
      return true;
    }

    state.last = now; save();
    const price = await mid();
    const bid = price * BigInt(Math.round((1 - SPREAD) * 1e6)) / 1_000_000n / TICK * TICK;
    const ask = (price * BigInt(Math.round((1 + SPREAD) * 1e6)) / 1_000_000n + TICK - 1n) / TICK * TICK;
    const addSui = w.sui > GAS_KEEP + STOP ? w.sui - GAS_KEEP : 0n;
    const h = await held();
    const sui = h.sui + addSui, gts = h.gts + w.gts;
    // 2% left free in the account for DeepBook's trading fee, paid in the coin given.
    const lots = q => q / LOT * LOT;
    const bidQty = lots([ORDER, sui * 98n / 100n].reduce((a, b) => (a < b ? a : b)) * 1_000_000_000n / bid);
    const askQty = lots([ORDER * 1_000_000_000n / ask, gts * 98n / 100n].reduce((a, b) => (a < b ? a : b)));

    const tx = new Transaction();
    const bm = tx.object(state.bm), pool = tx.object(state.pool);
    if (addSui > 0n) tx.moveCall({ target: `${DB}::balance_manager::deposit`, typeArguments: [SUI], arguments: [bm, tx.splitCoins(tx.gas, [addSui])[0]] });
    if (w.gts > 0n) tx.moveCall({ target: `${DB}::balance_manager::deposit`, typeArguments: [GTS], arguments: [bm, coinWithBalance({ type: GTS, balance: w.gts })] });
    const proof = tx.moveCall({ target: `${DB}::balance_manager::generate_proof_as_owner`, arguments: [bm] });
    tx.moveCall({ target: `${DB}::pool::cancel_all_orders`, typeArguments: T, arguments: [pool, bm, proof, tx.object.clock()] });
    const expire = BigInt(now + 2 * INTERVAL_MS);
    const place = (id, p, q, isBid) => tx.moveCall({ target: `${DB}::pool::place_limit_order`, typeArguments: T, arguments: [
      pool, bm, proof, tx.pure.u64(id), tx.pure.u8(POST_ONLY), tx.pure.u8(CANCEL_TAKER), tx.pure.u64(p), tx.pure.u64(q),
      tx.pure.bool(isBid), tx.pure.bool(false), tx.pure.u64(expire), tx.object.clock()] });
    if (bidQty >= MIN_SIZE) place(now, bid, bidQty, true);
    if (askQty >= MIN_SIZE) place(now + 1, ask, askQty, false);
    const f = n => (Number(n) / 1e9).toFixed(4);
    await send(`quote mid ${f(price)} buy ${f(bidQty)} @ ${f(bid)} sell ${f(askQty)} @ ${f(ask)} (account ${f(gts)} GTS ${f(sui)} SUI)`, tx);
    return true;
  };
}
