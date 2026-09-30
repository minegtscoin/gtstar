// GTStar Pulse: a sign of life for whoever has the game open. When the site reported a visitor in the
// last VISIT_MS (visit.php touches ~/gtstar-data/visit) and no round is live, it opens one with the
// minimum on one random tile. At most one round every GAP_MS and MAX_A_DAY rounds a UTC day
// (~0.008 SUI a round with the Player's entry and the draw: ~0.4 SUI a day at most).
// It claims its previous round in the same transaction. Mined GTS stays unrefined in the game.
// Signs with PULSE_KEY; off when unset. State: <BOTS_DIR>/.pulse-state.json.
import fs from "fs";
import path from "path";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const VISIT_MS = 90_000;
const GAP_MS = Number(process.env.PULSE_GAP_MS || 180_000);
const MAX_A_DAY = Number(process.env.PULSE_MAX_A_DAY || 50);
const KEEP = 50_000_000n; // stops below 0.05 SUI (gas)

export function makePulse(client, CFG, log, dir) {
  const key = process.env.PULSE_KEY;
  if (!key) return null;
  const signer = Ed25519Keypair.fromSecretKey(key);
  const me = signer.toSuiAddress();
  const MINER = `${CFG.origin}::game::Miner`;
  const C = f => `${CFG.package}::${f}`;
  const visitFile = process.env.VISIT_FILE || path.join(process.env.HOME || "", "gtstar-data", "visit");
  const file = path.join(dir, ".pulse-state.json");
  const state = (() => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return {}; } })();
  const save = () => fs.writeFileSync(file, JSON.stringify(state));

  // Returns true when it sent a transaction.
  return async function tick(b) {
    if (b.cur_started === true) return false;
    const now = Date.now();
    const day = new Date().toISOString().slice(0, 10);
    if (state.day !== day) { state.day = day; state.rounds = 0; save(); }
    if (state.rounds >= MAX_A_DAY || now - (state.last || 0) < GAP_MS) return false;
    let seen = 0;
    try { seen = fs.statSync(visitFile).mtimeMs; } catch { return false; }
    if (now - seen > VISIT_MS) return false;

    const r = await client.query({
      query: `query($o:SuiAddress!,$t:String!){address(address:$o){balance(coinType:"0x2::sui::SUI"){totalBalance} objects(filter:{type:$t},first:1){nodes{address contents{json}}}}}`,
      variables: { o: me, t: MINER },
    });
    const a = r.data.address;
    const bal = BigInt(a?.balance?.totalBalance || 0);
    const per = BigInt(b.min_deploy);
    state.last = now; save();
    if (bal < per + KEEP) { log.push(`pulse low balance ${Number(bal) / 1e9} SUI`); return false; }
    const n = a?.objects?.nodes?.[0];
    const miner = n ? { id: n.address, round: Number(n.contents.json.round_id) } : null;

    const tile = Math.floor(Math.random() * 25);
    const amounts = Array.from({ length: 25 }, (_, i) => (i === tile ? per : 0n));
    const tx = new Transaction();
    tx.setSender(me);
    if (miner && miner.round !== 0) {
      const s = tx.moveCall({ target: C("game::claim_sui_v2"), arguments: [tx.object(CFG.board), tx.object(miner.id), tx.object(CFG.treasury)] });
      tx.mergeCoins(tx.gas, [s]);
    }
    let m = miner ? tx.object(miner.id) : null, fresh = false;
    if (!m) { [m] = tx.moveCall({ target: C("game::new_miner") }); fresh = true; }
    const [pay] = tx.splitCoins(tx.gas, [per]);
    tx.moveCall({ target: C("game::deploy"), arguments: [tx.object(CFG.board), m, pay, tx.pure.vector("u64", amounts), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], me);
    const r0 = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const res = r0.Transaction || r0.FailedTransaction;
    log.push(`pulse #${b.cur_id} tile ${tile + 1} ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
    if (res.status.success) { state.rounds++; save(); }
    return true;
  };
}
