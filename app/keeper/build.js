// Bundle the keeper, the Player and the Runner (with the Auto Mine loop) into self-contained files for the Hostinger cron.
//   node keeper/build.js
const path = require("path");
for (const [entry, out] of [["cron.mjs", "keeper.mjs"], ["player.mjs", "player.mjs"], ["runner.mjs", "runner.mjs"]]) require("esbuild").buildSync({
  entryPoints: [path.join(__dirname, entry)],
  outfile: path.join(__dirname, "dist", out),
  bundle: true,
  platform: "node",
  target: "node22",
  format: "esm",
  banner: { js: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);" },
});
