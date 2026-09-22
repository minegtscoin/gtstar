// GTStar dApp — static and non-custodial. Every player signs with their own wallet.
import { Transaction } from "@mysten/sui/transactions";
import { getWallets } from "@wallet-standard/app";
import { signAndExecuteTransaction } from "@mysten/wallet-standard";

const CFG = window.GTSTAR_CONFIG;
const IDS = CFG.ids;
const CHAIN = `sui:${CFG.network}`;
const GQL = `https://graphql.${CFG.network}.sui.io/graphql`;
const SCAN = `https://suiscan.xyz/${CFG.network}`;
const MIST = 1e9;
const MAX_SUPPLY = 1_000_000;
const HALVING_MS = 15_778_800_000;          // 6 months
const EMISSION_END = 1_893_456_000_000;       // 2030-01-01T00:00:00Z
const BASE_REWARD = 1;                        // GTS per round to miners at genesis
const STAKER_SHARE = 0.1;                     // +10% of the round reward to stakers
const YEAR_MS = 31_557_600_000;
const SCALE = 1_000_000_000_000n;
const T = name => `${IDS.package}::${name}`;          // game package (upgradeable)
const TK = name => `${IDS.token}::${name}`;           // token package (immutable)
const T_MINER = T("game::Miner"), T_GTS = TK("gts::GTS"), T_POS = T("staking::StakePosition");
const EV = { settled: T("game::RoundSettled"), deployed: T("game::Deployed"), redeemed: TK("gts::Redeemed"), staked: T("staking::Staked"), unstaked: T("staking::Unstaked") };
const VIEWS = ["home", "mine", "explorer", "tokenomics", "stake"];

const $ = id => document.getElementById(id);
const num = x => Number(x || 0);
const short = s => (s ? s.slice(0, 6) + "…" + s.slice(-4) : "");
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
let STATE = null, USER = null, HIST = null;
let selected = new Set();
let busy = false, view = "home";

// ---------- chain reads ----------
async function gql(query) {
  const r = await fetch(GQL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ query }) });
  const j = await r.json();
  if (j.errors) throw new Error(j.errors[0].message);
  return j.data;
}
const objQ = (alias, id) => `${alias}:object(address:"${id}"){asMoveObject{contents{json}}}`;
const pick = (d, k) => d[k]?.asMoveObject?.contents?.json || {};

async function loadGlobal() {
  const d = await gql(`{${objQ("b", IDS.board)} ${objQ("t", IDS.treasury)} ${objQ("p", IDS.pool)}
    ev:events(filter:{type:"${EV.settled}"},last:1){nodes{contents{json}}}}`);
  const b = pick(d, "b"), t = pick(d, "t"), p = pick(d, "p");
  const supply = num(t.cap?.total_supply?.value), vault = num(t.vault);
  const minted = num(t.minted), tGenesis = num(t.genesis_ms);
  const ev = d.ev?.nodes?.[0]?.contents?.json;
  return {
    supply, vault, minted, floor: supply > 0 ? vault / supply : 0,
    staked: num(p.total_staked),
    pool: {
      total: BigInt(p.total_staked || 0), acc: BigInt(p.acc_reward_per_share || 0), rate: BigInt(p.reward_rate || 0),
      finish: num(p.period_finish), last: num(p.last_update),
    },
    last: ev ? { round: num(ev.round_id), tile: num(ev.winning_square), total: num(ev.total_deployed), winners: num(ev.winners_total) } : null,
    board: {
      genesis: num(b.genesis_ms) || tGenesis,
      cur_id: num(b.cur_id), cur_total: num(b.cur_total), cur_started: b.cur_started === true,
      cur_deployed: (b.cur_deployed || []).map(num), cur_end_ms: num(b.cur_end_ms),
      freeze_ms: num(b.freeze_ms), min_deploy: num(b.min_deploy) || 10_000_000, dev_fees: num(b.dev_fees),
    },
  };
}
async function objectsOf(owner, type, first = 50) {
  const d = await gql(`{address(address:"${owner}"){objects(filter:{type:"${type}"},first:${first}){nodes{address contents{json}}}}}`);
  return (d.address?.objects?.nodes || []).map(n => ({ id: n.address, f: n.contents?.json || {} }));
}
async function loadUser(addr) {
  const [bal, miners, coins, positions] = await Promise.all([
    gql(`{address(address:"${addr}"){s:balance(coinType:"0x2::sui::SUI"){totalBalance} g:balance(coinType:"${T_GTS}"){totalBalance}}}`),
    objectsOf(addr, T_MINER, 10),
    objectsOf(addr, `0x2::coin::Coin<${T_GTS}>`, 50),
    objectsOf(addr, T_POS, 50),
  ]);
  const miner = miners.find(m => num(m.f.round_id) !== 0) || miners[0] || null;
  return {
    sui: num(bal.address?.s?.totalBalance), gts: num(bal.address?.g?.totalBalance),
    miner: miner ? { id: miner.id, round_id: num(miner.f.round_id), deployed: (miner.f.deployed || []).map(num) } : null,
    gtsCoins: coins.map(c => ({ id: c.id, balance: num(c.f.balance) })).sort((a, b) => b.balance - a.balance),
    positions: positions.map(p => ({
      id: p.id, amount: num(p.f.amount), snap: BigInt(p.f.acc_snapshot || 0), pending: BigInt(p.f.pending || 0),
    })),
  };
}

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
async function loadHistory() {
  const [settled, deployed, redeemed, staked, unstaked] = await Promise.all([allEvents(EV.settled), allEvents(EV.deployed), allEvents(EV.redeemed), allEvents(EV.staked), allEvents(EV.unstaked)]);
  const stakes = new Map();
  staked.list.forEach(e => stakes.set(e.j.player, (stakes.get(e.j.player) || 0) + num(e.j.amount)));
  unstaked.list.forEach(e => stakes.set(e.j.player, (stakes.get(e.j.player) || 0) - num(e.j.amount)));
  const byRound = new Map();
  deployed.list.forEach(e => {
    const r = num(e.j.round_id);
    if (!byRound.has(r)) byRound.set(r, []);
    byRound.get(r).push({ player: e.j.player, total: num(e.j.total), amounts: (e.j.amounts || []).map(num) });
  });
  const rounds = settled.list.map(e => ({
    round: num(e.j.round_id), tile: num(e.j.winning_square), total: num(e.j.total_deployed),
    winners: num(e.j.winners_total), payout: num(e.j.winners_payout), reward: num(e.j.round_reward),
    vault: num(e.j.vault_fee), stakerReward: num(e.j.staker_reward), dev: num(e.j.dev_fee), players: num(e.j.players),
    ts: e.ts, digest: e.digest,
  }));
  return {
    rounds, byRound, stakes, deployed: deployed.list, redeemed: redeemed.list,
    capped: settled.capped || deployed.capped,
    totals: {
      rounds: rounds.length,
      volume: rounds.reduce((a, r) => a + r.total, 0),
      paid: rounds.reduce((a, r) => a + (r.winners > 0 ? r.winners + r.payout : 0), 0),
      reserve: rounds.reduce((a, r) => a + r.vault + (r.winners === 0 ? r.payout : 0), 0),
      stakerGts: rounds.reduce((a, r) => a + r.stakerReward, 0),
      fees: rounds.reduce((a, r) => a + r.vault + r.dev, 0),
      emitted: rounds.reduce((a, r) => a + r.reward + r.stakerReward, 0),
      burned: redeemed.list.reduce((a, e) => a + num(e.j.gts_burned), 0),
      players: new Set(deployed.list.map(e => e.j.player)).size,
      stakerCount: [...stakes.values()].filter(v => v > 0).length,
    },
  };
}

