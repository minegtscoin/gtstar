// Relaunch game settings through the AdminCap. Changes apply at once, only inside the contract's bounds.
//   node scripts/admin2.mjs show                           current settings and emission
//   node scripts/admin2.mjs set odds=1000 reserve=400      change some settings, keep the rest
//   node scripts/admin2.mjs emission reward=1 step=15658   change the emission, keep the rest
//   node scripts/admin2.mjs staking 300                    stakers' share of the losing pot, bps (creates the pool once)
//   node scripts/admin2.mjs buyback-to-reserve             move the buyback SUI held on the Board into the reserve
// set keys: odds (Wealth Fund 1 in N), fund (fund share of a no-winner pot, bps), reserve (bps),
//   buyback (bps), refine (withdraw fee, bps), min (min deposit per tile, SUI), round (s), freeze (s), paused (true/false).
// emission keys: reward (GTS per round), step (rounds per step), decay (cut per step, %), count (rounds into the step),
//   full (SUI in a round for the full reward).
// Signs with the active `sui client` address (the deployer, which holds the AdminCap). DRY=1 simulates.
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
if (!dep.relaunch) throw new Error("deployments/mainnet.json is not the relaunch game");
const G = `${dep.latest}::game`;
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });
const gql = async query => (await client.query({ query })).data;
const MIST = 1e9;

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
  const d = await gql(`{b:object(address:"${dep.board}"){asMoveObject{contents{json}}}}`);
  const b = d.b.asMoveObject.contents.json;
  return {
    params: { odds: +b.ml_odds, fund: +b.ml_share_bps, reserve: +b.vault_bps, buyback: +b.buyback_bps, refine: +b.refine_fee_bps,
      min: +b.min_deploy / MIST, round: +b.round_ms / 1000, freeze: +b.freeze_ms / 1000, paused: b.paused === true },
    emission: { reward: +b.reward / MIST, step: +b.step_rounds, decay: +b.decay_ppm / 1e4, count: +b.step_count, full: +b.full_reward_deploy / MIST },
    state: { round: +b.cur_id, mined: +b.committed / MIST, fund: +b.motherlode / MIST, buybackSui: +b.buyback / MIST },
  };
}

async function run(build) {
  const kp = signer(), tx = new Transaction();
  const me = kp.toSuiAddress();
  const d = await gql(`{address(address:"${me}"){objects(filter:{type:"${dep.package}::game::AdminCap"},first:1){nodes{address}}}}`);
  const cap = d.address?.objects?.nodes?.[0]?.address;
  if (!cap) throw new Error("no AdminCap in this wallet");
  build(tx, tx.object(cap));
  if (process.env.DRY) {
    tx.setSender(me);
    const r = await client.simulateTransaction({ transaction: tx });
    return console.log("dry run:", JSON.stringify((r.Transaction || r.FailedTransaction).status));
  }
  const out = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true } });
  const r = out.Transaction || out.FailedTransaction;
  if (!r.status.success) throw new Error(JSON.stringify(r.status));
  await client.waitForTransaction({ digest: r.digest });
  console.log("tx", r.digest);
}

function apply(obj, args) {
  for (const a of args) {
    const [k, v] = a.split("=");
    if (!(k in obj)) throw new Error(`unknown key ${k} (use one of: ${Object.keys(obj).join(", ")})`);
    obj[k] = k === "paused" ? v === "true" : Number(v);
  }
}

const [mode, ...args] = process.argv.slice(2);
if (mode === "staking") {
  const bps = Number(args[0]);
  if (!(bps >= 0)) throw new Error("usage: staking <bps>");
  await run((tx, cap) => tx.moveCall({ target: `${G}::set_staking`, arguments: [cap, tx.object(dep.board), tx.pure.u64(bps)] }));
  console.log(await current());
  process.exit(0);
}
if (mode === "buyback-to-reserve") {
  await run((tx, cap) => {
    const [c] = tx.moveCall({ target: `${G}::take_buyback`, arguments: [cap, tx.object(dep.board)] });
    const bal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: ["0x2::sui::SUI"], arguments: [c] });
    tx.moveCall({ target: `${dep.latest}::gts::vault_add`, arguments: [tx.object(dep.treasury), bal] });
  });
  console.log(await current());
  process.exit(0);
}
if (mode === "show") console.log(await current());
else if (mode === "set") {
  const s = (await current()).params;
  apply(s, args);
  await run((tx, cap) => tx.moveCall({ target: `${G}::set_params`, arguments: [cap, tx.object(dep.board),
    tx.pure.u64(s.odds), tx.pure.u64(s.fund), tx.pure.u64(s.reserve), tx.pure.u64(s.buyback), tx.pure.u64(s.refine),
    tx.pure.u64(Math.round(s.min * MIST)), tx.pure.u64(Math.round(s.round * 1000)), tx.pure.u64(Math.round(s.freeze * 1000)), tx.pure.bool(s.paused)] }));
  console.log(await current());
} else if (mode === "emission") {
  const e = (await current()).emission;
  apply(e, args);
  await run((tx, cap) => tx.moveCall({ target: `${G}::set_emission`, arguments: [cap, tx.object(dep.board),
    tx.pure.u64(Math.round(e.reward * MIST)), tx.pure.u64(e.step), tx.pure.u64(Math.round(e.decay * 1e4)), tx.pure.u64(e.count),
    tx.pure.u64(Math.round(e.full * MIST))] }));
  console.log(await current());
} else throw new Error("usage: node scripts/admin2.mjs <show|set key=value ...|emission key=value ...>");
