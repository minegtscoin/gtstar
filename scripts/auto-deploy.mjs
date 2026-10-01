// Deploy Auto Mine to mainnet, one step at a time. Every step is a dry run unless GO=1.
//   node scripts/auto-deploy.mjs vault       publish contracts/auto_vault (the players' balances)
//   node scripts/auto-deploy.mjs immutable   destroy the vault's upgrade key: its code can never change
//   node scripts/auto-deploy.mjs upgrade     upgrade the game (contracts/gtstar) with auto_run
//   node scripts/auto-deploy.mjs install     hand the vault's only PullCap to the game, for good
//   node scripts/auto-deploy.mjs status      what is done so far
// Signs with the active `sui client` address (the deployer: UpgradeCap and AdminCap). Each step writes
// what it made to deployments/mainnet.json; after the last one run `node app/build.js mainnet`,
// then `node app/keeper/build.js`.
import fs from "fs";
import path from "path";
import { execFileSync } from "child_process";
import { fileURLToPath } from "url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const SUI = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const GO = process.env.GO === "1";
const DEP = path.join(ROOT, "deployments", "mainnet.json");
const dep = JSON.parse(fs.readFileSync(DEP, "utf8"));
const save = () => fs.writeFileSync(DEP, JSON.stringify(dep, null, 2) + "\n");

function sui(args, cwd = ROOT) {
  const full = ["client", "--client.env", "mainnet", ...args, "--json"];
  if (!GO) full.push("--dry-run");
  const out = execFileSync(SUI, full, { cwd, maxBuffer: 64 << 20, stdio: ["ignore", "pipe", "inherit"] }).toString();
  const d = JSON.parse(out.slice(out.indexOf("{")));
  if (d.effects?.status?.status !== "success") throw new Error(`failed: ${JSON.stringify(d.effects?.status)}`);
  const g = d.effects.gasUsed;
  const cost = (Number(g.computationCost) + Number(g.storageCost) - Number(g.storageRebate)) / 1e9;
  console.log(`${GO ? "done" : "dry run ok"}: ${cost.toFixed(4)} SUI${GO ? `, tx ${d.digest}` : ""}`);
  return d;
}
const created = (d, suffix) => d.objectChanges.find(c => c.type === "created" && (c.objectType || "").endsWith(suffix));
const proof = (text, digest) => { dep.proof.push([text, digest]); };

const step = process.argv[2];
if (step === "status") {
  console.log({
    vault: dep.autoVaultPkg ? `published ${dep.autoVaultPkg}` : "not published",
    immutable: dep.autoVaultImmutable ? "yes" : "no",
    game: dep.autoPkg ? `upgraded ${dep.autoPkg}` : "not upgraded",
    installed: dep.autoInstalled ? "yes" : "no",
  });
} else if (step === "vault") {
  if (dep.autoVaultPkg) throw new Error("the vault is already published");
  const d = sui(["publish", "--gas-budget", "100000000"], path.join(ROOT, "contracts", "auto_vault"));
  if (GO) {
    const v = created(d, "::vault::Vault");
    dep.autoVaultPkg = d.objectChanges.find(c => c.type === "published").packageId;
    dep.autoVault = v.objectId;
    dep.autoVaultIsv = Number(v.owner.Shared.initial_shared_version);
    dep.autoPullCap = created(d, "::vault::PullCap").objectId;
    dep.autoVaultUpgradeCap = created(d, "::package::UpgradeCap").objectId;
    proof("Auto Mine vault published: a separate package that holds each player's Auto Mine balance; only the player can withdraw it, at any time", d.digest);
    save();
  }
} else if (step === "immutable") {
  if (!dep.autoVaultUpgradeCap) throw new Error("publish the vault first");
  if (dep.autoVaultImmutable) throw new Error("already immutable");
  const d = sui(["call", "--package", "0x2", "--module", "package", "--function", "make_immutable", "--args", dep.autoVaultUpgradeCap, "--gas-budget", "20000000"]);
  if (GO) {
    dep.autoVaultImmutable = d.digest;
    proof("Auto Mine vault made immutable: its upgrade key was destroyed, so no one can ever change it, pause it or block a withdrawal", d.digest);
    save();
  }
} else if (step === "upgrade") {
  if (!dep.autoVaultImmutable) throw new Error("make the vault immutable first");
  if (dep.autoPkg) throw new Error("the game is already upgraded");
  const d = sui(["upgrade", "--upgrade-capability", dep.upgradeCap, "--gas-budget", "300000000"], path.join(ROOT, "contracts", "gtstar"));
  if (GO) {
    dep.latest = d.objectChanges.find(c => c.type === "published").packageId;
    dep.autoPkg = dep.latest;
    proof("Game upgraded: Auto Mine. A plan plays every round for you from your own balance in the immutable vault (Spread, Sniper or Hunter); 1% of each automatic deposit goes to whoever runs it and 1% to the buyback and burn", d.digest);
    save();
  }
} else if (step === "install") {
  if (!dep.autoPkg) throw new Error("upgrade the game first");
  if (dep.autoInstalled) throw new Error("already installed");
  const d = sui(["call", "--package", dep.latest, "--module", "game", "--function", "auto_install", "--args", dep.adminCap, dep.board, dep.autoPullCap, "--gas-budget", "50000000"]);
  if (GO) {
    dep.autoInstalled = d.digest;
    proof("Auto Mine vault's only pull key stored in the game for good: no wallet holds it, and no function returns it", d.digest);
    save();
  }
} else throw new Error("usage: node scripts/auto-deploy.mjs <vault|immutable|upgrade|install|status>   (GO=1 to send)");
