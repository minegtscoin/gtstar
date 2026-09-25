// GTStar Bots: two public bot wallets that keep the board moving. Each plays BOT_PER_TILE_MIST
// on one random tile at random times (at least 20 minutes apart), never in the same round as the
// other bot: Bot 1 about 12 times a day, Bot 2 about 6. Every GTS they mine is burned through the reserve: redeem burns it and
// the SUI it pays out goes straight back into the reserve, so supply drops and the floor rises.
// Signs with BOT1_KEY / BOT2_KEY; each bot is off when its key is unset.
// Schedule: .bots-state.json next to the keeper ({address: next play time in ms}).
import fs from "fs";
import path from "path";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const PER_TILE = BigInt(process.env.BOT_PER_TILE_MIST || 10_000_000);   // 0.01 SUI
const KEEP = BigInt(process.env.BOT_KEEP_MIST || 100_000_000);          // stop below 0.1 SUI
const MIN_GAP_MS = 20 * 60_000;
// Gap = 20 min + random extra: Bot 1 averages 2 h (~12 rounds a day), Bot 2 4 h (~6 a day).
const MEAN_EXTRA_MS = { BOT1_KEY: 100 * 60_000, BOT2_KEY: 220 * 60_000 };
const LEAD_MS = 8_000;
const TOKEN = "0x39019f183d8d19df19bd7c3e14fed735c7a1b11e2aa02669eba1089602394c3e";
const GTS = `${TOKEN}::gts::GTS`;

export function makeBots(client, CFG, log, dir) {
  const bots = Object.keys(MEAN_EXTRA_MS).filter(k => process.env[k]).map(k => {
    const signer = Ed25519Keypair.fromSecretKey(process.env[k]);
    return { signer, me: signer.toSuiAddress(), extra: MEAN_EXTRA_MS[k] };
  });
  if (!bots.length) return null;
  const MINER = `${CFG.origin || CFG.package}::game::Miner`;
  const C = f => `${CFG.package}::${f}`;
  const file = path.join(dir, ".bots-state.json");
  let state = {};
  try { state = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
  const nextGap = bot => MIN_GAP_MS + Math.round(-Math.log(1 - Math.random()) * bot.extra);
  const save = () => fs.writeFileSync(file, JSON.stringify(state));
  let changed = false;
  for (const b of bots) if (!state[b.me]) { state[b.me] = Date.now() + Math.round(Math.random() * 2 * 3600_000); changed = true; }
  if (changed) save();
  const failed = new Map(); // bot -> round whose join failed (never retried; each attempt costs gas)

  async function load() {
    const r = await client.query({
      query: `query($t:String!){${bots.map((b, i) => `b${i}:address(address:"${b.me}"){balance(coinType:"0x2::sui::SUI"){totalBalance} objects(filter:{type:$t},first:1){nodes{address contents{json}}} gts:objects(filter:{type:"0x2::coin::Coin<${GTS}>"},first:50){nodes{address contents{json}}}}`).join(" ")}}`,
      variables: { t: MINER },
    });
    return bots.map((b, i) => {
      const a = r.data[`b${i}`];
      const n = a?.objects?.nodes?.[0];
      return {
        ...b,
        balance: BigInt(a?.balance?.totalBalance || 0),
        miner: n ? { id: n.address, round_id: Number(n.contents.json.round_id) } : null,
        gts: (a?.gts?.nodes || []).filter(c => Number(c.contents.json.balance) > 0).map(c => c.address),
      };
    });
  }

  // How many bots are in round `id`, so the House can stay out of rounds only bots have joined.
  let botsInRound = { id: 0, n: 0 };
  async function botsIn(id) {
    if (botsInRound.id !== id) botsInRound = { id, n: (await load()).filter(x => x.miner?.round_id === id).length };
    return botsInRound.n;
  }

  // Called by the keeper with a fresh board. Returns true when it sent a transaction.
  async function tick(b) {
    const now = Date.now();
    const cur = Number(b.cur_id);
    if (b.cur_started === true && now > Number(b.cur_end_ms) - Number(b.freeze_ms) - LEAD_MS) return false;
    const due = bots.filter(x => now >= state[x.me] && failed.get(x.me) !== cur);
    if (!due.length || (botsInRound.id === cur && botsInRound.n > 0)) return false;
    const all = await load();
    botsInRound = { id: cur, n: all.filter(x => x.miner?.round_id === cur).length };
    if (botsInRound.n > 0) return false; // one bot per round
    const bot = all.find(x => due.some(d => d.me === x.me));
    if (bot.balance < PER_TILE + KEEP) {
      failed.set(bot.me, cur);
      state[bot.me] = now + nextGap(bot); save();
      log.push(`bot ${bot.me.slice(0, 6)} low balance ${Number(bot.balance) / 1e9} SUI`);
      return false;
    }

    const tile = Math.floor(Math.random() * 25);
    const tx = new Transaction();
    tx.setSender(bot.me);
    let m, fresh = false, burn = bot.gts.map(id => tx.object(id));
    if (bot.miner) {
      m = tx.object(bot.miner.id);
      if (bot.miner.round_id !== 0 && bot.miner.round_id < cur) {
        const [g, s] = tx.moveCall({ target: C("game::claim"), arguments: [tx.object(CFG.board), m, tx.object(CFG.treasury), tx.object.clock()] });
        tx.transferObjects([s], bot.me);
        if (burn.length) burn.push(g); else tx.transferObjects([g], bot.me); // a lone claim may be 0 GTS; burned next time
      }
    } else {
      [m] = tx.moveCall({ target: C("game::new_miner") });
      fresh = true;
    }
    if (burn.length) {
      // Burn every GTS the bot holds and put the SUI it redeems back into the reserve.
      if (burn.length > 1) tx.mergeCoins(burn[0], burn.slice(1));
      const out = tx.moveCall({ target: `${TOKEN}::gts::redeem`, arguments: [tx.object(CFG.treasury), burn[0]] });
      const bal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: ["0x2::sui::SUI"], arguments: [out] });
      tx.moveCall({ target: `${TOKEN}::gts::vault_add`, arguments: [tx.object(CFG.treasury), bal] });
    }
    const [pay] = tx.splitCoins(tx.gas, [PER_TILE]);
    tx.moveCall({ target: C("game::deploy"), arguments: [tx.object(CFG.board), m, pay, tx.pure.vector("u64", Array.from({ length: 25 }, (_, i) => (i === tile ? PER_TILE : 0n))), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], bot.me);

    failed.set(bot.me, cur);
    state[bot.me] = now + nextGap(bot); save(); // a failed attempt waits for the next slot too
    const r = await client.signAndExecuteTransaction({ transaction: tx, signer: bot.signer });
    const res = r.Transaction || r.FailedTransaction;
    log.push(`bot ${bot.me.slice(0, 6)} join #${cur}${burn.length ? " +burn" : ""} ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
    if (res.status.success) botsInRound = { id: cur, n: 1 };
    return true;
  }
  return { tick, botsIn };
}
