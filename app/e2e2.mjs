// One live round on mainnet with the deployer key, checked against the game's rules to the mist:
// deploy on five tiles, wait for the draw (by the keeper, or by this script if nobody draws), claim.
//   node app/e2e2.mjs            0.002 SUI on each of 5 tiles
//   PER=5000000 node app/e2e2.mjs
// Checks: creator 1%, buyback 3%, liquidity 2%, stakers 3%, the drawer 1%, the rest to the winners or the
// Wealth Fund; the GTS mined and the halving counter.
import fs from "fs";
import os from "os";
import path from "path";
import { execFileSync } from "child_process";
import { fileURLToPath } from "url";
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { fromBase64 } from "@mysten/sui/utils";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const dep = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments", "mainnet.json"), "utf8"));
const SUI = process.env.SUI_BIN || "C:/Users/ASD21/sui-cli/sui.exe";
const addr = execFileSync(SUI, ["client", "active-address"]).toString().trim();
const kp = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"))
  .map(k => Ed25519Keypair.fromSecretKey(fromBase64(k).slice(1))).find(k => k.toSuiAddress() === addr);
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });
const G = f => `${dep.latest}::game::${f}`;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const gql = async query => { const r = await client.query({ query }); if (r.errors?.length) throw new Error(JSON.stringify(r.errors)); return r.data; };
const PER = Number(process.env.PER || 2_000_000);
const CETUS_CFG = "0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f";
let failed = 0;
const check = (name, got, want) => { const ok = BigInt(got) === BigInt(want); if (!ok) failed++; console.log(`  ${ok ? "ok  " : "FAIL"} ${name}: ${got}${ok ? "" : ` (expected ${want})`}`); };

async function run(label, build, gas) {
  const tx = new Transaction();
  tx.setSender(addr);
  if (gas) tx.setGasBudget(gas);
  build(tx);
  const out = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true, events: true } });
  const r = out.Transaction || out.FailedTransaction;
  console.log(label, r.status.success ? "ok" : JSON.stringify(r.status), r.digest);
  if (!r.status.success) return null;
  await client.waitForTransaction({ digest: r.digest });
  return r;
}
// The Board with the dynamic fields the checks need.
async function state() {
  const pk = dep.package, key = (p, n) => `dynamicField(name:{type:"${p}::game::${n}",bcs:"AA=="}){value{... on MoveValue{json}}}`;
  const d = await gql(`{o:object(address:"${dep.board}"){asMoveObject{contents{json}}} b:address(address:"${dep.board}"){
    stake:${key(dep.stakePkg, "StakeKey")} liq:${key(dep.v11Pkg, "LiquidityKey")} sbps:${key(dep.stakePkg, "StakeBpsKey")} fbps:${key(dep.wfPkg, "FundBpsKey")}}}`);
  const b = d.o.asMoveObject.contents.json, n = x => BigInt(x ?? 0);
  return { round: Number(b.cur_id), started: b.cur_started, end: Number(b.cur_end_ms), pot: n(b.pot), dev: n(b.dev_fees), buyback: n(b.buyback), fund: n(b.motherlode),
    liq: n(d.b.liq?.value?.json), stakePaid: n(d.b.stake?.value?.json?.paid_total), stakeWeight: n(d.b.stake?.value?.json?.total_weight),
    stakeBps: n(d.b.sbps?.value?.json), fundBps: n(d.b.fbps?.value?.json), reward: n(b.reward), count: n(b.step_count), committed: n(b.committed), full: n(b.full_reward_deploy), version: b.version, _pk: pk };
}
const events = r => (r.events || []).map(e => ({ type: (e.eventType || e.type || "").split("::").pop(), json: e.json ?? e.parsedJson }));

const before = await state();
console.log(`board version ${before.version}, round ${before.round}, stakers ${before.stakeBps} bps, draw share ${before.fundBps} bps, reward ${before.reward}, mined in step ${before.count}`);
if (before.started) { console.log("a round is live: run again when it is over"); process.exit(1); }

const tiles = [0, 6, 12, 18, 24], amounts = Array(25).fill(0);
for (const t of tiles) amounts[t] = PER;
const total = BigInt(PER * tiles.length);
const dr = await run("deploy", tx => {
  const [m] = tx.moveCall({ target: G("new_miner") });
  const [pay] = tx.splitCoins(tx.gas, [Number(total)]);
  tx.moveCall({ target: G("deploy"), arguments: [tx.object(dep.board), m, pay, tx.pure.vector("u64", amounts), tx.object.clock()] });
  tx.transferObjects([m], addr);
});
if (!dr) process.exit(1);
const miner = (dr.effects?.changedObjects || []).find(o => o.idOperation === "Created" && o.outputState === "ObjectWrite" && o.outputOwner?.AddressOwner === addr)?.objectId
  || (await gql(`{address(address:"${addr}"){objects(filter:{type:"${dep.package}::game::Miner"},last:1){nodes{address}}}}`)).address.objects.nodes[0].address;
