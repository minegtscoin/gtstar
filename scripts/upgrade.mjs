// Upgrade the game package through the 48h timelock (contracts/timelock).
//   1. node scripts/upgrade.mjs announce   builds contracts/game and announces its digest on-chain
//   2. wait 48 hours (the site and anyone else can check the announced digest meanwhile)
//   3. node scripts/upgrade.mjs execute    rebuilds, authorizes, upgrades and commits in one transaction
// Bump VERSION in game.move before announcing. `execute` fails if the code changed since `announce`
// (the digest no longer matches). Signs with the active `sui client` address (the deployer).
import fs from "fs";
import os from "os";
import path from "path";
import { execFileSync } from "child_process";
import { fileURLToPath, pathToFileURL } from "url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
// The SDK is installed under app/ (ESM only), so resolve it from there.
const sdk = sub => import(pathToFileURL(path.join(ROOT, "app", "node_modules", "@mysten", "sui", "dist", sub)).href);
const { SuiGraphQLClient } = await sdk("graphql/index.mjs");
const { Transaction } = await sdk("transactions/index.mjs");
const { Ed25519Keypair } = await sdk("keypairs/ed25519/index.mjs");
const { fromBase64 } = await sdk("utils/index.mjs");

const mode = process.argv[2];
if (!["announce", "execute"].includes(mode)) throw new Error("usage: node scripts/upgrade.mjs <announce|execute>");
const SUI = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const DEP_FILE = path.join(ROOT, "deployments", "mainnet.json");
const dep = JSON.parse(fs.readFileSync(DEP_FILE, "utf8"));
const TL = `${dep.timelockPkg}::timelock`;
const COMPATIBLE = 0;

function signer() {
  const addr = execFileSync(SUI, ["client", "active-address"]).toString().trim();
  const keys = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"));
  for (const k of keys) {
    const kp = Ed25519Keypair.fromSecretKey(fromBase64(k).slice(1));
    if (kp.toSuiAddress() === addr) return kp;
  }
  throw new Error(`no ed25519 key for ${addr}`);
}

const build = () => JSON.parse(execFileSync(SUI, ["move", "build", "--dump-bytecode-as-base64"],
  { cwd: path.join(ROOT, "contracts", "game"), maxBuffer: 64 << 20, stdio: ["ignore", "pipe", "inherit"] }).toString());

const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });
const kp = signer();
const { modules, dependencies, digest } = build();
const tx = new Transaction();

if (mode === "announce") {
  tx.moveCall({ target: `${TL}::announce`, arguments: [tx.object(dep.timelock), tx.pure.u8(COMPATIBLE), tx.pure.vector("u8", digest), tx.object.clock()] });
} else {
  const ticket = tx.moveCall({ target: `${TL}::authorize`, arguments: [tx.object(dep.timelock), tx.object.clock()] });
  const receipt = tx.upgrade({ modules, dependencies, package: dep.latest, ticket });
  tx.moveCall({ target: `${TL}::commit`, arguments: [tx.object(dep.timelock), receipt] });
}

if (process.env.DRY) {
  tx.setSender(kp.toSuiAddress());
  const d = await client.simulateTransaction({ transaction: tx });
  console.log(`dry run ${mode}:`, JSON.stringify((d.Transaction || d.FailedTransaction).status));
  process.exit(0);
}

const out = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true, events: true } });
const r = out.Transaction || out.FailedTransaction;
if (!r.status.success) throw new Error(JSON.stringify(r.status));
await client.waitForTransaction({ digest: r.digest });
const event = name => r.events.find(e => e.eventType.endsWith(`::timelock::${name}`)).json;
console.log(`${mode}: ${r.digest}`);

if (mode === "announce") {
  console.log(`digest ${Buffer.from(digest).toString("hex")}, can run from ${new Date(Number(event("Announced").ready_ms)).toISOString()}`);
} else {
  const pkg = r.effects.changedObjects.find(c => c.outputState === "PackageWrite" && c.idOperation === "Created").objectId;
  const version = Number(event("Upgraded").version);
  dep.latest = pkg;
  dep.proof.push([`Game upgraded to v${version} through the timelock`, r.digest]);
  fs.writeFileSync(DEP_FILE, JSON.stringify(dep, null, 2) + "\n");
  const pub = path.join(ROOT, "contracts", "game", "Published.toml");
  fs.writeFileSync(pub, fs.readFileSync(pub, "utf8")
    .replace(/(\[published\.mainnet\][^[]*?published-at = ")0x[0-9a-f]+/, `$1${pkg}`)
    .replace(/(\[published\.mainnet\][^[]*?version = )\d+/, `$1${version}`));
  console.log(`new package ${pkg} (v${version}). Now update the keeper (app/keeper/keeper-config.json) and deploy the site.`);
}
