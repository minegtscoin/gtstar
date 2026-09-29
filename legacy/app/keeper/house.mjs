// GTStar House: a public, named house wallet that joins a round only after a real player has
// started it, so nobody plays alone and every round has a winner. It never starts a round itself,
// and stays out of rounds only the GTStar Bots have joined (bots.mjs).
// Like a normal player it puts HOUSE_PER_TILE_MIST on one random tile. It claims its previous round
// inside the same transaction.
// Once a day (addLiquidity) it puts the GTS it mined into the Cetus GTS/SUI pool, paired with its
// own SUI at the pool price, in one full-range position it keeps. It never sells GTS for this.
// Signs with HOUSE_KEY; does nothing when that is unset.
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const PER_TILE = BigInt(process.env.HOUSE_PER_TILE_MIST || 10_000_000);        // 0.01 SUI
const KEEP = BigInt(process.env.HOUSE_KEEP_MIST || 300_000_000);               // never spend below 0.3 SUI
const LEAD_MS = 8_000; // join only if the round has at least this long before its deploy freeze
const LP_KEEP = BigInt(process.env.HOUSE_LP_KEEP_MIST || 1_000_000_000);     // SUI left for playing after adding liquidity
const LP_MIN_GTS = 1_000_000_000n;                                           // add only once it holds at least 1 GTS
const LP_SLIP = 0.03; // abort if the pool asks for more than 3% more or less SUI than its price said

// Cetus CLMM, Pool<GTS, SUI>, tick spacing 200. Full range = ticks -443600..443600 (u32 bits for the lower one).
const GTS = "0x39019f183d8d19df19bd7c3e14fed735c7a1b11e2aa02669eba1089602394c3e::gts::GTS";
const CETUS_PKG = "0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084"; // clmm, latest version
const CETUS_CFG = "0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f";
const CETUS_POOL = "0x7492d608ea92b2274bd83be39ac17ebb0f3fed42e4b7a638c17ebf8743e6ebcf";
const POSITION = "0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb::position::Position";
const POOL_T = [GTS, "0x2::sui::SUI"];
const TICK_LO = 2 ** 32 - 443_600, TICK_HI = 443_600;

