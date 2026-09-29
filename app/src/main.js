// GTStar dApp — static and non-custodial. Every player signs with their own wallet.
import { Transaction } from "@mysten/sui/transactions";
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { SuiGrpcClient } from "@mysten/sui/grpc";
import { getWallets } from "@wallet-standard/app";
import { signAndExecuteTransaction } from "@mysten/wallet-standard";
import { SlushWallet, SLUSH_WALLET_ICON } from "@mysten/slush-wallet";

const CFG = window.GTSTAR_CONFIG;
const IDS = CFG.ids;
const CHAIN = `sui:${CFG.network}`;
const GQL = `https://graphql.${CFG.network}.sui.io/graphql`;
const SCAN = `https://suiscan.xyz/${CFG.network}`;
const MIST = 1e9;
// Emission at launch (game::init): 1 GTS a round, -1.425% every 15,658 rounds, stops at 1,000,000 GTS.
// The live values come from the Board (STATE.em) and can be changed by the owner at once.
const MAX_GTS = 1_000_000;
const LAUNCH_EM = { reward: 1e9, step: 15_658, decay: 14_250, count: 0, full: 1e9, committed: 0 };
const T = name => `${IDS.package}::${name}`;          // game package (upgradeable): types and events
const C = name => `${IDS.latest || IDS.package}::${name}`; // latest game version: calls
const TK = name => `${IDS.token}::${name}`;           // token package (immutable)
const T_MINER = T("game::Miner"), T_GTS = TK("gts::GTS");
// One package holds the whole relaunch game: the Wealth Fund, the fair split and unrefined GTS from round 1.
const ML_PKG = IDS.package;
const REFINE_PKG = IDS.package;
const REFINE_FEE = 0.1;                           // withdraw fee at launch; the live value is STATE.refineFee
const REFINE_SCALE = 10n ** 18n;
const HOUSE = "0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a"; // never keeps Wealth Fund SUI
const EV = { ml: `${ML_PKG}::game::MotherlodeUpdate`, settled: T("game::RoundSettled"), deployed: T("game::Deployed"), redeemed: TK("gts::Redeemed") };
const VIEWS = ["home", "mine", "trade", "stake", "explorer", "tokenomics", "learn"];
// Staking (game v3): its types were introduced by that version.
const STK_PKG = IDS.stake;
const STAKE_SCALE = 10n ** 18n;
const EV_STAKE_REWARD = STK_PKG ? `${STK_PKG}::staking::StakeRewarded` : "";
// Wealth Fund tickets (game v4): its types were introduced by that version. The fund pays one ticket,
// drawn by weight; a ticket is one mist of fee paid on SUI lost since the last payout.
const WF_PKG = IDS.wf;
const EV_WF_WON = WF_PKG ? `${WF_PKG}::game::WealthFundWon` : "";
// Withdraw clock (game v6): free once 7 days have passed since the last withdrawal (or first mining);
// before that the fee falls linearly from the full fee to 0 and is burned.
const V6_PKG = IDS.v6;
const REFINE_WINDOW_MS = 7 * 86_400_000;

const $ = id => document.getElementById(id);
const num = x => Number(x || 0);
const short = s => (s ? s.slice(0, 6) + "…" + s.slice(-4) : "");
// Usernames players set for their address (served by names.php); falls back to the short address.
let NAMES = {};
const nameOf = a => NAMES[a] || "";
const label = a => nameOf(a) || short(a);
// GTStar Bot 1 and 2 (keeper/bots.mjs) and the Matcher (keeper/matcher.mjs) are left off the leaderboard.
const BOTS = new Set(["0xab4deb30e34487f75bf5632038e46d419c6238b4ea52d35f3ad3421a5bb268fa", "0x779b49acf4db04d835440c12ffe24929de505a9b8112b4040da5103d225b37e7", "0x2a869532f55594a9ffed4a5d7ee2a48cf5c857ac740090d39c733e0279b6a8de", "0x0b8d118f954c90a87abc2b3e07c408681efed88b552ebcd94fc5cb292f3c9dc4"]);
const fmt = (n, d = 4) => Number(n).toLocaleString("en-US", { maximumFractionDigits: d });
const sui = (mist, d = 4) => fmt(mist / MIST, d);
const parseAmt = v => { const x = parseFloat(String(v).replace(/,/g, "")); return isFinite(x) && x > 0 ? x : 0; };
const toMist = v => Math.round(parseAmt(v) * MIST);
const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
function ago(ts) {
  const s = Math.max(0, (Date.now() - new Date(ts).getTime()) / 1000);
  if (s < 60) return `${Math.floor(s)}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

let wallet = null, account = null;
let WELCOME = null, welcomePoll = null, WELCOME_OPEN = false; // two free rounds (see welcome.php)
let STATE = null, USER = null, HIST = null;
let selected = new Set();
let busy = false, view = "home";
let userAt = 0, txAt = 0;   // when the wallet view was last loaded, and when we last sent a transaction

// ---------- chain reads ----------
// Every read has a time limit, and a read with no answer after 1.5 seconds is sent again in parallel:
// the public indexer sometimes stalls one request for many seconds while a second one answers at once.
function gqlOnce(query, ms) {
  const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), ms);
  return fetch(GQL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ query }), signal: ctl.signal })
    .then(r => r.json()).then(j => { if (j.errors) throw new Error(j.errors[0].message); return j.data; })
    .finally(() => clearTimeout(timer));
}
function gql(query) {
  return new Promise((resolve, reject) => {
    let sent = 0, failed = 0, done = false, hedge;
    const finish = (f, x) => { if (!done) { done = true; clearTimeout(hedge); f(x); } };
    const go = () => {
      sent++;
      gqlOnce(query, 6000).then(d => finish(resolve, d), e => {
        failed++;
        if (!(e.name === "AbortError" || e instanceof TypeError)) return finish(reject, e);
        if (sent < 2) { clearTimeout(hedge); go(); } else if (failed >= sent) finish(reject, e);
      });
    };
    go(); hedge = setTimeout(() => { if (!done && sent < 2) go(); }, 1500);
  });
}
const objQ = (alias, id) => `${alias}:object(address:"${id}"){asMoveObject{contents{json}}}`;
const pick = (d, k) => d[k]?.asMoveObject?.contents?.json || {};

const settledRow = (j, ts) => ({
  round: num(j.round_id), tile: num(j.winning_square), total: num(j.total_deployed),
  winners: num(j.winners_total), payout: num(j.winners_payout), reward: num(j.round_reward),
  vault: num(j.vault_fee), dev: num(j.dev_fee), players: num(j.players), ts,
});
// Motherlode events by round: SUI a round rolled into it (added) or received from it (paid).
// `winner`: the ticket holder it was paid to (game v4); before v4 it went to the winning tile.
const mlRows = (nodes, won = new Map()) => new Map(nodes.map(j => [num(j.round_id), { added: num(j.added), paid: num(j.paid), balance: num(j.balance), winner: won.get(num(j.round_id)) || null }]));
const wonRows = nodes => new Map(nodes.map(j => [num(j.round_id), j.winner]));
const withMl = (r, ml) => ({ ...r, ml: ml.get(r.round) || null });
// SUI a settled round added to the reserve: the event's vault_fee (a no-winner round's rest included),
// plus what winners did not keep at claim (the fair split).
const vaulted = r => r.vault + (r.split?.reserve || 0);
// Rounds 1-20 used the fair split (a spread deposit kept only part of its share). From round 21 (the first
// round settled by the v5 rules, V5FromKey on the Board) winners keep their full share and GTS goes by SUI lost.
const FAIR_FROM = 1, V5_FROM = 21;
// Relaunch game published (deployments/mainnet.json publishedAt).
const GAME_LAUNCH = Date.parse("2026-09-29T10:20:50Z");
const isFair = n => n >= FAIR_FROM && n < V5_FROM;
// GTS a player mined in settled round r: by SUI lost from V5_FROM, by SUI deployed before.
const gtsOf = (r, onWin, tot) => r.round >= V5_FROM
  ? (r.total > r.winners ? r.reward * (tot - onWin) / (r.total - r.winners) : 0)
  : (r.total ? r.reward * tot / r.total : 0);
// What a player gets from settled round r, exactly as game::claim computes it: `onWin` on the winning
// tile out of `tot` deployed in the round. back = SUI paid out (stake included); reserve / fund = the
// part of the share not kept (the share scales with onWin / tot; House bots keep no Wealth Fund SUI).
function payoutOf(r, onWin, tot, player) {
  const out = { back: 0, reserve: 0, fund: 0 };
  if (!(onWin > 0 && r.winners > 0)) return out;
  const md = (a, b, c) => Number((BigInt(a) * BigInt(b)) / BigInt(c));
  const share = md(r.payout, onWin, r.winners);
  const jackpot = r.ml?.paid > 0 && !r.ml.winner ? md(r.ml.paid, onWin, r.winners) : 0;
  const potShare = share - jackpot, fair = isFair(r.round) && tot > 0;
  const potKept = fair ? md(potShare, onWin, tot) : potShare;
  const jpKept = player === HOUSE || BOTS.has(player) ? 0 : fair ? md(jackpot, onWin, tot) : jackpot;
  return { back: onWin + potKept + jpKept, reserve: potShare - potKept, fund: jackpot - jpKept };
}
// Per player in a round: SUI on the winning tile and in total, from Deployed events.
function playersOf(r, list) {
  const agg = new Map();
  list.forEach(d => { const a = agg.get(d.player) || { onWin: 0, total: 0 }; a.onWin += d.amounts[r.tile] || 0; a.total += d.total; agg.set(d.player, a); });
  return agg;
}
// Fair-split rounds: SUI winners kept from the other tiles, and what went back to the reserve and the fund.
function splitOf(r, list) {
  if (!isFair(r.round) || !r.winners) return null;
  const s = { kept: 0, reserve: 0, fund: 0 };
  playersOf(r, list).forEach((a, p) => { const x = payoutOf(r, a.onWin, a.total, p); if (x.back) { s.kept += x.back - a.onWin; s.reserve += x.reserve; s.fund += x.fund; } });
  return s;
}
const wonFromOthers = r => (r.winners > 0 ? (r.split ? r.split.kept : r.payout) : 0);
async function loadGlobal() {
  const d = await gql(`{${objQ("b", IDS.board)} ${objQ("t", IDS.treasury)}${IDS.market ? " " + objQ("m", IDS.market) : ""}
    st:events(filter:{type:"${EV.settled}"},last:12){nodes{timestamp contents{json}}}
    dp:events(filter:{type:"${EV.deployed}"},last:50){nodes{timestamp transaction{digest} contents{json}}}
    mu:events(filter:{type:"${EV.ml}"},last:12){nodes{contents{json}}}
    ${STK_PKG ? `sk:object(address:"${IDS.board}"){p:dynamicField(name:{type:"${STK_PKG}::game::StakeKey",bcs:"AA=="}){value{... on MoveValue{json}}} bp:dynamicField(name:{type:"${STK_PKG}::game::StakeBpsKey",bcs:"AA=="}){value{... on MoveValue{json}}}}
    sr:events(filter:{type:"${EV_STAKE_REWARD}"},last:50){nodes{timestamp contents{json}}}` : ""}
    ${WF_PKG ? `wf:object(address:"${IDS.board}"){fb:dynamicField(name:{type:"${WF_PKG}::game::FundBpsKey",bcs:"AA=="}){value{... on MoveValue{json}}} tk:dynamicField(name:{type:"${WF_PKG}::game::TicketsKey",bcs:"AA=="}){value{... on MoveValue{json}}}}
    ww:events(filter:{type:"${EV_WF_WON}"},last:12){nodes{contents{json}}}` : ""}}`);
  const b = pick(d, "b"), t = pick(d, "t"), m = pick(d, "m");
  // Cetus pool is Pool<GTS, SUI>, both 9 decimals: price (SUI per GTS) = (sqrt_price / 2^64)^2.
  const sq = num(m.current_sqrt_price) / 2 ** 64;
  const supply = num(t.cap?.total_supply?.value), vault = num(t.vault);
  const minted = num(t.minted), tGenesis = 0;
  const ml = mlRows((d.mu?.nodes || []).map(n => n.contents?.json || {}), wonRows((d.ww?.nodes || []).map(n => n.contents?.json || {})));
  const tk = d.wf?.tk?.value?.json;
  const recent = (d.st?.nodes || []).map(n => withMl(settledRow(n.contents?.json || {}, n.timestamp), ml)).reverse();
  const deploys = (d.dp?.nodes || []).map(n => {
    const j = n.contents?.json || {};
    return { round: num(j.round_id), player: j.player, amounts: (j.amounts || []).map(num), total: num(j.total), ts: n.timestamp, digest: n.transaction?.digest };
  }).reverse();
  const board = await freshBoard(boardOf(b, tGenesis), tGenesis);
  return {
    supply, vault, minted, floor: supply > 0 ? vault / supply : 0, market: sq > 0 ? sq * sq : 0,
    motherlode: num(b.motherlode), mlOdds: num(b.ml_odds) || 1000,
    fundBps: num(d.wf?.fb?.value?.json), tickets: tk ? { epoch: num(tk.epoch), total: num(tk.total) } : null,
    refineFee: b.refine_fee_bps != null ? num(b.refine_fee_bps) / 10_000 : REFINE_FEE,
    em: emOf(b),
    stake: stakeOf(d),
    last: recent[0] || null, recent, deploys,
    board,
  };
}
// Staking pool (a dynamic field of the Board) and the SUI it earned over the last 7 days of rounds.
function stakeOf(d) {
  const p = d.sk?.p?.value?.json;
  if (!p) return null;
  const now = Date.now(), week = 7 * 86_400_000;
  const ev = (d.sr?.nodes || []).map(n => ({ t: new Date(n.timestamp).getTime(), a: num(n.contents?.json?.amount) }));
  const recent = ev.filter(e => now - e.t < week);
  // 50 events can cover less than a week: then scale by the time they span.
  const span = ev.length >= 50 && recent.length === ev.length ? Math.max(3600_000, now - Math.min(...ev.map(e => e.t))) : week;
  const yearly = recent.reduce((a, e) => a + e.a, 0) * (365.25 * 86_400_000 / span);
  return {
    bps: num(d.sk?.bp?.value?.json), amount: num(p.total_amount), weight: num(p.total_weight), paid: num(p.paid_total),
    acc: BigInt(p.acc || 0), table: p.positions?.id, yearly,
  };
}
// Emission state on the Board: the full reward of a round in this step, the step length, the cut at its
// end, rounds into the step, the deposit for the full reward, and GTS assigned to rounds so far.
const emOf = b => b.reward == null ? LAUNCH_EM : {
  reward: num(b.reward), step: num(b.step_rounds), decay: num(b.decay_ppm), count: num(b.step_count),
  full: num(b.full_reward_deploy), committed: num(b.committed),
};
const boardOf = (b, tGenesis) => ({
  genesis: num(b.genesis_ms) || tGenesis,
  cur_id: num(b.cur_id), cur_total: num(b.cur_total), cur_started: b.cur_started === true, cur_players: num(b.cur_players),
  round_ms: num(b.round_ms) || 60_000,
  cur_deployed: (b.cur_deployed || []).map(num), cur_end_ms: num(b.cur_end_ms),
  freeze_ms: num(b.freeze_ms), min_deploy: num(b.min_deploy) || 10_000_000, dev_fees: num(b.dev_fees),
  vault_bps: num(b.vault_bps), dev_bps: 100, buyback_bps: num(b.buyback_bps),
});
// The GraphQL indexer sometimes lags behind the chain for a while. A round that still looks unsettled
// a few seconds after it ended is re-read straight from a fullnode, so the board never hangs on "Drawing".
const NODE = new SuiGrpcClient({ network: CFG.network, baseUrl: `https://fullnode.${CFG.network}.sui.io:443` });
async function freshBoard(board, tGenesis) {
  if (!board.cur_started || Date.now() < board.cur_end_ms + 5000) return board;
  try {
    const r = await within(NODE.getObject({ objectId: IDS.board, include: { json: true } }), 5000);
    const f = boardOf(r.object.json, tGenesis);
    return f.cur_id > board.cur_id || !f.cur_started ? f : board;
  } catch (e) { console.warn("fullnode board read failed", e); return board; }
}
// Order of board states: a later round, then a started round, then more SUI deployed. Never go backwards.
const boardKey = b => [b.cur_id, b.cur_started ? 1 : 0, b.cur_total];
const newerBoard = (a, b) => { const x = boardKey(a), y = boardKey(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i]; return false; };
// Live board straight from a fullnode, separate from the slower indexer: the clock starts the moment a
// deploy lands and a new round shows as soon as the old one is drawn.
let boardBusy = false;
async function pollBoard() {
  if (boardBusy || !STATE) return; boardBusy = true;
  try {
    const r = await within(NODE.getObject({ objectId: IDS.board, include: { json: true } }), 3000);
    const f = boardOf(r.object.json, STATE.board.genesis);
    if (newerBoard(f, STATE.board)) { STATE.board = f; render(); }
  } catch (e) { console.warn("fullnode board read failed", e); }
  finally { boardBusy = false; }
}
// One request for everything the wallet view needs (balances, miner, GTS coins, unrefined GTS).
async function loadUser(addr) {
  const objs = (alias, type, first, after) => `${alias}:objects(filter:{type:"${type}"},first:${first}${after ? `,after:"${after}"` : ""}){pageInfo{hasNextPage endCursor} nodes{address contents{json}}}`;
  const T_COIN = `0x2::coin::Coin<${T_GTS}>`;
  // The player's unrefined GTS (a dynamic field on the Board) and the Board's fee accumulator.
  const addrBcs = btoa(String.fromCharCode(...addr.slice(2).padStart(64, "0").match(/../g).map(h => parseInt(h, 16))));
  // The player's Wealth Fund tickets in the current draw: PlayerTicketsKey { epoch (u64 LE), player }.
  const ep = STATE?.tickets?.epoch;
  const epBcs = ep == null ? "" : btoa(String.fromCharCode(...Array.from({ length: 8 }, (_, i) => Number((BigInt(ep) >> BigInt(8 * i)) & 255n)), ...atob(addrBcs).split("").map(c => c.charCodeAt(0))));
  const tkQ = WF_PKG && epBcs ? ` t:dynamicField(name:{type:"${WF_PKG}::game::PlayerTicketsKey",bcs:"${epBcs}"}){value{... on MoveValue{json}}}` : "";
  const ckQ = V6_PKG ? ` ck:dynamicField(name:{type:"${V6_PKG}::game::RefineClockKey",bcs:"${addrBcs}"}){value{... on MoveValue{json}}} cf:dynamicField(name:{type:"${V6_PKG}::game::RefineFromKey",bcs:"AA=="}){value{... on MoveValue{json}}}` : "";
  const refQ = `rf:object(address:"${IDS.board}"){asMoveObject{contents{json}} u:dynamicField(name:{type:"${REFINE_PKG}::game::UnrefinedKey",bcs:"${addrBcs}"}){value{... on MoveValue{json}}}${tkQ}${ckQ}}`;
  const d = await gql(`{address(address:"${addr}"){s:balance(coinType:"0x2::sui::SUI"){totalBalance} g:balance(coinType:"${T_GTS}"){totalBalance addressBalance}
    ${objs("m", T_MINER, 10)} ${objs("c", T_COIN, 50)}} ${refQ}}`);
  const uj = d.rf?.u?.value?.json, acc = BigInt(d.rf?.asMoveObject?.contents?.json?.acc || 0);
  const unrefined = uj ? { amount: num(uj.amount), bonus: Number(BigInt(uj.bonus) + BigInt(uj.amount) * (acc - BigInt(uj.snap)) / REFINE_SCALE) } : { amount: 0, bonus: 0 };
  // When the 7-day withdraw clock started (ms): own clock, else the v6 start, else 0 (full fee).
  unrefined.start = num(d.rf?.ck?.value?.json) || num(d.rf?.cf?.value?.json) || 0;
  const nodes = k => (d.address?.[k]?.nodes || []).map(n => ({ id: n.address, f: n.contents?.json || {} }));
  const bal = { address: d.address }, miners = nodes("m"), coins = nodes("c");
  // Read every page of each list: mining leaves many small GTS coins, and a missed coin
  // would be mistaken for address balance.
  const lists = { m: [miners, T_MINER], c: [coins, T_COIN] };
  for (const [k, [out, type]] of Object.entries(lists)) {
    for (let pi = d.address?.[k]?.pageInfo, n = 0; pi?.hasNextPage && n < 100; n++) {
      const more = (await gql(`{address(address:"${addr}"){${objs(k, type, 50, pi.endCursor)}}}`)).address?.[k];
      (more?.nodes || []).forEach(x => out.push({ id: x.address, f: x.contents?.json || {} }));
      pi = more?.pageInfo;
    }
  }
  const stake = await loadStake(addr).catch(() => null);
  userAt = Date.now();
  // With several Miners, use the one in the newest round: since v7 a round accepts one Miner per address.
  const miner = miners.reduce((a, m) => (!a || num(m.f.round_id) > num(a.f.round_id) ? m : a), null);
  return {
    sui: num(bal.address?.s?.totalBalance), gts: num(bal.address?.g?.totalBalance), gtsAB: num(bal.address?.g?.addressBalance), unrefined,
    tickets: num(d.rf?.t?.value?.json),
    miner: miner ? { id: miner.id, round_id: num(miner.f.round_id), deployed: (miner.f.deployed || []).map(num), total: num(miner.f.total_deployed) } : null,
    gtsCoins: coins.map(c => ({ id: c.id, balance: num(c.f.balance) })).sort((a, b) => b.balance - a.balance),
    stake,
  };
}

// The player's two staking positions (flexible, locked), read from the pool's table.
async function loadStake(addr) {
  const tbl = STATE?.stake?.table;
  if (!tbl) return null;
  const key = locked => btoa(String.fromCharCode(...addr.slice(2).padStart(64, "0").match(/../g).map(h => parseInt(h, 16)), locked ? 1 : 0));
  const q = alias => `${alias}:dynamicField(name:{type:"${STK_PKG}::staking::PosKey",bcs:"${key(alias === "l")}"}){value{... on MoveValue{json}}}`;
  // A Table is not an object: its entries are read as dynamic fields of its address.
  const d = await gql(`{object:address(address:"${tbl}"){${q("f")} ${q("l")}}}`);
  const pos = j => j ? { amount: num(j.amount), weight: BigInt(j.weight || 0), until: num(j.locked_until), snap: BigInt(j.snap || 0), pending: BigInt(j.pending || 0) } : null;
  return { flex: pos(d.object?.f?.value?.json), lock: pos(d.object?.l?.value?.json) };
}
const posYield = p => (p && STATE?.stake ? p.pending + p.weight * (STATE.stake.acc - p.snap) / STAKE_SCALE : 0n);

// Event history (newest first). Capped per type; the UI states the scope when capped.
const PAGE = 50, MAX_PAGES = 20;
async function allEvents(type) {
  let out = [], before = null, pages = 0, more = true;
  while (more && pages < MAX_PAGES) {
    const cur = before ? `,before:"${before}"` : "";
    const d = await gql(`{events(filter:{type:"${type}"},last:${PAGE}${cur}){pageInfo{hasPreviousPage startCursor}
      nodes{timestamp sender{address} transaction{digest} contents{json}}}}`);
    const e = d.events;
    out = out.concat(e.nodes.slice().reverse().map(n => ({ ts: n.timestamp, sender: n.sender?.address, digest: n.transaction?.digest, j: n.contents?.json || {} })));
    more = e.pageInfo.hasPreviousPage; before = e.pageInfo.startCursor; pages++;
  }
  return { list: out, capped: more };
}
// The site's cache of the same events (history.php) answers in one request; paging through Sui
// directly is the fallback when it is down or more than 2 minutes behind.
async function cachedEvents() {
  const h = await getJson(`/api/history?t=${Date.now()}`, 6000);
  if (!(h.at > Date.now() / 1000 - 120)) throw new Error("history cache stale");
  const ev = k => ({ list: (h[k] || []).slice().reverse(), capped: false });
  return topUp([ev("settled"), ev("deployed"), ev("redeemed"), ev("ml")]);
}
// The cache can be up to 2 minutes behind: add the newest events straight from Sui (one request), so every
// page counts the same rounds as the live board.
const HIST_KEYS = ["settled", "deployed", "redeemed", "ml"];
async function topUp(lists) {
  const q = HIST_KEYS.map((k, i) => EV[k] ? `e${i}:events(filter:{type:"${EV[k]}"},last:50){nodes{timestamp sender{address} transaction{digest} contents{json}}}` : "").join(" ");
  const d = await gql(`{${q}}`).catch(() => null);
  if (!d) return lists;
  return lists.map((l, i) => {
    const key = e => `${e.digest}:${JSON.stringify(e.j)}`, have = new Set(l.list.slice(0, 200).map(key));
    const fresh = (d[`e${i}`]?.nodes || []).map(n => ({ ts: n.timestamp, sender: n.sender?.address, digest: n.transaction?.digest, j: n.contents?.json || {} }))
      .filter(e => !have.has(key(e))).reverse();
    return { ...l, list: fresh.concat(l.list) };
  });
}
async function loadHistory() {
  const [settled, deployed, redeemed, mlEv] = await cachedEvents().catch(() =>
    Promise.all([allEvents(EV.settled), allEvents(EV.deployed), allEvents(EV.redeemed), allEvents(EV.ml)]));
  const wonEv = WF_PKG ? await allEvents(EV_WF_WON).catch(() => ({ list: [] })) : { list: [] };
  const ml = mlRows(mlEv.list.map(e => e.j), wonRows(wonEv.list.map(e => e.j)));
  const byRound = new Map();
  deployed.list.forEach(e => {
    const r = num(e.j.round_id);
    if (!byRound.has(r)) byRound.set(r, []);
    byRound.get(r).push({ player: e.j.player, total: num(e.j.total), amounts: (e.j.amounts || []).map(num) });
  });
  const rounds = settled.list.map(e => ({ ...withMl(settledRow(e.j, e.ts), ml), digest: e.digest }));
  rounds.forEach(r => { r.split = splitOf(r, byRound.get(r.round) || []); });
  return {
    rounds, byRound, deployed: deployed.list, redeemed: redeemed.list,
    capped: settled.capped || deployed.capped,
    totals: {
      rounds: rounds.length,
      volume: rounds.reduce((a, r) => a + r.total, 0),
      paid: rounds.reduce((a, r) => a + (r.winners > 0 ? r.winners + wonFromOthers(r) : 0), 0),
      reserve: rounds.reduce((a, r) => a + vaulted(r), 0),
      snPaid: rounds.reduce((a, r) => a + (r.ml?.paid || 0), 0),
      fees: rounds.reduce((a, r) => a + vaulted(r) + r.dev, 0),
      emitted: rounds.reduce((a, r) => a + r.reward, 0),
      burned: redeemed.list.reduce((a, e) => a + num(e.j.gts_burned), 0),
      players: new Set(deployed.list.map(e => e.j.player)).size,
    },
  };
}

// ---------- wallet ----------
const walletsApi = getWallets();
// "Continue with Google": Slush in the browser (zkLogin), no extension, no seed phrase. Kept out of the
// wallet registry so it is offered next to any installed wallet, the Slush extension included.
const WEB_KEY = "slush-web";
const SLUSH_WEB = new SlushWallet({ name: "GTStar", metadata: { id: "com.mystenlabs.suiwallet.web", walletName: "Slush", icon: SLUSH_WALLET_ICON, enabled: true } });
const isWeb = w => !!w && w === SLUSH_WEB;
// Slush opens its sign-in and approval screens with window.open("about:blank", "_blank"), which browsers show
// as a full tab. Give that call a size so it opens as a small popup window centered over the site.
const openWindow = window.open.bind(window);
// Phones: a plain new tab. A sized popup opens there as a minimal popup view in which Slush fails
// to load ("Failed to fetch api.slush.app") until it is reloaded.
const MOBILE = navigator.userAgentData?.mobile || /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent);
const openPopup = () => {
  if (MOBILE) return openWindow("about:blank", "_blank");
  const w = 440, h = 720;
  const left = Math.round(window.screenX + (window.outerWidth - w) / 2), top = Math.round(window.screenY + (window.outerHeight - h) / 2);
  return openWindow("about:blank", "_blank", `popup=yes,width=${w},height=${h},left=${Math.max(0, left)},top=${Math.max(0, top)}`);
};
// A window opened in the click itself: Slush only opens its own after the transaction is built, and a window
// opened that late (no longer "from a click") loads Slush broken on phones ("Failed to fetch api.slush.app").
let prePopup = null;
window.open = (url, target, features) => {
  if (url !== "about:blank" || target !== "_blank" || features) return openWindow(url, target, features);
  const pre = prePopup; prePopup = null;
  return pre && !pre.closed ? pre : openPopup();
};
const suiWallets = () => walletsApi.get().filter(w => w.chains.some(c => c.startsWith("sui:")) && w.features["standard:connect"]);

