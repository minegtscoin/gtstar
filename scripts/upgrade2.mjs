// Upgrade the game package (contracts/gtstar) on mainnet. A dry run unless GO=1.
//   node scripts/upgrade2.mjs "<what changed, one sentence>" [key]
// The sentence is added to the on-chain proofs in deployments/mainnet.json with the upgrade transaction.
// `key` (optional) also saves the new package ID under that name: types a version introduces (events,
// dynamic field keys) keep that package ID for good, and the site and the keeper look them up by it.
// Signs with the active `sui client` address (the deployer, which holds the UpgradeCap).
// After a real upgrade: `node app/build.js mainnet`, `node app/keeper/build.js`, upload both.
import fs from "fs";
import path from "path";
import { execFileSync } from "child_process";
import { fileURLToPath } from "url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const SUI = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const GO = process.env.GO === "1";
const DEP = path.join(ROOT, "deployments", "mainnet.json");
const dep = JSON.parse(fs.readFileSync(DEP, "utf8"));
const [text, key] = process.argv.slice(2);
if (!text) throw new Error('usage: node scripts/upgrade2.mjs "<what changed>" [key]   (GO=1 to send)');
if (key && dep[key]) throw new Error(`${key} is already set in deployments/mainnet.json`);

const args = ["client", "--client.env", "mainnet", "upgrade", "--upgrade-capability", dep.upgradeCap, "--gas-budget", "500000000", "--json"];
if (!GO) args.push("--dry-run");
const out = execFileSync(SUI, args, { cwd: path.join(ROOT, "contracts", "gtstar"), maxBuffer: 64 << 20, stdio: ["ignore", "pipe", "ignore"] }).toString();
const d = JSON.parse(out.slice(out.indexOf("{")));
if (d.effects?.status?.status !== "success") throw new Error(`failed: ${JSON.stringify(d.effects?.status)}`);
const g = d.effects.gasUsed;
const cost = (Number(g.computationCost) + Number(g.storageCost) - Number(g.storageRebate)) / 1e9;
const pkg = d.objectChanges.find(c => c.type === "published").packageId;
console.log(`${GO ? "upgraded" : "dry run ok"}: ${cost.toFixed(4)} SUI${GO ? `, package ${pkg}, tx ${d.digest}` : ""}`);
if (GO) {
  dep.latest = pkg;
  if (key) dep[key] = pkg;
  dep.proof.push([text, d.digest]);
  fs.writeFileSync(DEP, JSON.stringify(dep, null, 2) + "\n");
}
