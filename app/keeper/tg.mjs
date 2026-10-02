// GTStar Telegram announcer: posts to the group every time the Wealth Fund pays, and the size of the
// fund once a day (6 PM US Eastern, only when it holds MIN_FUND or more).
//   node tg.mjs          run once (the keeper cron starts it every minute)
//   node tg.mjs --dry    print what it would post now, send nothing, keep no state
// Needs TG_TOKEN (the bot's token from BotFather) in the environment; off when unset. TG_CHAT is the
// group (default @MineGTS). No dependencies, so it runs as it is, without a bundle.
// State: <dir>/.tg-state.json { next: first Wealth Fund epoch not announced yet, day: last daily post }.
import fs from "fs";
import path from "path";

const BOARD = "0xc171dcb3ebba55d0d186140f43b09ca987fef92fb02c49df921f08c4c1e7548b";
const WF_PKG = "0x7c1288891489591765402a61bee62df34a68de25ffb0459d6e83c020f4ae5c42";
const SITE = "https://minegts.fun";
const SCAN = "https://suiscan.xyz/mainnet/tx/";
const MIN_FUND = 1e9; // the daily post needs 1 SUI in the fund
const DAILY_HOUR = 18; // US Eastern

const DRY = process.argv.includes("--dry");
const dir = path.dirname(new URL(import.meta.url).pathname);
const token = process.env.TG_TOKEN, chat = process.env.TG_CHAT || "@MineGTS";
if (!token && !DRY) process.exit(0);

const file = path.join(dir, ".tg-state.json");
const state = (() => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return {}; } })();
const save = () => { if (!DRY) fs.writeFileSync(file, JSON.stringify(state)); };
const log = m => console.log(`${new Date().toISOString()} ${m}`);

const sui = (mist, d = 2) => (Number(mist) / 1e9).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const short = a => `${a.slice(0, 6)}…${a.slice(-4)}`;

async function send(text) {
  if (DRY) { console.log(`--- would post to ${chat}:\n${text}\n`); return; }
  const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat_id: chat, text, link_preview_options: { is_disabled: true } }),
  });
  const j = await r.json().catch(() => ({}));
  if (!j.ok) throw new Error(`telegram: ${j.description || r.status}`);
}

const q = `{
  object(address:"${BOARD}"){
    asMoveObject{contents{json}}
    tk:dynamicField(name:{type:"${WF_PKG}::game::TicketsKey",bcs:"AA=="}){value{... on MoveValue{json}}}
  }
  events(last:5, filter:{type:"${WF_PKG}::game::WealthFundWon"}){nodes{transaction{digest} contents{json}}}
}`;
const res = await fetch("https://graphql.mainnet.sui.io/graphql", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ query: q }) });
const data = (await res.json()).data;
const board = data?.object?.asMoveObject?.contents?.json;
if (!board) { log("no board"); process.exit(1); }
const epoch = Number(data.object.tk?.value?.json?.epoch || 0);
const odds = Number(board.ml_odds), fund = Number(board.motherlode), min = Number(board.min_deploy);

// First run: start from the fund that is open now, so no old payout is posted (a dry run shows the last one).
if (state.next === undefined) { state.next = DRY ? epoch - 1 : epoch; save(); }

const wins = data.events.nodes
  .map(n => ({ ...n.contents.json, digest: n.transaction?.digest }))
  .filter(w => Number(w.epoch) >= state.next)
  .sort((a, b) => Number(a.epoch) - Number(b.epoch));
for (const w of wins) {
  const share = Number(w.total_tickets) > 0 ? Number(w.winner_tickets) / Number(w.total_tickets) * 100 : 0;
  await send([
    `Wealth Fund paid ${sui(w.amount, 4)} SUI to ${short(w.winner)} in round ${w.round_id}.`,
    `The winner held ${share >= 10 ? share.toFixed(0) : share.toFixed(1)}% of the tickets.`,
    "",
    "Tickets reset with every payout, so whoever plays now holds the biggest share of the next fund.",
    "",
    `Proof: ${SCAN}${w.digest}`,
    `Play: ${SITE}`,
  ].join("\n"));
  state.next = Number(w.epoch) + 1; save();
  log(`win epoch ${w.epoch} posted`);
}

// The size of the fund, once a day.
const et = new Date(new Date().toLocaleString("en-US", { timeZone: "America/New_York" }));
const day = `${et.getFullYear()}-${et.getMonth() + 1}-${et.getDate()}`;
if (DRY || (et.getHours() === DAILY_HOUR && state.day !== day && fund >= MIN_FUND)) {
  await send([
    `Wealth Fund: ${sui(fund)} SUI`,
    "",
    `Any round can pay all of it to one ticket holder: 1 in ${odds} every round. Tickets come from playing, and a tile starts at ${Number(min) / 1e9} SUI.`,
    "",
    `Play: ${SITE}`,
  ].join("\n"));
  state.day = day; save();
  log(`daily posted, fund ${sui(fund)}`);
}