// A wallet that never answers must not leave the app waiting forever.
const within = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), ms))]);
let offChange = null, connecting = false;
async function connect(w, silent = false) {
  // A sign-in window closed without an answer never settles: give up after 2 minutes.
  const res = silent
    ? await within(w.features["standard:connect"].connect({ silent: true }), 4000)
    : await within(w.features["standard:connect"].connect(), 120_000);
  const accs = res?.accounts?.length ? res.accounts : w.accounts;
  if (!accs.length) return false;
  wallet = w; account = accs[0]; USER = null;
  try { localStorage.setItem("gtstar.wallet", isWeb(w) ? WEB_KEY : w.name); } catch {}
  if (isWeb(w)) try { localStorage.setItem("gtstar.webUsed", "1"); } catch {}
  // One listener, for the wallet in use: account switches in the wallet show up here.
  offChange?.();
  offChange = w.features["standard:events"]?.on("change", ({ accounts }) => {
    if (wallet !== w || !accounts) return;
    const next = accounts[0] || null;
    if (next?.address === account?.address) return;
    account = next; if (!account) wallet = null; USER = null; renderWallet(); refresh(); loadWelcome();
  }) || null;
  renderWallet(); refresh(); loadWelcome();
  return true;
}
async function disconnect() {
  const wasWeb = isWeb(wallet);
  offChange?.(); offChange = null;
  try { await within(wallet?.features["standard:disconnect"]?.disconnect() ?? Promise.resolve(), 4000); } catch {}
  try { localStorage.removeItem("gtstar.wallet"); } catch {}
  wallet = null; account = null; USER = null;
  $("acctMenu").hidden = true; $("mNameForm").hidden = true;
  renderWallet(); refresh();
  // Slush keeps the Google login on its own site, so signing in again would return the same account.
  if (wasWeb) toast('Signed out. To use a different Google account, also sign out at <a href="https://my.slush.app" target="_blank" rel="noopener">my.slush.app</a>.', false, true);
}
function renderWallet() {
  const b = $("btnConnect");
  b.textContent = account ? label(account.address) : "Sign in";
  b.classList.toggle("ghost", !!account);
  if (account) {
    $("mAddr").textContent = label(account.address);
    $("mAddr").classList.toggle("mono", !nameOf(account.address));
    $("mName").textContent = nameOf(account.address) ? "Edit username" : "Set username";
    $("mScan").href = `${SCAN}/account/${account.address}`;
    $("mSui").textContent = USER ? sui(USER.sui) : "—";
    $("mGts").textContent = USER ? sui(USER.gts) : "—";
  }
}
function openWalletModal() {
  const list = suiWallets();
  const box = $("walletList"); box.innerHTML = "";
  $("noWallet").hidden = list.length > 0;
  $("googleNote").innerHTML = (WELCOME_OPEN ? "<b>Your first 2 rounds are free.</b> " : "") +
    "New to crypto? This creates your free wallet in seconds. No app, no seed phrase. Apple sign-in works too.";
  $("btnGoogle").onclick = () => startConnect(SLUSH_WEB);
  list.forEach(w => {
    const b = document.createElement("button"); b.type = "button";
    const img = document.createElement("img"); img.src = w.icon; img.alt = "";
    const s = document.createElement("span"); s.textContent = w.name;
    b.append(img, s);
    b.onclick = () => startConnect(w);
    box.appendChild(b);
  });
  $("walletModal").hidden = false;
}
async function startConnect(w) {
  closeModal();
  const btn = $("btnConnect");
  btn.textContent = "Connecting…"; btn.disabled = true;
  toast(isWeb(w) ? "Finish signing in in the new window." : `Approve the connection in ${w.name}.`);
  // Extensions often queue the request without a visible window (locked, or the popup opened behind the browser).
  const hint = isWeb(w) ? 0 : setTimeout(() => { toast(`No window from ${w.name}? Click the ${w.name} icon in your browser toolbar (the puzzle piece if it is hidden), unlock it and approve the request.`); clearTimeout($("toast")._t); }, 5000);
  try { await connect(w); $("toast").hidden = true; }
  catch (e) {
    const m = String(e?.message || e);
    toast(/reject|cancel|denied/i.test(m) ? "Connection cancelled."
      : m === "timeout" ? "No answer from the wallet. Try again."
      : /open new window/i.test(m) ? "Your browser blocked the sign-in window. Allow pop-ups for this site and try again."
      : /set up your wallet/i.test(m) ? `${w.name} is installed but not set up yet. Open it to finish setup, or sign in with Google instead.`
      : "Connection failed: " + m, true);
  }
  finally { clearTimeout(hint); btn.disabled = false; renderWallet(); }
}
const closeModal = () => ($("walletModal").hidden = true);
async function autoReconnect() {
  let name = null;
  try { name = localStorage.getItem("gtstar.wallet"); } catch {}
  if (!name) return;
  if (name === WEB_KEY) { try { await connect(SLUSH_WEB, true); } catch {} return; }
  // The extension may register late; only one silent attempt runs at a time.
  const tryIt = async () => {
    const w = suiWallets().find(x => x.name === name);
    if (!w || wallet || connecting) return;
    connecting = true;
    try { await connect(w, true); } catch {} finally { connecting = false; }
  };
  await tryIt();
  walletsApi.on("register", tryIt);
}

