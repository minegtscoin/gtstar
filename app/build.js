// Build the static dApp into dist/ for a given network.
//   node build.js mainnet   (default)
//   node build.js testnet
const fs = require("fs");
const path = require("path");
const esbuild = require("esbuild");

const network = process.argv[2] || "mainnet";
const depFile = path.join(__dirname, "..", "deployments", `${network}.json`);
if (!fs.existsSync(depFile)) throw new Error(`missing ${depFile} — publish to ${network} first`);
const dep = JSON.parse(fs.readFileSync(depFile, "utf8"));

const out = path.join(__dirname, "dist");
// Empty dist/ rather than deleting it: on Windows a running preview server keeps the folder locked.
fs.mkdirSync(out, { recursive: true });
for (const f of fs.readdirSync(out)) fs.rmSync(path.join(out, f), { recursive: true, force: true });
// Build id: cache-busts assets and lets open tabs reload themselves after a new deploy.
const V = Date.now().toString(36);
for (const f of fs.readdirSync(path.join(__dirname, "public"))) {
  const src = path.join(__dirname, "public", f);
  if (f.endsWith(".html")) fs.writeFileSync(path.join(out, f), fs.readFileSync(src, "utf8").replace(/__V__/g, V));
  // Contract IDs for the PHP endpoints (history cache, supply).
  else if (f.endsWith(".php")) fs.writeFileSync(path.join(out, f), fs.readFileSync(src, "utf8")
    .replace(/__GAME__/g, dep.package).replace(/__TOKEN__/g, dep.token || dep.package).replace(/__TREASURY__/g, dep.treasury));
  else fs.copyFileSync(src, path.join(out, f));
}
fs.writeFileSync(path.join(out, "version.json"), JSON.stringify({ v: V }));
// Auto Mine: only once the vault's pull key is installed in the game (scripts/auto-deploy.mjs).
const auto = dep.autoInstalled ? { auto: dep.autoPkg, autoVaultPkg: dep.autoVaultPkg, autoVault: dep.autoVault } : {};
const config = { network, relaunch: !!dep.relaunch, ids: { package: dep.package, latest: dep.latest || dep.package, token: dep.token || dep.package, board: dep.board, treasury: dep.treasury, supplyLock: dep.supplyLock, mintLimit: dep.mintLimit, mintLimiter: dep.mintLimiter, pool: dep.pool, market: dep.market, motherlode: dep.motherlodePkg, fair: dep.fairPkg, refine: dep.refinePkg, stake: dep.stakePkg, wf: dep.wfPkg, v6: dep.v6Pkg, v10: dep.v10Pkg, v7: dep.v7Pkg, v11: dep.v11Pkg, v12: dep.v12Pkg, v18: dep.marketPkg, v20: dep.stakeLockPkg, ...auto }, accounts: { dev: dep.dev, keeper: dep.keeper, upgradeCap: dep.upgradeCap, timelock: dep.timelock, timelockPkg: dep.timelockPkg, lpBurn: dep.lpBurnProof }, proof: dep.siteProof || dep.proof || [] };
fs.writeFileSync(path.join(out, "config.js"), `window.GTSTAR_VERSION = "${V}";\nwindow.GTSTAR_CONFIG = ${JSON.stringify(config, null, 2)};\n`);

// Contract IDs for the keeper.
fs.writeFileSync(path.join(__dirname, "keeper", "keeper-config.json"),
  JSON.stringify({ network, relaunch: !!dep.relaunch, stakePkg: dep.stakePkg, package: dep.latest || dep.package, origin: dep.package, liqPkg: dep.v11Pkg, board: dep.board, treasury: dep.treasury, treasuryIsv: dep.treasuryIsv, pool: dep.pool, marketPkg: dep.marketPkg, mintLimiter: dep.mintLimiter,
    ...(dep.autoInstalled ? { autoPkg: dep.autoPkg, autoVault: dep.autoVault, autoVaultIsv: dep.autoVaultIsv } : {}) }, null, 2));

esbuild.buildSync({
  entryPoints: [path.join(__dirname, "src", "main.js")],
  bundle: true, minify: true, format: "iife", target: "es2020",
  outfile: path.join(out, "app.js"),
});
console.log(`built dist/ for ${network}: package ${dep.package}`);
