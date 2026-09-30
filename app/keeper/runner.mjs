// GTStar Runner: keeps the game live 24/7 from the Bot 1 wallet (a house bot in the contract: no Wealth
// Fund tickets, so its deposits store nothing new). Every round: the minimum on one fully random tile.
// When no round is live it opens one; when a round is live without it, it joins. It draws its own rounds
// right at the end (the keeper waits a few seconds while this runs, so the draw's storage cost and the
// refund when the round record is removed at the last claim land in the same wallet), then claims in the
// same transaction as its next deposit. Mined GTS is merged into one coin in that transaction (a new coin
// object every round would cost storage). Rounds other players joined are left to the keeper to draw
// (someone else may claim last and get the refund). Stops below KEEP.
// Runs as its own long process (started by cron.mjs); signs with BOT1_KEY. Log: runner-log.jsonl.
import fs from "fs";
import path from "path";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import CFG from "./keeper-config.json" with { type: "json" };

const dir = process.env.BOTS_DIR || path.dirname(new URL(import.meta.url).pathname);
if (fs.existsSync(path.join(dir, ".env"))) {
  for (const line of fs.readFileSync(path.join(dir, ".env"), "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m) process.env[m[1]] ??= m[2];
  }
}
const KEEP = 20_000_000n;          // stops below 0.02 SUI
const DEPLOY_GAS = 10_000_000;
const SETTLE_GAS = 20_000_000;

const key = process.env.BOT1_KEY;
if (!key) { console.log("BOT1_KEY not set"); process.exit(0); }
const signer = Ed25519Keypair.fromSecretKey(key);
const me = signer.toSuiAddress();
const node = new SuiGrpcClient({ network: CFG.network, baseUrl: `https://fullnode.${CFG.network}.sui.io:443` });
const C = f => `${CFG.package}::${f}`;
const MINER = `${CFG.origin}::game::Miner`;
const GTS = `${CFG.origin}::gts::GTS`;
const sleep = ms => new Promise(r => setTimeout(r, Math.max(0, ms)));
const sui = m => Math.round(Number(m) / 1e5) / 1e4;

// One instance only.
const pidFile = path.join(dir, ".runner-pid");
try {
  const pid = fs.readFileSync(pidFile, "utf8").trim();
  if (fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").includes("runner.mjs")) { console.log("runner already running"); process.exit(0); }
} catch {}
fs.writeFileSync(pidFile, String(process.pid));
const logFile = path.join(dir, "runner-log.jsonl");
const hbFile = path.join(dir, ".runner-hb");
const liveFile = path.join(dir, ".runner-live"); // touched only while funded: the keeper leaves the draw to us then
const log = o => fs.appendFileSync(logFile, JSON.stringify({ t: new Date().toISOString(), ...o }) + "\n");
const touch = f => { const t = new Date(); try { fs.utimesSync(f, t, t); } catch { fs.writeFileSync(f, ""); } };
const beat = () => touch(hbFile);

const boardArg = tx => tx.sharedObjectRef({ objectId: CFG.board, initialSharedVersion: 1, mutable: true });
const treasuryArg = tx => tx.sharedObjectRef({ objectId: CFG.treasury, initialSharedVersion: CFG.treasuryIsv, mutable: true });

async function board() {
  return (await node.getObject({ objectId: CFG.board, include: { json: true } })).object.json;
}
async function wallet() {
  const bal = BigInt((await node.getBalance({ owner: me })).balance.balance);
  const r = await node.listOwnedObjects({ owner: me, type: MINER, include: { json: true } });
  const o = r.objects[0];
  const g = await node.listCoins({ owner: me, coinType: GTS, limit: 100 });
  return { balance: bal, miner: o ? { id: o.objectId, round: Number(o.json.round_id) } : null, gts: g.objects.map(c => c.objectId) };
}
async function send(label, gas, build) {
  const tx = new Transaction();
  tx.setSender(me);
  tx.setGasBudget(gas);
  build(tx);
  const r0 = await node.signAndExecuteTransaction({ transaction: tx, signer, include: { effects: true } });
  const r = r0.Transaction || r0.FailedTransaction;
  const ok = r.status.success;
  log({ ev: label, ok, digest: r.digest, err: ok ? undefined : r.status.error?.message || String(r.status.error) });
  await node.waitForTransaction({ digest: r.digest }).catch(() => {});
  return ok;
}

// The minimum on one random tile, claiming the previous round in the same transaction.
async function play(b, w) {
  const cur = Number(b.cur_id);
  const per = Number(b.min_deploy);
  if (w.balance < BigInt(per) + KEEP) return false;
  const tile = Math.floor(Math.random() * 25);
  const amounts = Array.from({ length: 25 }, (_, i) => (i === tile ? per : 0));
  const pending = w.miner && w.miner.round !== 0 && w.miner.round < cur;
  return send(`play #${cur} tile ${tile + 1}`, DEPLOY_GAS, tx => {
    if (pending) {
      const [g, s] = tx.moveCall({ target: C("game::claim_v2"), arguments: [boardArg(tx), tx.object(w.miner.id), treasuryArg(tx)] });
      tx.mergeCoins(tx.gas, [s]);
      if (w.gts.length) tx.mergeCoins(tx.object(w.gts[0]), [g, ...w.gts.slice(1, 60).map(id => tx.object(id))]);
      else tx.transferObjects([g], me);
    }
    let m = w.miner ? tx.object(w.miner.id) : null, fresh = false;
    if (!m) { [m] = tx.moveCall({ target: C("game::new_miner") }); fresh = true; }
    const [pay] = tx.splitCoins(tx.gas, [per]);
    tx.moveCall({ target: C("game::deploy"), arguments: [boardArg(tx), m, pay, tx.pure.vector("u64", amounts), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], me);
  });
}

async function main() {
  log({ ev: "start", address: me });
  let errors = 0, low = false;
  for (;;) {
    beat();
    try {
      const b = await board();
      const cur = Number(b.cur_id), end = Number(b.cur_end_ms), freeze = Number(b.freeze_ms);
      const now = Date.now();
      if (b.paused === true) { await sleep(5000); continue; }
      if (!low) touch(liveFile);
      const w = await wallet();
      const inRound = b.cur_started && w.miner?.round === cur;
      if (b.cur_started && now >= end + 300) {
        // Draw a round we hold alone at once; one others joined only if nobody drew it within 15s.
        if (low || !inRound || (Number(b.cur_players) !== 1 && now < end + 15_000)) { await sleep(1000); continue; }
        const ok = await send(`settle #${cur}`, SETTLE_GAS, tx => tx.moveCall({ target: C("game::settle_v2"), arguments: [boardArg(tx), tx.object.random(), tx.object.clock()] }));
        if (!ok) await sleep(1500);
        continue;
      }
      if (low && w.balance >= BigInt(b.min_deploy) + KEEP) low = false;
      if (!inRound && (!b.cur_started || now < end - freeze - 1000)) {
        if (await play(b, w)) { low = false; errors = 0; continue; }
        if (w.balance < BigInt(b.min_deploy) + KEEP) {
          if (!low) log({ ev: "low balance", sui: sui(w.balance) });
          low = true;
          await sleep(20_000);
          continue;
        }
      }
      errors = 0;
      await sleep(b.cur_started ? Math.min(1000, end + 300 - now) : 300);
    } catch (e) {
      log({ ev: "error", msg: String(e.message || e).slice(0, 300) });
      await sleep(Math.min(30_000, 1000 * 2 ** Math.min(5, errors++)));
    }
  }
}

main();
