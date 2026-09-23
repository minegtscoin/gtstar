// Pre-deploy check of dist/: the bundle parses, and every element the app looks up exists in the page.
// A failure exits non-zero so deploy.sh never uploads a broken build.
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const dist = path.join(__dirname, "dist");
const fail = m => { console.error(`CHECK FAILED: ${m}`); process.exit(1); };
for (const f of ["index.html", "docs.html", "app.js", "config.js", "version.json", "style.css", "app.css", "docs.js"])
  if (!fs.existsSync(path.join(dist, f))) fail(`dist/${f} missing`);
for (const f of ["app.js", "config.js", "docs.js"]) {
  try { new vm.Script(fs.readFileSync(path.join(dist, f), "utf8"), { filename: f }); } catch (e) { fail(`${f} does not parse: ${e.message}`); }
}
const html = fs.readFileSync(path.join(dist, "index.html"), "utf8");
const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]));
const src = fs.readFileSync(path.join(__dirname, "src", "main.js"), "utf8");
const used = new Set([...src.matchAll(/\$\("([A-Za-z0-9_-]+)"\)/g)].map(m => m[1]));
const missing = [...used].filter(id => !ids.has(id));
if (missing.length) fail(`index.html has no element for: ${missing.join(", ")}`);
const V = JSON.parse(fs.readFileSync(path.join(dist, "version.json"), "utf8")).v;
if (!html.includes(`?v=${V}`) || !fs.readFileSync(path.join(dist, "config.js"), "utf8").includes(V)) fail("version stamp mismatch");
console.log(`check ok: ${used.size} element lookups, bundle parses, version ${V}`);