// ---------- transactions ----------
const ERRORS = {
  game: { 2: "Round has ended. Settle it first.", 3: "Round is closing. Try the next round.", 4: "Claim your previous round first.", 5: "Select at least one tile.", 6: "Amount is below the minimum.", 7: "Payment does not match the tile amounts.", 8: "Round has not ended yet.", 9: "This round was already settled.", 10: "Nothing to claim.", 11: "Round is not settled yet.", 22: "Staking is not open yet.", 14: "The game was just upgraded. Refresh the page and try again.", 15: "Use one miner per round. Refresh the page and try again.", 19: "The game is paused for a moment. Try again soon.", 20: "Nothing to withdraw." },
  gts: { 1: "Amount must be greater than zero.", 2: "Reserve is empty." },
  staking: { 1: "Amount must be greater than zero.", 2: "Amount exceeds your stake.", 3: "This stake is still locked.", 4: "Nothing staked here." },
};
function friendlyError(e) {
  const m = String(e?.message || e);
  // e.g. "MoveAbort in 1st command, abort code: 9, in '0x…::game::settle'" or "MoveAbort(…::game::…, 9)"
  const a1 = m.match(/abort code:\s*(\d+)[^']*'0x[0-9a-f]+::(\w+)::/i);
  const a2 = m.match(/::(game|gts|staking)::[^,]*?,\s*(\d+)\)/);
  const mod = a1 ? a1[2] : a2 && a2[1], code = a1 ? +a1[1] : a2 && +a2[2];
  if (mod && ERRORS[mod]?.[code]) return ERRORS[mod][code];
  if (/reject|cancel/i.test(m)) return "Transaction cancelled.";
  if (/InsufficientGas|GasBalanceTooLow|insufficient gas/i.test(m)) return "Insufficient SUI balance.";
  if (/insufficient/i.test(m)) return /GTS/.test(m) ? "Insufficient GTS balance." : "Insufficient balance.";
  if (/not found|deleted|version/i.test(m)) return "Your balance just changed. Try again.";
  if (/MoveAbort/i.test(m)) return "The transaction was rejected by the contract. Refresh and try again.";
  return m.slice(0, 140);
}
// The keeper draws every round within seconds of its end, so players never draw. Only if it has not after
// 2 minutes (keeper down) does the board offer the draw to the player as a fallback.
const KEEPER_GRACE_MS = 120_000;
const keeperDrawing = b => Date.now() < b.cur_end_ms + KEEPER_GRACE_MS;
const GAS_RESERVE = 5_000_000; // ~0.005 SUI kept for gas
function lowBalance(needMist) {
  if (!USER || USER.sui >= needMist + GAS_RESERVE) return false;
  const need = sui(needMist + GAS_RESERVE);
  toast(`Not enough SUI. You need about ${need} SUI including gas.`, true, true);
  return true;
}
async function exec(label, btnId, build, needMist = 0) {
  if (!account) { openWalletModal(); return; }
  if (busy || lowBalance(needMist)) return;
  busy = btnId;
  if (isWeb(wallet)) prePopup = openPopup();
  const b = $(btnId), old = b.textContent;
  b.disabled = true; b.textContent = "Confirm in wallet";
  try {
    // Coin and miner IDs from a cached view may have been consumed by an earlier transaction,
    // so re-read the wallet unless the cached view is fresh and nothing was sent since.
    if (!USER || userAt <= txAt || Date.now() - userAt > 6000) { const s = ++seqU; USER = await loadUser(account.address); shownU = s; }
    const tx = new Transaction();
    tx.setSender(account.address);
    abUsed = 0;
    await build(tx);
    // If the wallet window is closed without an answer the request never settles; release the app after 90s.
    const r = await within(signAndExecuteTransaction(wallet, { transaction: tx, account, chain: CHAIN }), 90_000)
      .catch(e => { throw e.message === "timeout" ? new Error("No answer from the wallet. Open it and try again.") : e; });
    txAt = Date.now();
    toast(`${label} confirmed. <a href="${SCAN}/tx/${r.digest}" target="_blank" rel="noopener">View transaction</a>`, false, true);
    pollBoard(); setTimeout(pollBoard, 500); setTimeout(pollBoard, 1200);
    refresh(); setTimeout(refresh, 1500); setTimeout(refresh, 4000);
    return r;
  } catch (e) {
    txAt = Date.now();
    // Older wallet SDKs (e.g. Surf) cannot read the address-balance withdrawal input and fail with a schema error.
    if (abUsed && /Invalid type|Expected .* but received|withdraw/i.test(String(e?.message || e))) {
      NO_AB.add(wallet?.name);
      const coins = (USER?.gtsCoins || []).reduce((a, c) => a + c.balance, 0);
      toast(esc(`${wallet?.name || "This wallet"} can't spend the ${sui(abUsed)} GTS held in your address balance yet. Swap up to ${sui(coins)} GTS here, or use Slush for the full amount.`), true, true);
    } else toast(esc(friendlyError(e)), true, true);
    refresh();
  } finally {
    // Not used (the build failed before signing): close the waiting window.
    if (prePopup) { try { prePopup.close(); } catch {} prePopup = null; }
    busy = false; b.disabled = false; b.textContent = old; render();
  }
}
// Mined GTS goes to the unrefined balance, so only the SUI comes back.
function claimInto(tx, minerArg) {
  const args = [tx.object(IDS.board), minerArg, tx.object(IDS.treasury)];
  tx.transferObjects([tx.moveCall({ target: C("game::claim_sui"), arguments: args })[0]], account.address);
}
// Withdraw fee as a fraction right now: the full fee at the clock's start, 0 after 7 days.
function withdrawFee(U, now = Date.now()) {
  if (!U?.start) return STATE.refineFee;
  const left = Math.max(0, U.start + REFINE_WINDOW_MS - now);
  return STATE.refineFee * Math.min(left, REFINE_WINDOW_MS) / REFINE_WINDOW_MS;
}
const dhm = ms => { const m = Math.ceil(ms / 60_000), d = Math.floor(m / 1440), h = Math.floor(m % 1440 / 60); return d ? `${d}d ${h}h` : h ? `${h}h ${m % 60}m` : `${m}m`; };
// Take the whole unrefined balance out (the fee, if any, is burned; the 7-day clock restarts).
const withdrawGts = () => exec("Withdraw", "btnWithdraw", tx => {
  if (!(USER?.unrefined?.amount > 0)) throw new Error("Nothing to withdraw.");
  const [g] = tx.moveCall({ target: C("game::withdraw_gts_v6"), arguments: [tx.object(IDS.board), tx.object(IDS.treasury), tx.object("0x6")] });
  tx.transferObjects([g], account.address);
});
// `split` may be a transaction result (the exact amount a pool asks for); `amount` is its known upper bound.
// GTS may sit partly in the address balance (not as Coin objects); the shortfall is withdrawn from there.
let abUsed = 0;              // GTS taken from the address balance in the transaction being built
const NO_AB = new Set();      // wallets that failed on an address-balance withdrawal
function gtsCoin(tx, amount, split = amount) {
  const coins = USER?.gtsCoins || [];
  const inCoins = coins.reduce((a, c) => a + c.balance, 0);
  if ((USER?.gts || 0) < amount) throw new Error("Insufficient GTS balance.");
  // Never withdraw more from the address balance than the chain reports is there.
  if (inCoins + (USER?.gtsAB || 0) < amount) throw new Error("Your balance just changed. Try again.");
  const parts = coins.map(c => tx.object(c.id));
  if (inCoins < amount) {
    abUsed = amount - inCoins;
    const w = tx.withdrawal({ amount: abUsed, type: T_GTS });
    parts.push(tx.moveCall({ target: "0x2::coin::redeem_funds", typeArguments: [T_GTS], arguments: [w] })[0]);
  }
  const primary = parts[0];
  if (parts.length > 1) tx.mergeCoins(primary, parts.slice(1));
  const [c] = tx.splitCoins(primary, [split]);
  return c;
}
// The site used to cap a wallet at 3 tiles a round until the v7 split; the contract never did, so the cap is off.
const TILE_CAP = 25;
function overCap() {
  if (FAIR_FROM !== Infinity) return false;
  const b = STATE?.board, m = USER?.miner, tiles = new Set(selected);
  if (b && m && b.cur_started && m.round_id === b.cur_id && Date.now() < b.cur_end_ms) m.deployed.forEach((v, i) => v > 0 && tiles.add(i));
  return tiles.size > TILE_CAP;
}
async function play() {
  if (!account) { openWalletModal(); return; }
  const per = toMist($("amt").value);
  if (!selected.size || per < STATE.board.min_deploy || overCap()) return;
  const amounts = Array(25).fill(0);
  selected.forEach(i => (amounts[i] = per));
  const total = per * selected.size;
  const r = await exec("Deploy", "btnPlay", tx => {
    const m = USER?.miner;
    let minerArg, fresh = false;
    if (m) {
      minerArg = tx.object(m.id);
      if (m.round_id !== 0 && m.round_id < STATE.board.cur_id) claimInto(tx, minerArg);
    } else {
      [minerArg] = tx.moveCall({ target: C("game::new_miner") });
      fresh = true;
    }
    const [pay] = tx.splitCoins(tx.gas, [total]);
    tx.moveCall({ target: C("game::deploy"), arguments: [tx.object(IDS.board), minerArg, pay, tx.pure.vector("u64", amounts), tx.object.clock()] });
    if (fresh) tx.transferObjects([minerArg], account.address);
  }, total);
  if (r) {
    store.set("gtstar.last", JSON.stringify({ tiles: [...selected], per: $("amt").value }));
    selected.clear(); render();
  }
}
// Claim the last round: SUI winnings to the wallet, mined GTS to the unrefined balance.
const claimAll = () => exec("Claim", "btnClaimAll", tx => {
  if (!rewards().ready) throw new Error("Nothing to claim.");
  claimInto(tx, tx.object(USER.miner.id));
});
// Fixed gas budget: the wallet's dry run usually takes the no-jackpot path, and a round that pays the
// Wealth Fund needs more gas than that. Unused gas is refunded.
const SETTLE_GAS = 20_000_000; // ~0.011 SUI gross for a settle, more when the Wealth Fund pays
const settle = () => exec("Draw", "btnPlay", tx => {
  tx.setGasBudget(SETTLE_GAS);
  tx.moveCall({ target: C("game::settle"), arguments: [tx.object(IDS.board), tx.object(IDS.treasury), tx.object.random(), tx.object.clock()] });
});
let stakeMode = "deposit", stakeKind = "flex";
const stakeTx = () => exec(stakeMode === "deposit" ? "Stake" : "Withdraw", "btnStake", tx => {
  const amt = toMist($("stakeAmt").value), locked = stakeKind === "lock";
  if (amt <= 0) throw new Error("Enter an amount.");
  if (stakeMode === "deposit") {
    tx.moveCall({ target: C("game::stake"), arguments: [tx.object(IDS.board), gtsCoin(tx, amt), tx.pure.bool(locked), tx.object.clock()] });
  } else {
    const [g] = tx.moveCall({ target: C("game::unstake"), arguments: [tx.object(IDS.board), tx.pure.u64(amt), tx.pure.bool(locked), tx.object.clock()] });
    tx.transferObjects([g], account.address);
  }
}).then(r => { if (r) $("stakeAmt").value = ""; });
const claimYield = () => exec("Yield claim", "btnStakeClaim", tx => {
  const [c] = tx.moveCall({ target: C("game::claim_yield"), arguments: [tx.object(IDS.board)] });
  tx.transferObjects([c], account.address);
});
// Pool<GTS, SUI> on Cetus: selling GTS is a2b, buying GTS is b2a.
// Selling takes whichever pays more for the exact amount: the pool, or the reserve (burn at the floor).
const CETUS_PKG = "0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084"; // clmm, latest version
const CETUS_CFG = "0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f";  // clmm GlobalConfig
const MAX_SQRT = "79226673515401279992447579055", MIN_SQRT = "4295048016";
const SLIPPAGE = 0.01;
const POOL_T = [T_GTS, "0x2::sui::SUI"];
const sim = new SuiGraphQLClient({ url: GQL, network: CFG.network });
const NO_QUOTE = { amt: 0, a2b: false, out: 0, exceed: false };
let QUOTE = NO_QUOTE, quoteSeq = 0;
// Exact pool output for `amt` in, read from the pool itself (a simulated call, nothing is signed).
async function quotePool(amt, a2b) {
  const seq = ++quoteSeq;
  if (amt <= 0 || !IDS.market) { QUOTE = NO_QUOTE; return renderTrade(); }
  try {
    const tx = new Transaction();
    tx.setSender("0x0000000000000000000000000000000000000000000000000000000000000000");
    const r = tx.moveCall({ target: `${CETUS_PKG}::pool::calculate_swap_result`, typeArguments: POOL_T, arguments: [tx.object(IDS.market), tx.pure.bool(a2b), tx.pure.bool(true), tx.pure.u64(amt)] });
    tx.moveCall({ target: `${CETUS_PKG}::pool::calculated_swap_result_amount_out`, arguments: [r] });
    tx.moveCall({ target: `${CETUS_PKG}::pool::calculated_swap_result_is_exceed`, arguments: [r] });
    const res = await sim.simulateTransaction({ transaction: tx, checksEnabled: false, include: { commandResults: true } });
    if (seq !== quoteSeq) return;
    const out = res.commandResults[1].returnValues[0].bcs, ex = res.commandResults[2].returnValues[0].bcs;
    QUOTE = { amt, a2b, out: Number(new DataView(Uint8Array.from(out).buffer).getBigUint64(0, true)), exceed: ex[0] === 1 };
  } catch (e) { if (seq === quoteSeq) QUOTE = NO_QUOTE; console.warn("quote failed", e); }
  renderTrade();
}
let quoteTimer = 0;
const requestQuote = () => { clearTimeout(quoteTimer); quoteTimer = setTimeout(() => quotePool(toMist($("swIn").value), swapDir === "sell"), 250); };
// Pool output for this amount and direction, or 0 when there is no usable quote.
const poolOut = (amt, a2b) => (QUOTE.amt === amt && QUOTE.a2b === a2b && !QUOTE.exceed ? QUOTE.out : 0);
// The reserve can only take up to the whole supply; beyond that there is no quote.
const reserveOut = amt => (STATE?.supply && amt <= STATE.supply ? Math.floor(STATE.vault * amt / STATE.supply) : 0);
const sellViaPool = amt => poolOut(amt, true) > reserveOut(amt);
const buy = () => exec("Swap", "btnSwap", async tx => {
  const amt = toMist($("swIn").value);
  if (amt <= 0) throw new Error("Enter an amount.");
  if (QUOTE.amt !== amt || QUOTE.a2b) await quotePool(amt, false);
  if (QUOTE.exceed || QUOTE.out <= 0) throw new Error("Not enough liquidity in the pool for this amount.");
  const minOut = Math.floor(QUOTE.out * (1 - SLIPPAGE));
  const [gts, suiLeft, receipt] = tx.moveCall({ target: `${CETUS_PKG}::pool::flash_swap`, typeArguments: POOL_T, arguments: [
    tx.object(CETUS_CFG), tx.object(IDS.market), tx.pure.bool(false), tx.pure.bool(true), tx.pure.u64(amt), tx.pure.u128(MAX_SQRT), tx.object.clock()] });
  const pay = tx.moveCall({ target: `${CETUS_PKG}::pool::swap_pay_amount`, typeArguments: POOL_T, arguments: [receipt] });
  const [payCoin] = tx.splitCoins(tx.gas, [pay]);
  const payBal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: [POOL_T[1]], arguments: [payCoin] });
  const noGts = tx.moveCall({ target: "0x2::balance::zero", typeArguments: [T_GTS] });
  tx.moveCall({ target: `${CETUS_PKG}::pool::repay_flash_swap`, typeArguments: POOL_T, arguments: [tx.object(CETUS_CFG), tx.object(IDS.market), noGts, payBal, receipt] });
  tx.moveCall({ target: "0x2::balance::destroy_zero", typeArguments: [POOL_T[1]], arguments: [suiLeft] });
  tx.transferObjects([guardedCoin(tx, gts, T_GTS, minOut)], account.address);
}, toMist($("swIn").value)).then(r => { if (r) { $("swIn").value = ""; QUOTE = NO_QUOTE; renderTrade(); } });
// Slippage guard: splitting minOut aborts the whole transaction if the pool gave less.
function guardedCoin(tx, bal, type, minOut) {
  const part = tx.moveCall({ target: "0x2::balance::split", typeArguments: [type], arguments: [bal, tx.pure.u64(minOut)] });
  tx.moveCall({ target: "0x2::balance::join", typeArguments: [type], arguments: [bal, part] });
  return tx.moveCall({ target: "0x2::coin::from_balance", typeArguments: [type], arguments: [bal] })[0];
}
const swap = () => exec("Swap", "btnSwap", async tx => {
  const amt = toMist($("swIn").value);
  if (amt <= 0) throw new Error("Enter an amount.");
  if (QUOTE.amt !== amt || !QUOTE.a2b) await quotePool(amt, true);
  if (!sellViaPool(amt)) {
    const [out] = tx.moveCall({ target: TK("gts::redeem"), arguments: [tx.object(IDS.treasury), gtsCoin(tx, amt)] });
    return tx.transferObjects([out], account.address);
  }
  const minOut = Math.floor(QUOTE.out * (1 - SLIPPAGE));
  const [gtsLeft, sui, receipt] = tx.moveCall({ target: `${CETUS_PKG}::pool::flash_swap`, typeArguments: POOL_T, arguments: [
    tx.object(CETUS_CFG), tx.object(IDS.market), tx.pure.bool(true), tx.pure.bool(true), tx.pure.u64(amt), tx.pure.u128(MIN_SQRT), tx.object.clock()] });
  const pay = tx.moveCall({ target: `${CETUS_PKG}::pool::swap_pay_amount`, typeArguments: POOL_T, arguments: [receipt] });
  const payBal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: [T_GTS], arguments: [gtsCoin(tx, amt, pay)] });
  const noSui = tx.moveCall({ target: "0x2::balance::zero", typeArguments: [POOL_T[1]] });
  tx.moveCall({ target: `${CETUS_PKG}::pool::repay_flash_swap`, typeArguments: POOL_T, arguments: [tx.object(CETUS_CFG), tx.object(IDS.market), payBal, noSui, receipt] });
  tx.moveCall({ target: "0x2::balance::destroy_zero", typeArguments: [T_GTS], arguments: [gtsLeft] });
  tx.transferObjects([guardedCoin(tx, sui, POOL_T[1], minOut)], account.address);
}).then(r => { if (r) { $("swIn").value = ""; QUOTE = NO_QUOTE; renderTrade(); } });

