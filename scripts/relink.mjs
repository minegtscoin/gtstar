// Link the game to the newest version of the packages it uses: a dependency-only upgrade.
//   node scripts/relink.mjs          dry run: what would change, and whether the chain accepts it
//   GO=1 node scripts/relink.mjs     send it
// When: Cetus has moved to a new version and the market draw (game::settle_v3) aborts on Cetus's version
// check. Rounds are still drawn by the plain draw meanwhile; this brings the buyback and the liquidity
// add back.
// The game's UpgradeCap is restricted for good to dependency-only upgrades (sui::package::only_dep_upgrades),
// so this is all it can do. The modules sent are the game's own bytes, read from the chain and unchanged
// (the chain refuses anything else); only the versions of the packages the game is linked to differ. No
// compiler is involved, so it keeps working whatever happens to the Move toolchain.
// Signs with the active `sui client` address (the wallet holding the UpgradeCap).
import fs from "fs";
import os from "os";
import path from "path";
import { execFileSync } from "child_process";
import { fileURLToPath, pathToFileURL } from "url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const mod = sub => import(pathToFileURL(path.join(ROOT, "app", "node_modules", ...sub.split("/"))).href);
const { SuiGraphQLClient } = await mod("@mysten/sui/dist/graphql/index.mjs");
const { Transaction } = await mod("@mysten/sui/dist/transactions/index.mjs");
const { Ed25519Keypair } = await mod("@mysten/sui/dist/keypairs/ed25519/index.mjs");
const { fromBase64, fromHex, toHex } = await mod("@mysten/sui/dist/utils/index.mjs");
const { blake2b } = await mod("@noble/hashes/blake2.js").catch(() => mod("@noble/hashes/blake2b.js"));

const SUI = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const GO = process.env.GO === "1";
const DEP = path.join(ROOT, "deployments", "mainnet.json");
const dep = JSON.parse(fs.readFileSync(DEP, "utf8"));
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });
const gql = async query => { const r = await client.query({ query }); if (r.errors?.length) throw new Error(JSON.stringify(r.errors)); return r.data; };
// sui::package: the policy of a dependency-only upgrade.
const DEP_ONLY = 192;
// The game's modules in the order they depend on each other.
const ORDER = ["gts", "staking", "game"];

function signer() {
  const addr = execFileSync(SUI, ["client", "active-address"]).toString().trim();
  const keys = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"));
  for (const k of keys) {
    const kp = Ed25519Keypair.fromSecretKey(fromBase64(k).slice(1));
    if (kp.toSuiAddress() === addr) return kp;
  }
  throw new Error(`no ed25519 key for ${addr}`);
}

// The digest the chain checks an upgrade against: blake2b-256 over the sorted list of each module's
// blake2b-256 and each dependency ID (MovePackage::compute_digest_for_modules_and_deps).
function digest(modules, deps) {
  const parts = [...modules.map(m => blake2b(m, { dkLen: 32 })), ...deps.map(d => fromHex(d.slice(2).padStart(64, "0")))];
  parts.sort((a, b) => { for (let i = 0; i < 32; i++) if (a[i] !== b[i]) return a[i] - b[i]; return 0; });
  const h = blake2b.create({ dkLen: 32 });
  for (const p of parts) h.update(p);
  return h.digest();
}

const cap = (await gql(`{object(address:"${dep.upgradeCap}"){asMoveObject{contents{json}}}}`)).object.asMoveObject.contents.json;
const pkg = (await gql(`{package(address:"${cap.package}"){version linkage{originalId upgradedId version} modules(first:50){nodes{name bytes}}}}`)).package;
console.log(`game package ${cap.package} (version ${pkg.version}), UpgradeCap policy ${cap.policy}${+cap.policy === DEP_ONLY ? " (dependency-only)" : ""}`);

// The newest version of every package the game is linked to.
const deps = [];
let changed = 0;
for (const l of pkg.linkage) {
  let latest = { address: l.upgradedId, version: l.version };
  if (!/^0x0{60,}/.test(l.originalId)) {
    const v = (await gql(`{packageVersions(address:"${l.originalId}",last:1){nodes{address version}}}`)).packageVersions.nodes[0];
    if (v && +v.version > +l.version) latest = v;
  }
  if (latest.address !== l.upgradedId) { changed++; console.log(`  ${l.originalId}: version ${l.version} -> ${latest.version} (${latest.address})`); }
  deps.push(latest.address);
}
if (!changed) console.log("  every package the game uses is already at its newest version: nothing to link (the run below only checks that the upgrade path works)");

// A module on chain carries the package's own address (its first ID); an upgrade must send it with that
// address set to zero, as the compiler wrote it. It sits once in each module, in the address table.
const self = fromHex(dep.package.slice(2));
function zeroSelf(name, bytes) {
  let hits = 0;
  for (let i = 0; i + 32 <= bytes.length; i++) {
    let same = true;
    for (let k = 0; k < 32 && same; k++) same = bytes[i + k] === self[k];
    if (same) { bytes.fill(0, i, i + 32); hits++; i += 31; }
  }
  if (hits !== 1) throw new Error(`module ${name}: the package address appears ${hits} times, expected once`);
  return bytes;
}
const modules = pkg.modules.nodes
  .sort((a, b) => (ORDER.indexOf(a.name) + 1 || 99) - (ORDER.indexOf(b.name) + 1 || 99) || a.name.localeCompare(b.name))
  .map(m => zeroSelf(m.name, fromBase64(m.bytes)));
const dg = digest(modules, deps);
console.log(`digest ${toHex(dg)}`);

const kp = signer(), me = kp.toSuiAddress();
const tx = new Transaction();
tx.setSender(me);
tx.setGasBudget(Number(process.env.GAS_BUDGET || 400_000_000));
const capArg = tx.object(dep.upgradeCap);
const ticket = tx.moveCall({ target: "0x2::package::authorize_upgrade", arguments: [capArg, tx.pure.u8(DEP_ONLY), tx.pure.vector("u8", [...dg])] });
const receipt = tx.upgrade({ modules: modules.map(m => [...m]), dependencies: deps, package: cap.package, ticket });
tx.moveCall({ target: "0x2::package::commit_upgrade", arguments: [capArg, receipt] });

if (!GO || !changed) {
  const r = await client.simulateTransaction({ transaction: tx });
  const res = r.Transaction || r.FailedTransaction;
  console.log("dry run:", res.status.success ? "ok" : JSON.stringify(res.status));
  process.exit(res.status.success ? 0 : 1);
}
const out = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true, objectTypes: true } });
const r = out.Transaction || out.FailedTransaction;
if (!r.status.success) throw new Error(JSON.stringify(r.status));
await client.waitForTransaction({ digest: r.digest });
const after = (await gql(`{object(address:"${dep.upgradeCap}"){asMoveObject{contents{json}}}}`)).object.asMoveObject.contents.json;
console.log(`linked: tx ${r.digest}, package ${after.package}`);
dep.latest = after.package;
dep.proof.push(["Game linked to the newest version of the packages it uses (a dependency-only upgrade: the game's own code is unchanged)", r.digest]);
fs.writeFileSync(DEP, JSON.stringify(dep, null, 2) + "\n");
console.log("next: node app/build.js mainnet, node app/keeper/build.js, upload the keeper bundles, sh app/deploy.sh");