// ---------- wallet ----------
const walletsApi = getWallets();
const suiWallets = () => walletsApi.get().filter(w => w.chains.some(c => c.startsWith("sui:")) && w.features["standard:connect"]);

async function connect(w, silent = false) {
  const res = await w.features["standard:connect"].connect(silent ? { silent: true } : undefined);
  const accs = res?.accounts?.length ? res.accounts : w.accounts;
  if (!accs.length) return false;
  wallet = w; account = accs[0];
  try { localStorage.setItem("gtstar.wallet", w.name); } catch {}
  w.features["standard:events"]?.on("change", ({ accounts }) => {
    if (accounts) { account = accounts[0] || null; if (!account) wallet = null; USER = null; renderWallet(); refresh(); }
  });
  renderWallet(); await refresh();
  return true;
}
async function disconnect() {
  try { await wallet?.features["standard:disconnect"]?.disconnect(); } catch {}
  try { localStorage.removeItem("gtstar.wallet"); } catch {}
  wallet = null; account = null; USER = null;
  $("acctMenu").hidden = true;
  renderWallet(); refresh();
}
function renderWallet() {
  const b = $("btnConnect");
  b.textContent = account ? short(account.address) : "Connect";
  b.classList.toggle("ghost", !!account);
  if (account) {
    $("mAddr").textContent = short(account.address);
    $("mScan").href = `${SCAN}/account/${account.address}`;
    $("mSui").textContent = USER ? sui(USER.sui) : "—";
    $("mGts").textContent = USER ? sui(USER.gts) : "—";
  }
}
function openWalletModal() {
  const list = suiWallets();
  const box = $("walletList"); box.innerHTML = "";
  $("noWallet").hidden = list.length > 0;
  list.forEach(w => {
    const b = document.createElement("button"); b.type = "button";
    const img = document.createElement("img"); img.src = w.icon; img.alt = "";
    const s = document.createElement("span"); s.textContent = w.name;
    b.append(img, s);
    b.onclick = async () => { closeModal(); try { await connect(w); } catch (e) { toast("Connection failed: " + (e.message || e), true); } };
    box.appendChild(b);
  });
  $("walletModal").hidden = false;
}
const closeModal = () => ($("walletModal").hidden = true);
async function autoReconnect() {
  let name = null;
  try { name = localStorage.getItem("gtstar.wallet"); } catch {}
  if (!name) return;
  const tryIt = async () => { const w = suiWallets().find(x => x.name === name); if (w && !wallet) { try { await connect(w, true); } catch {} } };
  await tryIt();
  walletsApi.on("register", tryIt);
}

