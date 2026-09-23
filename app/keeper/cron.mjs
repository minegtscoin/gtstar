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
// X poster, each run in its own process. 6:00-6:04 PM US Eastern: the post (it posts at most once a day,
// Tuesday and Friday only). Minute 30 of every third hour: engagement with new mentions.
const poster = path.join(dir, "..", "gtstar-poster", "poster.mjs");
const now = new Date(), et = new Date(now.toLocaleString("en-US", { timeZone: "America/New_York" }));
const runPoster = args => import("child_process").then(({ spawn }) => {
  const log = fs.openSync(path.join(path.dirname(poster), "log.txt"), "a");
  spawn(process.execPath, [poster, ...args], { detached: true, stdio: ["ignore", log, log] }).unref();
});
if (fs.existsSync(poster)) {
  if (et.getHours() === 18 && et.getMinutes() < 5) await runPoster([]);
  if (now.getUTCHours() % 3 === 0 && now.getUTCMinutes() === 30) await runPoster(["--engage"]);
}

// Low-balance email for the keeper and house wallets, every 10 minutes (alert.php mails at most once a day each).
const alert = path.join(dir, "alert.php");
if (fs.existsSync(alert) && now.getUTCMinutes() % 10 === 0) {
  const { spawn } = await import("child_process");
  spawn("/usr/bin/php", [alert], { detached: true, stdio: "ignore" }).unref();
}

try {
  const { default: keeper } = await import("./keeper.mjs");
  await keeper();
} finally {
  fs.rmSync(lock, { recursive: true, force: true });
}
