// GTStar X poster — Hostinger cron entry (started once a day, posts twice a week).
// Tuesday: a data post built from live Sui numbers, compared with the last data snapshot.
// Friday: a short, light post from a rotating pool (how it works, a question, a tip).
// Posts through the X v2 API (OAuth 1.0a user context). No dependencies: Node 22 only.
//   node poster.mjs                  post if today is a posting day and nothing went out yet
//   node poster.mjs --dry            print both posts, do not send or save
//   node poster.mjs --force data     post the data post now (or: --force fun)
//   node poster.mjs --engage         like new mentions of @MineGTS1, repost players' win shares
// Needs ~/gtstar-poster/.env with X_API_KEY, X_API_SECRET, X_ACCESS_TOKEN, X_ACCESS_SECRET.
import fs from "fs";
import path from "path";
import crypto from "crypto";
import { fileURLToPath } from "url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const envFile = path.join(dir, ".env");
if (fs.existsSync(envFile)) for (const line of fs.readFileSync(envFile, "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
  if (m) process.env[m[1]] ??= m[2];
}
const DRY = process.argv.includes("--dry");
const FORCE = process.argv.includes("--force") ? process.argv[process.argv.indexOf("--force") + 1] || "data" : null;
const DATA_DAY = 2, FUN_DAY = 5; // US Eastern weekdays: Tuesday and Friday
const stateFile = path.join(dir, "state.json");

const IDS = {
  pkg: "0x2cef85db37c28fccda8b409e2a321ee5932e1b292b596877184245972250004e",
  board: "0x324f7da04e5a328c8ec674f1ad5615fad1bc34ffa6cee48beb86731c718c1664",
  treasury: "0x1dfef30cd82739d4b70f71fdbe15dd9ad218324054401a3751ac7b91dcd1b786",
  pool: "0xb09a8451b452b779c7fd6fba094e12693f379af5924ea54c2a5ad5fd586787de",
  market: "0x7492d608ea92b2274bd83be39ac17ebb0f3fed42e4b7a638c17ebf8743e6ebcf",
};
const MAX_SUPPLY = 571_896.875;
const HALVING_ROUNDS = 262_000;
const D = 1e9;

// ---------- data ----------
async function gql(query) {
  const r = await fetch("https://graphql.mainnet.sui.io/graphql", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ query }),
  });
  const j = await r.json();
  if (j.errors) throw new Error(j.errors[0].message);
  return j.data;
}
const objQ = (a, id) => `${a}:object(address:"${id}"){asMoveObject{contents{json}}}`;
const pick = (d, k) => d[k]?.asMoveObject?.contents?.json || {};
const n = v => Number(v || 0);

async function snapshot() {
  const d = await gql(`{${objQ("b", IDS.board)} ${objQ("t", IDS.treasury)} ${objQ("p", IDS.pool)} ${objQ("m", IDS.market)}}`);
  const b = pick(d, "b"), t = pick(d, "t"), p = pick(d, "p"), m = pick(d, "m");
  const supply = n(t.cap?.total_supply?.value) / D, vault = n(t.vault) / D, minted = n(t.minted) / D;
  const sq = n(m.current_sqrt_price) / 2 ** 64;
  return {
    ts: Date.now(), rounds: n(b.rounds?.size), supply, minted, burned: Math.max(0, minted - supply),
    vault, floor: supply > 0 ? vault / supply : 0, market: sq * sq, staked: n(p.total_staked) / D,
    genesis: n(b.genesis_ms),
  };
}

