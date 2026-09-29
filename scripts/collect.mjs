// Collect what is still owed in the old game to the wallets whose keys are on this machine:
// the creator fees on the Board (always paid to the creator address), unclaimed rounds, staked GTS
// and staking rewards. Everything goes to <to> in one transaction per wallet.
// Dry run by default; GO=1 sends.
//   node scripts/collect.mjs <to-address>
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath, pathToFileURL } from "url";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const sdk = sub => import(pathToFileURL(path.join(ROOT, "app", "node_modules", "@mysten", "sui", "dist", sub)).href);
const { SuiGraphQLClient } = await sdk("graphql/index.mjs");
const { Transaction } = await sdk("transactions/index.mjs");
const { Ed25519Keypair } = await sdk("keypairs/ed25519/index.mjs");
const { fromBase64 } = await sdk("utils/index.mjs");

const TO = process.argv[2];
if (!/^0x[0-9a-f]{64}$/.test(TO || "")) throw new Error("usage: node scripts/collect.mjs <to-address 0x + 64 hex>");
const GO = process.env.GO === "1";
const dep = JSON.parse(fs.readFileSync(path.join(ROOT, "deployments", "mainnet.json"), "utf8"));
const G = `${dep.latest}::game`, S = `${dep.latest}::staking`;
const client = new SuiGraphQLClient({ url: "https://graphql.mainnet.sui.io/graphql", network: "mainnet" });

const keys = [];
for (const k of JSON.parse(fs.readFileSync(path.join(os.homedir(), ".sui", "sui_config", "sui.keystore"), "utf8"))) {
  const raw = fromBase64(k);
  if (raw[0] === 0) keys.push(Ed25519Keypair.fromSecretKey(raw.slice(1)));
}

async function owned(addr) {
  const out = [];
  let after = null;
  do {
    const q = `{address(address:"${addr}"){objects(first:50${after ? `,after:"${after}"` : ""}){pageInfo{hasNextPage endCursor} nodes{address contents{type{repr} json}}}}}`;
    const o = (await client.query({ query: q })).data.address.objects;
    out.push(...o.nodes);
    after = o.pageInfo.hasNextPage ? o.pageInfo.endCursor : null;
  } while (after);
  return out;
}

let feesDone = false;
for (const kp of keys) {
  const me = kp.toSuiAddress();
  const objs = await owned(me);
  const miners = objs.filter(n => /::game::Miner$/.test(n.contents.type.repr) && n.contents.json.round_id !== "0");
  const stakes = objs.filter(n => /::staking::StakePosition$/.test(n.contents.type.repr) && n.contents.json.amount !== "0");
  const tx = new Transaction();
  tx.setSender(me);
  const bal = BigInt((await client.query({ query: `{address(address:"${me}"){balance(coinType:"0x2::sui::SUI"){totalBalance}}}` })).data.address?.balance?.totalBalance || 0);
  tx.setGasBudget(bal < 30_000_000n ? bal : 30_000_000n);
  const out = [];
  if (!feesDone) { tx.moveCall({ target: `${G}::withdraw_dev_fees`, arguments: [tx.object(dep.board)] }); feesDone = true; }
  for (const m of miners) {
    const [g, s] = tx.moveCall({ target: `${G}::claim`, arguments: [tx.object(dep.board), tx.object(m.address), tx.object(dep.treasury), tx.object.clock()] });
    out.push(g, s);
  }
  for (const p of stakes) {
    out.push(tx.moveCall({ target: `${S}::claim_rewards`, arguments: [tx.object(dep.pool), tx.object(p.address), tx.object.clock()] }));
    out.push(tx.moveCall({ target: `${S}::unstake`, arguments: [tx.object(dep.pool), tx.object(p.address), tx.pure.u64(p.contents.json.amount), tx.object.clock()] }));
  }
  if (out.length) tx.transferObjects(out, TO);
  const what = `${me}  ${miners.length} rounds, ${stakes.length} stakes`;
  const d = await client.simulateTransaction({ transaction: tx, include: { balanceChanges: true } });
  const r = d.Transaction || d.FailedTransaction;
  const bc = (r.balanceChanges || []).filter(b => b.address === TO).map(b => `${(Number(b.amount) / 1e9).toFixed(4)} ${b.coinType.split("::").pop()}`).join(" + ");
  if (!r.status.success) { console.log(`${what}  dry run FAILED ${JSON.stringify(r.status).slice(0, 300)}`); continue; }
  if (!GO) { console.log(`${what}  dry run ok, to ${TO.slice(0, 8)}: ${bc || "nothing"}`); continue; }
  const e0 = await client.signAndExecuteTransaction({ signer: kp, transaction: tx, include: { effects: true } });
  const e = e0.Transaction || e0.FailedTransaction;
  if (!e.status.success) { console.log(`${what}  FAILED ${JSON.stringify(e.status)}`); continue; }
  await client.waitForTransaction({ digest: e.digest });
  console.log(`${what}  sent ${bc}, tx ${e.digest}`);
}