// ---------- transactions ----------
const ERRORS = {
  game: { 2: "Round has ended. Settle it first.", 3: "Round is closing. Try the next round.", 4: "Claim your previous round first.", 5: "Select at least one tile.", 6: "Amount is below the minimum.", 7: "Payment does not match the tile amounts.", 8: "Round has not ended yet.", 9: "This round was already settled.", 10: "Nothing to claim.", 11: "Round is not settled yet." },
  staking: { 1: "Amount must be greater than zero.", 2: "Amount exceeds your stake." },
  gts: { 1: "Amount must be greater than zero.", 2: "Reserve is empty." },
};
function friendlyError(e) {
  const m = String(e?.message || e);
  // e.g. "MoveAbort in 1st command, abort code: 9, in '0x…::game::settle'" or "MoveAbort(…::game::…, 9)"
  const a1 = m.match(/abort code:\s*(\d+)[^']*'0x[0-9a-f]+::(\w+)::/i);
  const a2 = m.match(/::(game|staking|gts)::[^,]*?,\s*(\d+)\)/);
  const mod = a1 ? a1[2] : a2 && a2[1], code = a1 ? +a1[1] : a2 && +a2[2];
  if (mod && ERRORS[mod]?.[code]) return ERRORS[mod][code];
  if (/reject|cancel/i.test(m)) return "Transaction cancelled.";
  if (/InsufficientGas|insufficient|GasBalanceTooLow|balance/i.test(m)) return "Insufficient SUI balance.";
  if (/not found|deleted|version/i.test(m)) return "Your balance just changed. Try again.";
  if (/MoveAbort/i.test(m)) return "The transaction was rejected by the contract. Refresh and try again.";
  return m.slice(0, 140);
}
const GAS_RESERVE = 5_000_000; // ~0.005 SUI kept for gas
function lowBalance(needMist) {
  if (!USER || USER.sui >= needMist + GAS_RESERVE) return false;
  const need = sui(needMist + GAS_RESERVE);
  toast(CFG.network === "mainnet"
    ? `Not enough SUI. You need about ${need} SUI including gas.`
    : `Not enough test SUI. You need about ${need} SUI including gas. Get free test SUI at <a href="https://faucet.sui.io/?address=${account.address}" target="_blank" rel="noopener">faucet.sui.io</a>.`, true, true);
  return true;
}
async function exec(label, btnId, build, needMist = 0) {
  if (!account) { openWalletModal(); return; }
  if (busy || lowBalance(needMist)) return;
  busy = true;
  const b = $(btnId), old = b.textContent;
  b.disabled = true; b.textContent = "Confirm in wallet";
  try {
    // Re-read the wallet's objects first: coin and miner IDs from a cached view
    // may already have been consumed by an earlier transaction.
    USER = await loadUser(account.address);
    const tx = new Transaction();
    tx.setSender(account.address);
    await build(tx);
    const r = await signAndExecuteTransaction(wallet, { transaction: tx, account, chain: CHAIN });
    toast(`${label} confirmed. <a href="${SCAN}/tx/${r.digest}" target="_blank" rel="noopener">View transaction</a>`, false, true);
    setTimeout(refresh, 1200); setTimeout(refresh, 3500);
    return r;
  } catch (e) {
    toast(esc(friendlyError(e)), true, true);
    refresh();
  } finally {
    busy = false; b.disabled = false; b.textContent = old; render();
  }
}
function claimInto(tx, minerArg) {
  const [g, s] = tx.moveCall({ target: T("game::claim"), arguments: [tx.object(IDS.board), minerArg, tx.object(IDS.treasury), tx.object.clock()] });
  tx.transferObjects([g, s], account.address);
}
function gtsCoin(tx, amount) {
  const coins = USER?.gtsCoins || [];
  const total = coins.reduce((a, c) => a + c.balance, 0);
  if (!coins.length || total < amount) throw new Error("Insufficient GTS balance.");
  const primary = tx.object(coins[0].id);
  if (coins.length > 1) tx.mergeCoins(primary, coins.slice(1).map(c => tx.object(c.id)));
  const [c] = tx.splitCoins(primary, [amount]);
  return c;
}
async function play() {
  if (!account) { openWalletModal(); return; }
  const per = toMist($("amt").value);
  if (!selected.size || per < STATE.board.min_deploy) return;
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
      [minerArg] = tx.moveCall({ target: T("game::new_miner") });
      fresh = true;
    }
    const [pay] = tx.splitCoins(tx.gas, [total]);
    tx.moveCall({ target: T("game::deploy"), arguments: [tx.object(IDS.board), minerArg, pay, tx.pure.vector("u64", amounts), tx.object.clock()] });
    if (fresh) tx.transferObjects([minerArg], account.address);
  }, total);
  if (r) { selected.clear(); render(); }
}
const claim = () => exec("Claim", "btnClaim", tx => claimInto(tx, tx.object(USER.miner.id)));
const settle = () => exec("Settlement", "btnPlay", tx => {
  tx.moveCall({ target: T("game::settle"), arguments: [tx.object(IDS.board), tx.object(IDS.treasury), tx.object(IDS.pool), tx.object.random(), tx.object.clock()] });
});
const myPos = () => (USER?.positions || []).slice().sort((a, b) => b.amount - a.amount)[0] || null;
const stake = () => exec(stakeMode === "deposit" ? "Stake" : "Withdraw", "btnStake", tx => {
  const amt = toMist($("stakeAmt").value);
  if (amt <= 0) throw new Error("Enter an amount.");
  const pos = myPos();
  if (stakeMode === "deposit") {
    const posArg = pos ? tx.object(pos.id) : tx.moveCall({ target: T("staking::new_position") })[0];
    tx.moveCall({ target: T("staking::stake"), arguments: [tx.object(IDS.pool), posArg, gtsCoin(tx, amt), tx.object.clock()] });
    if (!pos) tx.transferObjects([posArg], account.address);
  } else {
    if (!pos || pos.amount < amt) throw new Error("Amount exceeds your stake.");
    const [g] = tx.moveCall({ target: T("staking::unstake"), arguments: [tx.object(IDS.pool), tx.object(pos.id), tx.pure.u64(amt), tx.object.clock()] });
    tx.transferObjects([g], account.address);
  }
}).then(r => { if (r) $("stakeAmt").value = ""; });
const redeem = () => exec("Redeem", "btnRedeem", tx => {
  const amt = toMist($("redeemAmt").value);
  if (amt <= 0) throw new Error("Enter an amount.");
  const [out] = tx.moveCall({ target: TK("gts::redeem"), arguments: [tx.object(IDS.treasury), gtsCoin(tx, amt)] });
  tx.transferObjects([out], account.address);
}).then(r => { if (r) { $("redeemAmt").value = ""; renderRedeem(); } });
const claimStake = () => exec("Yield claim", "btnStakeClaim", tx => {
  const [c] = tx.moveCall({ target: T("staking::claim_rewards"), arguments: [tx.object(IDS.pool), tx.object(myPos().id), tx.object.clock()] });
  tx.transferObjects([c], account.address);
});
const compound = () => exec("Claim and deposit", "btnCompound", tx => {
  const pos = tx.object(myPos().id);
  const [c] = tx.moveCall({ target: T("staking::claim_rewards"), arguments: [tx.object(IDS.pool), pos, tx.object.clock()] });
  tx.moveCall({ target: T("staking::stake"), arguments: [tx.object(IDS.pool), pos, c, tx.object.clock()] });
});