// Settled rounds after a given time: SUI deployed, players, biggest pot.
async function activitySince(sinceMs) {
  const out = { rounds: 0, sui: 0, players: 0, biggest: 0 };
  let before = null;
  for (let page = 0; page < 40; page++) {
    const d = await gql(`{events(filter:{type:"${IDS.pkg}::game::RoundSettled"},last:50${before ? `,before:"${before}"` : ""}){
      pageInfo{hasPreviousPage startCursor} nodes{timestamp contents{json}}}}`);
    const ev = d.events;
    let older = false;
    for (const e of ev.nodes) {
      if (Date.parse(e.timestamp) <= sinceMs) { older = true; continue; }
      const j = e.contents?.json || {};
      const sui = n(j.total_deployed) / D;
      out.rounds++; out.sui += sui; out.players += n(j.players);
      out.biggest = Math.max(out.biggest, sui);
    }
    if (older || !ev.pageInfo.hasPreviousPage) break;
    before = ev.pageInfo.startCursor;
  }
  return out;
}

async function suiUsd() {
  try {
    const j = await (await fetch("https://api.coingecko.com/api/v3/simple/price?ids=sui&vs_currencies=usd")).json();
    return j.sui?.usd || null;
  } catch { return null; }
}

// ---------- text ----------
// One post a week, rotating between four angles. Every number comes from the chain; nothing is invented.
const fmt = (x, dp = 2) => x.toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
const int = x => Math.round(x).toLocaleString("en-US");
const pct = (a, b) => (b > 0 ? (a / b) * 100 : 0);
const usd = x => (x >= 0.01 ? "$" + fmt(x, 2) : "$" + x.toPrecision(2));
const small = x => (x >= 100 ? int(x) : fmt(x, x >= 1 ? 2 : 3));

const MILESTONES = {
  rounds: [100, 500, 1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000],
  vault: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000, 10_000],
  supply: [100, 1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000],
};
function milestone(prev, s) {
  if (!prev) return null;
  const crossed = k => MILESTONES[k].filter(v => prev[k] < v && s[k] >= v).pop();
  const r = crossed("rounds");
  if (r) return `Milestone: ${int(r)} rounds played on GTStar.`;
  const v = crossed("vault");
  if (v) return `Milestone: the GTS reserve just passed ${int(v)} SUI.`;
  const g = crossed("supply");
  if (g) return `Milestone: ${int(g)} GTS mined by players.`;
  return null;
}

function roundsToHalving(played) {
  if (played >= 7 * HALVING_ROUNDS) return null;
  return (Math.floor(played / HALVING_ROUNDS) + 1) * HALVING_ROUNDS - played;
}

function compose(s, prev, a, price, variant) {
  const week = s.genesis ? Math.floor((s.ts - s.genesis) / (7 * 86_400_000)) + 1 : null;
  const unmined = 100 - pct(s.supply, MAX_SUPPLY);
  const floorUsd = price ? ` (${usd(s.floor * price)})` : "";
  const dv = a.vaultIn;
  const h = roundsToHalving(s.rounds);
  const active = a.rounds > 0;
  let v = variant;
  if (!active && (v === 0 || v === 2)) v = 3;
  let body;
  if (v === 0) body = [
    `GTStar${week ? `, week ${week}` : ""}:`, "",
    `${int(a.rounds)} rounds played`,
    `${small(a.sui)} SUI in the pots`,
    `${small(a.mined)} GTS mined by players`, "",
    unmined >= 99.9 ? "Almost all GTS is still up for grabs. Early miners get the most." : `${fmt(unmined, 1)}% of all GTS is still up for grabs. Early miners get the most.`,
  ];
  else if (v === 1) body = [
    "Every GTS is backed by real SUI.", "",
    dv > 0 && dv < s.vault ? `The reserve grew +${small(dv)} SUI this week. It now holds ${small(s.vault)} SUI.` : `The reserve holds ${small(s.vault)} SUI.`,
    `That's a floor of ${fmt(s.floor, 5)} SUI per GTS${floorUsd}, and you can burn for it any time.`, "",
    "No premine. No team tokens. Just players.",
  ];
  else if (v === 2) body = [
    `Biggest pot this week: ${small(a.biggest)} SUI.`, "",
    `${int(a.rounds)} rounds, one winning tile each time, and everyone mined GTS along the way.`, "",
    "Next round starts in under a minute.",
  ];
  else body = [
    h ? `${int(h)} rounds until the GTS halving.` : "GTS emission halves every 262,000 rounds.", "",
    "After that, every round mints half as much. Mining now is the cheapest GTS will ever be.", "",
    `${small(s.staked)} GTS is already staked and earning.`,
  ];
  // No URL in the text: X charges $0.20 for a post with a link and $0.015 without. The site is in the bio.
  const tail = ["", "Link in bio."];
  const head = milestone(prev, s);
  const withHead = head ? [head, "", ...body, ...tail].join("\n") : null;
  const plain = [...body, ...tail].join("\n");
  return withHead && xLength(withHead) <= 280 ? withHead : plain;
}