// ---------- emission math (round-based, mirrors game::settle) ----------
// Full GTS reward of the round now open: the step reward, never past the 1,000,000 cap.
const em = () => STATE?.em || LAUNCH_EM;
const roundReward = () => { const e = em(); return Math.max(0, Math.min(e.reward, MAX_GTS * MIST - e.committed)) / MIST; };
// The schedule with every round at the full reward, from round 1 with 1 GTS and the current step and cut:
// GTS mined after `n` rounds, and the reward of round n + 1.
function schedule(n) {
  const { step, decay } = em(), q = 1 - decay / 1e6;
  let total = 0, r = 1, left = n;
  while (left > 0 && total < MAX_GTS && r > 0) {
    const k = Math.min(step, left);
    total += r * k; left -= k;
    if (k === step) r *= q;
  }
  return { total: Math.min(total, MAX_GTS), next: total >= MAX_GTS ? 0 : r };
}
// Round at which the full-reward schedule reaches the cap.
function lastRound() {
  const { step, decay } = em(), q = 1 - decay / 1e6;
  let total = 0, r = 1, n = 0;
  for (let i = 0; i < 100_000 && r > 0; i++) {
    if (total + r * step >= MAX_GTS) return n + Math.ceil((MAX_GTS - total) / r);
    total += r * step; n += step; r *= q;
  }
  return n;
}

// ---------- render: common ----------
function toast(msg, err = false, html = false) {
  const t = $("toast");
  if (html) t.innerHTML = msg; else t.textContent = msg;
  t.classList.toggle("err", err); t.hidden = false;
  clearTimeout(t._t); t._t = setTimeout(() => (t.hidden = true), 5000);
}
function phase() {
  const b = STATE?.board; if (!b) return "loading";
  const now = Date.now();
  if (!b.cur_started) return "open";
  if (now >= b.cur_end_ms) return "ended";
  if (now > b.cur_end_ms - b.freeze_ms) return "frozen";
  return "live";
}

// ---------- render: home ----------
function buildArt() {
  const g = $("artGrid");
  for (let i = 0; i < 25; i++) g.appendChild(document.createElement("i"));
  const cells = [...g.children];
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) { cells[12].className = "win"; return; }
  let step = 0;
  setInterval(() => {
    if (view !== "home") return;
    step++;
    cells.forEach(c => (c.className = ""));
    if (step % 4 === 0) { cells[Math.floor(Math.random() * 25)].className = "win"; return; }
    for (let k = 0; k < 7; k++) cells[Math.floor(Math.random() * 25)].className = "on";
  }, 700);
}
// One format per protocol number, used by every page, so Home, Explore and Tokenomics always read the same.
const N = {
  fund: () => sui(STATE.motherlode, 4), reserve: () => sui(STATE.vault, 4), floor: () => fmt(STATE.floor, 6),
  mined: () => sui(STATE.minted, 3), supply: () => sui(STATE.supply, 3), volume: () => sui(HIST.totals.volume, 3),
  floorUsd: () => (PRICE.sui ? usd(STATE.floor * PRICE.sui) : ""),
};
function renderHome() {
  $("hMotherlode").textContent = STATE ? N.fund() : "—";
  $("hReserve").textContent = STATE ? N.reserve() : "—";
  // Floor in dollars, next to the dollar price in the header; SUI until the SUI price loads.
  $("hFloor").textContent = STATE ? N.floorUsd() || `${N.floor()} SUI` : "—";
  $("hFloor").title = STATE ? `${N.floor()} SUI per GTS` : "";
  $("hSupply").textContent = STATE ? N.supply() : "—";
}

// ---------- render: mine ----------
const PERSON = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-7 8-7s8 2.6 8 7"/></svg>`;
const hue = a => parseInt(String(a).slice(2, 8), 16) % 360;
const tilesTxt = idx => idx.length === 25 ? "All 25 tiles" : `${idx.length === 1 ? "Tile" : "Tiles"} ${idx.map(i => i + 1).join(", ")}`;
let tileEls = [];
function buildBoard() {
  const g = $("board");
  for (let i = 0; i < 25; i++) {
    const c = document.createElement("button");
    c.type = "button"; c.className = "tile"; c.dataset.i = i;
    c.innerHTML = `<span class="n">${i + 1}</span><span class="pc" hidden>${PERSON}<b></b></span><span class="me" hidden></span><span class="add" hidden></span><span class="a"></span>`;
    c.addEventListener("animationend", () => c.classList.remove("bump"));
    c.onclick = () => {
      selected.has(i) ? selected.delete(i) : selected.add(i);
      // Picking a tile with no amount set starts at the minimum, so Deploy is ready right away.
      const min = STATE ? STATE.board.min_deploy / MIST : 0.01;
      if (selected.size && parseAmt($("amt").value) < min) $("amt").value = String(min);
      render();
    };
    g.appendChild(c);
  }
  tileEls = [...g.children];
}
// Deploys grouped per player for one round (a player can deploy several times).
function roundPlayers(round) {
  const m = new Map();
  (STATE?.deploys || []).filter(d => d.round === round).forEach(d => {
    const p = m.get(d.player) || { player: d.player, amounts: Array(25).fill(0), total: 0, ts: d.ts, digest: d.digest };
    d.amounts.forEach((v, i) => (p.amounts[i] += v));
    p.total += d.total;
    if (d.ts > p.ts) { p.ts = d.ts; p.digest = d.digest; }
    m.set(d.player, p);
  });
  return [...m.values()].sort((x, y) => (y.ts > x.ts ? 1 : -1));
}
const winOf = (p, r) => payoutOf(r, p.amounts[r.tile] || 0, p.total, p.player).back;
// Profit on the winning tile: the share of the losing tiles, without the stake that comes back.
const profitOf = (p, r) => winOf(p, r) - (p.amounts[r.tile] || 0);

// Round reveal: tiles flicker while the round is being drawn, then slow down and land on the winner.
let lastSeen = null, reveal = null, scanT = null;
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
function clearScan() { tileEls.forEach(c => c.classList.remove("scan")); }
function startScan() {
  if (scanT || reduceMotion) return;
  scanT = setInterval(() => { clearScan(); tileEls[Math.floor(Math.random() * 25)].classList.add("scan"); }, 110);
}
function stopScan() { clearInterval(scanT); scanT = null; clearScan(); }
// ---------- round alerts ----------
// Storage can be blocked (private mode); every read and write is optional.
const store = {
  get: k => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch {} },
};
// Tab title: the normal title, alternating with a short alert while the tab is in the background.
let baseTitle = "GTStar", flashTitle = null;
const paintTitle = () => { document.title = flashTitle && document.hidden && Math.floor(Date.now() / 1000) % 2 ? flashTitle : baseTitle; };
const setTitle = t => { baseTitle = t; paintTitle(); };
setInterval(() => { if (flashTitle) paintTitle(); }, 1000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) { flashTitle = null; paintTitle(); } });
const canNotify = "Notification" in window;
const alertsOn = () => canNotify && Notification.permission === "granted" && store.get("gtstar.alerts") === "on";
// A round you played has ended while you were in another tab: flash the title, and notify if you turned alerts on.
function roundAlert(L) {
  const m = USER?.miner;
  if (!document.hidden || !m || m.round_id !== L.round) return;
  const r = rewards(), net = r.sui - m.total;
  const head = net > 0 ? "You won!" : r.sui > 0 ? "Your tile won" : `Tile ${L.tile + 1} won`;
  const body = net > 0 ? `Round #${L.round}: +${sui(net, 4)} SUI and ${sui(r.gts, 4)} GTS mined.`
    : r.sui > 0 ? `Round #${L.round}: ${sui(r.sui, 4)} SUI back and ${sui(r.gts, 4)} GTS mined.`
    : `Round #${L.round}: your tiles did not win. ${sui(r.gts, 4)} GTS mined.`;
  flashTitle = `${head} · GTStar`;
  if (alertsOn()) try {
    const n = new Notification(head, { body, icon: "/icon-192.png", tag: "gtstar-round" });
    n.onclick = () => { window.focus(); location.hash = "#mine"; n.close(); };
  } catch {}
}
function renderAlerts() {
  $("alertsRow").hidden = !canNotify;
  if (!canNotify) return;
  const on = alertsOn();
  $("alertsBtn").textContent = Notification.permission === "denied" ? "Blocked" : on ? "On" : "Off";
  $("alertsBtn").classList.toggle("strong", on);
  $("alertsBtn").title = Notification.permission === "denied"
    ? "Notifications are blocked for this site in your browser settings"
    : "Browser notification when a round you played ends while this tab is in the background";
}
function lastDeploy() {
  try { const j = JSON.parse(store.get("gtstar.last")); return j && Array.isArray(j.tiles) && j.tiles.length ? j : null; } catch { return null; }
}

function trackRounds() {
  const L = STATE?.last;
  if (!L) return;
  if (lastSeen === null) { lastSeen = L.round; return; }
  if (L.round <= lastSeen) return;
  lastSeen = L.round;
  roundAlert(L);
  stopScan();
  reveal = { round: L.round, landing: !reduceMotion && view === "mine", at: 0 };
  if (!reveal.landing) { reveal.at = Date.now(); return; }
  const steps = [70, 90, 120, 160, 210, 280, 380];
  let k = 0;
  const next = () => {
    clearScan();
    if (k < steps.length) {
      tileEls[k === steps.length - 1 ? L.tile : Math.floor(Math.random() * 25)].classList.add("scan");
      setTimeout(next, steps[k++]);
    } else { reveal.landing = false; reveal.at = Date.now(); render(); }
  };
  next();
}

function renderBoard() {
  const b = STATE?.board, p = phase();
  const L = STATE?.last;
  const landing = reveal?.landing;
  // The winner lights up only for a few seconds after the draw; otherwise the board shows the current round only.
  const revealing = !!(reveal && reveal.at && Date.now() - reveal.at < 8_000);
  const showWin = L && b && !b.cur_started && !landing && revealing ? L.tile : -1;
  const shown = b?.cur_started || showWin < 0 ? b?.cur_id : L.round;
  const players = shown ? roundPlayers(shown) : [];
  let dep = b?.cur_started && b.cur_deployed?.length ? b.cur_deployed : Array(25).fill(0);
  if (b && !b.cur_started && players.length) { dep = Array(25).fill(0); players.forEach(pl => pl.amounts.forEach((v, i) => (dep[i] += v))); }
  const counts = Array(25).fill(0);
  players.forEach(pl => pl.amounts.forEach((v, i) => { if (v > 0) counts[i]++; }));
  const mine = USER?.miner && USER.miner.round_id === shown ? USER.miner.deployed : null;
  const max = Math.max(...dep, 1);
  const per = parseAmt($("amt").value), minPer = b ? b.min_deploy / MIST : 0.01;
  // Flash tiles that just received a deploy in the live round.
  const bump = b?.cur_started && bumpRound === shown ? dep.map((v, i) => v > (bumpDep[i] || 0)) : [];
  bumpRound = shown; bumpDep = dep.slice();
  // Only animate the draw when the keeper is about to settle; small rounds wait for a player to draw them.
  const auto = p === "ended" && keeperDrawing(b);
  if (auto && !landing) startScan(); else if (!landing) stopScan();
  $("board").classList.toggle("settled", showWin >= 0);
  $("board").classList.toggle("drawing", auto || !!landing);
  tileEls.forEach(c => {
    const i = +c.dataset.i, v = dep[i] / MIST, sel = selected.has(i);
    c.classList.toggle("has", v > 0);
    c.classList.toggle("sel", sel);
    c.classList.toggle("win", i === showWin);
    // Every played tile shows a visible fill; bigger stakes fill more (sqrt, so small ones are not lost).
    c.style.setProperty("--fill", v > 0 ? (0.22 + 0.78 * Math.sqrt(dep[i] / max)).toFixed(3) : 0);
    c.classList.toggle("mine", !!(mine && mine[i] > 0));
    c.setAttribute("aria-pressed", sel);
    c.setAttribute("aria-label", `Tile ${i + 1}, ${fmt(v, 3)} SUI, ${counts[i]} miners`);
    c.querySelector(".a").textContent = fmt(v, 3);
    const pc = c.querySelector(".pc");
    pc.hidden = !counts[i]; pc.querySelector("b").textContent = counts[i];
    const me = c.querySelector(".me");
    me.hidden = !(mine && mine[i] > 0); me.textContent = me.hidden ? "" : "YOU";
    // Center of the tile: what you put on it (gold), or what you are about to add.
    const add = c.querySelector(".add"), my = mine ? mine[i] : 0;
    add.hidden = !(my > 0 || (sel && per >= minPer));
    if (!add.hidden) add.textContent = sel && per >= minPer ? `${my > 0 ? sui(my, 3) + " " : ""}+${fmt(per, 3)}` : sui(my, 3);
    if (bump[i] && !reduceMotion) c.classList.add("bump");
  });
}
let bumpRound = null, bumpDep = [];

