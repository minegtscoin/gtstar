// GTStar Matcher: a public bot wallet that joins every round a real player starts, with 10%
// (MATCH_BPS) of that player's first deposit, on one random tile. No upper limit: it plays as much as
// its balance allows above MATCH_KEEP_MIST, and at least 0.01 SUI (the minimum per tile).
// Every GTS it mines is burned through the reserve, like the GTStar Bots: redeem burns it and the SUI
// it pays out goes straight back into the reserve, so supply drops and the floor rises.
// It claims its previous round inside the same transaction. Signs with MATCH_KEY; off when unset.
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";
import { Transaction } from "@mysten/sui/transactions";

const MIN = 10_000_000n;                                                   // 0.01 SUI, the minimum per tile
const MATCH_BPS = BigInt(process.env.MATCH_BPS || 1_000);                  // 10% of the first real deposit
const KEEP = BigInt(process.env.MATCH_KEEP_MIST || 50_000_000);            // SUI kept for gas
const LEAD_MS = 8_000; // join only if the round has at least this long before its deploy freeze
const TOKEN = "0x39019f183d8d19df19bd7c3e14fed735c7a1b11e2aa02669eba1089602394c3e";
const GTS = `${TOKEN}::gts::GTS`;
// Not "real" first deposits: the GTStar House and Bot 1 and 2.
const OURS = new Set([
  "0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a",
  "0xab4deb30e34487f75bf5632038e46d419c6238b4ea52d35f3ad3421a5bb268fa",
  "0x779b49acf4db04d835440c12ffe24929de505a9b8112b4040da5103d225b37e7",
]);

export function makeMatcher(client, CFG, log) {
  const key = process.env.MATCH_KEY;
  if (!key) return null;
  const signer = Ed25519Keypair.fromSecretKey(key);
  const me = signer.toSuiAddress();
  const MINER = `${CFG.origin || CFG.package}::game::Miner`;
  const C = f => `${CFG.package}::${f}`;
  let joined = 0;      // round this run already joined
  let failedRound = 0; // never retry a round whose join failed (each attempt costs gas)

  // Total of the first deposit in `round` by a real player (0 if none seen yet).
  async function firstDeposit(round) {
    const r = await client.query({ query: `{events(filter:{type:"${CFG.origin || CFG.package}::game::Deployed"},last:50){nodes{contents{json}}}}` });
    const d = (r.data.events?.nodes || []).map(n => n.contents.json)
      .find(j => Number(j.round_id) === round && j.player !== me && !OURS.has(j.player));
    return d ? BigInt(d.total) : 0n;
  }

  // Called by the keeper with a fresh board. Returns true when it sent a transaction.
  async function tick(b) {
    const cur = Number(b.cur_id);
    if (b.cur_started !== true || Number(b.cur_players) < 1) return false;
    if (Date.now() > Number(b.cur_end_ms) - Number(b.freeze_ms) - LEAD_MS) return false;
    if (joined === cur || failedRound === cur) return false;
    const first = await firstDeposit(cur);
    if (!first) return false;

    const r = await client.query({
      query: `query($o:SuiAddress!,$t:String!){address(address:$o){balance(coinType:"0x2::sui::SUI"){totalBalance} objects(filter:{type:$t},first:1){nodes{address contents{json}}} gts:objects(filter:{type:"0x2::coin::Coin<${GTS}>"},first:50){nodes{address contents{json}}}}}`,
      variables: { o: me, t: MINER },
    });
    const a = r.data.address;
    const n = a?.objects?.nodes?.[0];
    const miner = n ? { id: n.address, round_id: Number(n.contents.json.round_id) } : null;
    if (miner?.round_id === cur) { joined = cur; return false; }
    const balance = BigInt(a?.balance?.totalBalance || 0);
    let total = first * MATCH_BPS / 10_000n;
    if (total < MIN) total = MIN;
    if (total > balance - KEEP) total = balance - KEEP;
    if (total < MIN) { failedRound = cur; log.push(`matcher low balance ${Number(balance) / 1e9} SUI`); return false; }

    const tile = Math.floor(Math.random() * 25);
    const tx = new Transaction();
    tx.setSender(me);
    const burn = (a?.gts?.nodes || []).filter(c => Number(c.contents.json.balance) > 0).map(c => tx.object(c.address));
    let m, fresh = false;
    if (miner) {
      m = tx.object(miner.id);
      if (miner.round_id !== 0 && miner.round_id < cur) {
        const [g, s] = tx.moveCall({ target: C("game::claim"), arguments: [tx.object(CFG.board), m, tx.object(CFG.treasury), tx.object.clock()] });
        tx.transferObjects([s], me);
        if (burn.length) burn.push(g); else tx.transferObjects([g], me); // a lone claim may be 0 GTS; burned next time
      }
    } else {
      [m] = tx.moveCall({ target: C("game::new_miner") });
      fresh = true;
    }
    if (burn.length) {
      // Burn every GTS it holds and put the SUI it redeems back into the reserve.
      if (burn.length > 1) tx.mergeCoins(burn[0], burn.slice(1));
      const out = tx.moveCall({ target: `${TOKEN}::gts::redeem`, arguments: [tx.object(CFG.treasury), burn[0]] });
      const bal = tx.moveCall({ target: "0x2::coin::into_balance", typeArguments: ["0x2::sui::SUI"], arguments: [out] });
      tx.moveCall({ target: `${TOKEN}::gts::vault_add`, arguments: [tx.object(CFG.treasury), bal] });
    }
    const [pay] = tx.splitCoins(tx.gas, [total]);
    tx.moveCall({ target: C("game::deploy"), arguments: [tx.object(CFG.board), m, pay, tx.pure.vector("u64", Array.from({ length: 25 }, (_, i) => (i === tile ? total : 0n))), tx.object.clock()] });
    if (fresh) tx.transferObjects([m], me);

    failedRound = cur; // cleared below on success; a throw also stops retries this round
    const res0 = await client.signAndExecuteTransaction({ transaction: tx, signer });
    const res = res0.Transaction || res0.FailedTransaction;
    log.push(`matcher join #${cur} ${Number(total) / 1e9} SUI ${res.status.success ? "ok" : "failed"} ${res.digest}`);
    await client.waitForTransaction({ digest: res.digest });
    if (res.status.success) { failedRound = 0; joined = cur; }
    return true;
  }

  return { tick };
}
