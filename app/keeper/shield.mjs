// GTStar Shield: a temporary bot wallet against 0xf375...bac4, which covers all 25 tiles with 1 SUI a round
// straight through the contract. Until game v8 (the fair split) the whole winning share goes to whoever sits
// on the winning tile, so covering the board takes most of the GTS emission and the Wealth Fund.
// The Shield joins only rounds that wallet is in, with SHIELD_PER_TILE on every tile, so it takes most of
// both instead. It claims its previous round in the same transaction and redeems the GTS at the floor
// (burned, SUI back), so the same SUI rolls round after round.
// Stops by itself at STOP_AT (before the v8 upgrade) or when its SUI falls below SHIELD_STOP_MIST.
// Every 5 hours it sends the SUI above SHIELD_KEEP_MIST to SHIELD_TO (when set).
// Signs with SHIELD_KEY; off when unset.
import fs from "fs";
import path from "path";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

export const TARGET = "0xf375efd6dbfcad20fac4be034f37a74b546c6c89ac9607c4c9f4855a92ebbac4";
const PER_TILE = BigInt(process.env.SHIELD_PER_TILE || 150_000_000);   // 0.15 SUI a tile, 3.75 SUI a round
const STOP_LOSS = BigInt(process.env.SHIELD_STOP_MIST || 5_500_000_000); // stop below 5.5 SUI
const KEEP = BigInt(process.env.SHIELD_KEEP_MIST || 10_000_000_000);     // skim what is above 10 SUI
const GAS = 50_000_000n;
const STOP_AT = Date.parse(process.env.SHIELD_STOP_AT || "2026-09-29T13:40:00Z");
const SKIM_MS = 5 * 3600_000;
const LEAD_MS = 6_000; // join only if the round has at least this long before its deploy freeze
const TOKEN = "0x39019f183d8d19df19bd7c3e14fed735c7a1b11e2aa02669eba1089602394c3e";
const GTS = `${TOKEN}::gts::GTS`;

