// Lock the game for good, in one transaction. It cannot be undone.
//   node scripts/lock.mjs          dry run: the settings that would be frozen, and a simulation
//   GO=1 node scripts/lock.mjs     send it
// The transaction does three things:
//   1. game::renounce destroys the AdminCap: every setting stays as it is, and the game can never be paused.
//   2. sui::package::only_dep_upgrades restricts the UpgradeCap to dependency-only upgrades: the game's own
//      code can never change again; it can only be linked to a newer version of a package it uses
//      (scripts/relink.mjs, for a Cetus upgrade).
//   3. The GTS CoinMetadata (name, symbol, icon, description) is frozen.
// Signs with the active `sui client` address (the deployer, which holds the three objects).
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
const GO = process.env.GO === "1";
const DEP = path.join(ROOT, "deployments", "mainnet.json");
const dep = JSON.parse(fs.readFileSync(DEP, "utf8"));
if (dep.locked) throw new Error(`already locked: ${dep.locked}`);
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });
const gql = async query => { const r = await client.query({ query }); if (r.errors?.length) throw new Error(JSON.stringify(r.errors)); return r.data; };

const addr = execFileSync(SUI, ["client", "active-address"]).toString().trim();
const kp = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"))
  .map(k => Ed25519Keypair.fromSecretKey(fromBase64(k).slice(1))).find(k => k.toSuiAddress() === addr);
if (!kp) throw new Error(`no ed25519 key for ${addr}`);

// What is frozen: the settings as they are now. They must be the final ones.
const key = (p, n) => `dynamicField(name:{type:"${p}::game::${n}",bcs:"AA=="}){value{... on MoveValue{json}}}`;
const d = await gql(`{o:object(address:"${dep.board}"){asMoveObject{contents{json}}} b:address(address:"${dep.board}"){
  sbps:${key(dep.stakePkg, "StakeBpsKey")} fbps:${key(dep.wfPkg, "FundBpsKey")} tiles:${key(dep.v10Pkg, "MaxTilesKey")}}
  cap:object(address:"${dep.upgradeCap}"){asMoveObject{contents{json}}}}`);
const b = d.o.asMoveObject.contents.json;
const now = {
  version: +b.version, stakers_bps: +d.b.sbps.value.json, draw_bps: +d.b.fbps.value.json, max_tiles: +d.b.tiles.value.json,
  wealth_fund_odds: +b.ml_odds, min_deploy: +b.min_deploy, round_ms: +b.round_ms, freeze_ms: +b.freeze_ms,
  withdraw_fee_bps: +b.refine_fee_bps, paused: b.paused === true,
  reward: +b.reward, halving_rounds: +b.step_rounds, cut_ppm: +b.decay_ppm, full_reward_deploy: +b.full_reward_deploy,
};
const want = {
  version: 22, stakers_bps: 300, draw_bps: 100, max_tiles: 5, wealth_fund_odds: 250, min_deploy: 500_000, round_ms: 60_000, freeze_ms: 5_000,
  withdraw_fee_bps: 1_000, paused: false, reward: 1_000_000_000, halving_rounds: 15_658, cut_ppm: 500_000, full_reward_deploy: 7_000_000_000,
};
console.log("settings to freeze:", now);
for (const k of Object.keys(want)) if (now[k] !== want[k]) throw new Error(`${k} is ${now[k]}, the final value is ${want[k]}: fix it before locking`);
const cap = d.cap.asMoveObject.contents.json;
if (cap.package !== dep.latest) throw new Error(`the UpgradeCap points at ${cap.package}, deployments say ${dep.latest}`);
console.log(`UpgradeCap: package ${cap.package}, policy ${cap.policy} (0 = any compatible upgrade; 192 = dependency-only)`);

const tx = new Transaction();
tx.setSender(addr);
tx.moveCall({ target: `${dep.latest}::game::renounce`, arguments: [tx.object(dep.adminCap), tx.object(dep.board)] });
tx.moveCall({ target: "0x2::package::only_dep_upgrades", arguments: [tx.object(dep.upgradeCap)] });
tx.moveCall({ target: "0x2::transfer::public_freeze_object", typeArguments: [`0x2::coin::CoinMetadata<${dep.token}::gts::GTS>`], arguments: [tx.object(dep.coinMetadata)] });

const sim = await client.simulateTransaction({ transaction: tx });
const s = (sim.Transaction || sim.FailedTransaction).status;
console.log("simulation:", s.success ? "ok" : JSON.stringify(s));
if (!s.success) process.exit(1);
if (!GO) { console.log("dry run only. GO=1 sends it, and it cannot be undone."); process.exit(0); }

const out = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true, events: true } });
const r = out.Transaction || out.FailedTransaction;
if (!r.status.success) throw new Error(JSON.stringify(r.status));
await client.waitForTransaction({ digest: r.digest });
console.log("locked:", r.digest);
dep.locked = r.digest;
const line = "Game locked for good: the settings key (AdminCap) destroyed, the upgrade key restricted to dependency-only upgrades (the game's own code can never change), and the GTS coin metadata frozen";
dep.proof.push([line, r.digest]);
(dep.siteProof ||= []).push([line, r.digest]);
fs.writeFileSync(DEP, JSON.stringify(dep, null, 2) + "\n");
