// GTStar Player: the strategy wallet. It plays only rounds a real player is in (never rounds that hold
// only our own bots, the Runner and the Pulse): the minimum on one empty tile within seconds of the start,
// then a top-up in the last seconds before the deploy freeze, only on tiles that hold too little SUI for
// the pot around them.
//
// The top-up: read the board from a fullnode, wait until LEAD before the round end, and pick up to
// max_tiles tiles by the exact expected value of the whole deposit (one tile at a time, 0.01 SUI steps):
//   EV = 1/25 * sum over our tiles w of [x_w + win * (total - D_w - x_w) * x_w / (D_w + x_w)] - sum x
//        + Wealth Fund tickets (fee * expected SUI lost), valued at DILUTION * fund * mine / (all + mine)
// where D_w is what others hold on w, total is the round after our deposit and win = 1 - fees.
// Mined GTS counts as zero. It deploys only when EV beats gas + margin.
// Money left at the end: one tile at a time the marginal gain of a 0.01 SUI step is concave, so the
// greedy fill is the exact optimum for a single wallet.
//
// After the round: the keeper draws it (this wallet draws only if nobody did within SETTLE_AFTER_MS),
// then it claims at once (claim adds the Wealth Fund tickets and must come before the next deploy).
// Late money: the board is read again after the freeze; SUI others added after our read lands in the
// log, and its average on our tiles is added to D in the next rounds (moving earlier cannot help:
// who comes after us still sees our deposit).
// Mined GTS: once its 7-day clock has passed (no withdraw fee) it is withdrawn and staked (7-day lock),
// never sold. SUI yield from staking is claimed back into the bankroll once a day.
// Limits: at most ROUND_PCT of the bankroll a round, stops for the UTC day after DAILY_LOSS, and stops
// for good when the game package, the UpgradeCap or any game setting changes (restart: delete
// "stopped" from .player-state.json).
// Runs as its own long process (started by cron.mjs); signs with PLAYER_KEY.
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
const num = (k, d) => Number(process.env[k] ?? d);
const ROUND_PCT = num("PLAYER_ROUND_PCT", 1);                  // % of the bankroll a round at most
const DAILY_LOSS = num("PLAYER_DAILY_LOSS_MIST", 250_000_000); // 0.25 SUI down in a UTC day: pause to 00:00
const GAS_EST = num("PLAYER_GAS_MIST", 4_000_000);             // deploy + claim, net of rebates
const MARGIN = num("PLAYER_MARGIN_MIST", 3_000_000);           // EV must beat gas by this much
const KEEP = num("PLAYER_KEEP_MIST", 50_000_000);              // never deposit the last 0.05 SUI (gas)
const LEAD_MIN = num("PLAYER_LEAD_MS", 6_500);                 // decide this long before the round end
const DILUTION = 0.5;                                           // tickets: half of today's fund per ticket
const SETTLE_AFTER_MS = 10_000;
const GAS_BUDGET = 50_000_000;

const BOARD = CFG.board, TREASURY = CFG.treasury;
const UPGRADE_CAP = "0xe94fdc95c476e7b0fdc89c881ab5e8413a5745f31586ef8edab95f2a38d922b1";
const C = f => `${CFG.package}::${f}`;
const MINER = `${CFG.origin}::game::Miner`;
// Board dynamic fields, typed by the package version that added them.
const KEY = {
  tickets: "0x7c1288891489591765402a61bee62df34a68de25ffb0459d6e83c020f4ae5c42::game::TicketsKey",
  fundBps: "0x7c1288891489591765402a61bee62df34a68de25ffb0459d6e83c020f4ae5c42::game::FundBpsKey",
  stakeBps: `${CFG.stakePkg}::game::StakeBpsKey`,
  maxTiles: "0xa32053565e5bb314e5caadeb1f2934f3597eab4e1602c0840d4137116f3e952e::game::MaxTilesKey",
  refineClock: "0xfd20b3584720559b109870c1bb295295fcfa21774520500eea9f6253493b551f::game::RefineClockKey",
  unrefined: `${CFG.origin}::game::UnrefinedKey`,
};
const WEEK = 604_800_000;
const RUNNER = "0xab4deb30e34487f75bf5632038e46d419c6238b4ea52d35f3ad3421a5bb268fa";
const PULSE = "0xb5a4e8803b347c52b8ad0a144f23da825e80f7db2777e608a2dbaf9b5006bc08";
const SEAT = `${CFG.origin}::game::SeatKey`;
const seatBcs = (round, a) => { const r = new Uint8Array(40); let v = BigInt(round); for (let i = 0; i < 8; i++) { r[i] = Number(v & 255n); v >>= 8n; } r.set(Uint8Array.from(Buffer.from(a.slice(2), "hex")), 8); return r; };
const DEV_BPS = 100, BUYBACK_BPS = 200, LIQ_BPS = 100;