export function makeShield(client, CFG, log, dir) {
  const key = process.env.SHIELD_KEY;
  if (!key) return null;
  const signer = Ed25519Keypair.fromSecretKey(key);
  const me = signer.toSuiAddress();
  const to = process.env.SHIELD_TO;
  const MINER = `${CFG.origin || CFG.package}::game::Miner`;
  const C = f => `${CFG.package}::${f}`;
  const stateFile = path.join(dir, ".shield-state.json");
  const state = (() => { try { return JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch { return {}; } })();
  const save = () => fs.writeFileSync(stateFile, JSON.stringify(state));
  let joined = 0, failedRound = 0;

  let seen = 0; // last round the target was seen in
  async function targetIn(round) {
    if (seen === round) return true;
    const r = await client.query({ query: `{events(filter:{type:"${CFG.origin || CFG.package}::game::Deployed"},last:20){nodes{contents{json}}}}` });
    if ((r.data.events?.nodes || []).some(n => Number(n.contents.json.round_id) === round && n.contents.json.player === TARGET)) seen = round;
    return seen === round;
  }

  async function wallet() {
    const r = await client.query({
      query: `query($o:SuiAddress!,$t:String!){address(address:$o){balance(coinType:"0x2::sui::SUI"){totalBalance} objects(filter:{type:$t},first:1){nodes{address contents{json}}} gts:objects(filter:{type:"0x2::coin::Coin<${GTS}>"},first:50){nodes{address contents{json}}}}}`,
      variables: { o: me, t: MINER },
    });
    const a = r.data.address;
    const n = a?.objects?.nodes?.[0];
    return {
      balance: BigInt(a?.balance?.totalBalance || 0),
      miner: n ? { id: n.address, round_id: Number(n.contents.json.round_id), total: BigInt(n.contents.json.total_deployed || 0) } : null,
      gts: (a?.gts?.nodes || []).filter(c => Number(c.contents.json.balance) > 0).map(c => c.address),
    };
  }

  // Claim a settled round and redeem every GTS it holds; the SUI joins the gas coin.
  function collect(tx, w, cur) {
    const burn = w.gts.map(id => tx.object(id));
    if (w.miner && w.miner.round_id !== 0 && w.miner.round_id < cur) {
      const [g, s] = tx.moveCall({ target: C("game::claim"), arguments: [tx.object(CFG.board), tx.object(w.miner.id), tx.object(CFG.treasury), tx.object.clock()] });
      tx.mergeCoins(tx.gas, [s]);
      burn.push(g);
    }
    if (!burn.length) return;
    if (burn.length > 1) tx.mergeCoins(burn[0], burn.slice(1));
    const out = tx.moveCall({ target: `${TOKEN}::gts::redeem`, arguments: [tx.object(CFG.treasury), burn[0]] });
    tx.mergeCoins(tx.gas, [out]);
  }

  async function send(tx, label) {
    tx.setSender(me);
    const r0 = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const r = r0.Transaction || r0.FailedTransaction;
    log.push(`shield ${label} ${r.status.success ? "ok" : "failed"} ${r.digest}`);
    await client.waitForTransaction({ digest: r.digest });
    return r.status.success;
  }

  async function tick(b) {
    if (state.stopped) return false;
    const cur = Number(b.cur_id);
    const now = Date.now();

    // Past STOP_AT: collect the last round, send everything on, and stop for good.
    if (now >= STOP_AT) {
      const w = await wallet();
      if (w.miner?.round_id === cur && b.cur_started === true) return false; // wait for its settle
      const tx = new Transaction();
      collect(tx, w, cur + 1);
      if (to) { const [c] = tx.splitCoins(tx.gas, [w.balance > GAS * 2n ? w.balance - GAS * 2n : 0n]); tx.transferObjects([c], to); }
      state.stopped = "time"; save();
      return send(tx, "final");
    }

    if (b.cur_started !== true || joined === cur || failedRound === cur) return false;
    if (now > Number(b.cur_end_ms) - Number(b.freeze_ms) - LEAD_MS) return false;
    if (!(await targetIn(cur))) return false;

    const w = await wallet();
    if (w.miner?.round_id === cur) { joined = cur; return false; }
    // What it holds, counting the round it still has to claim at ~95%.
    const pending = w.miner && w.miner.round_id !== 0 && w.miner.round_id < cur ? w.miner.total * 95n / 100n : 0n;
    // The stop-loss only counts once it has played (an unfunded wallet just waits).
    if (state.started && w.balance + pending < STOP_LOSS) {
      state.stopped = `stop-loss ${Number(w.balance + pending) / 1e9} SUI`; save();
      log.push(`shield STOPPED: ${state.stopped}`);
      return false;
    }
    const total = PER_TILE * 25n;
    if (w.balance + pending < total + GAS) { failedRound = cur; log.push(`shield low balance ${Number(w.balance) / 1e9} SUI`); return false; }

    const tx = new Transaction();
    collect(tx, w, cur);
    let m = w.miner ? tx.object(w.miner.id) : null, fresh = false;
    if (!m) { [m] = tx.moveCall({ target: C("game::new_miner") }); fresh = true; }
    const [pay] = tx.splitCoins(tx.gas, [total]);
    tx.moveCall({ target: C("game::deploy"), arguments: [tx.object(CFG.board), m, pay, tx.pure.vector("u64", Array(25).fill(PER_TILE)), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], me);
    // Every 5 hours: send what is above KEEP (the round's deposit is already out, so compare after it).
    if (to && now - (state.skim || 0) >= SKIM_MS && w.balance + pending - total > KEEP) {
      const [c] = tx.splitCoins(tx.gas, [w.balance + pending - total - KEEP]);
      tx.transferObjects([c], to);
      state.skim = now; save();
    }
    failedRound = cur;
    const ok = await send(tx, `join #${cur} ${Number(total) / 1e9} SUI`);
    if (ok) { failedRound = 0; joined = cur; if (!state.started) { state.started = now; save(); } }
    return true;
  }

  return { tick, me, targetIn };
}
