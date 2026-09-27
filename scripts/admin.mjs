// Game settings through the AdminCap (game v7+). Changes apply at once, only inside the contract's bounds.
//   node scripts/admin.mjs show                      current settings
//   node scripts/admin.mjs take                      take the AdminCap (once, deployer only)
//   node scripts/admin.mjs set odds=500 fund=1950    change some settings, keep the rest
// Keys: odds (Wealth Fund 1 in N), fund (fund share of a no-winner pot, bps), reserve (reserve fee, bps),
// creator (bps, max 100), min (min deposit per tile, MIST), round (ms), freeze (ms), paused (true/false).
// Signs with the active `sui client` address (the deployer). DRY=1 simulates.
import fs from "fs";
import os from "os";
import path from "path";
import { execFileSync } from "child_process";
import { fileURLToPath, pathToFileURL } from "url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const sdk = sub => import(pathToFileURL(path.join(ROOT, "app", "node_modules", "@mysten", "sui", "dist", sub)).href);
const { SuiGraphQLClient } = await sdk("graphql/index.mjs");
const { Transaction } = await sdk("transactions/index.mjs");
const { Ed25519Keypair } = await sdk("keypairs/ed25519/index.mjs");
const { fromBase64 } = await sdk("utils/index.mjs");

const SUI = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const dep = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments", "mainnet.json"), "utf8"));
if (!dep.fairPkg) throw new Error("game v7 is not live yet (no fairPkg in deployments/mainnet.json)");
const G = `${dep.latest}::game`, TYPES = `${dep.fairPkg}::game`;
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });
const gql = async query => (await client.query({ query })).data;

function signer() {
  const addr = execFileSync(SUI, ["client", "active-address"]).toString().trim();
  const keys = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"));
  for (const k of keys) {
    const kp = Ed25519Keypair.fromSecretKey(fromBase64(k).slice(1));
    if (kp.toSuiAddress() === addr) return kp;
  }
  throw new Error(`no ed25519 key for ${addr}`);
}

async function current() {
  const d = await gql(`{b:object(address:"${dep.board}"){asMoveObject{contents{json}}
    dynamicField(name:{type:"${TYPES}::ParamsKey",bcs:"AA=="}){value{... on MoveValue{json}}}}}`);
  const b = d.b.asMoveObject.contents.json, p = d.b.dynamicField?.value?.json || { ml_odds: 500, ml_share_bps: 1950, paused: false };
  return { odds: +p.ml_odds, fund: +p.ml_share_bps, reserve: +b.vault_bps, creator: +b.dev_bps, min: +b.min_deploy, round: +b.round_ms, freeze: +b.freeze_ms, paused: p.paused === true };
}

async function run(build) {
  const kp = signer(), tx = new Transaction();
  await build(tx, kp.toSuiAddress());
  if (process.env.DRY) {
    tx.setSender(kp.toSuiAddress());
    const d = await client.simulateTransaction({ transaction: tx });
    return console.log("dry run:", JSON.stringify((d.Transaction || d.FailedTransaction).status));
  }
  const out = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true } });
  const r = out.Transaction || out.FailedTransaction;
  if (!r.status.success) throw new Error(JSON.stringify(r.status));
  await client.waitForTransaction({ digest: r.digest });
  console.log("tx", r.digest);
}

const [mode, ...args] = process.argv.slice(2);
if (mode === "show") console.log(await current());
else if (mode === "take") await run(tx => { tx.moveCall({ target: `${G}::take_admin`, arguments: [tx.object(dep.board)] }); });
else if (mode === "set") {
  const s = await current();
  for (const a of args) {
    const [k, v] = a.split("=");
    if (!(k in s)) throw new Error(`unknown key ${k}`);
    s[k] = k === "paused" ? v === "true" : Number(v);
  }
  await run(async (tx, me) => {
    const d = await gql(`{address(address:"${me}"){objects(filter:{type:"${TYPES}::AdminCap"},first:1){nodes{address}}}}`);
    const cap = d.address?.objects?.nodes?.[0]?.address;
    if (!cap) throw new Error("no AdminCap in this wallet: run `take` first");
    tx.moveCall({ target: `${G}::set_params`, arguments: [tx.object(cap), tx.object(dep.board),
      tx.pure.u64(s.odds), tx.pure.u64(s.fund), tx.pure.u64(s.reserve), tx.pure.u64(s.creator),
      tx.pure.u64(s.min), tx.pure.u64(s.round), tx.pure.u64(s.freeze), tx.pure.bool(s.paused)] });
  });
  console.log(await current());
} else throw new Error("usage: node scripts/admin.mjs <show|take|set key=value ...>");