function renderResult() {
  const box = $("result"), b = STATE?.board, L = STATE?.last;
  const fresh = reveal && reveal.at && Date.now() - reveal.at < 12_000;
  if (!L || !b || reveal?.landing || (b.cur_started && !fresh)) { box.hidden = true; return; }
  const players = roundPlayers(L.round);
  const winners = players.map(p => ({ p, won: winOf(p, L) })).filter(x => x.won > 0).sort((x, y) => y.won - x.won);
  const n = winners.length;
  const won = isFair(L.round) ? winners.reduce((a, x) => a + profitOf(x.p, L), 0) : L.payout;
  const toFund = L.ml?.added > 0 && L.total > 0 ? `${fmt(L.ml.added / L.total * 100, 1)}% of the pot` : "Part of the pot";
  let sub = L.winners === 0 ? (L.ml ? `No one was on this tile. ${toFund} went into the Wealth Fund, the rest to the reserve.` : "No one was on this tile. The pot went to the reserve.")
    : L.ml?.paid > 0 && !L.ml.winner ? `Wealth Fund paid out! ${sui(L.ml.paid, 4)} SUI landed on this tile. ${n === 1 ? "The winner takes" : `${n || "The"} winners split`} ${sui(won, 4)} SUI`
    : won > 0 ? `${n === 1 ? "The winner takes" : `${n || "The"} winners split`} ${sui(won, 4)} SUI from the other tiles`
    : "Only this tile was played. Stakes returned.";
  if (L.ml?.winner) sub = `Wealth Fund paid ${sui(L.ml.paid, 4)} SUI to ticket holder ${acctLink(L.ml.winner)} · ` + sub;
  const top = winners[0], topProfit = top ? top.won - top.p.total : 0;
  if (top && topProfit > 0) sub += ` · Top <span${nameOf(top.p.player) ? "" : ' class="mono"'}>${esc(top.p.player === account?.address ? "You" : label(top.p.player))}</span> +${sui(topProfit, 4)} SUI`;
  // Your result is net of everything you deployed this round, so a win that returns less than you put in never reads as a gain.
  let me = "";
  const m = USER?.miner, back = m && m.round_id === L.round ? rewards().sui : 0, net = back - (m?.total || 0);
  if (back > 0) me = net > 0 ? `<div class="res-me won">You won <b>+${sui(net, 4)} SUI</b></div>${shareLink(net, L)}` : `<div class="res-me">Your tile won · <b>${sui(back, 4)} SUI back</b></div>`;
  const youWon = back > 0 && net > 0;
  if (youWon && fresh && cheered !== L.round) { cheered = L.round; toast(`You won +${sui(net, 4)} SUI on tile ${L.tile + 1}. ${shareLink(net, L)}`, false, true); }
  box.hidden = false;
  box.classList.toggle("fresh", !!fresh);
  box.classList.toggle("won", youWon);
  box.innerHTML = `<div class="res-main"><span class="res-tile">${L.tile + 1}</span><div><b>Round #${fmt(L.round, 0)} · Tile ${L.tile + 1} wins</b><small>${sub}</small></div></div>${me ? `<div class="res-side">${me}</div>` : ""}`;
}

let cheered = null;
// Prefilled X post for a win. `related` makes X suggest following @MineGTS1 right after the post goes out.
const shareUrl = (net, L) => "https://x.com/intent/post?" + new URLSearchParams({
  text: `Just won +${sui(net, 4)} SUI on tile ${L.tile + 1} in round #${fmt(L.round, 0)} of @MineGTS1

25 tiles, one winner every round, GTS mined on Sui. Pick your tile:`,
  url: "https://minegts.fun/", related: "MineGTS1",
});
const shareLink = (net, L) => `<a class="share-x" href="${shareUrl(net, L)}" target="_blank" rel="noopener">Share on X</a>`;
function renderRecent() {
  const list = (STATE?.recent || []).slice(0, 3);
  $("recent").innerHTML = list.length ? list.map(r =>
    `<a href="#explorer" class="rc${r.winners ? "" : " none"}" title="Round #${r.round}: ${sui(r.total, 3)} SUI deployed, ${r.players} ${r.players === 1 ? "player" : "players"}"><b>${r.tile + 1}</b><span>#${r.round}</span></a>`).join("")
    : `<span class="muted">No rounds yet.</span>`;
}

let feedKeys = new Set(), feedSig = "", feedAt = 0;
function renderFeed() {
  const b = STATE?.board, L = STATE?.last;
  if (!b) return;
  const live = b.cur_started;
  const r = live ? null : L;
  const round = live ? b.cur_id : L?.round;
  const players = round ? roundPlayers(round) : [];
  $("liveTitle").textContent = live ? `Live round #${fmt(b.cur_id, 0)}` : L ? `Round #${fmt(L.round, 0)} results` : "Live round";
  $("liveSub").textContent = live ? `${b.cur_players} ${b.cur_players === 1 ? "player" : "players"} · ${sui(b.cur_total, 3)} SUI` : "Next round starts with the first deploy";
  if (!players.length) {
    $("feed").innerHTML = `<p class="muted feed-empty">${live ? "No deploys yet." : "Waiting for the first deploy. Pick your tiles and start the next round."}</p>`;
    feedKeys = new Set(); feedSig = "";
    return;
  }
  const rows = (r ? players.slice().sort((x, y) => winOf(y, r) - winOf(x, r) || y.total - x.total) : players).map(p => {
    const idx = p.amounts.map((v, i) => (v > 0 ? i : -1)).filter(i => i >= 0);
    const you = p.player === account?.address;
    const key = `${round}:${p.player}:${p.total}`;
    const isNew = feedKeys.size > 0 && !feedKeys.has(key);
    let res = "";
    if (r) { const w = winOf(p, r), net = w - p.total; res = !w ? `<span class="res">No win</span>` : net > 0 ? `<span class="res won">+${sui(net, 4)} SUI</span>` : `<span class="res">${sui(w, 4)} SUI back</span>`; }
    return { key, html: `<div class="fr${isNew ? " new" : ""}${you ? " you" : ""}" data-tiles="${idx.join(",")}">
      <span class="av" style="--h:${hue(p.player)}"></span>
      <span class="who">${you ? "You" : `<a${nameOf(p.player) ? "" : ' class="mono"'} href="${SCAN}/account/${p.player}" target="_blank" rel="noopener">${esc(label(p.player))}</a>`}</span>
      <span class="tl">${tilesTxt(idx)}</span>
      <span class="am">${sui(p.total, 3)} SUI</span>${res}
      <span class="tm"><a href="${SCAN}/tx/${p.digest}" target="_blank" rel="noopener">${ago(p.ts)}</a></span></div>` };
  });
  // Rebuild only when the rows change (or every 10s for the "ago" times) so hover and entry animations survive.
  const sig = (r ? "r" : "l") + rows.map(x => x.key).join("|") + (account?.address || "");
  if (sig === feedSig && Date.now() - feedAt < 10_000) return;
  feedSig = sig; feedAt = Date.now();
  tileEls.forEach(c => c.classList.remove("peek"));
  $("feed").innerHTML = rows.map(x => x.html).join("");
  feedKeys = new Set(rows.map(x => x.key));
  $("feed").querySelectorAll(".fr").forEach(el => {
    const tiles = el.dataset.tiles.split(",").filter(Boolean).map(Number);
    el.onmouseenter = () => tiles.forEach(i => tileEls[i].classList.add("peek"));
    el.onmouseleave = () => tileEls.forEach(c => c.classList.remove("peek"));
  });
}

// What the deploy being set up would earn if the round ended right now, as game::settle and
// game::claim compute it, with the player's earlier deposits this round included. The GTS is
// split by share of the round; the SUI is for the case one of the selected tiles wins (Wealth Fund left out).
function estimate(per, p) {
  const b = STATE?.board;
  if (!b || !selected.size || !(per > 0) || (p !== "open" && p !== "live" && p !== "ended")) return null;
  const live = p === "live", round = p === "ended" ? b.cur_id + 1 : b.cur_id;
  const dep = live && b.cur_deployed?.length ? [...b.cur_deployed] : Array(25).fill(0);
  const m = USER?.miner, mine = live && m && m.round_id === b.cur_id ? [...m.deployed] : Array(25).fill(0);
  const a = Math.round(per * MIST);
  selected.forEach(i => { dep[i] += a; mine[i] += a; });
  const tot = dep.reduce((x, y) => x + y, 0), myTot = mine.reduce((x, y) => x + y, 0);
  const gts = roundReward() * Math.min(1, tot / em().full) * myTot / tot;
  const keep = 1 - (b.vault_bps + b.dev_bps + b.buyback_bps + (STATE.stake?.bps || 0) + (STATE.fundBps || 0)) / 10_000, fair = isFair(round);
  const wins = [...selected].map(i => {
    const share = (tot - dep[i]) * keep * mine[i] / dep[i];
    return (mine[i] + (fair ? share * mine[i] / myTot : share)) / MIST;
  });
  return { gts, lo: Math.min(...wins), hi: Math.max(...wins), cost: myTot / MIST };
}
function renderEstimate(per, p) {
  const e = estimate(per, p), el = $("estLine");
  el.hidden = !e;
  if (!e) return;
  const v = e.gts * gtsSui() * (PRICE.sui || 0);
  const win = e.lo === e.hi ? fmt(e.hi, 4) : `${fmt(e.lo, 4)}–${fmt(e.hi, 4)}`;
  el.innerHTML = `If the round ended now: mine <b>~${fmt(e.gts, 4)} GTS</b>${PRICE.sui && v > 0 ? ` (${usd(v)})` : ""}. `
    + `If ${selected.size === 1 ? "your tile" : "one of your tiles"} wins (${selected.size} in 25): <b>${win} SUI</b> back for ${fmt(e.cost, 4)} SUI in. `
    + `<span>Changes as others join.</span>`;
}

// Everything the connected wallet can claim right now.
function rewards() {
  const out = { ready: false, sui: 0, gts: 0 };
  const m = USER?.miner, b = STATE?.board;
  if (m && m.round_id !== 0 && b && m.round_id < b.cur_id) {
    out.ready = true;
    const r = (STATE.recent || []).find(x => x.round === m.round_id) || HIST?.rounds.find(x => x.round === m.round_id);
    if (r) {
      const w = m.deployed[r.tile] || 0;
      out.gts = Math.floor(gtsOf(r, w, m.total));
      out.sui = payoutOf(r, w, m.total, account?.address).back;
    }
  }
  out.any = out.ready;
  return out;
}
function renderRewards() {
  const R = rewards();
  $("rwSui").textContent = USER ? sui(R.sui, 4) : "—";
  $("rwGts").textContent = USER ? sui(R.gts, 4) : "—";
  $("rwSui").classList.toggle("won", R.sui > 0);
  if (busy && busy !== "btnClaimAll") $("btnClaimAll").disabled = true;
  if (!busy) {
    $("btnClaimAll").textContent = account ? "Claim all" : "Sign in";
    $("btnClaimAll").disabled = !!account && !R.any;
  }
  // Unrefined GTS: what waits, any holder bonus from before v6, and the 7-day withdraw countdown.
  const U = USER?.unrefined || { amount: 0, bonus: 0, start: 0 };
  $("refine").hidden = !USER;
  if (USER && STATE) {
    const now = Date.now(), fee = withdrawFee(U, now), full = `${fmt(STATE.refineFee * 100, 2)}%`;
    const out = U.amount - Math.floor(U.amount * fee) + U.bonus;
    const left = U.start ? U.start + REFINE_WINDOW_MS - now : REFINE_WINDOW_MS;
    $("rfAmt").textContent = sui(U.amount, 4);
    $("rfBonus").textContent = `+${sui(U.bonus, 4)}`;
    $("rfBonus").classList.toggle("won", U.bonus > 0);
    $("rfBonusRow").hidden = !(U.bonus > 0);
    $("rfHint").textContent = !(U.amount > 0)
      ? `Mined GTS waits here. Withdrawing is free 7 days after your last withdrawal; before that the fee falls from ${full} to 0, and it is burned.`
      : left <= 0 ? `Free to withdraw: no fee.`
      : `Free withdrawal in ${dhm(left)}. Now: ${fmt(fee * 100, 2)}% fee, burned. Withdrawing now pays ${sui(out, 4)} GTS.`;
    if (!busy) { $("btnWithdraw").disabled = !(U.amount > 0); $("btnWithdraw").textContent = U.amount > 0 ? `Withdraw ${sui(out, 4)} GTS` : "Withdraw"; }
    else if (busy !== "btnWithdraw") $("btnWithdraw").disabled = true;
  }
  const hc = $("hdrClaim");
  hc.hidden = !R.any;
  if (R.any) hc.textContent = R.sui > 0 ? `Claim ${sui(R.sui, 3)} SUI` : "Claim";
}

// Wealth Fund line: odds, the player's share of the tickets, then the last payout and who got it, or
// the rounds since it started filling.
function mlOddsText() {
  if (!STATE) return "";
  const v4 = !!STATE.tickets || !!WF_PKG;
  let t = v4 ? `1 in ${fmt(STATE.mlOdds, 0)} chance each round` : `1 in ${fmt(STATE.mlOdds, 0)} chance each round with a winner`;
  const total = STATE.tickets?.total || 0, mine = USER?.tickets || 0;
  if (v4 && account) t += mine > 0 && total > 0 ? ` · you hold ${fmt(mine / total * 100, mine / total < 0.01 ? 2 : 1)}% of the tickets` : " · you hold no tickets yet";
  if (HIST?.rounds.length) {
    const hit = HIST.rounds.find(r => r.ml?.paid > 0), start = HIST.rounds.filter(r => r.ml).pop();
    const since = hit ? HIST.rounds.filter(r => r.round > hit.round).length : start ? HIST.rounds.filter(r => r.round >= start.round).length : 0;
    if (hit) {
      const who = hit.ml.winner ? [acctLink(hit.ml.winner)] : [...playersOf(hit, HIST.byRound.get(hit.round) || [])].filter(([, a]) => a.onWin > 0).map(([p]) => acctLink(p));
      t = esc(t) + ` · Last paid ${sui(hit.ml.paid, 4)} SUI in round #${fmt(hit.round, 0)} to ${who.length ? who.join(", ") : "the winners"} · ${fmt(since, 0)} rounds ago`;
      return t;
    }
    t += ` · no payout yet, ${fmt(since, 0)} rounds so far`;
  }
  return esc(t);
}
function renderMine() {
  const b = STATE?.board, p = phase();
  $("sDeployed").textContent = b ? sui(b.cur_total, 3) : "—";
  $("sMotherlode").textContent = STATE ? `${sui(STATE.motherlode, 4)} SUI` : "—";
  $("sMlOdds").innerHTML = mlOddsText(); $("sMlOdds").title = $("sMlOdds").textContent;
  $("sRound").textContent = b ? `#${fmt(b.cur_id, 0)}` : "—";
  $("sPlayers").textContent = b ? fmt(b.cur_players, 0) : "—";
  let t = "—", lbl = "Time left", prog = 0;
  if (p === "open") { t = `${b.round_ms / 60_000}:00`; lbl = "Waiting"; prog = 1; }
  else if (p === "live" || p === "frozen") {
    const ms = Math.max(0, b.cur_end_ms - Date.now()), s = Math.ceil(ms / 1000);
    t = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; prog = ms / b.round_ms;
    if (p === "frozen") lbl = "Closing";
  } else if (p === "ended") {
    const auto = keeperDrawing(b);
    t = auto ? "Drawing" : "Ready"; lbl = auto ? "Picking the winner" : "Draw the winner";
  }
  $("sTime").textContent = t; $("sPhase").textContent = lbl;
  $("sProg").style.transform = `scaleX(${Math.min(1, prog).toFixed(4)})`;
  const bar = document.querySelector(".round-bar");
  bar.dataset.phase = p;
  bar.toggleAttribute("data-urgent", p === "live" && b.cur_end_ms - Date.now() <= 10_000);
  // Countdown in the tab title brings players back from other tabs.
  setTitle(p === "live" || p === "frozen" ? `${t} · Round #${b.cur_id} · GTStar` : p === "ended" ? `${t === "Ready" ? "Ready to draw" : "Drawing"} · GTStar` : "GTStar");

  const per = parseAmt($("amt").value);
  $("tileCount").textContent = selected.size;
  $("selRepeat").disabled = !lastDeploy();
  renderAlerts();
  $("totalCost").textContent = fmt(per * selected.size, 4);
  renderEstimate(per, p);
  $("mbTiles").textContent = `${selected.size} ${selected.size === 1 ? "tile" : "tiles"} · ${fmt(per, 4)} SUI each`;
  $("mbTotal").textContent = `Total ${fmt(per * selected.size, 4)} SUI`;

  const claimable = rewards().ready;
  const min = b ? b.min_deploy / MIST : 0.01;
  if (!busy) {
    let label = "Deploy", dis = false;
    if (!account) label = "Sign in to play";
    else if (p === "loading") { label = "Loading"; dis = true; }
    else if (p === "ended" && keeperDrawing(b)) { label = "Picking the winner"; dis = true; }
    else if (p === "ended") label = selected.size ? "Draw winner, then deploy" : "Draw winner";
    else if (p === "frozen") { label = "Round closing"; dis = true; }
    else if (!selected.size) { label = "Select tiles"; dis = true; }
    else if (per < min) { label = `Minimum ${min} SUI per tile`; dis = true; }
    else if (overCap()) { label = `Up to ${TILE_CAP} tiles per round`; dis = true; }
    else label = `Deploy ${fmt(per * selected.size, 4)} SUI`;
    $("btnPlay").textContent = label; $("btnPlay").disabled = dis;
  } else if (busy !== "btnPlay") { $("btnPlay").textContent = "Waiting for your wallet"; $("btnPlay").disabled = true; }
  let hint = `Minimum ${min} SUI per tile. Every SUI you lose mines GTS.`;
  if (claimable && (p === "open" || p === "live")) {
    const R = rewards();
    hint = `${per * selected.size > 0 ? `You pay ${fmt(per * selected.size, 4)} SUI. ` : ""}Your rewards from the last round${R.gts ? ` (${sui(R.gts, 4)} GTS${R.sui ? `, ${sui(R.sui, 4)} SUI` : ""})` : ""} are collected in the same transaction.`;
    if (!selected.size) hint = "Your rewards from the last round are collected with your next deploy, or use Claim all.";
  } else if (p === "ended") hint = keeperDrawing(b)
    ? "The round has ended. The winner is drawn within seconds."
    : "The round has ended. Draw the winner: whoever draws is paid up to 0.005 SUI for it.";
  else if (p === "frozen") hint = "Deposits close 5 seconds before the round ends.";
  else if (p === "open") hint = "The next round starts with the first deploy and runs for 60 seconds.";
  if (!account && WELCOME_OPEN) hint = "New here? Continue with Google and play your first 2 rounds free.";
  $("playHint").textContent = hint;
  $("boardHint").hidden = selected.size > 0 || p === "ended" || p === "frozen" || !!reveal?.landing;
  $("myGts").textContent = USER ? sui(USER.gts, 3) : "—";
  $("mySui").textContent = USER ? sui(USER.sui, 3) : "—";
  document.querySelector(".rw-bal").hidden = !USER;
  renderRewards(); renderResult(); renderRecent(); renderFeed();
}

