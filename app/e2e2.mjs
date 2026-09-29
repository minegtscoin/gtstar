// One live round on the relaunch game with the deployer key: deploy on two tiles, settle, claim, withdraw GTS.
//   node app/e2e2.mjs
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
const SUI = "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const addr = execFileSync(SUI, ["client", "active-address"]).toString().trim();
const kp = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"))
  .map(k => Ed25519Keypair.fromSecretKey(fromBase64(k).slice(1))).find(k => k.toSuiAddress() === addr);
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });
const G = f => `${dep.package}::game::${f}`;
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function run(label, build, gas) {
  const tx = new Transaction();
  tx.setSender(addr);
  if (gas) tx.setGasBudget(gas);
  build(tx);
  const out = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true, events: true } });
  const r = out.Transaction || out.FailedTransaction;
  console.log(label, r.status.success ? "ok" : JSON.stringify(r.status), r.digest);
  if (!r.status.success) process.exit(1);
  await client.waitForTransaction({ digest: r.digest });
  return r;
}
const board = async () => (await client.query({ query: `{object(address:"${dep.board}"){asMoveObject{contents{json}}}}` })).data.object.asMoveObject.contents.json;
const minerId = async () => (await client.query({ query: `{address(address:"${addr}"){objects(filter:{type:"${G("Miner")}"},first:1){nodes{address}}}}` })).data.address.objects.nodes[0]?.address;

const amounts = Array(25).fill(0); amounts[0] = 10_000_000; amounts[12] = 10_000_000;
await run("deploy", tx => {
  const [m] = tx.moveCall({ target: G("new_miner") });
  const [pay] = tx.splitCoins(tx.gas, [20_000_000]);
  tx.moveCall({ target: G("deploy"), arguments: [tx.object(dep.board), m, pay, tx.pure.vector("u64", amounts), tx.object.clock()] });
  tx.transferObjects([m], addr);
});
let b = await board();
console.log("round", b.cur_id, "ends in", Math.round((+b.cur_end_ms - Date.now()) / 1000), "s");
await sleep(Math.max(0, +b.cur_end_ms - Date.now()) + 2000);
await run("settle", tx => tx.moveCall({ target: G("settle"), arguments: [tx.object(dep.board), tx.object(dep.treasury), tx.object.random(), tx.object.clock()] }), 50_000_000);
b = await board();
console.log("after settle: round", b.cur_id, "committed", +b.committed / 1e9, "GTS, fund", +b.motherlode / 1e9, "SUI");
const mid = await minerId();
await run("claim", tx => {
  const [s] = tx.moveCall({ target: G("claim_sui"), arguments: [tx.object(dep.board), tx.object(mid), tx.object(dep.treasury)] });
  tx.transferObjects([s], addr);
});
b = await board();
console.log("unrefined total", +b.unrefined_total / 1e9, "GTS");
await run("withdraw", tx => {
  const [g] = tx.moveCall({ target: G("withdraw_gts"), arguments: [tx.object(dep.board), tx.object(dep.treasury)] });
  tx.transferObjects([g], addr);
});
const t = (await client.query({ query: `{object(address:"${dep.treasury}"){asMoveObject{contents{json}}}}` })).data.object.asMoveObject.contents.json;
console.log("treasury: minted", +t.minted / 1e9, "supply", +t.cap.total_supply.value / 1e9, "reserve", +t.vault / 1e9, "SUI");
