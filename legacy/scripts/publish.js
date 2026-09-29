// Launch GTStar on a network, end to end:
//   1. publish the token package (GTS, supply schedule, reserve)
//   2. publish the game package (game + staking), which depends on it
//   3. install: give the game its MinterCap and start the emission clock
//   4. lock the token: freeze its metadata and make the token package immutable
// The game package stays upgradeable (its UpgradeCap is kept by the publisher).
// Every object ID is recorded in deployments/<network>.json.
//
//   node scripts/publish.js <testnet|mainnet>
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const network = process.argv[2];
if (!["mainnet", "testnet"].includes(network)) throw new Error("usage: node scripts/publish.js <mainnet|testnet>");
const SUI = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const ROOT = path.join(__dirname, "..");
const DEV = "0xa19b2d37f95ca4c48efafb2cd01d0f97f33852457daa27cfba3de37fdec24d4b";
const GAS = "95000000";

function sui(args, cwd = ROOT) {
  const out = execFileSync(SUI, ["client", "--client.env", network, ...args, "--json"],
    { cwd, maxBuffer: 64 << 20, stdio: ["ignore", "pipe", "inherit"] }).toString();
  const d = JSON.parse(out.slice(out.indexOf("{")));
  if (d.effects?.status?.status !== "success") throw new Error(`${args[0]} failed: ${JSON.stringify(d.effects?.status)}`);
  return d;
}
const created = (d, suffix) => (d.objectChanges.find(c => c.type === "created" && (c.objectType || "").endsWith(suffix)) || {}).objectId;
const published = d => d.objectChanges.find(c => c.type === "published").packageId;

const dep = { network, dev: DEV, publishedAt: new Date().toISOString() };

console.log("1/4 publishing token package");
const t = sui(["publish", "--gas-budget", GAS], path.join(ROOT, "contracts", "token"));
dep.token = published(t);
dep.tokenDigest = t.digest;
dep.treasury = created(t, "::gts::Treasury");
dep.minterCap = created(t, "::gts::MinterCap");
dep.coinMetadata = created(t, "::coin::CoinMetadata<" + dep.token + "::gts::GTS>");
dep.tokenUpgradeCap = created(t, "::package::UpgradeCap");

console.log("2/4 publishing game package");
const g = sui(["publish", "--gas-budget", GAS], path.join(ROOT, "contracts", "game"));
dep.package = published(g);
dep.digest = g.digest;
dep.board = created(g, "::game::Board");
dep.pool = created(g, "::staking::StakePool");
dep.upgradeCap = created(g, "::package::UpgradeCap");

console.log("3/4 installing (starts the emission clock)");
dep.installDigest = sui(["call", "--package", dep.package, "--module", "game", "--function", "install",
  "--args", dep.board, dep.minterCap, dep.treasury, "0x6", "--gas-budget", "20000000"]).digest;

console.log("4/4 locking the token package");
dep.freezeDigest = sui(["call", "--package", "0x2", "--module", "transfer", "--function", "public_freeze_object",
  "--type-args", `0x2::coin::CoinMetadata<${dep.token}::gts::GTS>`, "--args", dep.coinMetadata, "--gas-budget", "10000000"]).digest;
dep.immutableDigest = sui(["call", "--package", "0x2", "--module", "package", "--function", "make_immutable",
  "--args", dep.tokenUpgradeCap, "--gas-budget", "10000000"]).digest;
delete dep.tokenUpgradeCap;
delete dep.minterCap; // now held inside the Board

fs.mkdirSync(path.join(ROOT, "deployments"), { recursive: true });
fs.writeFileSync(path.join(ROOT, "deployments", `${network}.json`), JSON.stringify(dep, null, 2));
console.log(JSON.stringify(dep, null, 2));