// ---------- render: explorer ----------
const ROWS = 10;
let actShown = ROWS, revShown = ROWS, lbShown = ROWS, actTab = "rounds", revTab = "reserve", lbTab = "miners";
const openRounds = new Set();
const txLink = d => `<a href="${SCAN}/tx/${d}" target="_blank" rel="noopener" data-stop>${d.slice(0, 6)}…</a>`;
const acctLink = a => `<a href="${SCAN}/account/${a}" target="_blank" rel="noopener"${nameOf(a) ? "" : ' class="mono"'} data-stop>${esc(label(a))}</a>`;
// Players on the winning tile: address -> { onWin, total }.
function winnersOf(r) {
  const agg = playersOf(r, HIST.byRound.get(r.round) || []);
  agg.forEach((a, p) => { if (!a.onWin) agg.delete(p); });
  return agg;
}
const marketText = () => (STATE.market ? `${fmt(STATE.market, 6)} SUI` : "—");
function renderExplorer() {
  if (!STATE) return;
  const t = HIST?.totals;
  $("gFloor").textContent = `${N.floor()} SUI${N.floorUsd() ? ` · ${N.floorUsd()}` : ""}`;
  $("gReserve").textContent = `${N.reserve()} SUI`;
  $("gMarket").textContent = marketText();
  $("gSupernova").textContent = `${N.fund()} SUI`;
  $("gMlOdds").textContent = WF_PKG ? `1 in ${fmt(STATE.mlOdds, 0)} per round, to one ticket` : `1 in ${fmt(STATE.mlOdds, 0)} per round with a winner`;
  $("gSnPaid").textContent = t ? `${sui(t.snPaid, 4)} SUI` : "—";
  $("gDeployed").textContent = `${sui(STATE.board.cur_total, 3)} SUI`;
  $("gRounds").textContent = t ? fmt(t.rounds, 0) : "—";
  $("gVolume").textContent = t ? `${N.volume()} SUI` : "—";
  $("gMiners").textContent = t ? fmt(t.players, 0) : "—";
  $("gCost").textContent = t && t.emitted ? `${fmt(t.fees / t.emitted, 4)} SUI` : "—";
  $("gReward").textContent = `${fmt(roundReward(), 6)} GTS`;
  $("gNextCut").textContent = roundReward() > 0 ? `In ${fmt(em().step - em().count, 0)} rounds` : "Mining ended";
  $("gMined").textContent = `${N.mined()} GTS`;
  $("gSupply").textContent = `${N.supply()} GTS`;
  $("gBurned").textContent = t ? `${sui(t.burned, 3)} GTS` : "—";
  document.querySelectorAll(".tabset").forEach(ts => {
    const cur = { act: actTab, rev: revTab, lb: lbTab }[ts.dataset.set];
    ts.querySelectorAll("button").forEach(b => b.classList.toggle("on", b.dataset.t === cur));
  });
  if (!HIST) { $("actTbl").innerHTML = `<tbody><tr><td class="muted">Loading…</td></tr></tbody>`; return; }
  renderActivity(); renderRevenue(); renderLeaderboard();
  $("xScope").textContent = HIST.capped ? `History covers the most recent ${fmt(HIST.rounds.length, 0)} rounds.` : "";
}
function renderActivity() {
  const tbl = $("actTbl");
  if (actTab === "rounds") {
    $("actSub").textContent = "Recent mining rounds and winners. Select a round to see every miner.";
    const rows = HIST.rounds.slice(0, actShown);
    const head = `<thead><tr><th>Round</th><th>Tile</th><th>Winner</th><th class="r">Winners</th><th class="r">Deployed</th><th class="r">Vaulted</th><th class="r">Won from others</th><th class="r">Wealth Fund</th><th class="r">GTS mined</th><th class="r">Time</th></tr></thead>`;
    const body = rows.map(r => {
      const w = winnersOf(r);
      const winner = w.size === 0 ? `<span class="muted">No winner</span>` : w.size === 1 ? acctLink([...w.keys()][0]) : "Split";
      const sn = r.ml?.paid > 0 ? `<span class="gold">Hit ${sui(r.ml.paid, 4)}</span>` : r.ml?.added > 0 ? `+${sui(r.ml.added, 4)}` : "–";
      const winnings = wonFromOthers(r);
      let html = `<tr class="round" data-r="${r.round}" tabindex="0" aria-expanded="${openRounds.has(r.round)}">
        <td><b>#${fmt(r.round, 0)}</b></td><td><span class="tile-badge${w.size ? "" : " none"}">#${r.tile + 1}</span></td><td>${winner}</td>
        <td class="r">${w.size}</td><td class="r">${sui(r.total, 3)}</td><td class="r">${sui(vaulted(r), 4)}</td>
        <td class="r">${winnings ? sui(winnings, 3) : "–"}</td><td class="r">${sn}</td><td class="r">${sui(r.reward, 3)}</td>
        <td class="r muted">${txLinkAgo(r)}</td></tr>`;
      if (openRounds.has(r.round)) html += `<tr class="detail"><td colspan="10">${minersHtml(r)}</td></tr>`;
      return html;
    }).join("");
    tbl.innerHTML = head + `<tbody>${body || `<tr><td colspan="10" class="muted">No rounds settled yet.</td></tr>`}</tbody>`;
    tbl.querySelectorAll("a[data-stop]").forEach(a => a.addEventListener("click", e => e.stopPropagation()));
    tbl.querySelectorAll("tr.round").forEach(tr => {
      const toggle = () => { const n = +tr.dataset.r; openRounds.has(n) ? openRounds.delete(n) : openRounds.add(n); renderActivity(); };
      tr.onclick = toggle;
      tr.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } };
    });
    $("moreAct").hidden = HIST.rounds.length <= actShown;
  } else {
    $("actSub").textContent = "Every deploy, newest first.";
    const rows = HIST.deployed.slice(0, actShown);
    tbl.innerHTML = `<thead><tr><th>Miner</th><th>Round</th><th class="r">Tiles</th><th class="r">Deployed</th><th class="r">Time</th></tr></thead><tbody>` +
      (rows.map(e => `<tr><td>${acctLink(e.j.player)}</td><td>#${fmt(num(e.j.round_id), 0)}</td>
        <td class="r">${(e.j.amounts || []).filter(a => num(a) > 0).length}</td><td class="r">${sui(num(e.j.total), 3)}</td>
        <td class="r muted"><a href="${SCAN}/tx/${e.digest}" target="_blank" rel="noopener">${ago(e.ts)}</a></td></tr>`).join("")
        || `<tr><td colspan="5" class="muted">No deploys yet.</td></tr>`) + `</tbody>`;
    $("moreAct").hidden = HIST.deployed.length <= actShown;
  }
}
const txLinkAgo = r => `<a href="${SCAN}/tx/${r.digest}" target="_blank" rel="noopener" data-stop>${ago(r.ts)}</a>`;
function minersHtml(r) {
  const list = HIST.byRound.get(r.round) || [];
  if (!list.length) return `<span class="muted">No deploy events found for this round.</span>`;
  const agg = playersOf(r, list);
  return `<div class="miners">` + [...agg.entries()].sort((x, y) => y[1].total - x[1].total).map(([p, a]) => {
    const back = payoutOf(r, a.onWin, a.total, p).back, net = back - a.total;
    const gts = gtsOf(r, a.onWin, a.total);
    return `<div class="m">${acctLink(p)}<span>${sui(a.total, 3)} SUI deployed · ${sui(gts, 4)} GTS mined</span>
      <span class="${net > 0 ? "won" : "muted"}">${net > 0 ? `Won +${sui(net, 4)} SUI` : back > 0 ? `${sui(back, 4)} SUI back` : "No SUI win"}</span></div>`;
  }).join("") + `</div>`;
}
function renderRevenue() {
  const cfg = {
    reserve: { v: vaulted, unit: "SUI", share: "Reserve fee, plus the rest when no one wins", label: "Added to the GTS reserve" },
    supernova: { v: r => r.ml?.added || 0, unit: "SUI", share: "2% of every losing pot, more when no one wins", label: "Added to the Wealth Fund" },
  }[revTab];
  const rows = HIST.rounds.filter(r => cfg.v(r) > 0);
  const total = rows.reduce((a, r) => a + cfg.v(r), 0);
  const day = Date.now() - 86_400_000;
  const d24 = rows.filter(r => new Date(r.ts).getTime() >= day).reduce((a, r) => a + cfg.v(r), 0);
  $("revSum").innerHTML = `<div><span>All time</span><b>${sui(total, 4)} ${cfg.unit}</b></div><div><span>Last 24h</span><b>${sui(d24, 4)} ${cfg.unit}</b></div><div><span>Source</span><b>${cfg.share}</b></div>`;
  $("revTbl").innerHTML = `<thead><tr><th>Round</th><th>${cfg.label}</th><th class="r">Amount</th><th class="r">Time</th></tr></thead><tbody>` +
    (rows.slice(0, revShown).map(r => `<tr><td>#${fmt(r.round, 0)}</td><td class="muted">${revTab === "supernova" ? "No miner on the winning tile" : r.winners === 0 ? "Fee plus pot (no miner on winning tile)" : r.split?.reserve > 0 ? "Fee plus winnings not kept (spread stakes, rounds 1-20)" : "Fee from losing pot"}</td>
      <td class="r">${sui(cfg.v(r), 5)} ${cfg.unit}</td><td class="r muted"><a href="${SCAN}/tx/${r.digest}" target="_blank" rel="noopener">${ago(r.ts)}</a></td></tr>`).join("")
      || `<tr><td colspan="4" class="muted">Nothing yet.</td></tr>`) + `</tbody>`;
  $("moreRev").hidden = rows.length <= revShown;
}
function renderLeaderboard() {
  let rows = [], sub = "";
  const unit = "SUI";
  if (lbTab === "miners") {
    sub = "Top miners by total SUI deployed.";
    const m = new Map(); HIST.deployed.forEach(e => m.set(e.j.player, (m.get(e.j.player) || 0) + num(e.j.total)));
    rows = [...m.entries()];
  } else if (lbTab === "winners") {
    sub = "Top winners by SUI won from other tiles (stakes returned are not counted).";
    const m = new Map();
    HIST.rounds.forEach(r => { if (!r.winners) return; winnersOf(r).forEach((a, p) => m.set(p, (m.get(p) || 0) + payoutOf(r, a.onWin, a.total, p).back - a.onWin)); });
    rows = [...m.entries()].filter(([, v]) => v > 0);
  }
  $("lbSub").textContent = sub;
  rows = rows.filter(([p]) => !BOTS.has(p));
  rows.sort((a, b) => b[1] - a[1]);
  $("lbTbl").innerHTML = `<thead><tr><th>Rank</th><th>Address</th><th class="r">Total</th></tr></thead><tbody>` +
    (rows.slice(0, lbShown).map(([p, v], i) => `<tr><td>#${i + 1}</td><td>${acctLink(p)}</td><td class="r">${sui(v, 4)} ${unit}</td></tr>`).join("")
      || `<tr><td colspan="3" class="muted">Nothing here yet.</td></tr>`) + `</tbody>`;
  $("moreLb").hidden = rows.length <= lbShown;
}

