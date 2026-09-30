// GTStar Pulse: a sign of life. Once every hour, at a random minute of that hour, it deploys the minimum
// (0.01 SUI) on 3 random tiles, joining a running round or starting one. It claims its previous
// round in the same transaction. Mined GTS stays unrefined in the game.
// Signs with PULSE_KEY; off when unset. State: <BOTS_DIR>/.pulse-state.json.
import fs from "fs";
import path from "path";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const TILES = 3;
const KEEP = 50_000_000n; // stops below 0.05 SUI (gas)
const LEAD_MS = 8_000;    // joins a running round only with this long left before its freeze

export function makePulse(client, CFG, log, dir) {
  const key = process.env.PULSE_KEY;
  if (!key) return null;
  const signer = Ed25519Keypair.fromSecretKey(key);
  const me = signer.toSuiAddress();
  const MINER = `${CFG.origin}::game::Miner`;
  const C = f => `${CFG.package}::${f}`;
  const file = path.join(dir, ".pulse-state.json");
  const state = (() => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return {}; } })();
  const save = () => fs.writeFileSync(file, JSON.stringify(state));

  // Returns true when it sent a transaction.
  return async function tick(b) {
    const now = new Date();
    const hour = now.toISOString().slice(0, 13);
    if (state.hour !== hour) { state.hour = hour; state.minute = Math.floor(Math.random() * 59); state.played = false; save(); }
    if (state.played || now.getUTCMinutes() < state.minute) return false;
    const end = Number(b.cur_end_ms), freeze = Number(b.freeze_ms);
    if (b.cur_started === true && (Date.now() > end - freeze - LEAD_MS)) return false; // wait for the next round

    const r = await client.query({
      query: `query($o:SuiAddress!,$t:String!){address(address:$o){balance(coinType:"0x2::sui::SUI"){totalBalance} objects(filter:{type:$t},first:1){nodes{address contents{json}}}}}`,
      variables: { o: me, t: MINER },
    });
    const a = r.data.address;
    const bal = BigInt(a?.balance?.totalBalance || 0);
    const per = BigInt(b.min_deploy);
    if (bal < per * BigInt(TILES) + KEEP) { state.played = true; save(); log.push(`pulse low balance ${Number(bal) / 1e9} SUI`); return false; }
    const n = a?.objects?.nodes?.[0];
    const miner = n ? { id: n.address, round: Number(n.contents.json.round_id) } : null;
    if (miner && miner.round === Number(b.cur_id)) { state.played = true; save(); return false; }

    const tiles = new Set();
    while (tiles.size < TILES) tiles.add(Math.floor(Math.random() * 25));
    const amounts = Array.from({ length: 25 }, (_, i) => (tiles.has(i) ? per : 0n));
    const tx = new Transaction();
    tx.setSender(me);
    if (miner && miner.round !== 0) {
      const s = tx.moveCall({ target: C("game::claim_sui"), arguments: [tx.object(CFG.board), tx.object(miner.id), tx.object(CFG.treasury)] });
      tx.mergeCoins(tx.gas, [s]);
    }
    let m = miner ? tx.object(miner.id) : null, fresh = false;
    if (!m) { [m] = tx.moveCall({ target: C("game::new_miner") }); fresh = true; }
    const [pay] = tx.splitCoins(tx.gas, [per * BigInt(TILES)]);
    tx.moveCall({ target: C("game::deploy"), arguments: [tx.object(CFG.board), m, pay, tx.pure.vector("u64", amounts), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], me);
    const r0 = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const res = r0.Transaction || r0.FailedTransaction;
    log.push(`pulse #${b.cur_id} tiles ${[...tiles].map(i => i + 1).join(",")} ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
    state.played = true; save();
    return true;
  };
}
