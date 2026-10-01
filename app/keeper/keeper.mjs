// GTStar keeper: settles each round as soon as it ends and sweeps creator fees to DEV_ADDR once a day (00:00 UTC).
// The House also adds its mined GTS to the Cetus pool once a day (12:00 UTC).
// Signs with KEEPER_KEY (a dedicated key that only holds SUI for gas). Also pays the free first round (welcome.mjs).
// The buyback and the liquidity add are not the keeper's any more: they run inside the draw itself
// (game::settle_v3, see draw.mjs), which anyone may call. Once a day the keeper has the game collect the
// trading fees of its locked Cetus positions back into the pool (game::compound_fees, open to anyone).
// The Pulse opens a round when someone has the site open (pulse.mjs).
// The first game's House, Shield, Matcher, Bots and Floor bot are archived in legacy/app/keeper.
// The Market Maker keeps a small buy and sell order for GTS on the DeepBook GTS/SUI book (mm.mjs).
import fs from "fs";
import path from "path";
import { SuiGraphQLClient } from "@mysten/sui/graphql";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";
import CFG from "./keeper-config.json" with { type: "json" };
import { drawCall, marketDrawOk, cetusConfigArg, marketPoolArg } from "./draw.mjs";
import { makeWelcome } from "./welcome.mjs";
import { makePulse } from "./pulse.mjs";
import { makeMM } from "./mm.mjs";

const WINDOW_MS = Number(process.env.KEEPER_WINDOW_MS) || 25_000;
// Every round is settled automatically (~0.004 SUI of keeper gas each). KEEPER_MIN_POT_MIST can
// raise the bar if dust rounds ever start draining the keeper; smaller rounds are then drawn by players.
const MIN_POT = Number(process.env.KEEPER_MIN_POT_MIST ?? 0);
// While the Runner is alive it draws the rounds it holds alone; the keeper steps in on those only RUNNER_GRACE_MS after the end.
const RUNNER_GRACE_MS = 8_000;
// Locked Cetus positions whose fees one compound_fees call collects (the game holds 20).
const LP_BATCH = 50;
const sleep = ms => new Promise(r => setTimeout(r, ms));

