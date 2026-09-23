// Loaded only for MetaMask's Sui Snap, which resolves and executes through its own backend and
// fails on some transactions. The site builds the transaction, the wallet only signs, the site submits.
import { Transaction } from "@mysten/sui/transactions";
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { fromBase64 } from "@mysten/sui/utils";
import { signTransaction } from "@mysten/wallet-standard";

let client = null;
export async function send({ wallet, account, chain, txJson, url, network }) {
  client ||= new SuiGraphQLClient({ url, network });
  const built = await Transaction.from(txJson).build({ client });
  const { bytes, signature } = await signTransaction(wallet, { transaction: Transaction.from(built), account, chain });
  const r = await client.executeTransaction({ transaction: fromBase64(bytes), signatures: [signature] });
  const res = r.Transaction || r.FailedTransaction;
  if (!res?.status?.success) throw new Error(`MoveAbort ${JSON.stringify(res?.status?.error ?? "failed")}`);
  return { digest: res.digest };
}
