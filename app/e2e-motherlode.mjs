// Motherlode check against a live network: one round on one tile with the deployer key,
// settle with the latest package, then read the Motherlode field and events and claim.
//   node app/e2e-motherlode.mjs testnet
import fs from "fs";
import os from "os";
import path from "path";
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const net = process.argv[2] || "testnet";
const dep = JSON.parse(fs.readFileSync(new URL(`../deployments/${net}.json`, import.meta.url)));
const PKG = dep.latest, ORIG = dep.package, ML = dep.motherlodePkg || dep.latest;
const DEPLOYER = "0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e";
const keys = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui/sui_config/sui.keystore"), "utf8"));
const signer = keys.map(k => Buffer.from(k, "base64")).filter(b => b[0] === 0)
  .map(b => Ed25519Keypair.fromSecretKey(b.subarray(1))).find(k => k.toSuiAddress() === DEPLOYER);
const client = new SuiGraphQLClient({ url: `https://graphql.${net}.sui.io/graphql`, network: net });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const q = async query => { const r = await client.query({ query }); if (r.errors) throw new Error(JSON.stringify(r.errors)); return r.data; };

async function exec(build) {
  const tx = new Transaction(); tx.setSender(DEPLOYER); build(tx);
  const r = await client.signAndExecuteTransaction({ transaction: tx, signer });
  const res = r.Transaction || r.FailedTransaction;
  await client.waitForTransaction({ digest: res.digest });
  if (!res.status.success) throw new Error(`tx failed ${res.digest} ${JSON.stringify(res.status)}`);
  return res.digest;
}
const board = async () => (await q(`{object(address:"${dep.board}"){asMoveObject{contents{json}}}}`)).object.asMoveObject.contents.json;
async function motherlode() {
  const d = await q(`{object(address:"${dep.board}"){dynamicField(name:{type:"${ML}::game::MotherlodeKey",bcs:"AA=="}){value{... on MoveValue{json}}}}}`);
  return d.object.dynamicField?.value?.json;
}
async function miner() {
  const d = await q(`{address(address:"${DEPLOYER}"){objects(filter:{type:"${ORIG}::game::Miner"},first:5){nodes{address contents{json}}}}}`);
  return d.address.objects.nodes[0];
}

const b0 = await board();
console.log("round", b0.cur_id, "started", b0.cur_started, "motherlode before", JSON.stringify(await motherlode()));
let m = await miner();
const tile = Number(process.argv[3] || 0);
await exec(tx => {
  let mo;
  if (m) {
    mo = tx.object(m.address);
    if (Number(m.contents.json.round_id) !== 0) {
      const [g, s] = tx.moveCall({ target: `${PKG}::game::claim`, arguments: [tx.object(dep.board), mo, tx.object(dep.treasury), tx.object.clock()] });
      tx.transferObjects([g, s], DEPLOYER);
    }
  } else [mo] = tx.moveCall({ target: `${PKG}::game::new_miner` });
  const [pay] = tx.splitCoins(tx.gas, [10_000_000]);
  tx.moveCall({ target: `${PKG}::game::deploy`, arguments: [tx.object(dep.board), mo, pay, tx.pure.vector("u64", Array.from({ length: 25 }, (_, i) => (i === tile ? 10_000_000 : 0))), tx.object.clock()] });
  if (!m) tx.transferObjects([mo], DEPLOYER);
});
const b1 = await board();
console.log("deployed on tile", tile, "round", b1.cur_id, "ends", new Date(Number(b1.cur_end_ms)).toISOString());
await sleep(Math.max(0, Number(b1.cur_end_ms) - Date.now() + 2500));
const dg = await exec(tx => tx.moveCall({ target: `${PKG}::game::settle`, arguments: [tx.object(dep.board), tx.object(dep.treasury), tx.object(dep.pool), tx.object.random(), tx.object.clock()] }));
console.log("settled", dg);
const ev = await q(`{transaction(digest:"${dg}"){effects{events{nodes{contents{type{repr} json}}}}}}`);
for (const e of ev.transaction.effects.events.nodes) console.log(e.contents.type.repr.split("::").slice(1).join("::"), JSON.stringify(e.contents.json));
console.log("motherlode after", JSON.stringify(await motherlode()));
m = await miner();
const cd = await exec(tx => {
  const [g, s] = tx.moveCall({ target: `${PKG}::game::claim`, arguments: [tx.object(dep.board), tx.object(m.address), tx.object(dep.treasury), tx.object.clock()] });
  tx.transferObjects([g, s], DEPLOYER);
});
console.log("claimed", cd);