// ---------- emission math (time-based, mirrors game::reward_at) ----------
const rewardAt = (genesis, t) => (!genesis || t < genesis || t >= EMISSION_END) ? 0 : BASE_REWARD / 2 ** Math.floor((t - genesis) / HALVING_MS);
// Maximum cumulative emission by time t, assuming a round every minute.
function cumAt(genesis, t) {
  let total = 0, s = genesis;
  while (s < Math.min(t, EMISSION_END)) {
    const e = Math.min(s + HALVING_MS, t, EMISSION_END);
    total += rewardAt(genesis, s) * (1 + STAKER_SHARE) * ((e - s) / 60_000);
    s = Math.min(s + HALVING_MS, EMISSION_END);
  }
  return Math.min(total, MAX_SUPPLY);
}
const fmtDate = t => new Date(t).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });

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
function renderHome() {
  $("hRound").textContent = STATE ? `#${STATE.board.cur_id}` : "—";
  $("hReserve").textContent = STATE ? sui(STATE.vault, 3) : "—";
  $("hFloor").textContent = STATE ? fmt(STATE.floor, 5) : "—";
  $("hMined").textContent = STATE ? sui(STATE.supply, 2) : "—";
  $("hVolume").textContent = HIST ? sui(HIST.totals.volume, 2) : "—";
}

// ---------- render: mine ----------
function buildBoard() {
  const g = $("board");
  for (let i = 0; i < 25; i++) {
    const c = document.createElement("button");
    c.type = "button"; c.className = "tile"; c.dataset.i = i;
    c.setAttribute("aria-label", `Tile ${i + 1}`);
    c.innerHTML = `<span class="n">${i + 1}</span><span class="me" hidden></span><span class="a"></span>`;
    c.onclick = () => { selected.has(i) ? selected.delete(i) : selected.add(i); render(); };
    g.appendChild(c);
  }
}
function renderBoard() {
  const b = STATE?.board;
  const dep = b?.cur_deployed?.length ? b.cur_deployed : Array(25).fill(0);
  const mine = USER?.miner && b && USER.miner.round_id === b.cur_id ? USER.miner.deployed : null;
  const showWin = STATE?.last && b && !b.cur_started ? STATE.last.tile : -1;
  document.querySelectorAll(".tile").forEach(c => {
    const i = +c.dataset.i, v = dep[i] / MIST, sel = selected.has(i);
    c.classList.toggle("has", v > 0);
    c.classList.toggle("sel", sel);
    c.classList.toggle("win", i === showWin);
    c.setAttribute("aria-pressed", sel);
    c.querySelector(".a").textContent = fmt(v, 3);
    c.querySelector(".me").hidden = !(mine && mine[i] > 0);
  });
}
function renderMine() {
  const b = STATE?.board, p = phase();
  $("sDeployed").textContent = b ? sui(b.cur_total, 2) : "—";
  $("sRound").textContent = b ? `#${b.cur_id}` : "—";
  let t = "—";
  if (p === "open") t = "1:00";
  else if (p === "live" || p === "frozen") { const s = Math.max(0, Math.ceil((b.cur_end_ms - Date.now()) / 1000)); t = `0:${String(s).padStart(2, "0")}`; }
  else if (p === "ended") t = "0:00";
  $("sTime").textContent = t;
  const L = STATE?.last;
  $("lastRound").textContent = L ? `#${L.round} · Tile ${L.tile + 1} · ${sui(L.total, 2)} SUI` : "No rounds yet";

  const per = parseAmt($("amt").value);
  $("tileCount").textContent = selected.size;
  $("totalCost").textContent = fmt(per * selected.size, 4);

  const m = USER?.miner;
  const claimable = !!(m && m.round_id !== 0 && b && m.round_id < b.cur_id);
  const min = b ? b.min_deploy / MIST : 0.01;
  if (!busy) {
    let label = "Deploy", dis = false;
    if (!account) label = "Connect wallet";
    else if (p === "loading") { label = "Loading"; dis = true; }
    else if (p === "ended") label = "Settle round";
    else if (p === "frozen") { label = "Round closing"; dis = true; }
    else if (!selected.size) { label = "Select tiles"; dis = true; }
    else if (per < min) { label = `Minimum ${min} SUI per tile`; dis = true; }
    $("btnPlay").textContent = label; $("btnPlay").disabled = dis;
  }
  $("claimRow").hidden = !claimable;
  let hint = `Minimum ${min} SUI per tile. Every participant mines GTS.`;
  if (p === "ended") hint = "Round ended. It settles automatically within seconds, or settle it yourself.";
  else if (p === "frozen") hint = "Deposits close 5 seconds before the round ends.";
  else if (p === "open") hint = "The next round starts with the first deploy and runs for 60 seconds.";
  else if (claimable) hint = "Your previous round is claimed automatically with your next deploy.";
  $("playHint").textContent = hint;
  $("myGts").textContent = USER ? sui(USER.gts) : "—";
  $("mySui").textContent = USER ? sui(USER.sui) : "—";
}

