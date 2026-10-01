// The draw, shared by the keeper, the Runner and the Player.
// game::settle_v3 is the draw every bot uses: before it draws the winner it runs the market step on the
// Cetus GTS/SUI pool with the SUI saved by earlier rounds (liquidity add, buyback and burn, inside the
// contract, at most 2% above the reference price), and it pays the draw reward (up to 0.008 SUI). A
// paused pool is skipped inside the contract. If Cetus has moved to a version the game is not linked
// to, settle_v3 aborts; the bot then uses the plain draw game::settle_v2, which touches no market, so
// rounds never get stuck (it pays up to 0.004 SUI once the market has been down for 6 hours).
import { Transaction } from "@mysten/sui/transactions";

const CETUS_CONFIG = { objectId: "0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f", initialSharedVersion: 1574190, mutable: false };
export const MARKET_POOL = { objectId: "0x0628902c5acd5b5755c9b1a6494e925d0c5327177486b5e3b25d0e9b0211de71", initialSharedVersion: 1026864682, mutable: true };
// Fixed budgets (unused gas is refunded): the dry run usually takes the no-jackpot path, and a round that
// pays the Wealth Fund needs more. The market draw also swaps and adds liquidity.
export const DRAW_GAS = 50_000_000;
export const PLAIN_DRAW_GAS = 20_000_000;

const boardArg = (tx, CFG) => tx.sharedObjectRef({ objectId: CFG.board, initialSharedVersion: 1, mutable: true });
const treasuryArg = (tx, CFG) => tx.sharedObjectRef({ objectId: CFG.treasury, initialSharedVersion: CFG.treasuryIsv, mutable: true });
export const cetusConfigArg = tx => tx.sharedObjectRef(CETUS_CONFIG);
export const marketPoolArg = tx => tx.sharedObjectRef(MARKET_POOL);

// Add the draw to `tx`: the market draw, or the plain one.
export function drawCall(tx, CFG, market) {
  tx.setGasBudget(market ? DRAW_GAS : PLAIN_DRAW_GAS);
  if (market) {
    tx.moveCall({ target: `${CFG.package}::game::settle_v3`, arguments: [boardArg(tx, CFG), cetusConfigArg(tx), marketPoolArg(tx),
      treasuryArg(tx, CFG), tx.object.random(), tx.object.clock()] });
  } else {
    tx.moveCall({ target: `${CFG.package}::game::settle_v2`, arguments: [boardArg(tx, CFG), tx.object.random(), tx.object.clock()] });
  }
}

// Whether the market draw would go through right now (a simulation, nothing is signed). False sends the
// caller to the plain draw. `why` is filled with the reason when it would not.
export async function marketDrawOk(client, CFG, sender, why = {}) {
  const tx = new Transaction();
  tx.setSender(sender);
  drawCall(tx, CFG, true);
  try {
    const r = await client.simulateTransaction({ transaction: tx });
    const res = r.Transaction || r.FailedTransaction;
    if (res?.status?.success) return true;
    why.msg = res?.status?.error?.message || JSON.stringify(res?.status || {});
  } catch (e) {
    why.msg = String(e.message || e);
  }
  // The round not ended yet (clock a moment behind) or already drawn: not a market problem, try again later.
  why.retry = /abort code: (8|9)\b|, (8|9)\)/.test(why.msg || "") && /game/.test(why.msg || "");
  return false;
}
