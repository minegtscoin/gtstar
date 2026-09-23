// GTStar dApp — static and non-custodial. Every player signs with their own wallet.
import { Transaction } from "@mysten/sui/transactions";
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { getWallets } from "@wallet-standard/app";
import { signAndExecuteTransaction } from "@mysten/wallet-standard";

const CFG = window.GTSTAR_CONFIG;
const IDS = CFG.ids;
const CHAIN = `sui:${CFG.network}`;
const GQL = `https://graphql.${CFG.network}.sui.io/graphql`;
const SCAN = `https://suiscan.xyz/${CFG.network}`;
const MIST = 1e9;
const MAX_SUPPLY = 572_003.236678098;          // emission ceiling at 2030-01-01 for the mainnet genesis
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
const VIEWS = ["home", "mine", "trade", "explorer", "tokenomics", "stake"];

const $ = id => document.getElementById(id);
const num = x => Number(x || 0);
const short = s => (s ? s.slice(0, 6) + "…" + s.slice(-4) : "");
// Usernames players set for their address (served by names.php); falls back to the short address.
let NAMES = {};
const nameOf = a => NAMES[a] || "";
const label = a => nameOf(a) || short(a);
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
let userAt = 0, txAt = 0;   // when the wallet view was last loaded, and when we last sent a transaction

// ---------- chain reads ----------
// Every read has a time limit and one retry: a stalled request must never freeze the app.
async function gql(query) {
  for (let attempt = 0; ; attempt++) {
    const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), 8000);
    try {
      const r = await fetch(GQL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ query }), signal: ctl.signal });
      const j = await r.json();
      if (j.errors) throw new Error(j.errors[0].message);
      return j.data;
    } catch (e) {
      if (attempt >= 1 || !(e.name === "AbortError" || e instanceof TypeError)) throw e;
    } finally { clearTimeout(timer); }
  }
}
const objQ = (alias, id) => `${alias}:object(address:"${id}"){asMoveObject{contents{json}}}`;
const pick = (d, k) => d[k]?.asMoveObject?.contents?.json || {};