export function makeHouse(client, CFG, log, botsIn) {
  const key = process.env.HOUSE_KEY;
  if (!key) return null;
  const signer = Ed25519Keypair.fromSecretKey(key);
  const me = signer.toSuiAddress();
  const MINER = `${CFG.origin || CFG.package}::game::Miner`;
  const C = f => `${CFG.package}::${f}`;
  let miner; // { id, round_id }, cached for this run
  let failedRound = 0; // never retry a round whose join failed (each attempt costs gas)

  async function load() {
    const r = await client.query({
      query: `query($o:SuiAddress!,$t:String!){address(address:$o){balance(coinType:"0x2::sui::SUI"){totalBalance} objects(filter:{type:$t},first:1){nodes{address contents{json}}}}}`,
      variables: { o: me, t: MINER },
    });
    const a = r.data.address;
    const n = a?.objects?.nodes?.[0];
    miner = n ? { id: n.address, round_id: Number(n.contents.json.round_id) } : null;
    return BigInt(a?.balance?.totalBalance || 0);
  }

  // Called by the keeper with a fresh board. Returns true when it sent a transaction.
  async function tick(b) {
    if (b.cur_started !== true || Number(b.cur_players) < 1) return false;
    if (Date.now() > Number(b.cur_end_ms) - Number(b.freeze_ms) - LEAD_MS) return false;
    if (failedRound === Number(b.cur_id)) return false;
    if (miner && miner.round_id === Number(b.cur_id)) return false;
    if (botsIn && Number(b.cur_players) - await botsIn(Number(b.cur_id)) < 1) return false;
    const balance = await load();
    if (miner && miner.round_id === Number(b.cur_id)) return false;
    const total = PER_TILE;
    if (balance < total + KEEP) { failedRound = Number(b.cur_id); log.push(`house low balance ${Number(balance) / 1e9} SUI`); return false; }

    const tile = Math.floor(Math.random() * 25);
    const tx = new Transaction();
    tx.setSender(me);
    let m, fresh = false;
    if (miner) {
      m = tx.object(miner.id);
      if (miner.round_id !== 0 && miner.round_id < Number(b.cur_id)) {
        const [g, s] = tx.moveCall({ target: C("game::claim"), arguments: [tx.object(CFG.board), m, tx.object(CFG.treasury), tx.object.clock()] });
        tx.transferObjects([g, s], me);
      }
    } else {
      [m] = tx.moveCall({ target: C("game::new_miner") });
      fresh = true;
    }
    const [pay] = tx.splitCoins(tx.gas, [total]);
    tx.moveCall({ target: C("game::deploy"), arguments: [tx.object(CFG.board), m, pay, tx.pure.vector("u64", Array.from({ length: 25 }, (_, i) => (i === tile ? PER_TILE : 0n))), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], me);

    failedRound = Number(b.cur_id); // cleared below on success; a throw also stops retries this round
    const r = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const res = r.Transaction || r.FailedTransaction;
    log.push(`house join #${b.cur_id} ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
    if (res.status.success) failedRound = 0;
    miner = res.status.success && !fresh ? { id: miner.id, round_id: Number(b.cur_id) } : undefined; // else reload next time
    return true;
  }

  // Adds all the House's GTS (as much as its SUI above LP_KEEP can pair) to its Cetus position.
  async function addLiquidity() {
    const r = await client.query({
      query: `query($o:SuiAddress!,$p:String!){address(address:$o){balance(coinType:"0x2::sui::SUI"){totalBalance} pos:objects(filter:{type:$p},first:50){nodes{address contents{json}}}} object(address:"${CETUS_POOL}"){asMoveObject{contents{json}}}}`,
      variables: { o: me, p: POSITION },
    });
    const a = r.data.address;
    const coins = [];
    for (let after = null, i = 0; i < 10; i++) { // up to 500 GTS coins (one per claim); the rest wait for the next day
      const g = await client.query({
        query: `query($o:SuiAddress!,$c:String){address(address:$o){objects(filter:{type:"0x2::coin::Coin<${GTS}>"},first:50,after:$c){nodes{address contents{json}} pageInfo{hasNextPage endCursor}}}}`,
        variables: { o: me, c: after },
      });
      const o = g.data.address.objects;
      coins.push(...o.nodes.filter(c => BigInt(c.contents.json.balance) > 0n));
      if (!o.pageInfo.hasNextPage) break;
      after = o.pageInfo.endCursor;
    }
    const held = coins.reduce((t, c) => t + BigInt(c.contents.json.balance), 0n);
    const sui = BigInt(a?.balance?.totalBalance || 0);
    const pos = (a?.pos?.nodes || []).find(n => n.contents.json.pool === CETUS_POOL)?.address;
    const price = (Number(r.data.object.asMoveObject.contents.json.current_sqrt_price) / 2 ** 64) ** 2; // SUI per GTS
    const spare = Number(sui - LP_KEEP - 50_000_000n); // 0.05 SUI for gas
    const gts = BigInt(Math.min(Number(held), Math.floor(spare / (price * (1 + LP_SLIP)))));
    if (gts < LP_MIN_GTS) { if (held >= LP_MIN_GTS) log.push(`house lp skipped: ${Number(sui) / 1e9} SUI`); return false; }
    const want = Number(gts) * price;

    const tx = new Transaction();
    tx.setSender(me);
    const p = pos ? tx.object(pos) : tx.moveCall({ target: `${CETUS_PKG}::pool::open_position`, typeArguments: POOL_T,
      arguments: [tx.object(CETUS_CFG), tx.object(CETUS_POOL), tx.pure.u32(TICK_LO), tx.pure.u32(TICK_HI)] });
    const receipt = tx.moveCall({ target: `${CETUS_PKG}::pool::add_liquidity_fix_coin`, typeArguments: POOL_T,
      arguments: [tx.object(CETUS_CFG), tx.object(CETUS_POOL), p, tx.pure.u64(gts), tx.pure.bool(true), tx.object.clock()] });
    const [payA, payB] = tx.moveCall({ target: `${CETUS_PKG}::pool::add_liquidity_pay_amount`, typeArguments: POOL_T, arguments: [receipt] });
    const gc = coins.map(c => tx.object(c.address));
    if (gc.length > 1) tx.mergeCoins(gc[0], gc.slice(1));
    const [gtsPay] = tx.splitCoins(gc[0], [payA]);
    // Price guard: the SUI split aborts the transaction when the pool asks for more than max or less than min.
    const [cap] = tx.splitCoins(tx.gas, [tx.pure.u64(Math.ceil(want * (1 + LP_SLIP)))]);
    const [suiPay] = tx.splitCoins(cap, [payB]);
    const [floor] = tx.splitCoins(suiPay, [tx.pure.u64(Math.floor(want * (1 - LP_SLIP)))]);
    tx.mergeCoins(suiPay, [floor]);
    tx.mergeCoins(tx.gas, [cap]);
    const bal = (coin, t) => tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: [t], arguments: [coin] });
    tx.moveCall({ target: `${CETUS_PKG}::pool::repay_add_liquidity`, typeArguments: POOL_T,
      arguments: [tx.object(CETUS_CFG), tx.object(CETUS_POOL), bal(gtsPay, POOL_T[0]), bal(suiPay, POOL_T[1]), receipt] });
    if (!pos) tx.transferObjects([p], me);

    const res0 = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const res = res0.Transaction || res0.FailedTransaction;
    log.push(`house lp ${Number(gts) / 1e9} GTS + ~${(want / 1e9).toFixed(3)} SUI ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
    return true;
  }

  return { tick, addLiquidity };
}
