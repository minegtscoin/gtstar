// End-to-end check of the dApp's transaction shapes on a live network,
// signed with the local Sui CLI key (same PTBs the browser builds).
//   node e2e.mjs testnet
import fs from "fs";
import os from "os";
import path from "path";
import { Transaction } from "@mysten/sui/transactions";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { SuiGraphQLClient } from "@mysten/sui/graphql";

const network = process.argv[2] || "testnet";
const dep = JSON.parse(fs.readFileSync(`../deployments/${network}.json`, "utf8"));
const keystore = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"));
const kp = keystore.map(k => { const raw = Buffer.from(k, "base64"); return raw[0] === 0 ? Ed25519Keypair.fromSecretKey(raw.subarray(1)) : null; })
  .find(k => k && k.toSuiAddress() === "0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e");
const me = kp.toSuiAddress();
const client = new SuiGraphQLClient({ url: `https://graphql.${network}.sui.io/graphql`, network });
const T = f => `${dep.package}::${f}`;
const TK = f => `${dep.token}::${f}`;

async function q(query) { const r = await client.query({ query }); if (r.errors) throw new Error(JSON.stringify(r.errors)); return r.data; }
async function objs(type) {
  const d = await q(`{address(address:"${me}"){objects(filter:{type:"${type}"},first:50){nodes{address contents{json}}}}}`);
  return d.address.objects.nodes.map(n => ({ id: n.address, f: n.contents.json }));
}
async function board() { const d = await q(`{object(address:"${dep.board}"){asMoveObject{contents{json}}}}`); return d.object.asMoveObject.contents.json; }
async function run(name, build) {
  const tx = new Transaction(); tx.setSender(me); await build(tx);
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer: kp, include: { effects: true } });
  const res = r.Transaction || r.FailedTransaction;
  const ok = res.status.success;
  console.log(ok ? "PASS" : "FAIL", name, res.digest, ok ? "" : JSON.stringify(res.status.error));
  await client.waitForTransaction({ digest: res.digest });
  if (!ok) process.exit(1);
  return res;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

// 1) first deploy creates the miner in the same PTB
const per = 10_000_000, amounts = Array(25).fill(0); amounts[3] = per;
await run("deploy+new_miner", tx => {
  const [m] = tx.moveCall({ target: T("game::new_miner") });
  const [pay] = tx.splitCoins(tx.gas, [per]);
  tx.moveCall({ target: T("game::deploy"), arguments: [tx.object(dep.board), m, pay, tx.pure.vector("u64", amounts), tx.object.clock()] });
  tx.transferObjects([m], me);
});
let b = await board();
console.log("round", b.cur_id, "ends in", Math.round((Number(b.cur_end_ms) - Date.now()) / 1000), "s");
const firstRound = Number(b.cur_id);

// 2) wait for the crank bot to settle
for (let i = 0; i < 60; i++) { await sleep(3000); b = await board(); if (Number(b.cur_id) > firstRound) break; }
if (Number(b.cur_id) <= firstRound) { console.log("FAIL crank did not settle"); process.exit(1); }
console.log("PASS crank settled round", firstRound);

// 3) next deploy auto-claims the settled round in the same PTB
const miner = (await objs(T("game::Miner"))).find(m => Number(m.f.round_id) === firstRound);
await run("claim+deploy", tx => {
  const mArg = tx.object(miner.id);
  const [g, s] = tx.moveCall({ target: T("game::claim"), arguments: [tx.object(dep.board), mArg, tx.object(dep.treasury), tx.object.clock()] });
  tx.transferObjects([g, s], me);
  const a = Array(25).fill(0); a[0] = per;
  const [pay] = tx.splitCoins(tx.gas, [per]);
  tx.moveCall({ target: T("game::deploy"), arguments: [tx.object(dep.board), mArg, pay, tx.pure.vector("u64", a), tx.object.clock()] });
});

// 4) stake + redeem using merged GTS coins
const coins = (await objs(`0x2::coin::Coin<${TK("gts::GTS")}>`)).map(c => ({ id: c.id, bal: Number(c.f.balance) }));
const total = coins.reduce((a, c) => a + c.bal, 0);
console.log("GTS balance", total / 1e9);
await run("stake (no lock, new position)", tx => {
  const p = tx.object(coins[0].id);
  if (coins.length > 1) tx.mergeCoins(p, coins.slice(1).map(c => tx.object(c.id)));
  const [c] = tx.splitCoins(p, [Math.floor(total / 2)]);
  const [pos] = tx.moveCall({ target: T("staking::new_position") });
  tx.moveCall({ target: T("staking::stake"), arguments: [tx.object(dep.pool), pos, c, tx.object.clock()] });
  tx.transferObjects([pos], me);
});
const coins2 = (await objs(`0x2::coin::Coin<${TK("gts::GTS")}>`)).map(c => ({ id: c.id, bal: Number(c.f.balance) }));
await run("redeem", tx => {
  const [c] = tx.splitCoins(tx.object(coins2[0].id), [Math.floor(coins2[0].bal / 10)]);
  const [out] = tx.moveCall({ target: TK("gts::redeem"), arguments: [tx.object(dep.treasury), c] });
  tx.transferObjects([out], me);
});
const pos = (await objs(T("staking::StakePosition")))[0];
await run("claim staking rewards", tx => {
  const [c] = tx.moveCall({ target: T("staking::claim_rewards"), arguments: [tx.object(dep.pool), tx.object(pos.id), tx.object.clock()] });
  tx.transferObjects([c], me);
});
await run("withdraw half the stake (no lock)", tx => {
  const [g] = tx.moveCall({ target: T("staking::unstake"), arguments: [tx.object(dep.pool), tx.object(pos.id), tx.pure.u64(Math.floor(Number(pos.f.amount) / 2)), tx.object.clock()] });
  tx.transferObjects([g], me);
});
console.log("ALL PASS");
