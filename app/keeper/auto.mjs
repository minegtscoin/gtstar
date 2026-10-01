// GTStar Auto Mine keeper: plays every round for the players who set an Auto Mine plan (game::auto_run).
// The call is permissionless and pays its caller 1% of every deposit it makes; this process is the one
// that makes it every round. It holds no player funds: balances sit in the immutable auto_vault package,
// and auto_run can only take a player's own per-round amount and put it on tiles in their name.
//
// Every round:
//  - as soon as a round can take deposits (a new round, or none live): one auto_run for every player with a
//    round to claim (SUI won goes back to their vault balance) and every Spread and Sniper plan that is ready;
//  - shortly before deposits close: one auto_run for the Hunter plans.
// Players the contract cannot play now are skipped by the contract itself, so a stale read here costs
// nothing but a little gas; each player is sent at most once a round. Nothing is sent when no player
// needs anything.
// Runs as its own long process (started by cron.mjs); signs with AUTO_KEY, a wallet that only holds SUI
// for gas. Log: auto-log.jsonl. Stops sending below KEEP.
import fs from "fs";
import path from "path";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import { deriveDynamicFieldID } from "@mysten/sui/utils";
import { TypeTagSerializer } from "@mysten/sui/bcs";
import CFG from "./keeper-config.json" with { type: "json" };