const settledRow = (j, ts) => ({
  round: num(j.round_id), tile: num(j.winning_square), total: num(j.total_deployed),
  winners: num(j.winners_total), payout: num(j.winners_payout), reward: num(j.round_reward),
  vault: num(j.vault_fee), stakerReward: num(j.staker_reward), dev: num(j.dev_fee), players: num(j.players), ts,
});
// SUI a settled round added to the reserve. With no miner on the winning tile the whole pot
// except the 1% creator fee goes there, but the event's vault_fee only carries the 4% part.
const vaulted = r => (r.winners === 0 ? r.total - r.dev : r.vault);
async function loadGlobal() {
  const d = await gql(`{${objQ("b", IDS.board)} ${objQ("t", IDS.treasury)} ${objQ("p", IDS.pool)}${IDS.market ? " " + objQ("m", IDS.market) : ""}
    st:events(filter:{type:"${EV.settled}"},last:12){nodes{timestamp contents{json}}}
    dp:events(filter:{type:"${EV.deployed}"},last:50){nodes{timestamp transaction{digest} contents{json}}}}`);
  const b = pick(d, "b"), t = pick(d, "t"), p = pick(d, "p"), m = pick(d, "m");
  // Cetus pool is Pool<GTS, SUI>, both 9 decimals: price (SUI per GTS) = (sqrt_price / 2^64)^2.
  const sq = num(m.current_sqrt_price) / 2 ** 64;
  const supply = num(t.cap?.total_supply?.value), vault = num(t.vault);
  const minted = num(t.minted), tGenesis = num(t.genesis_ms);
  const recent = (d.st?.nodes || []).map(n => settledRow(n.contents?.json || {}, n.timestamp)).reverse();
  const deploys = (d.dp?.nodes || []).map(n => {
    const j = n.contents?.json || {};
    return { round: num(j.round_id), player: j.player, amounts: (j.amounts || []).map(num), total: num(j.total), ts: n.timestamp, digest: n.transaction?.digest };
  }).reverse();
  return {
    supply, vault, minted, floor: supply > 0 ? vault / supply : 0, market: sq > 0 ? sq * sq : 0,
    staked: num(p.total_staked),
    pool: {
      total: BigInt(p.total_staked || 0), acc: BigInt(p.acc_reward_per_share || 0), rate: BigInt(p.reward_rate || 0),
      finish: num(p.period_finish), last: num(p.last_update),
    },
    last: recent[0] || null, recent, deploys,
    board: {
      genesis: num(b.genesis_ms) || tGenesis,
      cur_id: num(b.cur_id), cur_total: num(b.cur_total), cur_started: b.cur_started === true, cur_players: num(b.cur_players),
      round_ms: num(b.round_ms) || 60_000,
      cur_deployed: (b.cur_deployed || []).map(num), cur_end_ms: num(b.cur_end_ms),
      freeze_ms: num(b.freeze_ms), min_deploy: num(b.min_deploy) || 10_000_000, dev_fees: num(b.dev_fees),
    },
  };
}
// One request for everything the wallet view needs (balances, miner, GTS coins, stake positions).
async function loadUser(addr) {
  const objs = (alias, type, first) => `${alias}:objects(filter:{type:"${type}"},first:${first}){nodes{address contents{json}}}`;
  const d = await gql(`{address(address:"${addr}"){s:balance(coinType:"0x2::sui::SUI"){totalBalance} g:balance(coinType:"${T_GTS}"){totalBalance}
    ${objs("m", T_MINER, 10)} ${objs("c", `0x2::coin::Coin<${T_GTS}>`, 50)} ${objs("p", T_POS, 50)}}}`);
  const nodes = k => (d.address?.[k]?.nodes || []).map(n => ({ id: n.address, f: n.contents?.json || {} }));
  const bal = { address: d.address }, miners = nodes("m"), coins = nodes("c"), positions = nodes("p");
  userAt = Date.now();
  const miner = miners.find(m => num(m.f.round_id) !== 0) || miners[0] || null;
  return {
    sui: num(bal.address?.s?.totalBalance), gts: num(bal.address?.g?.totalBalance),
    miner: miner ? { id: miner.id, round_id: num(miner.f.round_id), deployed: (miner.f.deployed || []).map(num), total: num(miner.f.total_deployed) } : null,
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
  const rounds = settled.list.map(e => ({ ...settledRow(e.j, e.ts), digest: e.digest }));
  return {
    rounds, byRound, stakes, deployed: deployed.list, redeemed: redeemed.list,
    capped: settled.capped || deployed.capped,
    totals: {
      rounds: rounds.length,
      volume: rounds.reduce((a, r) => a + r.total, 0),
      paid: rounds.reduce((a, r) => a + (r.winners > 0 ? r.winners + r.payout : 0), 0),
      reserve: rounds.reduce((a, r) => a + vaulted(r), 0),
      stakerGts: rounds.reduce((a, r) => a + r.stakerReward, 0),
      fees: rounds.reduce((a, r) => a + vaulted(r) + r.dev, 0),
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

// A wallet that never answers must not leave the app waiting forever.
const within = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("timeout")), ms))]);
async function connect(w, silent = false) {
  const res = silent
    ? await within(w.features["standard:connect"].connect({ silent: true }), 4000)
    : await w.features["standard:connect"].connect();
  const accs = res?.accounts?.length ? res.accounts : w.accounts;
  if (!accs.length) return false;
  wallet = w; account = accs[0];
  try { localStorage.setItem("gtstar.wallet", w.name); } catch {}
  w.features["standard:events"]?.on("change", ({ accounts }) => {
    if (accounts) { account = accounts[0] || null; if (!account) wallet = null; USER = null; renderWallet(); refresh(); }
  });
  renderWallet(); refresh();
  return true;
}
async function disconnect() {
  try { await wallet?.features["standard:disconnect"]?.disconnect(); } catch {}
  try { localStorage.removeItem("gtstar.wallet"); } catch {}
  wallet = null; account = null; USER = null;
  $("acctMenu").hidden = true; $("mNameForm").hidden = true;
  renderWallet(); refresh();
}
function renderWallet() {
  const b = $("btnConnect");
  b.textContent = account ? label(account.address) : "Connect";
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
  list.forEach(w => {
    const b = document.createElement("button"); b.type = "button";
    const img = document.createElement("img"); img.src = w.icon; img.alt = "";
    const s = document.createElement("span"); s.textContent = w.name;
    b.append(img, s);
    b.onclick = async () => {
      closeModal();
      const btn = $("btnConnect");
      btn.textContent = "Connecting…"; btn.disabled = true;
      toast(`Approve the connection in ${w.name}.`);
      try { await connect(w); $("toast").hidden = true; }
      catch (e) { toast(/reject|cancel|denied/i.test(String(e?.message || e)) ? "Connection cancelled." : "Connection failed: " + (e.message || e), true); }
      finally { btn.disabled = false; renderWallet(); }
    };
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
const KEEPER_MIN_POT = 0;   // the keeper draws every round; raise together with KEEPER_MIN_POT_MIST if that changes
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
  const b = $(btnId), old = b.textContent;
  b.disabled = true; b.textContent = "Confirm in wallet";
  try {
    // Coin and miner IDs from a cached view may have been consumed by an earlier transaction,
    // so re-read the wallet unless the cached view is fresh and nothing was sent since.
    if (!USER || userAt <= txAt || Date.now() - userAt > 6000) USER = await loadUser(account.address);
    const tx = new Transaction();
    tx.setSender(account.address);
    await build(tx);
    // If the wallet window is closed without an answer the request never settles; release the app after 90s.
    const r = await within(signAndExecuteTransaction(wallet, { transaction: tx, account, chain: CHAIN }), 90_000)
      .catch(e => { throw e.message === "timeout" ? new Error("No answer from the wallet. Open it and try again.") : e; });
    txAt = Date.now();
    toast(`${label} confirmed. <a href="${SCAN}/tx/${r.digest}" target="_blank" rel="noopener">View transaction</a>`, false, true);
    refresh(); setTimeout(refresh, 1500); setTimeout(refresh, 4000);
    return r;
  } catch (e) {
    txAt = Date.now();
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
// `split` may be a transaction result (the exact amount a pool asks for); `amount` is its known upper bound.
function gtsCoin(tx, amount, split = amount) {
  const coins = USER?.gtsCoins || [];
  const total = coins.reduce((a, c) => a + c.balance, 0);
  if (!coins.length || total < amount) throw new Error("Insufficient GTS balance.");
  const primary = tx.object(coins[0].id);
  if (coins.length > 1) tx.mergeCoins(primary, coins.slice(1).map(c => tx.object(c.id)));
  const [c] = tx.splitCoins(primary, [split]);
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
// One transaction for everything claimable: the last round (SUI winnings + mined GTS) and staking yield.
const claimAll = () => exec("Claim", "btnClaimAll", tx => {
  let n = 0;
  if (rewards().ready) { claimInto(tx, tx.object(USER.miner.id)); n++; }
  (USER.positions || []).forEach(p => {
    if (posPending(p, Date.now()) <= 0n) return;
    const [c] = tx.moveCall({ target: T("staking::claim_rewards"), arguments: [tx.object(IDS.pool), tx.object(p.id), tx.object.clock()] });
    tx.transferObjects([c], account.address); n++;
  });
  if (!n) throw new Error("Nothing to claim.");
});
const settle = () => exec("Draw", "btnPlay", tx => {
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
  $("hMined").textContent = STATE ? sui(STATE.minted, 2) : "—";
  $("hVolume").textContent = HIST ? sui(HIST.totals.volume, 2) : "—";
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
const winOf = (p, r) => { const w = p.amounts[r.tile] || 0; return w > 0 && r.winners > 0 ? w + Math.floor(r.payout * w / r.winners) : 0; };
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
function trackRounds() {
  const L = STATE?.last;
  if (!L) return;
  if (lastSeen === null) { lastSeen = L.round; return; }
  if (L.round <= lastSeen) return;
  lastSeen = L.round;
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
  const auto = p === "ended" && b.cur_total >= KEEPER_MIN_POT;
  if (auto && !landing) startScan(); else if (!landing) stopScan();
  $("board").classList.toggle("settled", showWin >= 0);
  $("board").classList.toggle("drawing", auto || !!landing);
  tileEls.forEach(c => {
    const i = +c.dataset.i, v = dep[i] / MIST, sel = selected.has(i);
    c.classList.toggle("has", v > 0);
    c.classList.toggle("sel", sel);
    c.classList.toggle("win", i === showWin);
    c.style.setProperty("--heat", (dep[i] / max).toFixed(3));
    c.setAttribute("aria-pressed", sel);
    c.setAttribute("aria-label", `Tile ${i + 1}, ${fmt(v, 3)} SUI, ${counts[i]} miners`);
    c.querySelector(".a").textContent = fmt(v, 3);
    const pc = c.querySelector(".pc");
    pc.hidden = !counts[i]; pc.querySelector("b").textContent = counts[i];
    c.querySelector(".me").hidden = true;
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
  let sub = L.winners === 0 ? "No one was on this tile. The pot went to the reserve."
    : L.payout > 0 ? `${n === 1 ? "The winner takes" : `${n || "The"} winners split`} ${sui(L.payout, 4)} SUI from the other tiles`
    : "Only this tile was played. Stakes returned.";
  const top = winners[0], topProfit = top ? profitOf(top.p, L) : 0;
  if (top && topProfit > 0) sub += ` · Top <span${nameOf(top.p.player) ? "" : ' class="mono"'}>${esc(top.p.player === account?.address ? "You" : label(top.p.player))}</span> +${sui(topProfit, 4)} SUI`;
  // Your result is net of everything you deployed this round, so a win that returns less than you put in never reads as a gain.
  let me = "";
  const m = USER?.miner, back = m && m.round_id === L.round ? rewards().sui : 0, net = back - (m?.total || 0);
  if (back > 0) me = net > 0 ? `<div class="res-me won">You won <b>+${sui(net, 4)} SUI</b></div>` : `<div class="res-me">Your tile won · <b>${sui(back, 4)} SUI back</b></div>`;
  const youWon = back > 0 && net > 0;
  if (youWon && fresh && cheered !== L.round) { cheered = L.round; toast(`You won +${sui(net, 4)} SUI on tile ${L.tile + 1}.`); }
  box.hidden = false;
  box.classList.toggle("fresh", !!fresh);
  box.classList.toggle("won", youWon);
  box.innerHTML = `<div class="res-main"><span class="res-tile">${L.tile + 1}</span><div><b>Round #${fmt(L.round, 0)} · Tile ${L.tile + 1} wins</b><small>${sub}</small></div></div>${me ? `<div class="res-side">${me}</div>` : ""}`;
}

let cheered = null;
function renderRecent() {
  const list = STATE?.recent || [];
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
    if (r) { const w = winOf(p, r); res = w ? `<span class="res won">+${sui(w, 4)} SUI</span>` : `<span class="res">No win</span>`; }
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

// Everything the connected wallet can claim right now.
function rewards() {
  const out = { ready: false, sui: 0, gts: 0, yield: 0n };
  const m = USER?.miner, b = STATE?.board;
  if (m && m.round_id !== 0 && b && m.round_id < b.cur_id) {
    out.ready = true;
    const r = (STATE.recent || []).find(x => x.round === m.round_id) || HIST?.rounds.find(x => x.round === m.round_id);
    if (r) {
      out.gts = r.total ? Math.floor(r.reward * m.total / r.total) : 0;
      const w = m.deployed[r.tile] || 0;
      out.sui = w > 0 && r.winners > 0 ? w + Math.floor(r.payout * w / r.winners) : 0;
    }
  }
  if (STATE) out.yield = (USER?.positions || []).reduce((a, p) => a + posPending(p, Date.now()), 0n);
  out.any = out.ready || out.yield >= 100_000n;   // ignore dust below 0.0001 GTS
  return out;
}
function renderRewards() {
  const R = rewards();
  $("rwSui").textContent = USER ? sui(R.sui, 4) : "—";
  $("rwGts").textContent = USER ? sui(R.gts, 4) : "—";
  $("rwYield").textContent = USER ? sui(Number(R.yield), 6) : "—";
  $("rwSui").classList.toggle("won", R.sui > 0);
  if (busy && busy !== "btnClaimAll") $("btnClaimAll").disabled = true;
  if (!busy) {
    $("btnClaimAll").textContent = account ? "Claim all" : "Connect wallet";
    $("btnClaimAll").disabled = !!account && !R.any;
  }
  const hc = $("hdrClaim");
  hc.hidden = !R.any;
  if (R.any) hc.textContent = R.sui > 0 ? `Claim ${sui(R.sui, 3)} SUI` : "Claim";
}

function renderMine() {
  const b = STATE?.board, p = phase();
  $("sDeployed").textContent = b ? sui(b.cur_total, 3) : "—";
  $("sRound").textContent = b ? `#${fmt(b.cur_id, 0)}` : "—";
  $("sPlayers").textContent = b ? fmt(b.cur_players, 0) : "—";
  let t = "—", lbl = "Time left", prog = 0;
  if (p === "open") { t = `${b.round_ms / 60_000}:00`; lbl = "Waiting"; prog = 1; }
  else if (p === "live" || p === "frozen") {
    const ms = Math.max(0, b.cur_end_ms - Date.now()), s = Math.ceil(ms / 1000);
    t = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; prog = ms / b.round_ms;
    if (p === "frozen") lbl = "Closing";
  } else if (p === "ended") {
    const auto = b.cur_total >= KEEPER_MIN_POT;
    t = auto ? "Drawing" : "Ready"; lbl = auto ? "Picking the winner" : "Draw the winner";
  }
  $("sTime").textContent = t; $("sPhase").textContent = lbl;
  $("sProg").style.transform = `scaleX(${Math.min(1, prog).toFixed(4)})`;
  const bar = document.querySelector(".round-bar");
  bar.dataset.phase = p;
  bar.toggleAttribute("data-urgent", p === "live" && b.cur_end_ms - Date.now() <= 10_000);
  // Countdown in the tab title brings players back from other tabs.
  document.title = p === "live" || p === "frozen" ? `${t} · Round #${b.cur_id} · GTStar` : p === "ended" ? `${t === "Ready" ? "Ready to draw" : "Drawing"} · GTStar` : "GTStar";

  const per = parseAmt($("amt").value);
  $("tileCount").textContent = selected.size;
  $("totalCost").textContent = fmt(per * selected.size, 4);
  $("mbTiles").textContent = `${selected.size} ${selected.size === 1 ? "tile" : "tiles"} · ${fmt(per, 4)} SUI each`;
  $("mbTotal").textContent = `Total ${fmt(per * selected.size, 4)} SUI`;

  const claimable = rewards().ready;
  const min = b ? b.min_deploy / MIST : 0.01;
  if (!busy) {
    let label = "Deploy", dis = false;
    if (!account) label = "Connect wallet";
    else if (p === "loading") { label = "Loading"; dis = true; }
    else if (p === "ended") label = selected.size ? "Draw winner, then deploy" : "Draw winner";
    else if (p === "frozen") { label = "Round closing"; dis = true; }
    else if (!selected.size) { label = "Select tiles"; dis = true; }
    else if (per < min) { label = `Minimum ${min} SUI per tile`; dis = true; }
    else label = `Deploy ${fmt(per * selected.size, 4)} SUI`;
    $("btnPlay").textContent = label; $("btnPlay").disabled = dis;
  } else if (busy !== "btnPlay") { $("btnPlay").textContent = "Waiting for your wallet"; $("btnPlay").disabled = true; }
  let hint = `Minimum ${min} SUI per tile. Every participant mines GTS.`;
  if (claimable && (p === "open" || p === "live")) {
    const R = rewards();
    hint = `${per * selected.size > 0 ? `You pay ${fmt(per * selected.size, 4)} SUI. ` : ""}Your rewards from the last round${R.gts ? ` (${sui(R.gts, 4)} GTS${R.sui ? `, ${sui(R.sui, 4)} SUI` : ""})` : ""} are collected in the same transaction.`;
    if (!selected.size) hint = "Your rewards from the last round are collected with your next deploy, or use Claim all.";
  } else if (p === "ended") hint = b.cur_total >= KEEPER_MIN_POT
    ? "The round has ended. The winner is drawn within seconds."
    : "The round has ended. Anyone can draw the winner; rounds above 0.2 SUI are drawn automatically.";
  else if (p === "frozen") hint = "Deposits close 5 seconds before the round ends.";
  else if (p === "open") hint = "The next round starts with the first deploy and runs for 60 seconds.";
  $("playHint").textContent = hint;
  $("boardHint").hidden = selected.size > 0 || p === "ended" || p === "frozen" || !!reveal?.landing;
  $("myGts").textContent = USER ? sui(USER.gts, 3) : "—";
  $("mySui").textContent = USER ? sui(USER.sui, 3) : "—";
  document.querySelector(".rw-bal").hidden = !USER;
  renderRewards(); renderResult(); renderRecent(); renderFeed();
}

// ---------- render: explorer ----------
let actShown = 25, actTab = "rounds", revTab = "reserve", lbTab = "miners";
const openRounds = new Set();
const txLink = d => `<a href="${SCAN}/tx/${d}" target="_blank" rel="noopener" data-stop>${d.slice(0, 6)}…</a>`;
const acctLink = a => `<a href="${SCAN}/account/${a}" target="_blank" rel="noopener"${nameOf(a) ? "" : ' class="mono"'} data-stop>${esc(label(a))}</a>`;
function winnersOf(r) {
  const list = HIST.byRound.get(r.round) || [];
  const agg = new Map();
  list.forEach(d => { const w = d.amounts[r.tile] || 0; if (w > 0) agg.set(d.player, (agg.get(d.player) || 0) + w); });
  return agg;
}
const marketText = () => (STATE.market ? `${fmt(STATE.market, 6)} SUI` : "—");
function renderExplorer() {
  if (!STATE) return;
  const t = HIST?.totals;
  $("gFloor").textContent = `${fmt(STATE.floor, 6)} SUI`;
  $("gReserve").textContent = `${sui(STATE.vault, 4)} SUI`;
  $("gMarket").textContent = marketText();
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
    const head = `<thead><tr><th>Round</th><th>Tile</th><th>Winner</th><th class="r">Winners</th><th class="r">Deployed</th><th class="r">Vaulted</th><th class="r">Won from others</th><th class="r">GTS</th><th class="r">Time</th></tr></thead>`;
    const body = rows.map(r => {
      const w = winnersOf(r);
      const winner = w.size === 0 ? `<span class="muted">Reserve</span>` : w.size === 1 ? acctLink([...w.keys()][0]) : "Split";
      const winnings = r.winners > 0 ? r.payout : 0;
      let html = `<tr class="round" data-r="${r.round}" tabindex="0" aria-expanded="${openRounds.has(r.round)}">
        <td><b>#${fmt(r.round, 0)}</b></td><td><span class="tile-badge${w.size ? "" : " none"}">#${r.tile + 1}</span></td><td>${winner}</td>
        <td class="r">${w.size}</td><td class="r">${sui(r.total, 3)}</td><td class="r">${sui(vaulted(r), 4)}</td>
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
    const won = a.onWin > 0 && r.winners > 0 ? Math.floor(r.payout * a.onWin / r.winners) : 0;
    const gts = r.total ? r.reward * a.total / r.total : 0;
    return `<div class="m">${acctLink(p)}<span>${sui(a.total, 3)} SUI deployed · ${sui(gts, 4)} GTS mined</span>
      <span class="${won ? "won" : "muted"}">${won ? `Won +${sui(won, 4)} SUI` : a.onWin > 0 && r.winners > 0 ? "Stake returned" : "No SUI win"}</span></div>`;
  }).join("") + `</div>`;
}
function renderRevenue() {
  const cfg = {
    reserve: { v: vaulted, unit: "SUI", share: "4% of losing pot, 99% with no winner", label: "Added to the GTS reserve" },
    stakers: { v: r => r.stakerReward, unit: "GTS", share: "+10% of round GTS", label: "Minted to the staking stream" },
  }[revTab];
  const rows = HIST.rounds.filter(r => cfg.v(r) > 0);
  const total = rows.reduce((a, r) => a + cfg.v(r), 0);
  const day = Date.now() - 86_400_000;
  const d24 = rows.filter(r => new Date(r.ts).getTime() >= day).reduce((a, r) => a + cfg.v(r), 0);
  $("revSum").innerHTML = `<div><span>All time</span><b>${sui(total, 4)} ${cfg.unit}</b></div><div><span>Last 24h</span><b>${sui(d24, 4)} ${cfg.unit}</b></div><div><span>Source</span><b>${cfg.share}</b></div>`;
  $("revTbl").innerHTML = `<thead><tr><th>Round</th><th>${cfg.label}</th><th class="r">Amount</th><th class="r">Time</th></tr></thead><tbody>` +
    (rows.slice(0, 25).map(r => `<tr><td>#${fmt(r.round, 0)}</td><td class="muted">${revTab === "stakers" ? "Streamed over 7 days" : r.winners === 0 ? "Fee plus pot (no miner on winning tile)" : "Fee from losing pot"}</td>
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
    sub = "Top winners by SUI won from other tiles (stakes returned are not counted).";
    const m = new Map();
    HIST.rounds.forEach(r => { if (!r.winners) return; winnersOf(r).forEach((amt, p) => m.set(p, (m.get(p) || 0) + Math.floor(r.payout * amt / r.winners))); });
    rows = [...m.entries()].filter(([, v]) => v > 0);
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
  $("kSchedMax").textContent = fmt(Math.floor(cumAt(genesis || now, EMISSION_END)), 0);
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
  $("kMarket").textContent = marketText();
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
// ---------- prices + trade ----------
let PRICE = { sui: null };
// A failed or rate-limited source never overwrites the last good price.
const okPrice = sui => (sui > 0 && isFinite(sui) ? { sui } : null);
const getJson = url => within(fetch(url).then(r => r.json()), 8000);
async function loadPrice() {
  let p = null;
  try {
    const j = await getJson("https://api.coingecko.com/api/v3/simple/price?ids=sui&vs_currencies=usd");
    p = okPrice(+j.sui?.usd);
  } catch {}
  if (!p) try {
    const j = await getJson("https://api.binance.com/api/v3/ticker/24hr?symbol=SUIUSDT");
    p = okPrice(+j.lastPrice);
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
  $("swRoute").textContent = viaPool ? "Cetus GTS/SUI pool" : "GTS reserve (burn at floor)";
  $("swFee").textContent = viaPool ? `1% pool fee, ${SLIPPAGE * 100}% max slippage` : "None";
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
    if (!account) label = "Connect wallet";
    else if (need <= 0) { label = "Enter an amount"; dis = true; }
    else if (need > balIn) { label = `Insufficient ${tok}`; dis = true; }
    else if (sell && !known) { label = STATE?.supply && need > STATE.supply ? "Exceeds GTS supply" : "No quote for this amount"; dis = true; }
    else if (!sell && QUOTE.amt === need && !QUOTE.a2b && QUOTE.exceed) { label = "Not enough liquidity"; dis = true; }
    btn.textContent = label; btn.disabled = dis;
  }
}
// Amount the percentage buttons work from: all GTS when selling, SUI minus gas when buying.
const swapMax = () => (swapDir === "sell" ? USER.gts : Math.max(0, USER.sui - 2 * GAS_RESERVE));

function render() {
  if (view !== "mine") document.title = "GTStar";
  renderTicker(); renderWallet(); renderRewards();
  if (view === "home") renderHome();
  if (view === "mine") { renderBoard(); renderMine(); }
  if (view === "trade") renderTrade();
  if (view === "explorer") renderExplorer();
  if (view === "tokenomics") renderTokenomics();
  if (view === "stake") renderStake();
}
async function refresh() {
  try {
    const [g, u] = await Promise.all([loadGlobal(), account ? loadUser(account.address) : Promise.resolve(null)]);
    STATE = g; USER = u; trackRounds(); render();
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
  if (stale && !busy) return location.reload();
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
$("btnStake").onclick = () => (account ? stake() : openWalletModal());
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
$("moreAct").onclick = () => { actShown += 25; renderExplorer(); };
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

$("pkgLink").href = `${SCAN}/object/${IDS.package}`;
$("caAddr").textContent = T_GTS;
$("caScan").href = `${SCAN}/coin/${T_GTS}`;
$("caCopy").onclick = async () => { try { await navigator.clipboard.writeText(T_GTS); toast("Contract address copied."); } catch { toast(T_GTS); } };
$("amt").value = "0.01";
buildBoard(); buildArt(); route(); autoReconnect();
// Price every minute, retried after 10 seconds while there is none yet.
(function price() { loadPrice().then(ok => setTimeout(price, ok || PRICE.sui ? 60_000 : 10_000)); })();
// Poll faster on the board, fastest while a finished round is waiting to be drawn.
(function poll() { refresh().finally(() => setTimeout(poll, view !== "mine" ? 4000 : phase() === "ended" ? 1000 : 2000)); })();
setInterval(() => { if (["home", "explorer", "tokenomics"].includes(view)) refreshHistory(); }, 15000);
setInterval(() => { if (view === "mine") { renderBoard(); renderMine(); } if (view === "stake") renderStake(); }, 1000);
