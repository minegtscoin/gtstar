// Free first round: sends the welcome grant to wallets queued by welcome.php (which already checked
// the signature, the zkLogin scheme, that the wallet is brand new and the daily cap).
// Queue: ~/gtstar-data/welcome/queue/<address>; once paid the file moves to sent/<address> with the digest.
// Pays from WELCOME_KEY (defaults to the keeper key) and never spends below WELCOME_KEEP_MIST,
// so settlement gas is always left.
import fs from "fs";
import path from "path";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const AMOUNT = BigInt(process.env.WELCOME_MIST || 20_000_000);         // 0.02 SUI, matches welcome.php
const KEEP = BigInt(process.env.WELCOME_KEEP_MIST || 1_000_000_000);   // keep 1 SUI for settle gas
const MAX_BATCH = 20;

export function makeWelcome(client, log) {
  const key = process.env.WELCOME_KEY || process.env.KEEPER_KEY;
  const dir = process.env.WELCOME_DIR || path.join(process.env.HOME || "", "gtstar-data", "welcome");
  if (!key || !fs.existsSync(path.join(dir, "queue"))) return null;
  const signer = Ed25519Keypair.fromSecretKey(key);
  const me = signer.toSuiAddress();
  let lowUntil = 0;

  // Returns true when it sent a transaction.
  return async function tick() {
    if (Date.now() < lowUntil) return false;
    const queued = fs.readdirSync(path.join(dir, "queue")).filter(f => /^0x[0-9a-f]{64}$/.test(f)).slice(0, MAX_BATCH);
    const todo = queued.filter(a => !fs.existsSync(path.join(dir, "sent", a)));
    queued.filter(a => !todo.includes(a)).forEach(a => fs.rmSync(path.join(dir, "queue", a), { force: true }));
    if (!todo.length) return false;

    const r0 = await client.query({ query: `{address(address:"${me}"){balance(coinType:"0x2::sui::SUI"){totalBalance}}}` });
    const bal = BigInt(r0.data?.address?.balance?.totalBalance || 0);
    if (bal < AMOUNT * BigInt(todo.length) + KEEP) {
      log.push(`welcome paused: low balance ${Number(bal) / 1e9} SUI`);
      lowUntil = Date.now() + 10 * 60_000;
      return false;
    }
    const tx = new Transaction();
    tx.setSender(me);
    const coins = tx.splitCoins(tx.gas, todo.map(() => AMOUNT));
    todo.forEach((a, i) => tx.transferObjects([coins[i]], a));
    const r = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const res = r.Transaction || r.FailedTransaction;
    log.push(`welcome x${todo.length} ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
    if (res.status.success) {
      for (const a of todo) {
        fs.writeFileSync(path.join(dir, "sent", a), res.digest);
        fs.rmSync(path.join(dir, "queue", a), { force: true });
      }
    } else {
      lowUntil = Date.now() + 60_000;
    }
    return true;
  };
}