// ---------- render: explorer ----------
let actShown = 25, actTab = "rounds", revTab = "reserve", lbTab = "miners";
const openRounds = new Set();
const txLink = d => `<a href="${SCAN}/tx/${d}" target="_blank" rel="noopener" data-stop>${d.slice(0, 6)}…</a>`;
const acctLink = a => `<a href="${SCAN}/account/${a}" target="_blank" rel="noopener" class="mono" data-stop>${short(a)}</a>`;
function winnersOf(r) {
  const list = HIST.byRound.get(r.round) || [];
  const agg = new Map();
  list.forEach(d => { const w = d.amounts[r.tile] || 0; if (w > 0) agg.set(d.player, (agg.get(d.player) || 0) + w); });
  return agg;
}
function renderExplorer() {
  if (!STATE) return;
  const t = HIST?.totals;
  $("gFloor").textContent = `${fmt(STATE.floor, 6)} SUI`;
  $("gReserve").textContent = `${sui(STATE.vault, 4)} SUI`;
  $("gDeployed").textContent = `${sui(STATE.board.cur_total, 3)} SUI`;
  $("gRounds").textContent = t ? fmt(t.rounds, 0) : "—";
  $("gVolume").textContent = t ? `${sui(t.volume, 3)} SUI` : "—";
  $("gMiners").textContent = t ? fmt(t.players, 0) : "—";
  $("gCost").textContent = t && t.emitted ? `${fmt(t.fees / t.emitted, 4)} SUI` : "—";
  const apr = stakingApr();
  $("gApr").textContent = apr == null ? "—" : `${fmt(apr, apr < 10 ? 2 : 0)}%`;
  $("gStaked").textContent = `${sui(STATE.staked, 3)} GTS`;
  $("gStakers").textContent = t ? fmt(t.stakerCount, 0) : "—";
  $("gSupply").textContent = `${sui(STATE.supply, 3)} GTS`;
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
    const head = `<thead><tr><th>Round</th><th>Tile</th><th>Winner</th><th class="r">Winners</th><th class="r">Deployed</th><th class="r">Vaulted</th><th class="r">Winnings</th><th class="r">GTS</th><th class="r">Time</th></tr></thead>`;
    const body = rows.map(r => {
      const w = winnersOf(r);
      const winner = w.size === 0 ? `<span class="muted">Reserve</span>` : w.size === 1 ? acctLink([...w.keys()][0]) : "Split";
      const winnings = r.winners > 0 ? r.winners + r.payout : 0;
      const vaulted = r.vault + (r.winners === 0 ? r.payout : 0);
      let html = `<tr class="round" data-r="${r.round}" tabindex="0" aria-expanded="${openRounds.has(r.round)}">
        <td><b>#${fmt(r.round, 0)}</b></td><td><span class="tile-badge${w.size ? "" : " none"}">#${r.tile + 1}</span></td><td>${winner}</td>
        <td class="r">${w.size}</td><td class="r">${sui(r.total, 3)}</td><td class="r">${sui(vaulted, 4)}</td>
        <td class="r">${winnings ? sui(winnings, 3) : "–"}</td><td class="r">${sui(r.reward, 3)}</td>
        <td class="r muted">${txLinkAgo(r)}</td></tr>`;
      if (openRounds.has(r.round)) html += `<tr class="detail"><td colspan="9">${minersHtml(r)}</td></tr>`;
      return html;
    }).join("");
    tbl.innerHTML = head + `<tbody>${body || `<tr><td colspan="9" class="muted">No rounds settled yet.</td></tr>`}</tbody>`;
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
  const agg = new Map();
  list.forEach(d => { const a = agg.get(d.player) || { total: 0, onWin: 0 }; a.total += d.total; a.onWin += d.amounts[r.tile] || 0; agg.set(d.player, a); });
  return `<div class="miners">` + [...agg.entries()].sort((x, y) => y[1].total - x[1].total).map(([p, a]) => {
    const won = a.onWin > 0 && r.winners > 0 ? a.onWin + Math.floor(r.payout * a.onWin / r.winners) : 0;
    const gts = r.total ? r.reward * a.total / r.total : 0;
    return `<div class="m">${acctLink(p)}<span>${sui(a.total, 3)} SUI deployed · ${sui(gts, 4)} GTS mined</span>
      <span class="${won ? "won" : "muted"}">${won ? `Won ${sui(won, 4)} SUI` : "No SUI win"}</span></div>`;
  }).join("") + `</div>`;
}
function renderRevenue() {
  const cfg = {
    reserve: { v: r => r.vault + (r.winners === 0 ? r.payout : 0), unit: "SUI", share: "4% of losing pot", label: "Added to the GTS reserve" },
    stakers: { v: r => r.stakerReward, unit: "GTS", share: "+10% of round GTS", label: "Minted to the staking stream" },
    creator: { v: r => r.dev, unit: "SUI", share: "1% of losing pot", label: "Creator fee" },
  }[revTab];
  const rows = HIST.rounds.filter(r => cfg.v(r) > 0);
  const total = rows.reduce((a, r) => a + cfg.v(r), 0);
  const day = Date.now() - 86_400_000;
  const d24 = rows.filter(r => new Date(r.ts).getTime() >= day).reduce((a, r) => a + cfg.v(r), 0);
  $("revSum").innerHTML = `<div><span>All time</span><b>${sui(total, 4)} ${cfg.unit}</b></div><div><span>Last 24h</span><b>${sui(d24, 4)} ${cfg.unit}</b></div><div><span>Source</span><b>${cfg.share}</b></div>`;
  $("revTbl").innerHTML = `<thead><tr><th>Round</th><th>${cfg.label}</th><th class="r">Amount</th><th class="r">Time</th></tr></thead><tbody>` +
    (rows.slice(0, 25).map(r => `<tr><td>#${fmt(r.round, 0)}</td><td class="muted">${revTab === "reserve" && r.winners === 0 ? "Fee plus pot (no miner on winning tile)" : revTab === "stakers" ? "Streamed over 7 days" : "Fee from losing pot"}</td>
      <td class="r">${sui(cfg.v(r), 5)} ${cfg.unit}</td><td class="r muted"><a href="${SCAN}/tx/${r.digest}" target="_blank" rel="noopener">${ago(r.ts)}</a></td></tr>`).join("")
      || `<tr><td colspan="4" class="muted">Nothing yet.</td></tr>`) + `</tbody>`;
}
function renderLeaderboard() {
  let rows = [], sub = "", unit = "SUI";
  if (lbTab === "miners") {
    sub = "Top miners by total SUI deployed.";
    const m = new Map(); HIST.deployed.forEach(e => m.set(e.j.player, (m.get(e.j.player) || 0) + num(e.j.total)));
    rows = [...m.entries()];
  } else if (lbTab === "winners") {
    sub = "Top winners by total SUI won.";
    const m = new Map();
    HIST.rounds.forEach(r => { if (!r.winners) return; winnersOf(r).forEach((amt, p) => m.set(p, (m.get(p) || 0) + amt + Math.floor(r.payout * amt / r.winners))); });
    rows = [...m.entries()];
  } else {
    sub = "Top stakers by GTS currently staked."; unit = "GTS";
    rows = [...HIST.stakes.entries()].filter(([, v]) => v > 0);
  }
  $("lbSub").textContent = sub;
  rows.sort((a, b) => b[1] - a[1]);
  $("lbTbl").innerHTML = `<thead><tr><th>Rank</th><th>Address</th><th class="r">Total</th></tr></thead><tbody>` +
    (rows.slice(0, 20).map(([p, v], i) => `<tr><td>#${i + 1}</td><td>${acctLink(p)}</td><td class="r">${sui(v, 4)} ${unit}</td></tr>`).join("")
      || `<tr><td colspan="3" class="muted">Nothing here yet.</td></tr>`) + `</tbody>`;
}

