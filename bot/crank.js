// GTStar crank bot: settles each round as soon as it ends, and periodically
// sweeps accrued creator fees to DEV_ADDR. Signs with the local Sui CLI key.
//
//   node bot/crank.js mainnet
//
// Needs: Sui CLI with an address that holds SUI for gas on that network.
// Gas: ~0.002-0.004 SUI per settle, only for rounds that had deposits.
const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

const network = process.argv[2] || "mainnet";
const dep = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "deployments", `${network}.json`), "utf8"));
const SUI = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const GQL = `https://graphql.${network}.sui.io/graphql`;
const POLL_MS = 1500;
const SWEEP_EVERY_MS = 6 * 60 * 60 * 1000; // creator fees -> DEV_ADDR every 6h
const GAS = "10000000";

const log = (...a) => console.log(new Date().toISOString(), ...a);

function sui(args) {
  return new Promise((resolve, reject) => {
    execFile(SUI, ["client", "--client.env", network, ...args.slice(1)],{ maxBuffer: 16 << 20 }, (err, stdout, stderr) => {
      const out = String(stdout || "");
      const i = out.indexOf("{");
      if (i >= 0) { try { return resolve(JSON.parse(out.slice(i))); } catch {} }
      reject(new Error(String(stderr || out || err?.message).slice(0, 300)));
    });
  });
}
async function board() {
  const r = await fetch(GQL, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ query: `{object(address:"${dep.board}"){asMoveObject{contents{json}}}}` }),
  });
  const j = await r.json();
  if (j.errors) throw new Error(j.errors[0].message);
  return j.data.object.asMoveObject.contents.json;
}
const status = d => d?.effects?.status?.status === "success";

async function settle() {
  const d = await sui(["client", "call", "--package", dep.package, "--module", "game", "--function", "settle",
    "--args", dep.board, dep.treasury, dep.pool, "0x8", "0x6", "--gas-budget", GAS, "--json"]);
  const ev = (d.events || []).find(e => (e.type || "").includes("RoundSettled"));
  if (status(d)) log(`settled round ${ev?.parsedJson?.round_id} -> square ${ev?.parsedJson?.winning_square}  ${d.digest}`);
  else log("settle failed", d?.effects?.status?.error);
}
async function sweep() {
  const d = await sui(["client", "call", "--package", dep.package, "--module", "game", "--function", "withdraw_dev_fees",
    "--args", dep.board, "--gas-budget", GAS, "--json"]);
  log(status(d) ? `swept creator fees ${d.digest}` : `sweep failed ${d?.effects?.status?.error}`);
}

let lastSweep = 0, settling = false, lastErr = "";
async function tick() {
  if (settling) return;
  try {
    const b = await board();
    if (b.cur_started === true && Date.now() >= Number(b.cur_end_ms) + 500) {
      settling = true;
      await settle();
    } else if (Date.now() - lastSweep > SWEEP_EVERY_MS && Number(b.dev_fees || 0) > 0) {
      lastSweep = Date.now();
      await sweep();
    }
    lastErr = "";
  } catch (e) {
    const m = String(e.message || e);
    if (m !== lastErr) log("error:", m);
    lastErr = m;
  } finally {
    settling = false;
  }
}

log(`GTStar crank on ${network}, board ${dep.board}`);
setInterval(tick, POLL_MS);
tick();
