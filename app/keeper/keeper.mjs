// GTStar keeper: settles each round as soon as it ends and sweeps creator fees to DEV_ADDR once a day (00:00 UTC).
// Signs with KEEPER_KEY (a dedicated key that only holds SUI for gas). Also pays the free first round (welcome.mjs).
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import CFG from "./keeper-config.json" with { type: "json" };
import { makeHouse } from "./house.mjs";
import { makeWelcome } from "./welcome.mjs";

const WINDOW_MS = Number(process.env.KEEPER_WINDOW_MS) || 25_000;
// Every round is settled automatically (~0.004 SUI of keeper gas each). KEEPER_MIN_POT_MIST can
// raise the bar if dust rounds ever start draining the keeper; smaller rounds are then drawn by players.
const MIN_POT = Number(process.env.KEEPER_MIN_POT_MIST ?? 0);
const sleep = ms => new Promise(r => setTimeout(r, ms));

export default async () => {
  const key = process.env.KEEPER_KEY;
  if (!key) return new Response("KEEPER_KEY not set", { status: 500 });
  const signer = Ed25519Keypair.fromSecretKey(key);
  const client = new SuiGraphQLClient({ url: `https://graphql.${CFG.network}.sui.io/graphql`, network: CFG.network });
  const T = f => `${CFG.package}::${f}`;
  const start = Date.now();
  const log = [];
  const house = makeHouse(client, CFG, log);
  const welcome = makeWelcome(client, log);

  async function board() {
    const r = await client.query({ query: `{object(address:"${CFG.board}"){asMoveObject{contents{json}}}}` });
    return r.data.object.asMoveObject.contents.json;
  }
  async function run(label, build) {
    const tx = new Transaction();
    tx.setSender(signer.toSuiAddress());
    build(tx);
    const r = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const res = r.Transaction || r.FailedTransaction;
    log.push(`${label} ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
  }

  let b;
  try {
    b = await board();
    const now = new Date();
    if (now.getUTCHours() === 0 && now.getUTCMinutes() === 0 && Number(b.dev_fees || 0) > 0) {
      await run("sweep", tx => tx.moveCall({ target: T("game::withdraw_dev_fees"), arguments: [tx.object(CFG.board)] }));
    }
  } catch (e) {
    log.push(`error ${String(e.message || e).slice(0, 200)}`);
  }
  // A failed attempt (e.g. the chain clock still a moment behind the round end) is retried
  // within the same run instead of waiting for the next cron minute.
  while (Date.now() - start < WINDOW_MS) {
    try {
      if (!b) b = await board();
      if (house && await house(b)) { b = await board(); continue; }
      if (welcome && await welcome()) continue;
      const end = Number(b.cur_end_ms);
      const worth = Number(b.cur_total) >= MIN_POT;
      if (b.cur_started === true && !worth) {
        await sleep(2000);
      } else if (b.cur_started === true && Date.now() >= end + 300) {
        await run(`settle #${b.cur_id}`, tx => tx.moveCall({
          target: T("game::settle"),
          arguments: [tx.object(CFG.board), tx.object(CFG.treasury), tx.object(CFG.pool), tx.object.random(), tx.object.clock()],
        }));
      } else if (b.cur_started === true && end - Date.now() < WINDOW_MS - (Date.now() - start)) {
        await sleep(Math.max(300, end + 400 - Date.now()));
      } else {
        await sleep(2000);
      }
      b = await board();
    } catch (e) {
      log.push(`error ${String(e.message || e).slice(0, 200)}`);
      b = null;
      await sleep(1500);
    }
  }
  console.log(log.join("\n") || "idle");
  return new Response(log.join("\n") || "idle");
};