// ---------- render: tokenomics ----------
function renderTokenomics() {
  if (!STATE) return;
  const now = Date.now();
  const genesis = STATE.board.genesis;
  const supply = STATE.supply / MIST;
  const emitted = STATE.minted / MIST;
  const burned = HIST ? HIST.totals.burned / MIST : null;
  $("kSupply").textContent = fmt(supply, 2);
  $("kMinedPct").textContent = emitted == null ? "—" : `${fmt(emitted, 3)} GTS`;
  $("kSchedMax").textContent = `≈ ${fmt(Math.round(cumAt(genesis || now, EMISSION_END) / 1000) * 1000, 0)}`;
  $("kDevLink").textContent = short(IDS.dev); $("kDevLink").href = `${SCAN}/account/${IDS.dev}`;
  renderRedeem();
  $("kBurned").textContent = burned == null ? "—" : fmt(burned, 3);
  $("kReserve").textContent = `${sui(STATE.vault, 3)} SUI`;
  $("kFloor").textContent = `${fmt(STATE.floor, 5)} SUI`;
  if (genesis) {
    const epoch = Math.floor((now - genesis) / HALVING_MS);
    const next = Math.min(genesis + (epoch + 1) * HALVING_MS, EMISSION_END);
    const done = now >= EMISSION_END;
    $("kEpoch").textContent = done ? "Ended" : `${epoch + 1} of 7`;
    $("kEpochLbl").textContent = `Genesis ${fmtDate(genesis)}`;
    $("kReward").textContent = `${fmt(rewardAt(genesis, now), 6)} GTS + ${fmt(rewardAt(genesis, now) * STAKER_SHARE, 6)} to stakers`;
    $("kToHalving").textContent = done ? "—" : next >= EMISSION_END ? `Emission ends ${fmtDate(EMISSION_END)}` : `${fmtDate(next)} · ${Math.ceil((next - now) / 86_400_000)}d`;
    $("kNextReward").textContent = done || next >= EMISSION_END ? "0 GTS" : `${fmt(rewardAt(genesis, next), 6)} GTS`;
  } else {
    $("kEpoch").textContent = "Not started";
    $("kEpochLbl").textContent = "Starts with the first round";
    $("kReward").textContent = `${BASE_REWARD} GTS + ${BASE_REWARD * STAKER_SHARE} to stakers`;
    $("kToHalving").textContent = "6 months after first round";
    $("kNextReward").textContent = `${BASE_REWARD / 2} GTS`;
  }
  $("kEmitted").textContent = emitted == null ? "—" : `${fmt(emitted, 3)} GTS`;
  $("kUnclaimed").textContent = emitted == null ? "—" : `${fmt(Math.max(0, emitted - supply - burned), 3)} GTS`;
  $("kFloor2").textContent = `${fmt(STATE.floor, 6)} SUI`;
  $("kBacked").textContent = `${sui(STATE.vault, 4)} SUI`;
  $("kStaked").textContent = `${sui(STATE.staked, 3)} GTS`;
  $("kStakedPct").textContent = STATE.supply ? `${fmt(STATE.staked / STATE.supply * 100, 2)}%` : "0%";
  drawChart(genesis || now, now);
}
let chartSize = 0;
function drawChart(genesis, now) {
  const box = $("chart");
  const W = box.clientWidth, H = box.clientHeight;
  if (!W) return;
  const pad = { l: 48, r: 14, t: 12, b: 26 };
  const X0 = genesis, X1 = EMISSION_END;
  const Y = Math.ceil(cumAt(genesis, X1) / 100_000) * 100_000 || MAX_SUPPLY;
  const x = t => pad.l + ((t - X0) / (X1 - X0)) * (W - pad.l - pad.r);
  const y = v => H - pad.b - (v / Y) * (H - pad.t - pad.b);
  const pts = [];
  for (let i = 0; i <= 200; i++) { const t = X0 + (X1 - X0) * i / 200; pts.push(`${x(t).toFixed(1)},${y(cumAt(genesis, t)).toFixed(1)}`); }
  const line = "M" + pts.join("L");
  const area = `${line}L${x(X1).toFixed(1)},${y(0)}L${x(X0)},${y(0)}Z`;
  const years = [];
  for (let yr = new Date(X0).getUTCFullYear() + 1; yr <= 2030; yr++) years.push(Date.UTC(yr, 0, 1));
  const yt = [0, Y / 4, Y / 2, Y * 3 / 4, Y];
  const k = v => (v === 0 ? "0" : v >= 1e6 ? `${fmt(v / 1e6, 2)}M` : `${fmt(v / 1e3, 0)}K`);
  const halvings = [];
  for (let t = genesis + HALVING_MS; t < X1; t += HALVING_MS) halvings.push(t);
  const nx = x(Math.min(Math.max(now, X0), X1)), ny = y(cumAt(genesis, now));
  box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Maximum cumulative GTS emission over time, halving every 6 months until January 2030.">
    ${yt.map(v => `<line class="ax" x1="${pad.l}" x2="${W - pad.r}" y1="${y(v)}" y2="${y(v)}" opacity="${v ? 0.5 : 1}"/><text class="tick" x="${pad.l - 8}" y="${y(v) + 4}" text-anchor="end">${k(v)}</text>`).join("")}
    ${halvings.map(t => `<line class="ax" x1="${x(t)}" x2="${x(t)}" y1="${pad.t}" y2="${y(0)}" opacity="0.35"/>`).join("")}
    ${years.map(t => `<text class="tick" x="${x(t)}" y="${H - 6}" text-anchor="middle">${new Date(t).getUTCFullYear()}</text>`).join("")}
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
    const t = X0 + f * (X1 - X0), v = cumAt(genesis, t);
    hov.setAttribute("visibility", "visible");
    box.querySelector("#hx").setAttribute("x1", x(t)); box.querySelector("#hx").setAttribute("x2", x(t));
    box.querySelector("#hd").setAttribute("cx", x(t)); box.querySelector("#hd").setAttribute("cy", y(v));
    tip.hidden = false; tip.style.left = `${Math.min(Math.max(x(t), 100), W - 100)}px`; tip.style.top = `${y(v)}px`;
    tip.innerHTML = `<b>${fmtDate(t)}</b><br>Up to <b>${fmt(v, 0)}</b> GTS · ${fmt(rewardAt(genesis, t), 4)} per round`;
  };
  hit.onmousemove = e => move(e.clientX);
  hit.ontouchmove = e => move(e.touches[0].clientX);
  hit.onmouseleave = () => { hov.setAttribute("visibility", "hidden"); tip.hidden = true; };
  chartSize = W;
}