const key = process.env.PLAYER_KEY;
if (!key) { console.log("PLAYER_KEY not set"); process.exit(0); }
const signer = Ed25519Keypair.fromSecretKey(key);
const me = signer.toSuiAddress();
const node = new SuiGrpcClient({ network: CFG.network, baseUrl: `https://fullnode.${CFG.network}.sui.io:443` });
const sleep = ms => new Promise(r => setTimeout(r, Math.max(0, ms)));
const sui = m => Math.round(Number(m) / 1e6) / 1e3;

// One instance only: a second copy exits while the first one runs.
const pidFile = path.join(dir, ".player-pid");
try {
  const pid = fs.readFileSync(pidFile, "utf8").trim();
  if (fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").includes("player.mjs")) { console.log("player already running"); process.exit(0); }
} catch {}
fs.writeFileSync(pidFile, String(process.pid));
const stateFile = path.join(dir, ".player-state.json");
const logFile = path.join(dir, "player-log.jsonl");
const hbFile = path.join(dir, ".player-hb");
const state = (() => { try { return JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch { return {}; } })();
state.lat ??= [];      // last deploy latencies, ms
state.late ??= 0;      // average SUI (mist) others add to one of our tiles after our read
const save = () => fs.writeFileSync(stateFile, JSON.stringify(state));
const log = o => fs.appendFileSync(logFile, JSON.stringify({ t: new Date().toISOString(), ...o }) + "\n");
const beat = () => { const t = new Date(); try { fs.utimesSync(hbFile, t, t); } catch { fs.writeFileSync(hbFile, ""); } };

// ---------- chain reads ----------
async function board() {
  return (await node.getObject({ objectId: BOARD, include: { json: true } })).object.json;
}
function u64(bytes, at = 0) { let v = 0n; for (let i = 7; i >= 0; i--) v = (v << 8n) | BigInt(bytes[at + i]); return v; }
async function field(type, bcs) {
  try {
    const r = await node.getDynamicField({ parentId: BOARD, name: { type, bcs } });
    return r.dynamicField.value.bcs;
  } catch { return null; }
}
const unit = new Uint8Array([0]);
const addrBytes = a => Uint8Array.from(Buffer.from(a.slice(2).padStart(64, "0"), "hex"));
async function extras() {
  const [t, f, s, m] = await Promise.all([field(KEY.tickets, unit), field(KEY.fundBps, unit), field(KEY.stakeBps, unit), field(KEY.maxTiles, unit)]);
  return {
    tickets: t ? u64(t, 8) : 0n,
    fundBps: f ? Number(u64(f)) : 0,
    stakeBps: s ? Number(u64(s)) : 0,
    maxTiles: m ? Number(u64(m)) : 25,
  };
}
async function wallet() {
  const bal = (await node.getBalance({ owner: me })).balance;
  let miner = null;
  for (let cursor = null; ;) {
    const r = await node.listOwnedObjects({ owner: me, type: MINER, include: { json: true }, cursor });
    for (const o of r.objects) if (!miner) miner = { id: o.objectId, round: Number(o.json.round_id), total: BigInt(o.json.total_deployed), deployed: o.json.deployed.map(Number) };
    if (!r.hasNextPage) break;
    cursor = r.cursor;
  }
  cache = { balance: BigInt(bal.balance), miner };
  return cache;
}
let cache = null; // last wallet read, kept current after our own transactions (saves a read at a round start)

// Players in the round other than our own wallets (this one, the Runner, the Pulse).
async function realPlayers(b) {
  const cur = Number(b.cur_id);
  const seated = await Promise.all([me, RUNNER, PULSE].map(a => field(SEAT, seatBcs(cur, a))));
  return Number(b.cur_players) - seated.filter(Boolean).length;
}

// ---------- kill switch ----------
// Package version, UpgradeCap version and every game setting. Any change stops the bot for good.
async function fingerprint(b, x) {
  const cap = (await node.getObject({ objectId: UPGRADE_CAP, include: { json: true } })).object.json;
  return JSON.stringify([b.version, cap.version, cap.package, b.round_ms, b.freeze_ms, b.min_deploy, b.vault_bps,
    b.ml_odds, b.refine_fee_bps, b.paused, x.fundBps, x.stakeBps, x.maxTiles]);
}
async function guard(b, x) {
  const fp = await fingerprint(b, x);
  if (!state.fp) { state.fp = fp; save(); return true; }
  if (fp === state.fp) return true;
  state.stopped = `game changed: ${state.fp} -> ${fp}`;
  save();
  log({ ev: "stopped", reason: state.stopped });
  return false;
}

// ---------- strategy ----------
// SUI values in mist as Numbers (all far below 2^53).
function expected(x, D, S, win, fee, fund, tickets) {
  let sum = 0, pay = 0;
  for (let i = 0; i < 25; i++) sum += x[i];
  if (!sum) return 0;
  const total = S + sum;
  for (let i = 0; i < 25; i++) if (x[i] > 0) pay += x[i] + win * (total - D[i] - x[i]) * x[i] / (D[i] + x[i]);
  const mine = fee * (sum - sum / 25);
  const bonus = fund > 0 ? DILUTION * fund * mine / (tickets + mine) : 0;
  return pay / 25 - sum + bonus;
}
// Starts from what we already hold this round (x0); budget counts it.
function plan(D, S, budget, step, maxTiles, win, fee, fund, tickets, x0) {
  const x = x0.slice();
  let used = x.reduce((a, v) => a + v, 0), tiles = x.filter(Boolean).length;
  let base = expected(x, D, S, win, fee, fund, tickets);
  while (used + step <= budget) {
    let best = -1, gain = 0;
    for (let i = 0; i < 25; i++) {
      if (!x[i] && tiles >= maxTiles) continue;
      x[i] += step;
      const g = expected(x, D, S, win, fee, fund, tickets) - base;
      x[i] -= step;
      if (g > gain) { gain = g; best = i; }
    }
    if (best < 0) break;
    if (!x[best]) tiles++;
    x[best] += step; used += step; base += gain;
  }
  return { x, ev: base, used };
}

// ---------- transactions ----------
async function send(label, build) {
  const tx = new Transaction();
  tx.setSender(me);
  tx.setGasBudget(GAS_BUDGET);
  build(tx);
  const t0 = Date.now();
  const r0 = await node.signAndExecuteTransaction({ transaction: tx, signer, include: { balanceChanges: true, effects: true } });
  const r = r0.Transaction || r0.FailedTransaction;
  const ms = Date.now() - t0;
  const change = (r.balanceChanges || []).filter(c => c.address === me && c.coinType.endsWith("::sui::SUI")).reduce((a, c) => a + BigInt(c.amount), 0n);
  const ok = r.status.success;
  const done = Date.now();
  log({ ev: label, ok, digest: r.digest, ms, sui: sui(change), err: ok ? undefined : r.status.error?.message || String(r.status.error) });
  await node.waitForTransaction({ digest: r.digest }).catch(() => {});
  return { ok, ms, change, done };
}
const boardArg = tx => tx.sharedObjectRef({ objectId: BOARD, initialSharedVersion: 1, mutable: true });
const treasuryArg = tx => tx.sharedObjectRef({ objectId: TREASURY, initialSharedVersion: 1, mutable: true });
function claimInto(tx, minerId) {
  const s = tx.moveCall({ target: C("game::claim_sui"), arguments: [boardArg(tx), tx.object(minerId), treasuryArg(tx)] });
  tx.mergeCoins(tx.gas, [s]);
}

// ---------- round flow ----------
let entered = 0;       // round joined at its start
let joined = 0;        // round topped up in (or decided not to)
let skipped = 0;       // round decided not to join
let topped = 0;        // round the late top-up landed in
let recorded = 0;      // round whose final board is logged
let pick = null;       // what was read and deployed this round
let lastChores = 0;
let owe = true;        // a round may still wait to be claimed (checked once at start)

function lead(freeze) {
  const lat = [...state.lat].sort((a, b) => a - b);
  const p90 = lat.length ? lat[Math.floor(lat.length * 0.9)] : 1500;
  return Math.max(LEAD_MIN, freeze + p90 + 700);
}

// Within seconds of the start of a round a real player is in: the minimum on one empty tile (a random
// one; the thinnest tile when none is empty).
async function enter(b) {
  const cur = Number(b.cur_id);
  entered = cur;
  const w = cache || await wallet();
  if (w.miner && w.miner.round === cur) return;
  const step = Number(b.min_deploy);
  if (Number(w.balance) < step + KEEP + GAS_BUDGET) { log({ ev: "skip", round: cur, why: "bankroll", balance: sui(w.balance) }); return; }
  // Not in a round that holds only our own bots (a real player may still join: decide() looks again).
  if (await realPlayers(b) < 1) { log({ ev: "skip", round: cur, why: "no real player" }); return; }
  const pending = w.miner && w.miner.round !== 0 && w.miner.round < cur ? w.miner : null;
  const D = b.cur_deployed.map(Number);
  const low = Math.min(...D);
  const pool = D.map((d, i) => d === low ? i : -1).filter(i => i >= 0);
  const tile = pool[Math.floor(Math.random() * pool.length)];
  const x = Array(25).fill(0);
  x[tile] = step;
  const r = await send(`enter #${cur}`, tx => {
    if (pending) claimInto(tx, pending.id);
    let m = w.miner ? tx.object(w.miner.id) : null, fresh = false;
    if (!m) { [m] = tx.moveCall({ target: C("game::new_miner") }); fresh = true; }
    const [pay] = tx.splitCoins(tx.gas, [step]);
    tx.moveCall({ target: C("game::deploy"), arguments: [boardArg(tx), m, pay, tx.pure.vector("u64", x), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], me);
  });
  log({ ev: "entered", round: cur, ok: r.ok, tile: tile + 1, afterStartMs: r.done - Number(b.cur_start_ms) });
  if (r.ok) owe = true;
  await wallet();
}

async function decide(cur) {
  const [b, x, w] = await Promise.all([board(), extras(), wallet()]);
  if (Number(b.cur_id) !== cur || !b.cur_started) return;
  if (!(await guard(b, x))) return;
  if (await realPlayers(b) < 1) { skipped = cur; log({ ev: "skip", round: cur, why: "no real player" }); return; }
  const x0 = w.miner && w.miner.round === cur ? w.miner.deployed : Array(25).fill(0);
  const pending = w.miner && w.miner.round !== 0 && w.miner.round < cur ? w.miner : null;

  // Daily loss cap, by UTC day.
  const day = new Date().toISOString().slice(0, 10);
  if (state.day !== day) { state.day = day; state.dayStart = Number(w.balance) + (pending ? Number(pending.total) : 0); save(); }
  if (Number(w.balance) < state.dayStart - DAILY_LOSS) { skipped = cur; log({ ev: "skip", round: cur, why: "daily loss cap" }); return; }

  const step = Number(b.min_deploy);
  let budget = Math.floor(Number(w.balance) * ROUND_PCT / 100 / step) * step;
  budget = Math.min(budget, Math.floor((Number(w.balance) - KEEP - GAS_BUDGET) / step) * step);
  if (budget < step) { skipped = cur; log({ ev: "skip", round: cur, why: "bankroll", balance: sui(w.balance) }); return; }

  // Others only: the board less what we already hold.
  const D = b.cur_deployed.map((d, i) => Number(d) - x0[i]);
  const S = Number(b.cur_total) - x0.reduce((a, v) => a + v, 0);
  const fee = (DEV_BPS + Number(b.vault_bps) + BUYBACK_BPS + LIQ_BPS + x.stakeBps + x.fundBps) / 10_000;
  // Expected late money is added to every tile we might pick (and to the round total with it).
  const late = Math.round(state.late);
  const Dl = D.map(d => d + late);
  const args = [Dl, S + late, budget, step, x.maxTiles, 1 - fee, fee, Number(b.motherlode), Number(x.tickets)];
  const p = plan(...args, x0);
  const add = p.x.map((v, i) => v - x0[i]);
  const used = add.reduce((a, v) => a + v, 0);
  const gain = p.ev - expected(x0, ...args.slice(0, 2), ...args.slice(5));
  const need = GAS_EST + MARGIN;
  pick = { round: cur, D, x: p.x, x0 };
  if (!used || gain <= need) {
    joined = cur;
    log({ ev: "skip", round: cur, why: "ev", evSui: sui(gain), pot: sui(S), late: sui(late) });
    return;
  }
  const tiles = add.map((a, i) => a ? `${i + 1}:${sui(a)}` : "").filter(Boolean).join(" ");
  const r = await send(`deploy #${cur}`, tx => {
    if (pending) claimInto(tx, pending.id);
    let m = w.miner ? tx.object(w.miner.id) : null, fresh = false;
    if (!m) { [m] = tx.moveCall({ target: C("game::new_miner") }); fresh = true; }
    const [pay] = tx.splitCoins(tx.gas, [used]);
    tx.moveCall({ target: C("game::deploy"), arguments: [boardArg(tx), m, pay, tx.pure.vector("u64", add), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], me);
  });
  state.lat = [...state.lat, r.ms].slice(-20);
  save();
  log({ ev: "pick", round: cur, ok: r.ok, tiles, evSui: sui(gain), used: sui(used), pot: sui(S), fund: sui(b.motherlode), late: sui(late), lead: lead(Number(b.freeze_ms)) });
  if (r.ok) { joined = topped = cur; owe = true; } else skipped = cur;
  await wallet();
}

// After the freeze: what others added after our read.
async function record(b) {
  const cur = Number(b.cur_id);
  recorded = cur;
  if (!pick || pick.round !== cur) return;
  const F = b.cur_deployed.map(Number);
  const mine = topped === cur ? pick.x : pick.x0;
  let onOurs = 0, ours = 0, all = 0;
  for (let i = 0; i < 25; i++) {
    const add = F[i] - pick.D[i] - mine[i];
    all += add;
    if (pick.x[i]) { onOurs += add; ours++; }
  }
  // Moving average of late SUI on one of the tiles we picked.
  if (ours) state.late = state.late * 0.8 + (onOurs / ours) * 0.2;
  save();
  log({ ev: "final", round: cur, topped: topped === cur, lateOnOurs: sui(onOurs), lateAll: sui(all), finalPot: sui(b.cur_total), lateAvg: sui(state.late) });
}

// Claim as soon as the round is drawn; draw it ourselves only if nobody did.
async function afterRound(b) {
  if (!owe) return false;
  const w = await wallet();
  const cur = Number(b.cur_id);
  if (w.miner && w.miner.round !== 0 && w.miner.round < cur) {
    await send(`claim #${w.miner.round}`, tx => claimInto(tx, w.miner.id));
    await wallet();
    return true;
  }
  if (!w.miner || w.miner.round === 0) { owe = false; return false; }
  if (b.cur_started && w.miner?.round === cur && Date.now() > Number(b.cur_end_ms) + SETTLE_AFTER_MS) {
    await send(`settle #${cur}`, tx => tx.moveCall({ target: C("game::settle"), arguments: [boardArg(tx), treasuryArg(tx), tx.object.random(), tx.object.clock()] }));
    return true;
  }
  return false;
}

// Every 6 hours while idle: stake mined GTS once it is free to withdraw, take the staking SUI yield.
async function chores() {
  lastChores = Date.now();
  const u = await field(KEY.unrefined, addrBytes(me));
  const clock = await field(KEY.refineClock, addrBytes(me));
  const amount = u ? u64(u) : 0n;
  const free = clock && Date.now() >= Number(u64(clock)) + WEEK;
  if (amount > 0n && free) {
    await send("stake gts", tx => {
      const g = tx.moveCall({ target: C("game::withdraw_gts_v6"), arguments: [boardArg(tx), treasuryArg(tx), tx.object.clock()] });
      tx.moveCall({ target: C("game::stake"), arguments: [boardArg(tx), g, tx.pure.bool(true), tx.object.clock()] });
    });
    state.staked = true; save();
  }
  if (state.staked && Date.now() - (state.yieldAt || 0) >= 86_400_000) {
    await send("claim yield", tx => { const s = tx.moveCall({ target: C("game::claim_yield"), arguments: [boardArg(tx)] }); tx.mergeCoins(tx.gas, [s]); });
    state.yieldAt = Date.now(); save();
  }
}

async function main() {
  log({ ev: "start", address: me });
  let errors = 0;
  while (!state.stopped) {
    beat();
    try {
      const b = await board();
      const cur = Number(b.cur_id), end = Number(b.cur_end_ms), freeze = Number(b.freeze_ms);
      const now = Date.now();
      if (b.cur_started && entered !== cur && now < end - freeze - 1000) { await enter(b); continue; }
      if (b.cur_started && now < end - freeze) {
        const at = end - lead(freeze);
        if (joined !== cur && skipped !== cur) {
          if (now < at - 1500) { await sleep(Math.min(1000, at - 1500 - now)); continue; }
          if (now < at) await sleep(at - now);
          if (Date.now() < end - freeze - 1000) await decide(cur); else skipped = cur;
          continue;
        }
        await sleep(Math.min(1000, end - freeze + 300 - now));
        continue;
      }
      if (b.cur_started && now < end + 1000 && recorded !== cur && (joined === cur || skipped === cur)) { await record(b); continue; }
      if ((!b.cur_started || now >= end) && await afterRound(b)) continue;
      if (!b.cur_started && Date.now() - lastChores > 6 * 3600_000) { await chores(); continue; }
      errors = 0;
      await sleep(b.cur_started ? 500 : 150);
    } catch (e) {
      log({ ev: "error", msg: String(e.message || e).slice(0, 300) });
      await sleep(Math.min(30_000, 1000 * 2 ** Math.min(5, errors++)));
    }
  }
  console.log(`player stopped: ${state.stopped}`);
}

main();
