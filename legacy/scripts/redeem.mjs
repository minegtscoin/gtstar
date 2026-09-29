// Redeem all the GTS in the deployer wallet against the reserve and send the SUI to <to>.
// Dry run by default; GO=1 sends.
//   node scripts/redeem.mjs <to-address>
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
if (!/^0x[0-9a-f]{64}$/.test(TO || "")) throw new Error("usage: node scripts/redeem.mjs <to-address 0x + 64 hex>");
const SUI_BIN = process.env.SUI_BIN || "C:\\Users\\ASD21\\sui-cli\\sui.exe";
const dep = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments", "mainnet.json"), "utf8"));
const GTS = `${dep.token}::gts::GTS`;
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });

const addr = execFileSync(SUI_BIN, ["client", "active-address"]).toString().trim();
let kp;
for (const k of JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"))) {
  const c = Ed25519Keypair.fromSecretKey(fromBase64(k).slice(1));
  if (c.toSuiAddress() === addr) kp = c;
}
if (!kp) throw new Error(`no ed25519 key for ${addr}`);

const q = `{address(address:"${addr}"){g:balance(coinType:"${GTS}"){totalBalance}}}`;
const gts = BigInt((await client.query({ query: q })).data.address?.g?.totalBalance || 0);
if (gts === 0n) { console.log(`${addr} has no GTS`); process.exit(0); }

const tx = new Transaction();
tx.setSender(addr);
const sui = tx.moveCall({ target: `${dep.token}::gts::redeem`, arguments: [tx.object(dep.treasury), coinWithBalance({ type: GTS, balance: gts })] });
tx.transferObjects([sui], TO);

const d = await client.simulateTransaction({ transaction: tx, include: { balanceChanges: true } });
const r = d.Transaction || d.FailedTransaction;
if (!r.status.success) throw new Error(`dry run failed: ${JSON.stringify(r.status)}`);
const got = (r.balanceChanges || []).find(b => b.address === TO && b.coinType.endsWith("::sui::SUI"));
const line = `${(Number(gts) / 1e9).toFixed(4)} GTS from ${addr.slice(0, 8)} -> ${(Number(got?.amount || 0) / 1e9).toFixed(4)} SUI to ${TO.slice(0, 8)}`;
if (process.env.GO !== "1") { console.log(`dry run ok: ${line}`); process.exit(0); }
const e0 = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true } });
const e = e0.Transaction || e0.FailedTransaction;
if (!e.status.success) throw new Error(JSON.stringify(e.status));
await client.waitForTransaction({ digest: e.digest });
console.log(`redeemed: ${line}, tx ${e.digest}`);
