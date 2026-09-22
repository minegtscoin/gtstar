// Bundle the keeper into one self-contained file for the Hostinger cron.
//   node keeper/build.js
const path = require("path");
require("esbuild").buildSync({
  entryPoints: [path.join(__dirname, "cron.mjs")],
  outfile: path.join(__dirname, "dist", "keeper.mjs"),
  bundle: true,
  platform: "node",
  target: "node22",
  format: "esm",
  banner: { js: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);" },
});