export default async () => {
  const key = process.env.KEEPER_KEY;
  if (!key) return new Response("KEEPER_KEY not set", { status: 500 });
  const signer = Ed25519Keypair.fromSecretKey(key);
  const client = new SuiGraphQLClient({ url: `https://graphql.${CFG.network}.sui.io/graphql`, network: CFG.network });
  const T = f => `${CFG.package}::${f}`;
  const start = Date.now();
  const log = [];
  const welcome = makeWelcome(client, log);
  // PULSE_OFF=1 (since 2026-10-01): no GTStar wallet opens rounds; players and Auto Mine plans do.
  const pulse = process.env.BOTS_DIR && process.env.PULSE_OFF !== "1" ? makePulse(client, CFG, log, process.env.BOTS_DIR) : null;
  const mm = process.env.BOTS_DIR ? makeMM(client, CFG, log, process.env.BOTS_DIR) : null;

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
  // Once a day (12:00 UTC): the trading fees of the game's locked positions go back into the pool.
  async function compoundFees() {
    await run("compound fees", tx => tx.moveCall({ target: T("game::compound_fees"), arguments: [tx.object(CFG.board), cetusConfigArg(tx), marketPoolArg(tx),
      tx.pure.u64(0), tx.pure.u64(LP_BATCH), tx.object.clock()] }));
  }
  const runnerAlive = () => {
    try { return !!process.env.BOTS_DIR && Date.now() - fs.statSync(path.join(process.env.BOTS_DIR, ".runner-live")).mtimeMs < 30_000; } catch { return false; }
  };

  // Ended 7-day locks go back to 1x: poke every locked stake whose lock has passed but still counts 1.5x.
  async function pokeLocks() {
    if (!CFG.stakePkg) return;
    const q = `{b:object(address:"${CFG.board}"){dynamicField(name:{type:"${CFG.stakePkg}::game::StakeKey",bcs:"AA=="}){value{... on MoveValue{json}}}}}`;
    const d = (await client.query({ query: q })).data;
    const table = d.b?.dynamicField?.value?.json?.positions?.id;
    if (!table) return;
    // Every Staked event, paged, so older locks are poked too.
    const now = Date.now(), due = new Set();
    for (let after = null; ;) {
      const e = (await client.query({ query: `{events(filter:{type:"${CFG.stakePkg}::staking::Staked"},first:50${after ? `,after:"${after}"` : ""}){pageInfo{hasNextPage endCursor} nodes{contents{json}}}}` })).data.events;
      for (const n of e.nodes) { const j = n.contents.json; if (j.locked && +j.locked_until < now) due.add(j.player); }
      if (!e.pageInfo.hasNextPage) break;
      after = e.pageInfo.endCursor;
    }
    for (const player of due) {
      const key = Buffer.from(player.slice(2).padStart(64, "0") + "01", "hex").toString("base64");
      const r = (await client.query({ query: `{object:address(address:"${table}"){dynamicField(name:{type:"${CFG.stakePkg}::staking::PosKey",bcs:"${key}"}){value{... on MoveValue{json}}}}}` })).data;
      const pos = r.object?.dynamicField?.value?.json;
      if (!pos || BigInt(pos.weight) <= BigInt(pos.amount) * 10n || +pos.locked_until > now) continue;
      await run(`poke ${player.slice(0, 8)}`, tx => tx.moveCall({ target: T("game::poke"), arguments: [tx.object(CFG.board), tx.pure.address(player), tx.object.clock()] }));
    }
  }

  // Draw rewards arrive as small SUI coins and settles pay gas from the address balance, so the coins pile up;
  // past 256 of them a transaction that spends the gas coin is rejected. From 50 coins on, merge up to 250 into one.
  async function mergeCoins() {
    const me = signer.toSuiAddress(), coins = [];
    for (let cursor = null; coins.length < 250;) {
      const r = await client.core.listCoins({ owner: me, cursor, limit: 50 });
      coins.push(...r.objects);
      if (!r.hasNextPage) break;
      cursor = r.cursor;
    }
    if (coins.length < 50) return;
    await run(`merge ${Math.min(coins.length, 250)} coins`, tx => {
      tx.setGasPayment(coins.slice(0, 250).map(c => ({ objectId: c.objectId, version: c.version, digest: c.digest })));
      tx.transferObjects([tx.gas], me);
    });
  }

  let b;
  try {
    await mergeCoins();
  } catch (e) {
    log.push(`error ${String(e.message || e).slice(0, 200)}`);
  }
  try {
    await pokeLocks();
    b = await board();
    const now = new Date();
    if (now.getUTCHours() === 0 && now.getUTCMinutes() === 0 && Number(b.dev_fees || 0) > 0) {
      await run("sweep", tx => tx.moveCall({ target: T("game::withdraw_dev_fees"), arguments: [tx.object(CFG.board)] }));
    }
    if (now.getUTCHours() === 12 && now.getUTCMinutes() === 0) await compoundFees();
  } catch (e) {
    log.push(`error ${String(e.message || e).slice(0, 200)}`);
  }
  // A failed attempt (e.g. the chain clock still a moment behind the round end) is retried
  // within the same run instead of waiting for the next cron minute.
  while (Date.now() - start < WINDOW_MS) {
    try {
      if (!b) b = await board();
      if (welcome && await welcome()) continue;
      if (pulse && await pulse(b)) { b = await board(); continue; }
      if (mm && await mm()) continue;
      const end = Number(b.cur_end_ms);
      const worth = Number(b.cur_total) >= MIN_POT;
      if (b.cur_started === true && !worth) {
        await sleep(2000);
      } else if (b.cur_started === true && Date.now() >= end + (runnerAlive() && Number(b.cur_players) === 1 ? RUNNER_GRACE_MS : 300)) {
        // The market draw; the plain draw only when the market draw cannot run (see draw.mjs).
        const why = {};
        const market = await marketDrawOk(client, CFG, signer.toSuiAddress(), why);
        if (!market && why.retry) { await sleep(700); b = await board(); continue; }
        if (!market) log.push(`market draw not possible, plain draw: ${String(why.msg).slice(0, 160)}`);
        await run(`settle #${b.cur_id}${market ? "" : " (plain)"}`, tx => drawCall(tx, CFG, market));
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