// Friday posts: short and human, no numbers that could go stale. Rotates in order.
const FUN = [
  `Pick a number from 1 to 25.

That's the whole game. A new round every minute on Sui, one tile takes the pot, and everyone mines GTS, win or lose.

Drop your lucky tile below.`,
  `Weekend plan: 0.01 SUI, one tile, 60 seconds.

Worst case you still walk away with GTS. Best case you take the pot.

Link in bio.`,
  `Lost the round? You still got paid.

Every player mines GTS, not just the winner. Stake it and it earns more GTS, no lock-up.

Link in bio.`,
  `Two kinds of players:

Spread across a few tiles and win more often.
Go all in on one and take a bigger cut when it hits.

Which one are you?`,
  `No premine. No team tokens. No VC bags.

Every GTS out there was mined by a player, and every one is backed by SUI in the reserve.

Go mine yours. Link in bio.`,
  `25 tiles. 60 seconds. One winner.

The fastest game on Sui is live right now. Come take a tile.

Link in bio.`,
  `Be honest: what tile are you picking first?

1 to 25. Wrong answers only.`,
  `You don't need to win to mine.

Play one round, claim your GTS, stake it. That's it. Your GTS keeps working while you sleep.

Link in bio.`,
];

// X counts every URL as 23 characters.
const xLength = t => t.replace(/https?:\/\/\S+/g, "x".repeat(23)).length;

