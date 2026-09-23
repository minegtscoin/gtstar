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
  else fs.copyFileSync(src, path.join(out, f));
}
fs.writeFileSync(path.join(out, "version.json"), JSON.stringify({ v: V }));
const config = { network, ids: { package: dep.package, token: dep.token || dep.package, board: dep.board, treasury: dep.treasury, pool: dep.pool }, proof: dep.proof || [] };
fs.writeFileSync(path.join(out, "config.js"), `window.GTSTAR_VERSION = "${V}";\nwindow.GTSTAR_CONFIG = ${JSON.stringify(config, null, 2)};\n`);

// Contract IDs for the keeper function.
fs.writeFileSync(path.join(__dirname, "netlify", "functions", "keeper-config.json"),
  JSON.stringify({ network, package: dep.package, board: dep.board, treasury: dep.treasury, pool: dep.pool }, null, 2));

esbuild.buildSync({
  entryPoints: [path.join(__dirname, "src", "main.js")],
  bundle: true, minify: true, format: "iife", target: "es2020",
  outfile: path.join(out, "app.js"),
});
// MetaMask-only transaction path, loaded on demand so the main bundle stays small.
esbuild.buildSync({
  entryPoints: [path.join(__dirname, "src", "snap-send.js")],
  bundle: true, minify: true, format: "esm", target: "es2020",
  outfile: path.join(out, "snap-send.js"),
});
console.log(`built dist/ for ${network}: package ${dep.package}`);