// ---------- render: stake / redeem ----------
// Mirrors staking::pending_rewards.
function poolAcc(now) {
  const p = STATE.pool;
  let acc = p.acc;
  if (p.total > 0n && now > p.last) {
    const end = Math.min(now, p.finish);
    if (end > p.last) acc += p.rate * BigInt(end - p.last) / p.total;
  }
  return acc;
}
const posPending = (p, now) => p.pending + BigInt(p.amount) * (poolAcc(now) - p.snap) / SCALE;
function stakingApr() {
  const p = STATE?.pool;
  if (!p || p.total === 0n || p.finish <= Date.now()) return null;
  const yearly = Number(p.rate) / Number(SCALE) * YEAR_MS;   // GTS base units per year
  return yearly / Number(p.total) * 100;
}
let stakeMode = "deposit";
const myStake = () => (USER?.positions || []).reduce((a, p) => a + p.amount, 0);
function renderStake() {
  if (!STATE) return;
  const now = Date.now();
  const pos = USER?.positions || [];
  const mine = myStake();
  const pending = pos.reduce((a, p) => a + posPending(p, now), 0n);
  const apr = stakingApr();
  $("sApr").textContent = apr == null ? "—" : `${fmt(apr, apr < 10 ? 2 : 0)}%`;
  $("sStaked").textContent = `${sui(STATE.staked, 3)} GTS`;
  $("sTvl").textContent = `${fmt(STATE.staked / MIST * STATE.floor, 4)} SUI`;
  $("sWallet").textContent = USER ? `${sui(USER.gts, 6)} GTS` : "—";
  $("sMyStaked").textContent = USER ? `${sui(mine, 6)} GTS` : "—";
  $("sPending").textContent = USER ? `${sui(Number(pending), 9)} GTS` : "—";
  const avail = stakeMode === "deposit" ? (USER?.gts || 0) : mine;
  $("stakeBal").textContent = `${USER ? sui(avail, 6) : 0} GTS ${stakeMode === "deposit" ? "in wallet" : "staked"}`;
  document.querySelectorAll("#stakeSeg button").forEach(b => b.setAttribute("aria-selected", String(b.dataset.mode === stakeMode)));
  if (!busy) {
    const btn = $("btnStake"), amt = toMist($("stakeAmt").value);
    let label = stakeMode === "deposit" ? "Deposit" : "Withdraw", dis = false;
    if (!account) label = "Connect wallet";
    else if (amt <= 0) dis = true;
    else if (amt > avail) { label = stakeMode === "deposit" ? "Insufficient GTS" : "Exceeds your stake"; dis = true; }
    btn.textContent = label; btn.disabled = dis;
    $("btnStakeClaim").disabled = !account || pending <= 0n;
    $("btnCompound").disabled = !account || pending <= 0n;
  }
}
function renderRedeem() {
  if (!busy) $("btnRedeem").textContent = account ? "Redeem" : "Connect wallet";
  const a = parseAmt($("redeemAmt").value);
  $("redeemOut").textContent = STATE && STATE.supply ? fmt(STATE.vault * a / STATE.supply, 6) : "0";
}

