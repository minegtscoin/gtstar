// Loaded only for MetaMask's Sui Snap. The Snap builds and signs (fast, over gRPC); the site submits
// the signed transaction itself instead of relying on the Snap's execute path.
import { Transaction } from "@mysten/sui/transactions";
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { fromBase64 } from "@mysten/sui/utils";
import { signTransaction } from "@mysten/wallet-standard";

let client = null;
export async function send({ wallet, account, chain, txJson, url, network }) {
  client ||= new SuiGraphQLClient({ url, network });
  const { bytes, signature } = await signTransaction(wallet, { transaction: Transaction.from(txJson), account, chain });
  const r = await client.executeTransaction({ transaction: fromBase64(bytes), signatures: [signature] });
  const res = r.Transaction || r.FailedTransaction;
  if (!res?.status?.success) throw new Error(`MoveAbort ${JSON.stringify(res?.status?.error ?? "failed")}`);
  return { digest: res.digest };
}
