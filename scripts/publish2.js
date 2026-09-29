// Publish the relaunch package (contracts/gts2: GTS token + game in one package) to mainnet.
//   node scripts/publish2.js            dry run: build, simulate, print the gas cost
//   GO=1 node scripts/publish2.js       publish for real
// The publisher keeps the UpgradeCap, the AdminCap and the CoinMetadata. The first game's
// deployments/mainnet.json is kept as deployments/mainnet-v1.json; the new one replaces it.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const SUI = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const ROOT = path.join(__dirname, "..");
const PKG = path.join(ROOT, "contracts", "gts2");
const DEV = "0xa19b2d37f95ca4c48efafb2cd01d0f97f33852457daa27cfba3de37fdec24d4b";
const KEEPER = "0x22390096d8def0638c92f86da60683e37d1a7f00b4b22fcb359952db300c3549";
const GAS = "300000000";
const GO = process.env.GO === "1";

const args = ["client", "--client.env", "mainnet", "publish", "--gas-budget", GAS, "--json"];
if (!GO) args.splice(4, 0, "--dry-run");
const out = execFileSync(SUI, args, { cwd: PKG, maxBuffer: 64 << 20, stdio: ["ignore", "pipe", "inherit"] }).toString();
const d = JSON.parse(out.slice(out.indexOf("{")));
if (d.effects?.status?.status !== "success") throw new Error(`publish failed: ${JSON.stringify(d.effects?.status)}`);
const g = d.effects.gasUsed;
const cost = (Number(g.computationCost) + Number(g.storageCost) - Number(g.storageRebate)) / 1e9;
console.log(`${GO ? "published" : "dry run ok"}: ${cost.toFixed(4)} SUI`);
if (!GO) process.exit(0);

const created = suffix => (d.objectChanges.find(c => c.type === "created" && (c.objectType || "").endsWith(suffix)) || {}).objectId;
const pkg = d.objectChanges.find(c => c.type === "published").packageId;
const dep = {
  network: "mainnet",
  relaunch: true,
  dev: DEV,
  keeper: KEEPER,
  publishedAt: new Date().toISOString(),
  package: pkg,
  latest: pkg,
  token: pkg,
  digest: d.digest,
  board: created("::game::Board"),
  treasury: created("::gts::Treasury"),
  coinMetadata: created(`::coin::CoinMetadata<${pkg}::gts::GTS>`),
  adminCap: created("::game::AdminCap"),
  upgradeCap: created("::package::UpgradeCap"),
  proof: [["GTS token and game published (1,000,000 cap, no premine)", d.digest]],
};
for (const k of ["board", "treasury", "coinMetadata", "adminCap", "upgradeCap"]) if (!dep[k]) throw new Error(`missing ${k}`);

const dir = path.join(ROOT, "deployments");
const cur = path.join(dir, "mainnet.json"), old = path.join(dir, "mainnet-v1.json");
if (!fs.existsSync(old)) fs.copyFileSync(cur, old);
fs.writeFileSync(cur, JSON.stringify(dep, null, 2) + "\n");
console.log(JSON.stringify(dep, null, 2));