const dir = process.env.BOTS_DIR || path.dirname(new URL(import.meta.url).pathname);
if (fs.existsSync(path.join(dir, ".env"))) {
  for (const line of fs.readFileSync(path.join(dir, ".env"), "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m) process.env[m[1]] ??= m[2];
  }
}
const KEEP = 20_000_000n;      // stops below 0.02 SUI
const GAS = 100_000_000;       // ceiling per call; unused gas is refunded
const BATCH = 40;              // players per call
const LEAD_MIN = 1_800;        // Hunter: send this long before deposits close, at least
const HUNT_MS = 10_000;        // game::AUTO_HUNT_MS
const MIN_ROUND = 50_000_000;  // game::AUTO_MIN_ROUND
const GAP_MS = 20_000;         // vault::MIN_GAP_MS
const LIST_MS = 15_000;        // how often the whole vault is read again
const HUNTER = 2;

const key = process.env.AUTO_KEY;
if (!key) { console.log("AUTO_KEY not set"); process.exit(0); }
if (!CFG.autoVault) { console.log("Auto Mine is not deployed"); process.exit(0); }
const signer = Ed25519Keypair.fromSecretKey(key);
const me = signer.toSuiAddress();
const node = new SuiGrpcClient({ network: CFG.network, baseUrl: `https://fullnode.${CFG.network}.sui.io:443` });
const C = f => `${CFG.package}::${f}`;
const SEAT_KEY = TypeTagSerializer.parseFromStr(`${CFG.autoPkg}::game::AutoKey`);
const sleep = ms => new Promise(r => setTimeout(r, Math.max(0, ms)));
const sui = m => Math.round(Number(m) / 1e5) / 1e4;
const hex = b => "0x" + Buffer.from(b).toString("hex");
const bytes = a => Uint8Array.from(Buffer.from(a.slice(2).padStart(64, "0"), "hex"));

// One instance only.
const pidFile = path.join(dir, ".auto-pid");
try {
  const pid = fs.readFileSync(pidFile, "utf8").trim();
  if (fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").includes("auto.mjs")) { console.log("auto already running"); process.exit(0); }
} catch {}
fs.writeFileSync(pidFile, String(process.pid));
const logFile = path.join(dir, "auto-log.jsonl");
const hbFile = path.join(dir, ".auto-hb");
const log = o => fs.appendFileSync(logFile, JSON.stringify({ t: new Date().toISOString(), ...o }) + "\n");
const beat = () => { const t = new Date(); try { fs.utimesSync(hbFile, t, t); } catch { fs.writeFileSync(hbFile, ""); } };

const boardArg = tx => tx.sharedObjectRef({ objectId: CFG.board, initialSharedVersion: 1, mutable: true });
const vaultArg = tx => tx.sharedObjectRef({ objectId: CFG.autoVault, initialSharedVersion: CFG.autoVaultIsv, mutable: true });
const treasuryArg = tx => tx.sharedObjectRef({ objectId: CFG.treasury, initialSharedVersion: CFG.treasuryIsv, mutable: true });

// ---------- chain reads ----------
async function board() {
  return (await node.getObject({ objectId: CFG.board, include: { json: true } })).object.json;
}
// Every account in the vault: address -> the id of its entry in the accounts table.
let table = null;
async function listAccounts() {
  table ??= (await node.getObject({ objectId: CFG.autoVault, include: { json: true } })).object.json.accounts.id;
  const all = new Map();
  for (let cursor = null; ;) {
    const r = await node.listDynamicFields({ parentId: table, cursor, limit: 200 });
    for (const f of r.dynamicFields) all.set(hex(f.name.bcs), f.fieldId);
    if (!r.hasNextPage) break;
    cursor = r.cursor;
  }
  return all;
}
// Live plan and seat of the given accounts, straight from a fullnode. A player without a seat is left
// out (the game skips them).
async function read(accounts) {
  const addrs = [...accounts.keys()];
  if (!addrs.length) return [];
  const ids = addrs.flatMap(a => [accounts.get(a), deriveDynamicFieldID(CFG.board, SEAT_KEY, bytes(a))]);
  const { objects } = await node.getObjects({ objectIds: ids, include: { json: true } });
  return addrs.map((address, i) => {
    const acct = objects[2 * i], seat = objects[2 * i + 1];
    if (acct instanceof Error || seat instanceof Error || !acct?.json || !seat?.json) return null;
    const a = acct.json.value, s = seat.json.value;
    return {
      address, field: accounts.get(address), on: a.on === true, strategy: Number(a.strategy), perRound: Number(a.per_round),
      roundsLeft: Number(a.rounds_left), balance: Number(a.balance), keep: Number(a.keep), target: Number(a.target), lastMs: Number(a.last_ms),
      seatRound: Number(s.miner.round_id), tickets: Number(s.tickets),
    };
  }).filter(Boolean);
}
// game::auto_live: the plan still has a round to play. `ready` adds the vault's 20 seconds between rounds.
const live = p => p.on && p.roundsLeft > 0 && p.perRound >= MIN_ROUND && p.balance >= p.perRound + p.keep && (p.target === 0 || p.balance < p.target);
const ready = (p, now) => live(p) && now >= p.lastMs + GAP_MS;

// ---------- transactions ----------
const lat = [];
async function send(label, list) {
  let ok = true;
  for (let i = 0; i < list.length; i += BATCH) {
    const tx = new Transaction();
    tx.setSender(me);
    tx.setGasBudget(GAS);
    tx.moveCall({ target: C("game::auto_run"), arguments: [boardArg(tx), vaultArg(tx), treasuryArg(tx), tx.pure.vector("address", list.slice(i, i + BATCH)), tx.object.random(), tx.object.clock()] });
    const t0 = Date.now();
    const r0 = await node.signAndExecuteTransaction({ transaction: tx, signer, include: { effects: true, balanceChanges: true } });
    const r = r0.Transaction || r0.FailedTransaction;
    lat.push(Date.now() - t0); if (lat.length > 20) lat.shift();
    const change = (r.balanceChanges || []).filter(c => c.address === me && c.coinType.endsWith("::sui::SUI")).reduce((a, c) => a + BigInt(c.amount), 0n);
    log({ ev: label, ok: r.status.success, players: Math.min(BATCH, list.length - i), digest: r.digest, sui: sui(change), err: r.status.success ? undefined : r.status.error?.message || String(r.status.error) });
    await node.waitForTransaction({ digest: r.digest }).catch(() => {});
    ok &&= r.status.success;
  }
  return ok;
}
// How long before deposits close the Hunter call is sent: the slowest recent call plus a margin.
function lead() {
  const s = [...lat].sort((a, b) => a - b);
  return Math.max(LEAD_MIN, (s.length ? s[Math.floor(s.length * 0.9)] : 1500) + 700);
}

async function main() {
  log({ ev: "start", address: me });
  let errors = 0, low = false, listedAt = 0, balAt = 0, bal = 0n;
  let watch = new Map();        // accounts with something to do: a plan that can play, a round to claim, tickets to add
  const tried = new Map();      // address -> the round it was last sent in to play
  const claimTried = new Map(); // address -> the round a claim-only call was last sent in
  let hunted = 0;
  for (;;) {
    beat();
    try {
      if (Date.now() - balAt > 60_000) { bal = BigInt((await node.getBalance({ owner: me })).balance.balance); balAt = Date.now(); }
      if (bal < KEEP) { if (!low) log({ ev: "low balance", sui: sui(bal) }); low = true; balAt = 0; await sleep(20_000); continue; }
      low = false;
      // The whole vault every LIST_MS (a new player is picked up within that time); between those, only
      // the accounts with something to do are read.
      if (Date.now() - listedAt > LIST_MS) {
        const all = await read(await listAccounts());
        watch = new Map(all.filter(p => live(p) || p.seatRound !== 0 || p.tickets > 0).map(p => [p.address, p.field]));
        listedAt = Date.now();
      }
      if (!watch.size) { await sleep(3000); continue; }
      const b = await board();
      if (b.paused === true) { await sleep(5000); continue; }
      const cur = Number(b.cur_id), end = Number(b.cur_end_ms), freeze = Number(b.freeze_ms), started = b.cur_started === true;
      const ps = await read(watch);
      const now = Date.now();
      // The round takes deposits for at least 1.5s more (or no round is live: a deposit starts one).
      const open = !started || now < end - freeze - 1500;
      // A seat round below the current one is settled and waits to be claimed.
      const owed = ps.filter(p => p.seatRound !== 0 && p.seatRound < cur && claimTried.get(p.address) !== cur);
      // Tickets still waiting in the seat of a plan with no round left to play.
      const idle = ps.filter(p => !live(p) && p.seatRound === 0 && p.tickets > 0 && claimTried.get(p.address) !== cur);
      const early = open ? ps.filter(p => p.strategy !== HUNTER && p.seatRound !== cur && tried.get(p.address) !== cur && ready(p, now)) : [];
      if (early.length || owed.length || idle.length) {
        // One call: it claims everyone owed, then plays every Spread and Sniper plan that is ready.
        const list = [...new Set([...early, ...owed, ...idle].map(p => p.address))];
        if (await send(early.length ? `play #${cur}` : `claim before #${cur}`, list)) {
          early.forEach(p => tried.set(p.address, cur));
          list.forEach(a => claimTried.set(a, cur));
          errors = 0; balAt = 0;
        } else await sleep(Math.min(30_000, 1000 * 2 ** Math.min(5, errors++)));
        continue;
      }
      const hunters = ps.filter(p => p.strategy === HUNTER && p.seatRound !== cur && live(p));
      if (started && hunters.length && hunted !== cur && now < end - freeze) {
        const at = end - freeze - lead();
        if (now < at - 1200) { await sleep(Math.min(1000, at - 1200 - now)); continue; }
        if (now < at) await sleep(at - now);
        // The contract takes Hunters only in the last HUNT_MS before deposits close.
        if (Date.now() >= end - freeze - HUNT_MS && Date.now() < end - freeze - 600) { await send(`hunt #${cur}`, hunters.map(p => p.address)); balAt = 0; }
        hunted = cur;
        continue;
      }
      errors = 0;
      await sleep(started ? Math.min(1000, Math.max(300, end + 400 - now)) : 700);
    } catch (e) {
      log({ ev: "error", msg: String(e.message || e).slice(0, 300) });
      await sleep(Math.min(30_000, 1000 * 2 ** Math.min(5, errors++)));
    }
  }
}

main();