function render() {
  $("tFloor").textContent = STATE ? `${fmt(STATE.floor, 5)} SUI` : "—";
  $("tGtsWrap").hidden = !USER; if (USER) $("tGts").textContent = sui(USER.gts, 4);
  renderWallet();
  if (view === "home") renderHome();
  if (view === "mine") { renderBoard(); renderMine(); }
  if (view === "explorer") renderExplorer();
  if (view === "tokenomics") renderTokenomics();
  if (view === "stake") renderStake();
}
async function refresh() {
  try {
    const [g, u] = await Promise.all([loadGlobal(), account ? loadUser(account.address) : Promise.resolve(null)]);
    STATE = g; USER = u; render();
  } catch (e) { console.warn("refresh failed", e); }
}
let histBusy = false;
async function refreshHistory() {
  if (histBusy) return; histBusy = true;
  try { HIST = await loadHistory(); render(); } catch (e) { console.warn("history failed", e); }
  histBusy = false;
}

// ---------- routing ----------
function route() {
  const v = (location.hash || "#home").slice(1);
  view = VIEWS.includes(v) ? v : "home";
  VIEWS.forEach(n => ($("view-" + n).hidden = n !== view));
  document.querySelectorAll(".tabs a[data-view]").forEach(a => a.classList.toggle("on", a.dataset.view === view));
  window.scrollTo(0, 0);
  render();
  if (["home", "explorer", "tokenomics"].includes(view)) refreshHistory();
}

// ---------- wire ----------
$("btnConnect").onclick = e => {
  if (!account) return openWalletModal();
  e.stopPropagation(); $("acctMenu").hidden = !$("acctMenu").hidden;
};
document.addEventListener("click", e => { if (!e.target.closest(".acct")) $("acctMenu").hidden = true; });
$("mDisconnect").onclick = disconnect;
$("mCopy").onclick = async () => { try { await navigator.clipboard.writeText(account.address); toast("Address copied."); } catch { toast(account.address); } };
$("closeModal").onclick = closeModal;
$("walletModal").onclick = e => { if (e.target.id === "walletModal") closeModal(); };
document.addEventListener("keydown", e => { if (e.key === "Escape") { closeModal(); $("acctMenu").hidden = true; } });
document.querySelectorAll(".quick [data-add]").forEach(b => (b.onclick = () => {
  $("amt").value = String(+(parseAmt($("amt").value) + parseFloat(b.dataset.add)).toFixed(4)); render();
}));
$("amtClear").onclick = () => { $("amt").value = "0"; render(); };
$("amt").addEventListener("input", render);
$("amt").addEventListener("focus", e => { if (e.target.value === "0") e.target.value = ""; });
$("amt").addEventListener("blur", e => { if (!e.target.value) e.target.value = "0"; });
$("selAll").onclick = () => { selected = new Set([...Array(25).keys()]); render(); };
$("selNone").onclick = () => { selected.clear(); render(); };
$("btnPlay").onclick = () => (account && phase() === "ended" ? settle() : play());
$("btnClaim").onclick = claim;
$("btnStake").onclick = () => (account ? stake() : openWalletModal());
$("btnRedeem").onclick = () => (account ? redeem() : openWalletModal());
document.querySelectorAll("#stakeSeg button").forEach(b => (b.onclick = () => { stakeMode = b.dataset.mode; $("stakeAmt").value = ""; renderStake(); }));
document.querySelectorAll("#view-stake [data-pct]").forEach(b => (b.onclick = () => {
  if (!USER) return openWalletModal();
  const avail = stakeMode === "deposit" ? USER.gts : myStake();
  const v = +b.dataset.pct === 100 ? avail : Math.floor(avail * +b.dataset.pct / 100);
  $("stakeAmt").value = String(v / MIST); renderStake();
}));
document.querySelectorAll(".tabset").forEach(ts => ts.querySelectorAll("button").forEach(b => (b.onclick = () => {
  const set = ts.dataset.set, t = b.dataset.t;
  if (set === "act") { actTab = t; actShown = 25; } else if (set === "rev") revTab = t; else lbTab = t;
  renderExplorer();
})));
$("btnStakeClaim").onclick = () => (account ? claimStake() : openWalletModal());
$("btnCompound").onclick = () => (account ? compound() : openWalletModal());
$("stakeAmt").addEventListener("input", renderStake);
$("redeemMax").onclick = () => { if (USER) { $("redeemAmt").value = String(USER.gts / MIST); renderRedeem(); } };
$("redeemAmt").addEventListener("input", renderRedeem);
$("moreAct").onclick = () => { actShown += 25; renderExplorer(); };
window.addEventListener("hashchange", route);
window.addEventListener("resize", () => { if (view === "tokenomics" && $("chart").clientWidth !== chartSize) renderTokenomics(); });

async function checkVersion() {
  try {
    const v = (await (await fetch(`version.json?t=${Date.now()}`, { cache: "no-store" })).json()).v;
    if (window.GTSTAR_VERSION && v && v !== window.GTSTAR_VERSION && !busy) location.reload();
  } catch {}
}
setInterval(checkVersion, 60_000);
document.addEventListener("visibilitychange", () => { if (!document.hidden) checkVersion(); });

$("netNotice").hidden = CFG.network === "mainnet";
$("pkgLink").href = `${SCAN}/object/${IDS.package}`;
$("amt").value = "0.01";
buildBoard(); buildArt(); route(); refresh(); autoReconnect();
setInterval(refresh, 4000);
setInterval(() => { if (["home", "explorer", "tokenomics"].includes(view)) refreshHistory(); }, 15000);
setInterval(() => { if (view === "mine") renderMine(); if (view === "stake") renderStake(); }, 1000);