// ---------- render: tokenomics ----------
function renderTokenomics() {
  if (!STATE) return;
  $("kSupply").textContent = N.supply();
  $("kSchedMax").textContent = fmt(MAX_GTS, 0);
  $("kReserve").textContent = `${N.reserve()} SUI`;
  $("kPrice").textContent = PRICE.sui ? usd(gtsSui() * PRICE.sui) : `${fmt(gtsSui(), 5)} SUI`;
  const round = STATE.board.cur_id, e = em(), r = roundReward();
  $("kEpochLbl").textContent = `${fmt(e.committed / MIST, 2)} of ${fmt(MAX_GTS, 0)} GTS mined`;
  $("kRound").textContent = `#${fmt(round, 0)}`;
  $("kReward").textContent = `Up to ${fmt(r, 6)} GTS`;
  $("kToHalving").textContent = r > 0 ? `-${fmt(e.decay / 1e4, 3)}% in ${fmt(e.step - e.count, 0)} rounds` : "Mining ended";
  drawChart(STATE.board.cur_id - 1);
}
let chartSize = 0;
function drawChart(played) {
  const box = $("chart");
  const W = box.clientWidth, H = box.clientHeight;
  if (!W) return;
  const pad = { l: 48, r: 14, t: 12, b: 26 };
  const X0 = 0, X1 = lastRound();
  const Y = MAX_GTS;
  const x = t => pad.l + ((t - X0) / (X1 - X0)) * (W - pad.l - pad.r);
  const y = v => H - pad.b - (v / Y) * (H - pad.t - pad.b);
  const pts = [];
  for (let i = 0; i <= 200; i++) { const t = X0 + (X1 - X0) * i / 200; pts.push(`${x(t).toFixed(1)},${y(schedule(t).total).toFixed(1)}`); }
  const line = "M" + pts.join("L");
  const area = `${line}L${x(X1).toFixed(1)},${y(0)}L${x(X0)},${y(0)}Z`;
  const k = v => (v === 0 ? "0" : v >= 1e6 ? `${fmt(v / 1e6, 2)}M` : `${fmt(v / 1e3, 0)}K`);
  const yt = [0, Y / 4, Y / 2, Y * 3 / 4, Y];
  const narrow = W < 560;
  const xt = (narrow ? [0, 0.5] : [0, 0.25, 0.5, 0.75]).map(f => Math.round(X1 * f / 100_000) * 100_000);
  // The dot is what was really mined: rounds below the full-reward deposit mint less than the line.
  const now = Math.min(Math.max(played, X0), X1);
  const nx = x(now), ny = y(Math.min(em().committed / MIST, MAX_GTS));
  box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Maximum cumulative GTS by rounds played: the reward drops ${fmt(em().decay / 1e4, 3)}% every ${fmt(em().step, 0)} rounds until 1,000,000 GTS.">
    ${yt.map(v => `<line class="ax" x1="${pad.l}" x2="${W - pad.r}" y1="${y(v)}" y2="${y(v)}" opacity="${v ? 0.5 : 1}"/><text class="tick" x="${pad.l - 8}" y="${y(v) + 4}" text-anchor="end">${k(v)}</text>`).join("")}
    ${xt.map(t => `<text class="tick" x="${x(t)}" y="${H - 6}" text-anchor="${t ? "middle" : "start"}">Round ${narrow ? k(t) : fmt(t, 0)}</text>`).join("")}
    <path class="ar" d="${area}"/><path class="ln" d="${line}"/>
    <line class="nowline" x1="${nx}" x2="${nx}" y1="${pad.t}" y2="${y(0)}"/>
    <circle class="now" cx="${nx}" cy="${ny}" r="5"/>
    <g id="hov" visibility="hidden"><line class="cross" id="hx" y1="${pad.t}" y2="${y(0)}"/><circle class="dot" id="hd" r="4"/></g>
    <rect x="${pad.l}" y="0" width="${W - pad.l - pad.r}" height="${H - pad.b}" fill="transparent" id="hit"/>
  </svg><div class="chart-tip" id="tip" hidden></div>`;
  const hit = box.querySelector("#hit"), hov = box.querySelector("#hov"), tip = box.querySelector("#tip");
  const move = clientX => {
    const rect = box.getBoundingClientRect();
    const f = Math.max(0, Math.min(1, (clientX - rect.left - pad.l) / (W - pad.l - pad.r)));
    const t = Math.round(X0 + f * (X1 - X0)), sc = schedule(t), v = sc.total;
    hov.setAttribute("visibility", "visible");
    box.querySelector("#hx").setAttribute("x1", x(t)); box.querySelector("#hx").setAttribute("x2", x(t));
    box.querySelector("#hd").setAttribute("cx", x(t)); box.querySelector("#hd").setAttribute("cy", y(v));
    tip.hidden = false; tip.style.left = `${Math.min(Math.max(x(t), 100), W - 100)}px`; tip.style.top = `${y(v)}px`;
    tip.innerHTML = `<b>Round ${fmt(t, 0)}</b><br>Up to <b>${fmt(v, 0)}</b> GTS · ${fmt(sc.next, 4)} per round`;
  };
  hit.onmousemove = e => move(e.clientX);
  hit.ontouchmove = e => move(e.touches[0].clientX);
  hit.onmouseleave = () => { hov.setAttribute("visibility", "hidden"); tip.hidden = true; };
  chartSize = W;
}

// ---------- render: stake ----------
const myPos = () => USER?.stake?.[stakeKind] || null;
function renderStake() {
  if (!STATE) return;
  const S = STATE.stake, U = USER?.stake, now = Date.now();
  const f = U?.flex, l = U?.lock;
  $("sFlex").textContent = USER ? `${sui(f?.amount || 0, 4)} GTS` : "—";
  const lockLeft = l && l.until > now ? Math.ceil((l.until - now) / 3600_000) : 0;
  $("sLock").textContent = USER ? `${sui(l?.amount || 0, 4)} GTS${l?.amount ? lockLeft ? ` · unlocks in ${lockLeft >= 24 ? `${Math.ceil(lockLeft / 24)}d` : `${lockLeft}h`}` : " · unlocked" : ""}` : "—";
  const pending = posYield(f) + posYield(l);
  $("sPending").textContent = USER ? `${sui(Number(pending), 6)} SUI` : "—";
  // APR: yearly SUI per weight unit, over the value of the GTS behind it.
  const px = gtsSui();
  // No APR until the game has 7 days of rounds: a few hours scaled to a year says nothing.
  const aprReady = Date.now() - GAME_LAUNCH >= 7 * 86_400_000;
  const aprFlex = aprReady && S && S.weight > 0 && px > 0 ? S.yearly * 10 / S.weight / px * 100 : null;
  const aprTxt = a => (!aprReady ? "After 7 days" : a == null ? "—" : `${fmt(a, a < 10 ? 2 : 0)}%`);
  $("sAprFlex").textContent = aprTxt(aprFlex);
  $("sAprLock").textContent = aprTxt(aprFlex == null ? null : aprFlex * 1.5);
  $("sStaked").textContent = S ? `${sui(S.amount, 3)} GTS` : "—";
  $("sPaid").textContent = S ? `${sui(S.paid, 4)} SUI` : "—";
  $("stakeNote").textContent = `Stakers share ${S ? fmt(S.bps / 100, 2) : 3}% of every round's losing pot, paid in SUI. Locked stakes count 1.5x. ${aprReady ? "APR is based on the last 7 days of rounds and changes with how much is played." : "APR shows once the game has 7 days of rounds."}`;
  document.querySelectorAll("#stakeSeg button").forEach(b => b.setAttribute("aria-selected", String(b.dataset.mode === stakeMode)));
  document.querySelectorAll("#stakeKind button").forEach(b => b.setAttribute("aria-selected", String(b.dataset.kind === stakeKind)));
  const pos = myPos();
  const avail = stakeMode === "deposit" ? (USER?.gts || 0) : (pos?.amount || 0);
  $("stakeBal").textContent = `${USER ? sui(avail, 4) : 0} GTS ${stakeMode === "deposit" ? "in wallet" : "staked"}`;
  const lockedNow = stakeKind === "lock" && pos && pos.until > now;
  $("stakeHint").textContent = stakeKind === "lock"
    ? (stakeMode === "deposit" ? "Locked for 7 days at 1.5x. Adding more restarts the 7 days for the whole locked stake." : lockedNow ? "Locked stakes can be withdrawn once their 7 days have passed." : "Your lock has ended: withdraw any time.")
    : "Flexible: withdraw any time.";
  if (!busy) {
    const btn = $("btnStake"), amt = toMist($("stakeAmt").value);
    let label = stakeMode === "deposit" ? "Deposit" : "Withdraw", dis = false;
    if (!account) label = "Sign in";
    else if (!S) { label = "Staking opens soon"; dis = true; }
    else if (stakeMode === "withdraw" && lockedNow) { label = "Locked"; dis = true; }
    else if (amt <= 0) dis = true;
    else if (amt > avail) { label = stakeMode === "deposit" ? "Insufficient GTS" : "Exceeds your stake"; dis = true; }
    btn.textContent = label; btn.disabled = dis;
    $("btnStakeClaim").disabled = !account || pending <= 0n;
  }
}

// ---------- prices + trade ----------
let PRICE = { sui: null };
// A failed or rate-limited source never overwrites the last good price.
const okPrice = sui => (sui > 0 && isFinite(sui) ? { sui } : null);
const getJson = (url, ms = 8000) => within(fetch(url).then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); }), ms);
async function loadPrice() {
  let p = null;
  // Binance, then Coinbase: both allow browser calls (CoinGecko's free API was blocked by CORS).
  try {
    const j = await getJson("https://api.binance.com/api/v3/ticker/price?symbol=SUIUSDT");
    p = okPrice(+j.price);
  } catch {}
  if (!p) try {
    const j = await getJson("https://api.coinbase.com/v2/prices/SUI-USD/spot");
    p = okPrice(+j.data?.amount);
  } catch {}
  if (p) PRICE = p;
  render();
  return !!p;
}
// $1.23, $0.0456, $0.000123: two decimals above $1, three significant digits below.
const usd = x => x == null || !isFinite(x) ? "—" : x >= 1 ? `$${fmt(x, 2)}` : x === 0 ? "$0" : `$${Number(x.toPrecision(3))}`;
// Header GTS price: the pool (market) price; the reserve floor only while there is no pool price.
const gtsSui = () => (STATE ? STATE.market || STATE.floor : 0);
function renderTicker() {
  $("tSuiUsd").textContent = usd(PRICE.sui);
  $("tGtsUsd").textContent = STATE ? (PRICE.sui ? usd(gtsSui() * PRICE.sui) : `${fmt(gtsSui(), 5)} SUI`) : "—";
  $("tGts").title = STATE?.market ? "GTS market price, Cetus GTS/SUI pool" : "GTS, valued at the reserve floor";
}

let swapDir = "sell";   // sell: GTS -> SUI via the pool or the reserve, whichever pays more; buy: SUI -> GTS from the pool
function renderTrade() {
  const sell = swapDir === "sell";
  const [tin, tout] = sell ? ["GTS", "SUI"] : ["SUI", "GTS"];
  $("swTokIn").textContent = tin; $("swTokOut").textContent = tout;
  $("swIconIn").className = `tok ${tin.toLowerCase()}`; $("swIconOut").className = `tok ${tout.toLowerCase()}`;
  const balIn = USER ? (sell ? USER.gts : USER.sui) : 0, balOut = USER ? (sell ? USER.sui : USER.gts) : 0;
  $("swBalIn").textContent = USER ? `Balance ${sui(balIn, 4)}` : "Balance —";
  $("swBalOut").textContent = USER ? `Balance ${sui(balOut, 4)}` : "";
  const need = toMist($("swIn").value);
  const viaPool = sell ? sellViaPool(need) : true;
  const outMist = sell ? (viaPool ? poolOut(need, true) : reserveOut(need)) : poolOut(need, false);
  const known = need > 0 && outMist > 0;
  $("swOut").textContent = known ? fmt(outMist / MIST, 6) : "—";
  // Each side at its own market value (GTS at the pool price), so fee and price impact show as the gap.
  const gtsSuiPx = STATE?.market || STATE?.floor || 0;
  const val = (mist, isGts) => (PRICE.sui ? usd(mist / MIST * (isGts ? gtsSuiPx : 1) * PRICE.sui) : "");
  $("swUsdIn").textContent = need > 0 ? val(need, sell) : "";
  $("swUsdOut").textContent = known ? val(outMist, !sell) : "";
  const rate = known ? (sell ? outMist / need : need / outMist) : sell ? STATE?.floor : STATE?.market;
  $("swRate").textContent = rate ? `1 GTS = ${fmt(rate, 6)} SUI` : "—";
  // Price impact: how far this trade's price is from the pool's current price, fee included.
  const spot = STATE?.market || 0, px = known ? (sell ? outMist / need : need / outMist) : 0;
  const impact = viaPool && spot && px ? (sell ? 1 - px / spot : px / spot - 1) : 0;
  const warn = impact >= 0.05;
  $("swHint").classList.toggle("warn", warn);
  $("swHint").textContent = warn
    ? `Price impact ${fmt(impact * 100, 1)}%. ${sell ? "You receive" : "You pay"} ${fmt(impact * 100, 1)}% ${sell ? "less" : "more per GTS"} than at the current pool price of ${fmt(spot, 6)} SUI per GTS, because the pool is small. A smaller amount gets a better price.`
    : sell
    ? "Sells at the better of two prices: the GTS/SUI pool, or the on-chain reserve at the floor price (the GTS is burned). The route is picked for the exact amount."
    : "Buys GTS directly from the GTS/SUI pool. The price moves with the size of the trade.";
  if (!busy) {
    const btn = $("btnSwap"), tok = sell ? "GTS" : "SUI";
    let label = "Swap", dis = false;
    if (!account) label = "Sign in";
    else if (need <= 0) { label = "Enter an amount"; dis = true; }
    else if (need > balIn) { label = `Insufficient ${tok}`; dis = true; }
    else if (!sell && !IDS.market) { label = "No GTS/SUI pool yet"; dis = true; }
    else if (sell && !known) { label = STATE?.supply && need > STATE.supply ? "Exceeds GTS supply" : "No quote for this amount"; dis = true; }
    else if (!sell && QUOTE.amt === need && !QUOTE.a2b && QUOTE.exceed) { label = "Not enough liquidity"; dis = true; }
    btn.textContent = label; btn.disabled = dis;
  }
}
// Amount the percentage buttons work from: all GTS when selling, SUI minus gas when buying.
const swapMax = () => (swapDir === "sell"
  ? (NO_AB.has(wallet?.name) ? USER.gtsCoins.reduce((a, c) => a + c.balance, 0) : USER.gts)
  : Math.max(0, USER.sui - 2 * GAS_RESERVE));

function render() {
  if (view !== "mine") setTitle("GTStar");
  renderTicker(); renderWallet(); renderRewards();
  if (view === "home") renderHome();
  if (view === "mine") { renderBoard(); renderMine(); }
  if (view === "trade") renderTrade();
  if (view === "explorer") renderExplorer();
  if (view === "tokenomics") renderTokenomics();
  if (view === "stake") renderStake();
}
// Refreshes overlap (poll, wallet change, after a transaction). A reply only counts if nothing newer has
// been shown yet and, for the wallet view, the same wallet is still signed in; the board and the wallet
// load independently so one slow or failed read never holds back the other.
// The last protocol state is kept in the browser and shown the moment the page opens, so the numbers
// are never blank while Sui answers; the live read replaces it within a second.
// One snapshot per game board: a snapshot of another game (the first one) must never be shown or kept.
const SNAP_KEY = `gtstar.state.${IDS.board}`;
function saveSnap(g) { try { localStorage.setItem(SNAP_KEY, JSON.stringify({ at: Date.now(), g }, (k, v) => typeof v === "bigint" ? { $b: String(v) } : v)); } catch {} }
function loadSnap() {
  try {
    const s = JSON.parse(localStorage.getItem(SNAP_KEY), (k, v) => v && typeof v === "object" && "$b" in v ? BigInt(v.$b) : v);
    if (s && Date.now() - s.at < 6 * 3600_000 && !STATE) { STATE = s.g; render(); pollBoard(); }
  } catch {}
}
let seqG = 0, seqU = 0, shownG = 0, shownU = 0;
async function refresh() {
  const sg = ++seqG, su = ++seqU, addr = account?.address;
  const g = loadGlobal().then(g => {
    if (sg < shownG) return;
    if (STATE?.board && newerBoard(STATE.board, g.board)) g.board = STATE.board;
    shownG = sg; STATE = g; trackRounds(); render(); saveSnap(g);
  }, e => console.warn("refresh failed", e));
  const u = (addr ? loadUser(addr) : Promise.resolve(null)).then(u => {
    if (su < shownU || account?.address !== addr) return;
    shownU = su; USER = u; render(); renderWelcome();
  }, e => console.warn("wallet refresh failed", e));
  await Promise.all([g, u]);
  // The first load reads the wallet before the staking pool is known: read the positions once it is.
  if (USER && !USER.stake && STATE?.stake && account?.address === addr) {
    const st = await loadStake(addr).catch(() => null);
    if (USER && account?.address === addr) { USER.stake = st; render(); }
  }
  // A round to claim older than the last 12 is only in the full history: load it so the amounts show.
  const m = USER?.miner;
  if (STATE && !HIST && m && m.round_id !== 0 && m.round_id < STATE.board.cur_id && !STATE.recent.some(r => r.round === m.round_id)) refreshHistory();
}
let histBusy = false;
async function refreshHistory() {
  if (histBusy) return; histBusy = true;
  try { HIST = await loadHistory(); render(); } catch (e) { console.warn("history failed", e); }
  histBusy = false;
}

// ---------- routing ----------
function route() {
  if (stale && !busy) return location.reload();
  const v = (location.hash || "#home").slice(1);
  view = VIEWS.includes(v) ? v : "home";
  VIEWS.forEach(n => ($("view-" + n).hidden = n !== view));
  document.body.classList.toggle("on-home", view === "home");
  document.body.classList.toggle("on-mine", view === "mine");
  document.querySelectorAll(".tabs a[data-view]").forEach(a => a.classList.toggle("on", a.dataset.view === view));
  $("moreBtn").classList.toggle("on", !!$("moreMenu").querySelector(`[data-view="${view}"]`));
  $("moreMenu").hidden = true; $("moreBtn").setAttribute("aria-expanded", "false");
  window.scrollTo(0, 0);
  render();
  if (["home", "mine", "explorer", "tokenomics"].includes(view)) refreshHistory();
}