// ---------- X API (OAuth 1.0a) ----------
const enc = s => encodeURIComponent(s).replace(/[!'()*]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase());
async function x(method, path, { query = {}, body } = {}) {
  const { X_API_KEY, X_API_SECRET, X_ACCESS_TOKEN, X_ACCESS_SECRET } = process.env;
  if (!X_API_KEY || !X_API_SECRET || !X_ACCESS_TOKEN || !X_ACCESS_SECRET) throw new Error("X API keys missing in .env");
  const url = "https://api.x.com/2/" + path;
  const o = {
    oauth_consumer_key: X_API_KEY, oauth_nonce: crypto.randomBytes(16).toString("hex"),
    oauth_signature_method: "HMAC-SHA1", oauth_timestamp: String(Math.floor(Date.now() / 1000)),
    oauth_token: X_ACCESS_TOKEN, oauth_version: "1.0",
  };
  // Query parameters are part of the OAuth signature; the JSON body is not.
  const all = { ...o, ...query };
  const params = Object.keys(all).sort().map(k => `${enc(k)}=${enc(all[k])}`).join("&");
  const base = `${method}&${enc(url)}&${enc(params)}`;
  o.oauth_signature = crypto.createHmac("sha1", `${enc(X_API_SECRET)}&${enc(X_ACCESS_SECRET)}`).update(base).digest("base64");
  const auth = "OAuth " + Object.keys(o).sort().map(k => `${enc(k)}="${enc(o[k])}"`).join(", ");
  const qs = Object.keys(query).length ? "?" + Object.keys(query).map(k => `${enc(k)}=${enc(query[k])}`).join("&") : "";
  const r = await fetch(url + qs, { method, headers: { Authorization: auth, ...(body && { "Content-Type": "application/json" }) }, body: body && JSON.stringify(body) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`X API ${method} ${path} ${r.status}: ${JSON.stringify(j).slice(0, 300)}`);
  return j;
}
const tweet = async text => (await x("POST", "tweets", { body: { text } })).data?.id;

// Engagement: only with people who mentioned @MineGTS1 first (X automation rules allow that, not
// cold replies or follows). Like every new mention; repost players' win shares, a few a day at most.
async function engage() {
  state.me ??= (await x("GET", "users/me")).data.id;
  const query = { max_results: "20", "tweet.fields": "author_id" };
  if (state.mentionSince) query.since_id = state.mentionSince;
  const j = await x("GET", `users/${state.me}/mentions`, { query });
  const list = (j.data || []).filter(t => t.author_id !== state.me).reverse(); // oldest first
  if (j.meta?.newest_id) state.mentionSince = j.meta.newest_id;
  if (!state.mentionSince && !list.length) return console.log("no mentions yet");
  const day = new Date().toISOString().slice(0, 10);
  if (state.rtDay !== day) { state.rtDay = day; state.rtCount = 0; }
  let liked = 0, reposted = 0;
  for (const t of list) {
    if (DRY) { console.log("would like", t.id, t.text.slice(0, 80)); continue; }
    try { await x("POST", `users/${state.me}/likes`, { body: { tweet_id: t.id } }); liked++; } catch (e) { console.log(e.message); }
    if (/just won/i.test(t.text) && state.rtCount < 5) {
      try { await x("POST", `users/${state.me}/retweets`, { body: { tweet_id: t.id } }); state.rtCount++; reposted++; } catch (e) { console.log(e.message); }
    }
  }
  if (!DRY) save();
  console.log(new Date().toISOString(), `engage: ${list.length} mentions, ${liked} liked, ${reposted} reposted`);
}

// ---------- main ----------
const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, "utf8")) : {};
state.variant ??= 0; state.fun ??= 0;
const save = () => fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
// Posting days and times follow US Eastern time (6 PM ET, the evening peak), including daylight saving.
const et = new Date(new Date().toLocaleString("en-US", { timeZone: "America/New_York" }));
const today = et.toISOString().slice(0, 10), wd = et.getDay();
if (process.argv.includes("--engage")) { await engage(); process.exit(0); }
const kind = FORCE || (DRY ? "both" : wd === DATA_DAY ? "data" : wd === FUN_DAY ? "fun" : null);
if (!kind || (!FORCE && !DRY && state.day === today)) process.exit(0);

async function dataPost() {
  const s = await snapshot();
  // Weekly GTS mined and reserve growth come from snapshot differences (exact). Before the first
  // post there is no snapshot, so launch week counts from genesis (empty state at genesis).
  const base = state.last || (s.ts - s.genesis < 8 * 86_400_000 ? { ts: s.genesis, rounds: 0, supply: 0, minted: 0, vault: 0, staked: 0 } : null);
  if (!base) {
    // No reference point yet: record one now and post from next week on.
    if (!DRY) { state.last = s; save(); }
    console.log("baseline saved, first data post next week");
    return null;
  }
  const a = await activitySince(base.ts);
  a.mined = s.minted - base.minted;
  a.vaultIn = s.vault - base.vault;
  return { s, text: compose(s, state.last, a, await suiUsd(), state.variant % 4) };
}

async function send(text, done) {
  if (xLength(text) > 280) throw new Error(`post too long (${xLength(text)}):
${text}`);
  if (DRY) return console.log(text + `

[${xLength(text)} chars]
---`);
  state.day = today; save(); // claim the day first so an overlapping run can't post twice
  const id = await tweet(text);
  done(); state.lastId = id; save();
  console.log(new Date().toISOString(), "posted", id);
}

if (kind === "data" || kind === "both") {
  const d = await dataPost();
  if (d) await send(d.text, () => { state.last = d.s; state.variant++; });
}
if (kind === "fun" || kind === "both") await send(FUN[state.fun % FUN.length], () => state.fun++);
