// GTStar House: a public, named house wallet that joins a round only after a real player has
// started it, so nobody plays alone and every round has a winner. It never starts a round itself.
// Like a normal player it puts HOUSE_PER_TILE_MIST on one random tile. It claims its previous round
// inside the same transaction.
// Signs with HOUSE_KEY; does nothing when that is unset.
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const PER_TILE = BigInt(process.env.HOUSE_PER_TILE_MIST || 10_000_000);        // 0.01 SUI
const KEEP = BigInt(process.env.HOUSE_KEEP_MIST || 300_000_000);               // never spend below 0.3 SUI
const LEAD_MS = 8_000; // join only if the round has at least this long before its deploy freeze

export function makeHouse(client, CFG, log) {
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
  return async function tick(b) {
    if (b.cur_started !== true || Number(b.cur_players) < 1) return false;
    if (Date.now() > Number(b.cur_end_ms) - Number(b.freeze_ms) - LEAD_MS) return false;
    if (failedRound === Number(b.cur_id)) return false;
    if (miner && miner.round_id === Number(b.cur_id)) return false;
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
  };
}
