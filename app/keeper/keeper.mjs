// GTStar keeper: settles each round as soon as it ends and sweeps creator fees to DEV_ADDR once a day (00:00 UTC).
// The House also adds its mined GTS to the Cetus pool once a day (12:00 UTC).
// Signs with KEEPER_KEY (a dedicated key that only holds SUI for gas). Also pays the free first round (welcome.mjs)
// and runs the House (house.mjs), the Shield (shield.mjs), the Matcher (matcher.mjs), the GTStar Bots (bots.mjs)
// and the Floor bot (floor.mjs).
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import CFG from "./keeper-config.json" with { type: "json" };
import { makeBots } from "./bots.mjs";
import { makeFloor } from "./floor.mjs";
import { makeHouse } from "./house.mjs";
import { makeMatcher } from "./matcher.mjs";
import { makeShield } from "./shield.mjs";
import { makeWelcome } from "./welcome.mjs";

const WINDOW_MS = Number(process.env.KEEPER_WINDOW_MS) || 25_000;
// Every round is settled automatically (~0.004 SUI of keeper gas each). KEEPER_MIN_POT_MIST can
// raise the bar if dust rounds ever start draining the keeper; smaller rounds are then drawn by players.
const MIN_POT = Number(process.env.KEEPER_MIN_POT_MIST ?? 0);
const SETTLE_GAS = 20_000_000; // 0.02 SUI ceiling (a settle uses ~0.011 gross, ~0.004 net); unused gas is refunded
const sleep = ms => new Promise(r => setTimeout(r, ms));

export default async () => {
  const key = process.env.KEEPER_KEY;
  if (!key) return new Response("KEEPER_KEY not set", { status: 500 });
  const signer = Ed25519Keypair.fromSecretKey(key);
  const client = new SuiGraphQLClient({ url: `https://graphql.${CFG.network}.sui.io/graphql`, network: CFG.network });
  const T = f => `${CFG.package}::${f}`;
  const start = Date.now();
  const log = [];
  // Relaunch game: settle, creator-fee sweep and the free first round only. The House, Bots, Matcher,
  // Shield and Floor bot were written for the first game's calls and stay off.
  const extras = !CFG.relaunch;
  const bots = extras ? makeBots(client, CFG, log, process.env.BOTS_DIR || ".") : null;
  const house = extras ? makeHouse(client, CFG, log, bots?.botsIn) : null;
  const matcher = extras ? makeMatcher(client, CFG, log) : null;
  const shield = extras ? makeShield(client, CFG, log, process.env.BOTS_DIR || ".") : null;
  const welcome = makeWelcome(client, log);
  const floor = extras ? makeFloor(client, CFG, log) : null;

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

  // Ended 7-day locks go back to 1x: poke every locked stake whose lock has passed but still counts 1.5x.
  async function pokeLocks() {
    if (!CFG.stakePkg) return;
    const q = `{b:object(address:"${CFG.board}"){dynamicField(name:{type:"${CFG.stakePkg}::game::StakeKey",bcs:"AA=="}){value{... on MoveValue{json}}}}
      e:events(filter:{type:"${CFG.stakePkg}::staking::Staked"},last:50){nodes{contents{json}}}}`;
    const d = (await client.query({ query: q })).data;
    const table = d.b?.dynamicField?.value?.json?.positions?.id;
    if (!table) return;
    const now = Date.now(), due = new Set();
    for (const n of d.e?.nodes || []) { const j = n.contents.json; if (j.locked && +j.locked_until < now) due.add(j.player); }
    for (const player of due) {
      const key = Buffer.from(player.slice(2).padStart(64, "0") + "01", "hex").toString("base64");
      const r = (await client.query({ query: `{object:address(address:"${table}"){dynamicField(name:{type:"${CFG.stakePkg}::staking::PosKey",bcs:"${key}"}){value{... on MoveValue{json}}}}}` })).data;
      const pos = r.object?.dynamicField?.value?.json;
      if (!pos || BigInt(pos.weight) <= BigInt(pos.amount) * 10n || +pos.locked_until > now) continue;
      await run(`poke ${player.slice(0, 8)}`, tx => tx.moveCall({ target: T("game::poke"), arguments: [tx.object(CFG.board), tx.pure.address(player), tx.object.clock()] }));
    }
  }

  let b;
  try {
    await pokeLocks();
    b = await board();
    const now = new Date();
    if (now.getUTCHours() === 0 && now.getUTCMinutes() === 0 && Number(b.dev_fees || 0) > 0) {
      await run("sweep", tx => tx.moveCall({ target: T("game::withdraw_dev_fees"), arguments: [tx.object(CFG.board)] }));
    }
    if (house && now.getUTCHours() === 12 && now.getUTCMinutes() === 0) await house.addLiquidity();
  } catch (e) {
    log.push(`error ${String(e.message || e).slice(0, 200)}`);
  }
  // A failed attempt (e.g. the chain clock still a moment behind the round end) is retried
  // within the same run instead of waiting for the next cron minute.
  while (Date.now() - start < WINDOW_MS) {
    try {
      if (!b) b = await board();
      if (shield && await shield.tick(b)) { b = await board(); continue; }
      // In the target's rounds the House, Matcher and Bots stay out: a small stake on the winning tile
      // would only take a slice of the Shield's pot.
      const skip = shield && b.cur_started === true && await shield.targetIn(Number(b.cur_id));
      if (!skip && house && await house.tick(b)) { b = await board(); continue; }
      if (!skip && matcher && await matcher.tick(b)) { b = await board(); continue; }
      if (!skip && bots && await bots.tick(b)) { b = await board(); continue; }
      if (welcome && await welcome()) continue;
      if (floor && await floor.tick()) continue;
      const end = Number(b.cur_end_ms);
      const worth = Number(b.cur_total) >= MIN_POT;
      if (b.cur_started === true && !worth) {
        await sleep(2000);
      } else if (b.cur_started === true && Date.now() >= end + 300) {
        await run(`settle #${b.cur_id}`, tx => {
          // Fixed budget: the dry run usually takes the no-jackpot path, and a jackpot settle needs more gas.
          tx.setGasBudget(SETTLE_GAS);
          tx.moveCall({
            target: T("game::settle"),
            arguments: CFG.relaunch
              ? [tx.object(CFG.board), tx.object(CFG.treasury), tx.object.random(), tx.object.clock()]
              : [tx.object(CFG.board), tx.object(CFG.treasury), tx.object(CFG.pool), tx.object.random(), tx.object.clock()],
          });
        });
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

