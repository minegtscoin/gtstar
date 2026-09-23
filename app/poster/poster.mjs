// GTStar X poster — Hostinger cron entry (runs once a day, posts once a week).
// Reads live protocol data from Sui, compares it with the last posted snapshot, and posts one
// update to X through the v2 API (OAuth 1.0a user context). No dependencies: Node 22 only.
//   node poster.mjs            post if due
//   node poster.mjs --dry      print the post, do not send or save
//   node poster.mjs --force    post now even if not due
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
const FORCE = process.argv.includes("--force");
const POST_EVERY_H = Number(process.env.POST_EVERY_H) || 167; // weekly (an hour of slack for cron timing)
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
    `GTStar weekly${week ? `, week ${week}` : ""}.`, "",
    `${int(a.rounds)} rounds played`,
    `${small(a.sui)} SUI deployed`,
    `${small(a.mined)} GTS mined by players`,
    `Reserve now ${small(s.vault)} SUI`, "",
    `${fmt(unmined, 2)}% of all GTS is still unmined, and emission halves every 262,000 rounds. The earlier you mine, the more you get.`,
  ];
  else if (v === 1) body = [
    "Every GTS is backed by real SUI.", "",
    dv > 0 && dv < s.vault ? `The reserve grew +${small(dv)} SUI this week to ${small(s.vault)} SUI.` : `The reserve holds ${small(s.vault)} SUI.`,
    `Floor: ${fmt(s.floor, 5)} SUI per GTS${floorUsd}. Burn GTS any time for your share.`, "",
    "It grows as more people play. No premine, no team tokens.",
  ];
  else if (v === 2) body = [
    `Biggest pot this week: ${small(a.biggest)} SUI.`, "",
    "A new round every 60 seconds. One tile takes the pot, and every player mines GTS, win or lose.", "",
    `This week: ${int(a.rounds)} rounds, ${small(a.sui)} SUI deployed, ${small(a.mined)} GTS mined.`,
  ];
  else body = [
    h ? `Next GTS halving in ${int(h)} rounds.` : "GTS emission halves every 262,000 rounds.", "",
    "After it, every round mints half as much GTS. Mine now, stake what you mine, and earn more GTS with no lock-up.", "",
    `Staked: ${small(s.staked)} GTS (${fmt(pct(s.staked, s.supply), 1)}% of supply).`,
  ];
  // No URL in the text: X charges $0.20 for a post with a link and $0.015 without. The site is in the bio.
  const tail = ["", "Play now. Link in bio."];
  const head = milestone(prev, s);
  const withHead = head ? [head, "", ...body, ...tail].join("\n") : null;
  const plain = [...body, ...tail].join("\n");
  return withHead && xLength(withHead) <= 280 ? withHead : plain;
}

// X counts every URL as 23 characters.
const xLength = t => t.replace(/https?:\/\/\S+/g, "x".repeat(23)).length;

// ---------- X API (OAuth 1.0a) ----------
const enc = s => encodeURIComponent(s).replace(/[!'()*]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase());
async function tweet(text) {
  const { X_API_KEY, X_API_SECRET, X_ACCESS_TOKEN, X_ACCESS_SECRET } = process.env;
  if (!X_API_KEY || !X_API_SECRET || !X_ACCESS_TOKEN || !X_ACCESS_SECRET) throw new Error("X API keys missing in .env");
  const url = "https://api.x.com/2/tweets";
  const o = {
    oauth_consumer_key: X_API_KEY, oauth_nonce: crypto.randomBytes(16).toString("hex"),
    oauth_signature_method: "HMAC-SHA1", oauth_timestamp: String(Math.floor(Date.now() / 1000)),
    oauth_token: X_ACCESS_TOKEN, oauth_version: "1.0",
  };
  const params = Object.keys(o).sort().map(k => `${enc(k)}=${enc(o[k])}`).join("&");
  const base = `POST&${enc(url)}&${enc(params)}`;
  o.oauth_signature = crypto.createHmac("sha1", `${enc(X_API_SECRET)}&${enc(X_ACCESS_SECRET)}`).update(base).digest("base64");
  const auth = "OAuth " + Object.keys(o).sort().map(k => `${enc(k)}="${enc(o[k])}"`).join(", ");
  const r = await fetch(url, { method: "POST", headers: { Authorization: auth, "Content-Type": "application/json" }, body: JSON.stringify({ text }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`X API ${r.status}: ${JSON.stringify(j).slice(0, 300)}`);
  return j.data?.id;
}

// ---------- main ----------
const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, "utf8")) : { last: null, variant: 0 };
if (!FORCE && !DRY && state.last && Date.now() - state.last.ts < POST_EVERY_H * 3_600_000) process.exit(0);

const s = await snapshot();
// Weekly GTS mined and reserve growth come from snapshot differences (exact). Before the first
// post there is no snapshot, so launch week counts from genesis (empty state at genesis).
const base = state.last || (s.ts - s.genesis < 8 * 86_400_000 ? { ts: s.genesis, rounds: 0, supply: 0, minted: 0, vault: 0, staked: 0 } : null);
if (!base) {
  // No reference point yet: record one now and post from next week on.
  if (!DRY) fs.writeFileSync(stateFile, JSON.stringify({ last: s, variant: state.variant }, null, 2));
  console.log("baseline saved, first post next week");
  process.exit(0);
}
const a = await activitySince(base.ts);
a.mined = s.minted - base.minted;
a.vaultIn = s.vault - base.vault;
const price = await suiUsd();
const text = compose(s, state.last, a, price, state.variant % 4);
if (xLength(text) > 280) throw new Error(`post too long (${xLength(text)}):\n${text}`);

if (DRY) {
  console.log(text + `\n\n[${xLength(text)} chars]`);
} else {
  const id = await tweet(text);
  fs.writeFileSync(stateFile, JSON.stringify({ last: s, variant: state.variant + 1, lastId: id }, null, 2));
  console.log(new Date().toISOString(), "posted", id);
}