// ---------- wire ----------
$("btnConnect").onclick = e => {
  if (!account) return openWalletModal();
  e.stopPropagation(); $("acctMenu").hidden = !$("acctMenu").hidden;
};
document.addEventListener("click", e => {
  if (!e.target.closest(".acct")) $("acctMenu").hidden = true;
  if (!e.target.closest(".more")) { $("moreMenu").hidden = true; $("moreBtn").setAttribute("aria-expanded", "false"); }
});
$("moreBtn").onclick = () => { const m = $("moreMenu"); m.hidden = !m.hidden; $("moreBtn").setAttribute("aria-expanded", String(!m.hidden)); };
$("mDisconnect").onclick = disconnect;
async function loadNames() {
  try { const r = await fetch("/api/names", { cache: "no-store" }); if (r.ok) { NAMES = await r.json(); renderWallet(); render(); } } catch {}
}
loadNames(); setInterval(loadNames, 60_000);
$("mName").onclick = () => {
  const f = $("mNameForm"); f.hidden = !f.hidden;
  if (!f.hidden) { $("mNameIn").value = nameOf(account.address); $("mNameIn").focus(); }
};
$("mNameForm").onsubmit = async e => {
  e.preventDefault();
  const name = $("mNameIn").value.trim().replace(/\s+/g, " ");
  if (name === nameOf(account.address)) { $("mNameForm").hidden = true; return; }
  if (name && !/^[A-Za-z0-9][A-Za-z0-9 ._-]{1,14}[A-Za-z0-9]$/.test(name)) return toast("3 to 16 characters: letters, numbers, space, dot, dash or underscore.", true);
  const signer = wallet?.features["sui:signPersonalMessage"];
  if (!signer) return toast("This wallet cannot sign messages.", true);
  const btn = $("mNameSave"); btn.disabled = true; btn.textContent = "Sign…";
  try {
    const address = account.address, ts = Date.now();
    const message = new TextEncoder().encode(`GTStar username: ${name}\nAddress: ${address}\nTime: ${ts}`);
    const { signature } = await signer.signPersonalMessage({ message, account, chain: CHAIN });
    btn.textContent = "Saving…";
    const r = await fetch("/api/names", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ address, name, ts, signature }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) return toast(j.error || "Could not save the username.", true);
    if (name) NAMES[address] = name; else delete NAMES[address];
    $("mNameForm").hidden = true; renderWallet(); render();
    toast(name ? `Username set: ${name}` : "Username removed.");
  } catch (err) {
    toast(/reject|cancel|denied/i.test(err?.message || "") ? "Signature cancelled." : "Could not sign the message.", true);
  } finally { btn.disabled = false; btn.textContent = "Save"; }
};
// ---------- two free rounds ----------
// A brand-new wallet made with Google or Apple (Slush in the browser) gets enough SUI for two 0.01 SUI rounds.
// welcome.php checks the signed request; the keeper sends the SUI within seconds.
fetch("/api/welcome", { cache: "no-store" }).then(r => r.json()).then(j => { WELCOME_OPEN = !!j.open; render(); }).catch(() => {});
async function loadWelcome() {
  const addr = account?.address;
  if (!addr || !isWeb(wallet)) { WELCOME = null; return renderWelcome(); }
  try {
    const r = await fetch(`/api/welcome?address=${addr}`, { cache: "no-store" });
    const j = r.ok ? await r.json() : null;
    if (account?.address !== addr) return;
    const was = WELCOME?.addr === addr ? WELCOME.status : null;
    WELCOME = j && { ...j, addr };
    if (was === "queued" && j?.status === "sent") welcomeArrived();
  } catch {}
  renderWelcome();
}
// A new player sees the gift as a popup right after signing in (once per account), then as a gold box by Deploy.
const welcomeShown = new Set();
function renderWelcome() {
  const w = account && WELCOME?.addr === account.address ? WELCOME : null;
  const fresh = USER && !USER.miner && USER.sui === 0;
  const show = !!w && ((w.status === "none" && w.open && fresh) || w.status === "queued");
  $("welcome").hidden = !show;
  if (!show) { if (!$("welcomeModal").hidden && $("wlBtn").dataset.state !== "sent") $("welcomeModal").hidden = true; return; }
  const amt = sui(w.amount || 0, 3);
  const queued = w.status === "queued";
  $("welcomeTxt").textContent = queued ? `Sending ${amt} SUI to your wallet…` : `Claim ${amt} SUI free and play your first 2 rounds.`;
  $("btnWelcome").disabled = queued;
  $("btnWelcome").textContent = queued ? "Sending" : "Claim";
  $("wlAmt").textContent = amt;
  $("wlTitle").textContent = "Your first 2 rounds are on us";
  $("wlTxt").textContent = queued ? "Sending the SUI to your wallet. This takes a few seconds." : "Claim free SUI and play your first 2 rounds. No deposit, no card.";
  $("wlBtn").dataset.state = queued ? "queued" : "claim";
  $("wlBtn").disabled = queued;
  $("wlBtn").textContent = queued ? "Sending to your wallet…" : `Claim ${amt} SUI free`;
  $("wlNote").hidden = queued;
  if (!welcomeShown.has(account.address)) {
    welcomeShown.add(account.address);
    if (view !== "mine") location.hash = "#mine";
    $("walletModal").hidden = true;
    $("welcomeModal").hidden = false;
  }
  if (queued && !welcomePoll) welcomePoll = setInterval(loadWelcome, 3000);
}
async function welcomeArrived() {
  clearInterval(welcomePoll); welcomePoll = null;
  await refresh();
  const min = STATE?.board.min_deploy || 10_000_000;
  $("amt").value = String(min / MIST);
  render();
  const picked = selected.size > 0;
  const amt = sui(WELCOME.amount, 3);
  $("wlTitle").textContent = `${amt} SUI is in your wallet`;
  $("wlAmt").textContent = amt;
  $("wlTxt").textContent = picked ? "Deploy your tile now and play your first free round. The second one is on us too." : "Pick any tile you like, then deploy it to play your first free round. The second one is on us too.";
  $("wlBtn").dataset.state = "sent";
  $("wlBtn").disabled = false;
  $("wlBtn").textContent = picked ? "Play my free round" : "Pick my tile";
  $("wlNote").hidden = true;
  $("welcomeModal").hidden = false;
}
async function claimWelcome() {
  const signer = wallet?.features["sui:signPersonalMessage"];
  if (!signer || !account) return;
  const btn = $("btnWelcome"), big = $("wlBtn");
  btn.disabled = big.disabled = true; btn.textContent = "Sign…"; big.textContent = "Approve in the popup…";
  try {
    const address = account.address, ts = Date.now();
    const message = new TextEncoder().encode(`GTStar welcome
Address: ${address}
Time: ${ts}`);
    const { signature } = await signer.signPersonalMessage({ message, account, chain: CHAIN });
    btn.textContent = "Sending"; big.textContent = "Sending to your wallet…";
    const r = await fetch("/api/welcome", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ address, ts, signature }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { WELCOME = null; $("welcomeModal").hidden = true; renderWelcome(); return toast(j.error || "Could not get the free rounds.", true); }
    WELCOME = { ...WELCOME, status: j.status, addr: address };
    if (j.status === "sent") return welcomeArrived();
  } catch (err) {
    toast(/reject|cancel|denied/i.test(err?.message || "") ? "Signature cancelled." : "Could not sign the message.", true);
  }
  renderWelcome();
}
$("btnWelcome").onclick = claimWelcome;
$("wlBtn").onclick = () => {
  if ($("wlBtn").dataset.state !== "sent") return claimWelcome();
  $("welcomeModal").hidden = true;
  if (view !== "mine") location.hash = "#mine";
  if (selected.size) $("btnPlay").click();
  else toast("Tap a tile on the board, then deploy.");
};
$("wlClose").onclick = () => ($("welcomeModal").hidden = true);
$("welcomeModal").onclick = e => { if (e.target.id === "welcomeModal") $("welcomeModal").hidden = true; };
$("mBuy").onclick = async () => {
  // Opened synchronously so popup blockers allow it; the address is copied for the player to paste in MoonPay.
  window.open("https://buy.moonpay.com/?defaultCurrencyCode=sui", "_blank", "noopener");
  try { await navigator.clipboard.writeText(account.address); toast("Your address is copied. Paste it in MoonPay as the wallet address."); }
  catch { toast(`Paste this address in MoonPay as the wallet address: ${account.address}`); }
};
$("mCopy").onclick = async () => { try { await navigator.clipboard.writeText(account.address); toast("Address copied."); } catch { toast(account.address); } };
$("closeModal").onclick = closeModal;
$("walletModal").onclick = e => { if (e.target.id === "walletModal") closeModal(); };
document.addEventListener("keydown", e => { if (e.key === "Escape") { closeModal(); $("welcomeModal").hidden = true; $("acctMenu").hidden = true; } });
document.querySelectorAll(".quick [data-add]").forEach(b => (b.onclick = () => {
  $("amt").value = String(+(parseAmt($("amt").value) + parseFloat(b.dataset.add)).toFixed(4)); render();
}));
$("amtClear").onclick = () => { $("amt").value = "0"; render(); };
$("amt").addEventListener("input", render);
$("amt").addEventListener("focus", e => { if (e.target.value === "0") e.target.value = ""; });
$("amt").addEventListener("blur", e => { if (!e.target.value) e.target.value = "0"; });
$("selAll").onclick = () => { selected = new Set([...Array(25).keys()]); render(); };
$("selNone").onclick = () => { selected.clear(); render(); };
$("selRepeat").onclick = () => {
  const l = lastDeploy();
  if (!l) return;
  selected = new Set(l.tiles.filter(i => Number.isInteger(i) && i >= 0 && i < 25));
  $("amt").value = l.per; render();
};
$("alertsBtn").onclick = async () => {
  if (alertsOn()) store.set("gtstar.alerts", "off");
  else if ((await Notification.requestPermission()) === "granted") store.set("gtstar.alerts", "on");
  else if (Notification.permission === "denied") toast("Notifications are blocked for this site. Allow them in your browser settings.");
  renderAlerts();
};
// Phones: while the real Deploy button is off screen, a fixed bar mirrors it (same label, same state, same action).
const syncBar = () => { $("mbPlay").textContent = $("btnPlay").textContent; $("mbPlay").disabled = $("btnPlay").disabled; };
new MutationObserver(syncBar).observe($("btnPlay"), { childList: true, characterData: true, subtree: true, attributes: true, attributeFilter: ["disabled"] });
new IntersectionObserver(([e]) => {
  $("mbar").hidden = e.isIntersecting;
  document.body.classList.toggle("mbar-on", !$("mbar").hidden);
}).observe($("btnPlay"));
$("mbPlay").onclick = () => $("btnPlay").click();
$("mbSum").onclick = () => $("amt").scrollIntoView({ behavior: "smooth", block: "center" });
$("btnPlay").onclick = async () => {
  if (!(account && phase() === "ended")) return play();
  const r = await settle();
  if (r && selected.size) { await refresh(); play(); }
};
$("btnClaimAll").onclick = () => (account ? claimAll() : openWalletModal());
$("btnWithdraw").onclick = withdrawGts;
$("hdrClaim").onclick = claimAll;
$("selRand").onclick = () => { selected = new Set([Math.floor(Math.random() * 25)]); render(); };
$("btnSwap").onclick = () => (!account ? openWalletModal() : swapDir === "buy" ? buy() : swap());
const swInput = () => { renderTrade(); requestQuote(); };
$("swIn").addEventListener("input", swInput);
$("swFlip").onclick = () => { swapDir = swapDir === "sell" ? "buy" : "sell"; $("swIn").value = ""; QUOTE = NO_QUOTE; renderTrade(); };
$("swBalIn").onclick = () => { if (USER) { $("swIn").value = String(swapMax() / MIST); swInput(); } };
document.querySelectorAll("#swPct button").forEach(b => (b.onclick = () => {
  if (!USER) return openWalletModal();
  const max = swapMax(), v = +b.dataset.pct === 100 ? max : Math.floor(max * +b.dataset.pct / 100);
  $("swIn").value = String(v / MIST); swInput();
}));
$("btnStake").onclick = () => (account ? stakeTx() : openWalletModal());
$("btnStakeClaim").onclick = () => (account ? claimYield() : openWalletModal());
document.querySelectorAll("#stakeSeg button").forEach(b => (b.onclick = () => { stakeMode = b.dataset.mode; $("stakeAmt").value = ""; renderStake(); }));
document.querySelectorAll("#stakeKind button").forEach(b => (b.onclick = () => { stakeKind = b.dataset.kind; $("stakeAmt").value = ""; renderStake(); }));
document.querySelectorAll("#view-stake [data-pct]").forEach(b => (b.onclick = () => {
  if (!USER) return openWalletModal();
  const avail = stakeMode === "deposit" ? USER.gts : (myPos()?.amount || 0);
  const v = +b.dataset.pct === 100 ? avail : Math.floor(avail * +b.dataset.pct / 100);
  $("stakeAmt").value = String(v / MIST); renderStake();
}));
$("stakeAmt").addEventListener("input", renderStake);
document.querySelectorAll(".tabset").forEach(ts => ts.querySelectorAll("button").forEach(b => (b.onclick = () => {
  const set = ts.dataset.set, t = b.dataset.t;
  if (set === "act") { actTab = t; actShown = ROWS; } else if (set === "rev") { revTab = t; revShown = ROWS; } else { lbTab = t; lbShown = ROWS; }
  renderExplorer();
})));
$("moreAct").onclick = () => { actShown += ROWS; renderExplorer(); };
$("moreRev").onclick = () => { revShown += ROWS; renderExplorer(); };
$("moreLb").onclick = () => { lbShown += ROWS; renderExplorer(); };
window.addEventListener("hashchange", route);
window.addEventListener("resize", () => { if (view === "tokenomics" && $("chart").clientWidth !== chartSize) renderTokenomics(); });

// A new site version never reloads the page under the user: it is picked up on the next
// tab switch, or when the user comes back to the browser tab.
let stale = false;
const reloadIfStale = () => { if (stale && !busy) location.reload(); };
async function checkVersion() {
  try {
    const v = (await getJson(`version.json?t=${Date.now()}`)).v;
    stale = !!(window.GTSTAR_VERSION && v && v !== window.GTSTAR_VERSION);
  } catch {}
}
setInterval(checkVersion, 60_000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) checkVersion().then(reloadIfStale); });

// Install as an app: phones only, never once installed. Closed, it comes back after 3 more visits
// (a visit is a new browser session, so reloads and tab switches do not count).
// Android installs with one tap; iPhone has no install prompt, so the banner says how to add it.
if ("serviceWorker" in navigator) addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));
(() => {
  const ua = navigator.userAgent;
  const installed = matchMedia("(display-mode: standalone)").matches || navigator.standalone;
  const phone = matchMedia("(pointer: coarse) and (max-width: 760px)").matches;
  if (installed || !phone) return;
  let visits = +store.get("gtstar.visits") || 0;
  try { if (!sessionStorage.getItem("gtstar.visit")) { sessionStorage.setItem("gtstar.visit", "1"); store.set("gtstar.visits", ++visits); } } catch {}
  let snoozed = visits < (+store.get("gtstar.installNext") || 0);
  if (snoozed) return;
  const hide = () => { $("install").hidden = true; };
  const snooze = () => { snoozed = true; hide(); store.set("gtstar.installNext", visits + 3); };
  $("insX").onclick = snooze;
  addEventListener("appinstalled", hide);
  const show = () => setTimeout(() => { if (!snoozed) $("install").hidden = false; }, 4000);
  const ios = /iPhone|iPad|iPod/.test(ua) && /Safari\//.test(ua);
  if (ios) {
    $("insTxt").textContent = "Tap Share, then Add to Home Screen.";
    $("insBtn").hidden = true;
    show();
    return;
  }
  let prompt = null;
  addEventListener("beforeinstallprompt", e => {
    e.preventDefault();
    const first = !prompt;
    prompt = e;
    if (first) show();
  });
  $("insBtn").onclick = async () => {
    if (!prompt) return;
    prompt.prompt();
    const { outcome } = await prompt.userChoice.catch(() => ({}));
    prompt = null;
    if (outcome === "dismissed") snooze(); else hide();
  };
})();

$("pkgLink").href = `${SCAN}/coin/${T_GTS}`;
$("caAddr").textContent = T_GTS;
$("caScan").href = `${SCAN}/coin/${T_GTS}`;
$("caCopy").onclick = $("caAddr").onclick = async () => { try { await navigator.clipboard.writeText(T_GTS); toast("Contract address copied."); } catch { toast(T_GTS); } };
$("amt").value = "0.01";
buildBoard(); buildArt(); loadSnap(); route(); autoReconnect();
// Price every minute, retried after 10 seconds while there is none yet.
(function price() { loadPrice().then(ok => setTimeout(price, ok || PRICE.sui ? 60_000 : 10_000)); })();
// Poll faster on the board, fastest while a finished round is waiting to be drawn.
(function poll() { refresh().finally(() => setTimeout(poll, view !== "mine" ? 4000 : phase() === "ended" ? 1000 : 2000)); })();
setInterval(() => { if (["home", "explorer", "tokenomics"].includes(view)) refreshHistory(); }, 15000);
setInterval(() => { if (view === "mine" && !document.hidden) pollBoard(); }, 1000);
setInterval(() => { if (view === "mine") { renderBoard(); renderMine(); } }, 1000);
