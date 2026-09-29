// Move all SUI and GTS from the project wallets whose keys are on this machine (and the Floor bot's
// key on the server) to one address. Dry run by default; nothing moves without GO=1.
//   node scripts/sweep.mjs <to-address>          simulate every wallet, print what would move
//   GO=1 node scripts/sweep.mjs <to-address>     send for real
// Each wallet keeps only its gas (about 0.01 SUI) back.
import fs from "fs";
import os from "os";
import path from "path";
import { execFileSync } from "child_process";
import { fileURLToPath, pathToFileURL } from "url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const sdk = sub => import(pathToFileURL(path.join(ROOT, "app", "node_modules", "@mysten", "sui", "dist", sub)).href);
const { SuiGraphQLClient } = await sdk("graphql/index.mjs");
const { Transaction, coinWithBalance } = await sdk("transactions/index.mjs");
const { Ed25519Keypair } = await sdk("keypairs/ed25519/index.mjs");
const { fromBase64 } = await sdk("utils/index.mjs");

const TO = process.argv[2];
if (!/^0x[0-9a-f]{64}$/.test(TO || "")) throw new Error("usage: node scripts/sweep.mjs <to-address 0x + 64 hex>");
const GO = process.env.GO === "1";
const dep = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments", "mainnet.json"), "utf8"));
const GTS = `${dep.token}::gts::GTS`;
const GAS = 10_000_000n; // 0.01 SUI budget per wallet
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });

// Keys: the sui keystore (deployer, keeper, old b82a), the bot key files, the Floor key from the server.
const keys = [];
for (const k of JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"))) {
  const raw = fromBase64(k);
  if (raw[0] === 0) keys.push(["keystore", Ed25519Keypair.fromSecretKey(raw.slice(1))]);
}
for (const n of ["house", "bot1", "bot2", "bot3", "matcher", "shield"]) {
  const f = path.join(os.homedir(), ".sui", `gtstar-${n}.key`);
  if (fs.existsSync(f)) keys.push([n, Ed25519Keypair.fromSecretKey(fs.readFileSync(f, "utf8").trim())]);
}
try {
  const env = execFileSync("ssh", ["-i", path.join(os.homedir(), ".ssh", "gtstar_hostinger"), "-p", "65002",
    "u855846839@147.93.73.195", "grep ^FLOOR_KEY= ~/gtstar-keeper/.env"]).toString();
  const v = env.split("=")[1]?.trim();
  if (v) keys.push(["floor", Ed25519Keypair.fromSecretKey(v)]);
} catch { console.log("floor: could not read FLOOR_KEY from the server, skipped"); }

async function balances(addr) {
  const q = `{address(address:"${addr}"){s:balance(coinType:"0x2::sui::SUI"){totalBalance} g:balance(coinType:"${GTS}"){totalBalance}}}`;
  const a = (await client.query({ query: q })).data.address;
  return { sui: BigInt(a?.s?.totalBalance || 0), gts: BigInt(a?.g?.totalBalance || 0) };
}
const fmt = x => (Number(x) / 1e9).toFixed(4);

let totSui = 0n, totGts = 0n;
const seen = new Set();
for (const [name, kp] of keys) {
  const me = kp.toSuiAddress();
  if (seen.has(me) || me === TO) continue;
  seen.add(me);
  const b = await balances(me);
  const sui = b.sui > GAS ? b.sui - GAS : 0n;
  if (sui === 0n && b.gts === 0n) { console.log(`${name.padEnd(8)} ${me}  empty`); continue; }
  if (b.sui < GAS) { console.log(`${name.padEnd(8)} ${me}  ${fmt(b.gts)} GTS but no SUI for gas, skipped`); continue; }

  const tx = new Transaction();
  tx.setSender(me);
  tx.setGasBudget(GAS);
  const out = [];
  if (b.gts > 0n) out.push(coinWithBalance({ type: GTS, balance: b.gts }));
  if (sui > 0n) out.push(coinWithBalance({ balance: sui }));
  tx.transferObjects(out, TO);

  const line = `${name.padEnd(8)} ${me}  ${fmt(sui)} SUI + ${fmt(b.gts)} GTS`;
  if (!GO) {
    const d = await client.simulateTransaction({ transaction: tx });
    const st = (d.Transaction || d.FailedTransaction).status;
    console.log(`${line}  dry run: ${st.success ? "ok" : JSON.stringify(st)}`);
    if (!st.success) continue;
  } else {
    const r0 = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true } });
    const r = r0.Transaction || r0.FailedTransaction;
    if (!r.status.success) { console.log(`${line}  FAILED ${JSON.stringify(r.status)}`); continue; }
    await client.waitForTransaction({ digest: r.digest });
    console.log(`${line}  sent, tx ${r.digest}`);
  }
  totSui += sui; totGts += b.gts;
}
console.log(`${GO ? "Sent" : "Would send"} ${fmt(totSui)} SUI + ${fmt(totGts)} GTS to ${TO}`);