let b = await state();
const round = b.round;
console.log(`round ${round} ends in ${Math.round((b.end - Date.now()) / 1000)} s`);
await sleep(Math.max(0, b.end - Date.now()) + 1500);

// Give the keeper 12 seconds to draw; then draw here (the market draw, or the plain one if it fails).
let mine = null;
for (let i = 0; i < 12 && (b = await state()).round === round; i++) await sleep(1000);
if (b.round === round) {
  mine = await run("settle_v3 (market draw) by this script", tx => tx.moveCall({ target: G("settle_v3"), arguments: [tx.object(dep.board), tx.object(CETUS_CFG), tx.object(dep.market), tx.object(dep.treasury), tx.object.random(), tx.object.clock()] }), 60_000_000)
    || await run("settle_v2 (plain draw) by this script", tx => tx.moveCall({ target: G("settle_v2"), arguments: [tx.object(dep.board), tx.object.random(), tx.object.clock()] }), 30_000_000);
  if (!mine) process.exit(1);
}
// The draw's events, from its transaction.
let ev;
if (mine) ev = events(mine);
else {
  for (let i = 0; i < 20 && !ev; i++) {
    const d = await gql(`{events(filter:{type:"${dep.package}::game::RoundSettled"},last:3){nodes{transaction{digest effects{events{nodes{contents{type{repr} json}}}}} contents{json}}}}`);
    const n = d.events.nodes.find(x => Number(x.contents.json.round_id) === round);
    if (n) { console.log("drawn by the keeper:", n.transaction.digest); ev = n.transaction.effects.events.nodes.map(e => ({ type: e.contents.type.repr.split("::").pop(), json: e.contents.json })); }
    else await sleep(1500);
  }
}
const E = t => ev.find(e => e.type === t)?.json;
const s = E("RoundSettled"), after = await state();
const win = Number(s.winning_square), winners = BigInt(s.winners_total), losing = BigInt(s.losing_pot);
// Others may have joined the round: the shares go by the round's whole total.
const roundTotal = BigInt(s.total_deployed), myWin = tiles.includes(win) ? BigInt(PER) : 0n;
console.log(`winning tile ${win + 1}, on it ${winners}, losing pot ${losing}, ${s.players} player(s), ${roundTotal} deployed (${total} by this wallet)`);
const pct = (x, bps) => x * BigInt(bps) / 10_000n;
check("losing pot", losing, roundTotal - winners);
check("creator 1%", after.dev - before.dev, pct(losing, 100));
const drawPaid = BigInt(E("DrawPaid")?.amount ?? 0), share = pct(losing, Number(before.fundBps));
console.log(`  drawer was paid ${drawPaid} (the draw share is ${share})`);
if (drawPaid !== share && drawPaid !== share / 2n && drawPaid !== 0n) { failed++; console.log("  FAIL the drawer's pay is not all, half or none of the draw share"); }
const staked = pct(losing, Number(before.stakeBps));
check("stakers 3%", after.stakePaid - before.stakePaid, before.stakeWeight > 0n ? staked : 0n);
// The buyback and liquidity balances also move by what the draw's market step spent; the round's shares are in the events.
check("buyback 3% (RoundSettled)", s.buyback_fee, pct(losing, 300));
const toWinners = BigInt(s.winners_payout);
const rest = losing - pct(losing, 100) - pct(losing, 300) - pct(losing, 200) - staked - share;
check("winners' pot", toWinners, winners > 0n ? rest : 0n);
const fundIn = BigInt(E("MotherlodeUpdate").added), fundPaid = BigInt(E("MotherlodeUpdate").paid);
check("to the Wealth Fund", fundIn, (winners > 0n ? 0n : rest) + (share - drawPaid) + (before.stakeWeight > 0n ? 0n : staked));
if (fundPaid > 0n) console.log(`  the Wealth Fund paid out ${fundPaid} in this round`);
const reward = roundTotal >= before.full ? before.reward : before.reward * roundTotal / before.full;
check("GTS mined by the round", s.round_reward, reward);
check("GTS mined in the step", after.count, before.count + reward);
check("GTS mined in all", after.committed, before.committed + reward);
check("reward after the round", after.reward, before.reward);

const cr = await run("claim", tx => {
  const [c] = tx.moveCall({ target: G("claim_sui_v3"), arguments: [tx.object(dep.board), tx.object(miner), tx.object(dep.treasury), tx.object.clock()] });
  tx.transferObjects([c], addr);
});
if (!cr) process.exit(1);
const c = events(cr).find(e => e.type === "Claimed").json;
check("claimed GTS", c.gts, reward * total / roundTotal);
check("claimed SUI", c.sui, myWin > 0n ? myWin + toWinners * myWin / winners : 0n);
const end = await state();
// With other players in the round, what they have not claimed yet is still in the pot.
if (Number(s.players) === 1) check("pot left in the game", end.pot, before.pot);
else console.log(`  pot in the game ${end.pot} (was ${before.pot}; other players' winnings wait there for their claim)`);
console.log(failed ? `${failed} CHECK(S) FAILED` : "all checks passed");
process.exit(failed ? 1 : 0);
