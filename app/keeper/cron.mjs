// GTStar keeper — Hostinger cron entry (runs every minute, ~50s working window).
// Reads KEEPER_KEY from ~/gtstar-keeper/.env and skips if the previous run is still going.
// Bundled into keeper/dist/keeper.mjs by `node keeper/build.js`.
import fs from "fs";
import path from "path";

const dir = path.dirname(new URL(import.meta.url).pathname);
for (const line of fs.readFileSync(path.join(dir, ".env"), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
  if (m) process.env[m[1]] ??= m[2];
}
process.env.KEEPER_WINDOW_MS ??= "50000";

const lock = path.join(dir, ".lock");
try {
  fs.mkdirSync(lock);
} catch {
  if (Date.now() - fs.statSync(lock).mtimeMs < 110_000) process.exit(0);
}
try {
  const { default: keeper } = await import("./keeper.mjs");
  await keeper();
} finally {
  fs.rmSync(lock, { recursive: true, force: true });
}
