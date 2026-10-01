/// GTStar game (relaunch): a 5x5 grid, 60s rounds, on Sui.
///
/// Rounds: players deploy SUI onto squares, one winning square is drawn with `sui::random`, and the
/// losing pot pays: creator DEV_BPS (1%, fixed), buyback and burn BUYBACK_BPS (3%, fixed), liquidity LIQ_BPS
/// (2%, fixed), stakers `stake_bps`, Wealth Fund `fund_bps` (every round, see `set_fund_bps`), and the rest to the winners by their stake on
/// the winning square. From v10 a winner keeps their whole share (rounds settled by v9 kept only the
/// part matching the part of their round deposit on the winning square, the fair split). A player may
/// deposit on at most `max_tiles` squares a round (5; see `set_max_tiles`). With no one on the winning
/// square the whole rest goes to the Wealth Fund. Every round
/// has a 1 in `ml_odds` chance to pay the whole Wealth Fund to one ticket, drawn by weight. Tickets:
/// every mist of fee a player paid (creator + buyback + liquidity + stakers + Wealth Fund, on the SUI lost)
/// since the last payout is one ticket, added when the round is claimed. House bots get no tickets.
/// Tickets reset after each payout.
///
/// No reserve from v9: GTS cannot be redeemed for SUI, the reserve share (`vault_bps`) is 0 and must
/// stay 0, and the SUI that was in the reserve moved to the Wealth Fund once (`reserve_to_fund`).
///
/// Emission, by rounds played (not by time): each settled round mints `reward` GTS (1 GTS at launch),
/// shared by everyone in the round by SUI deployed, win or lose; the full reward needs
/// `full_reward_deploy` SUI in the round, less scales it down, so with 1 GTS per 1 SUI a player mines
/// exactly the SUI they deployed while the round holds at most 1 SUI. (Rounds 21-30 were shared by SUI
/// lost and capped by the old floor.) Every `step_rounds` settled rounds (15,658) the reward drops by
/// `decay_ppm` (1.425%). Mining stops for good once 1,000,000 GTS have been assigned to rounds.
/// No staker or other mint: the round reward is the only source of GTS.
///
/// Mined GTS waits in the player's unrefined balance, for house bots too (v18). Withdrawing it is free
/// once the player's 7-day clock has run out; before that the fee falls linearly from `refine_fee_bps`
/// to 0 over the 7 days. The clock is one per player, weighted by amount (v18): GTS mined now starts its
/// own 7 days, and the player's clock moves to the average of the GTS already held and the new GTS, by
/// their amounts (5 GTS with 3 days left plus 1 new GTS: 3.67 days left for all 6). GTS held longer than
/// 7 days counts as 7 days. A withdrawal takes the whole balance, so the next GTS starts a new clock.
/// (Before v18 new GTS joined the running clock as it was, so a small old balance could free a large new
/// one at once.) From v16 half the fee GTS is burned and half is shared by everyone still holding
/// unrefined GTS, by their unrefined amount (paid when they withdraw); with no one else holding, all of
/// it is burned. (v6 to v15 burned all of it.)
///
/// The market (v18): the buyback and the liquidity add run inside the draw `settle_v3`, straight on the
/// Cetus GTS/SUI pool `MARKET_POOL`, with no keeper and no privileged address: `buyback_take`,
/// `liquidity_take` and their receipts are closed. A draw's buys may lift the pool price at most 2% above
/// a reference price (the pool price after the last market step, itself rising at most 2% a draw), so
/// pushing the price up just before a draw does not make the game buy higher; what the limit leaves
/// unspent stays saved for the next draw. A paused pool is skipped, not an abort. If Cetus has moved to
/// a version this package is not linked to, `settle_v3` aborts; the plain draw `settle_v2` stays open for
/// that and runs no market step.
///
/// If the market stops (v19): the game keeps the time a market draw last found the market usable (the
/// Cetus link current, the pool taking swaps and liquidity; a draw that only skipped a paused pool does
/// not count). `settle_v2` pays no draw reward while the market works, so nobody gains by choosing it;
/// after 6 hours without a usable market it pays up to 0.004 SUI, so rounds keep being drawn by anyone.
/// After 7 days without one, the SUI saved for the buyback and for liquidity moves to the Wealth Fund
/// and so do those two shares of every round (`MarketToFund`), until a market draw finds the market
/// usable again. So the game needs no one to keep running and no SUI can get stuck, even if Cetus stops
/// for good and the game can no longer be upgraded.
///
/// Buyback and burn: 3% of every losing pot (v16; 1% in v14-v15, 2% in v11-v13) and 1% of every Auto
/// Mine deposit are saved in the game. Once 0.005 SUI is saved, the draw spends it on GTS and burns the
/// GTS for good in the same transaction, together with any GTS left from liquidity. `BuybackDone` shows
/// the SUI spent and the GTS burned. (v12 to v15 paid the GTS bought to the stakers instead; GTS already
/// credited to stakers stays claimable with `claim_gts`.)
///
/// Liquidity: 2% of every losing pot (v16; 3% in v14-v15, 1% before) is saved in the game. Once 0.05 SUI
/// is saved, the draw buys GTS with 49% of it and adds the GTS with the matching SUI to a Cetus position
/// locked in the game (`LiquidityAdded`). SUI not used stays saved, GTS not used is burned with the next
/// buyback. The positions (20, opened by the keeper before v18) are stored in the game for good: no
/// function can take one out or remove its liquidity. `compound_fees`, open to anyone, collects the
/// trading fees they earn and adds them back to the pool the same way, only while the pool price is
/// within 2% of the draws' reference price (v19).
///
/// Supply lock (v15): `lock_supply` moved the GTS TreasuryCap into `supply_lock::capped`, a separate
/// package made immutable, and deleted the old Treasury. GTS can only be minted through its
/// `CappedTreasury`, and never past 1,000,000 in total: no upgrade of this game, and no one (the owner
/// included), can change that limit.
///
/// Daily mint limit (v16): `limit_mint_rate` sealed the `MinterCap` in `mint_limit::daily`, another
/// package made immutable. GTS can only be minted through that `DailyLimiter`, at most 2,000 GTS per UTC
/// day (by the on-chain clock), and no upgrade of this game can change or bypass that. A claim never
/// fails over it (v18): the SUI is paid, and GTS that does not fit under the day's limit is recorded as
/// owed to the player (`GtsOwed`) and minted to their unrefined balance once there is room, by their
/// next claim or by `claim_owed`, which only they can call (v19). The emission settings can still be
/// lowered (a longer curve), never raised past 2,000 GTS a day in effect.
///
/// Auto Mine (v17): a player may keep SUI in the `auto_vault` package (immutable, so nobody can pause or
/// block a withdrawal) with a plan: a strategy, an amount per round, a number of rounds. `auto_run`, which
/// anyone may call (the keeper does, every round), then plays the round for them: it takes the player's
/// per-round amount from the vault, pays 1% of it to the caller and 1% to the buyback and burn, and deploys
/// the rest for the player exactly like `deploy` (same mining, same payout, same tickets, in the player's
/// name). Spread: 5 random tiles. Sniper: 1 random tile. Hunter: the 5 tiles holding the least SUI, only in
/// the last 10 seconds before deposits close. The round is claimed by the next `auto_run`: SUI won goes
/// back to the player's vault balance, mined GTS to their unrefined balance (owed if the day's mint limit is full). Wealth Fund tickets of
/// automatic rounds are added to the draw every 10 claims (at once when that costs no new storage, and
/// when the plan has no round left to play). At least 0.05 SUI a round. A pause stops automatic deposits too.
///
/// The owner holds the AdminCap (settings change at once, each fee within its own cap) and the
/// UpgradeCap. `renounce` destroys the AdminCap for good. Fixed: the creator fee (1%), the 1,000,000
/// cap (enforced by the immutable supply lock from v15), at most 2,000 GTS minted per UTC day (immutable
/// daily mint limit from v16), the buyback and burn (3%), the liquidity share (2%), emission that can only
/// go down (v16: `set_emission` can lower the reward, never raise it or slow its decay), and no address can be blocked from playing, claiming or withdrawing. A pause only stops new
/// deposits.
#[allow(lint(self_transfer))]
module gtstar::game;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::dynamic_object_field as dof;
use sui::event;
use sui::random::{Self, Random, RandomGenerator};
use sui::sui::SUI;
use sui::table::{Self, Table};
use gtstar::gts::{Self, Treasury, GTS};
use gtstar::staking::{Self, Pool as StakePool, Schedule};
use supply_lock::capped::{Self, CappedTreasury, MinterCap};
use mint_limit::daily::{Self, DailyLimiter};
use auto_vault::vault::{Self, Vault, PullCap};
use cetus_clmm::config::{Self as cetus_config, GlobalConfig};
use cetus_clmm::pool::{Self as cetus_pool, Pool as CetusPool};
use cetus_clmm::position::{Self as cetus_position, Position};
use cetus_clmm::tick_math;

// ===== Constants =====
const GRID: u64 = 25;
const PPM: u64 = 1_000_000;

// Emission at launch (see `set_emission`).
const INITIAL_ROUND_REWARD: u64 = 1_000_000_000; // 1 GTS
const DEFAULT_STEP_ROUNDS: u64 = 15_658;
const DEFAULT_DECAY_PPM: u64 = 14_250;           // 1.425%
const DEFAULT_FULL_REWARD_DEPLOY: u64 = 1_000_000_000; // full reward from 1 SUI in the round

/// Creator fee: 1% of the losing pot, fixed, paid only to DEV_ADDR.
const DEV_BPS: u64 = 100;
const DEV_ADDR: address = @0xa19b2d37f95ca4c48efafb2cd01d0f97f33852457daa27cfba3de37fdec24d4b;

/// Buyback and burn: 3% of the losing pot, fixed (v16; 1% in v14-v15, 2% in v11-v13). The GTS bought is burned.
const BUYBACK_BPS: u64 = 300;
/// Liquidity: 2% of the losing pot, fixed (v16; 3% in v14-v15, 1% in v11-v13). Added to the Cetus GTS/SUI pool and locked in the game.
const LIQ_BPS: u64 = 200;

/// The market (v18): the Cetus GTS/SUI pool the draw buys back on and adds liquidity to. Fixed: no other
/// pool is accepted, so nobody can point the game at a pool they control.
const MARKET_POOL: address = @0x0628902c5acd5b5755c9b1a6494e925d0c5327177486b5e3b25d0e9b0211de71;
/// A draw's buys may lift the pool price at most 2% above the reference price (see `market_step`).
/// Cetus prices are square roots: sqrt(1.02) = 1.009950, so this is 2% in price.
const PRICE_CAP_NUM: u128 = 1_009_950;
const PRICE_CAP_DEN: u128 = 1_000_000;
/// No buy with less than 0.05% of square-root price room left under the limit (it would buy dust).
const PRICE_ROOM_NUM: u128 = 1_000_500;
/// The buyback runs once this much SUI is saved (0.005), the liquidity add once this much is (0.05), so
/// the gas of a draw stays small next to what it buys. Smaller amounts wait for the next draws.
const MARKET_BUY_MIN: u64 = 5_000_000;
const MARKET_LIQ_MIN: u64 = 50_000_000;
/// Of the liquidity SUI, this part buys GTS; the GTS and the matching SUI then go into the pool.
const LIQ_BUY_PCT: u64 = 49;

// Default settings (see `set_params`).
const DEFAULT_VAULT_BPS: u64 = 0;          // no reserve (v9)
const DEFAULT_BUYBACK_BPS: u64 = 300;      // fixed (v16)
const DEFAULT_ML_ODDS: u64 = 1_000;        // Wealth Fund: 1 in 1000
const DEFAULT_ML_SHARE_BPS: u64 = 1_950;   // 19.5% of a no-winner round
const DEFAULT_REFINE_FEE_BPS: u64 = 1_000; // 10%

// Bounds.
const MIN_ODDS: u64 = 100;
const MAX_ODDS: u64 = 1_000_000;
const MAX_REFINE_FEE_BPS: u64 = 5_000;
// Each fee has its own cap (v5).
const MAX_STAKE_BPS: u64 = 500;      // stakers 5%
const MAX_FUND_BPS: u64 = 1_000;     // Wealth Fund, every round, 10%
const MAX_ML_SHARE_BPS: u64 = 3_000; // Wealth Fund, no-winner round, 30%
const MIN_MIN_DEPLOY: u64 = 500_000;        // 0.0005 SUI
const MAX_MIN_DEPLOY: u64 = 10_000_000_000; // 10 SUI
const MIN_ROUND_MS: u64 = 30_000;
const MAX_ROUND_MS: u64 = 3_600_000;
const MAX_ROUND_REWARD: u64 = 10_000_000_000; // 10 GTS
const MAX_DECAY_PPM: u64 = 500_000;
const MIN_FULL_REWARD_DEPLOY: u64 = 1_000_000;         // 0.001 SUI
const MAX_FULL_REWARD_DEPLOY: u64 = 1_000_000_000_000; // 1,000 SUI

/// House bots: no Wealth Fund tickets. Nothing else sets them apart (v18): their mined GTS goes to the
/// unrefined balance under the same 7-day clock and withdraw fee as every player's.
const HOUSE_ADDR: address = @0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a;
const BOT1_ADDR: address = @0xab4deb30e34487f75bf5632038e46d419c6238b4ea52d35f3ad3421a5bb268fa;
const BOT2_ADDR: address = @0x779b49acf4db04d835440c12ffe24929de505a9b8112b4040da5103d225b37e7;
const BOT3_ADDR: address = @0x0b8d118f954c90a87abc2b3e07c408681efed88b552ebcd94fc5cb292f3c9dc4;
const MATCHER_ADDR: address = @0x2a869532f55594a9ffed4a5d7ee2a48cf5c857ac740090d39c733e0279b6a8de;
/// Shield bot: no Wealth Fund tickets either.
const SHIELD_ADDR: address = @0xadf4446b0340e1b8d4c0abde15da3381db54057a1e4bda533cc3c8ca1abbc077;

/// Draw reward (v19): whoever draws a round with `settle_v3` (the draw that also runs the market) is
/// paid up to this much SUI (0.008, about the gas of a draw) out of the round's Wealth Fund share, and
/// only out of it: the buyback, the liquidity share, the stakers and the creator are never touched.
/// (v13 to v18: up to 0.005 SUI, from the Wealth Fund share and then the liquidity share.)
const DRAW_REWARD_MAX: u64 = 8_000_000;
/// The plain draw `settle_v2` pays nothing while the market works, so nobody gains by picking it over
/// `settle_v3`. Once the market has not been usable in a draw for 6 hours it pays up to 0.004 SUI, the
/// same way, so rounds keep being drawn; half the market draw's reward, so `settle_v3` still pays better
/// whenever it can run.
const PLAIN_DRAW_REWARD_MAX: u64 = 4_000_000;
const PLAIN_DRAW_AFTER_MS: u64 = 21_600_000;
/// Once the market has not been usable in a draw for 7 days, the SUI saved for the buyback and for
/// liquidity moves to the Wealth Fund, and so do those two shares of every round, until a market draw
/// finds the market usable again. So no SUI is ever stuck in the game if Cetus stops for good.
const MARKET_DEAD_MS: u64 = 604_800_000;

/// Daily mint limit (v16): at most 2,000 GTS minted per UTC day, sealed in the immutable `mint_limit` package.
const DAILY_MINT_MAX: u64 = 2_000_000_000_000;

/// Precision of the per-GTS withdraw-fee accumulator.
const REFINE_SCALE: u256 = 1_000_000_000_000_000_000;

/// v6: the withdraw fee falls to 0 over this long after the last withdrawal (7 days).
const REFINE_WINDOW_MS: u64 = 604_800_000;

/// Auto Mine (v17): of every automatic deposit, 1% to whoever runs it and 1% to the buyback and burn.
const AUTO_KEEPER_BPS: u64 = 100;
const AUTO_BUYBACK_BPS: u64 = 100;
/// Least SUI a plan may spend per round (0.05).
const AUTO_MIN_ROUND: u64 = 50_000_000;
/// Hunter only deploys this long before deposits close.
const AUTO_HUNT_MS: u64 = 10_000;
/// Wealth Fund tickets of automatic rounds are added to the draw at the latest every this many claims.
const AUTO_TICKET_BATCH: u64 = 10;
const AUTO_SNIPER: u8 = 1;
const AUTO_HUNTER: u8 = 2; // 0 is Spread
const AUTO_SPREAD_TILES: u64 = 5;

/// Package version: only the latest version may change the Board. Bump it on every upgrade.
const VERSION: u64 = 20;

// ===== Errors =====
const EBadLen: u64 = 1;
const ERoundEnded: u64 = 2;
const EFrozen: u64 = 3;
const EUnclaimed: u64 = 4;
const ENothingDeployed: u64 = 5;
const EBelowMin: u64 = 6;
const EAmountMismatch: u64 = 7;
const ERoundNotEnded: u64 = 8;
const ENotStarted: u64 = 9;
const ENothingToClaim: u64 = 10;
const ENotSettled: u64 = 11;
const EWrongVersion: u64 = 14;
const EOneMinerPerRound: u64 = 15;
const EBadParams: u64 = 18;
const EPaused: u64 = 19;
const ENothingToWithdraw: u64 = 20;
const ENoStaking: u64 = 22;
const EBuybackOff: u64 = 23;
const EUseWithdrawV6: u64 = 24;
const ENoReserve: u64 = 28;
const ETooManyTiles: u64 = 29;
const EUseBuybackKeep: u64 = 30;
const EUseLockedSupply: u64 = 33;
const EUseClaimV3: u64 = 34;
const EUseBuybackBurn: u64 = 35;
const EEmissionUp: u64 = 36;
const EAutoInstalled: u64 = 37;
const ENoAuto: u64 = 38;
const EInDraw: u64 = 39;
const EWrongPool: u64 = 40;
const ENotYours: u64 = 41;

/// Archived, settled round.
public struct RoundInfo has store {
    total_deployed: u64,
    deployed: vector<u64>,
    winning_square: u8,
    losing_pot_after_fee: u64,
    winners_total: u64,
    round_reward: u64,
    rng: u64,
}

/// The game board (shared).
public struct Board has key {
    id: UID,
    version: u64,
    cur_id: u64,
    cur_started: bool,
    cur_start_ms: u64,
    cur_end_ms: u64,
    cur_total: u64,
    cur_deployed: vector<u64>,
    cur_players: u64,
    rounds: Table<u64, RoundInfo>,
    pot: Balance<SUI>,
    dev_fees: Balance<SUI>,
    buyback: Balance<SUI>,
    motherlode: Balance<SUI>,
    /// All unrefined GTS; `unrefined_total` of it belongs to players, the rest is their fee bonus.
    unrefined: Balance<GTS>,
    unrefined_total: u64,
    /// Fee GTS earned per unrefined GTS so far, scaled by REFINE_SCALE.
    acc: u256,
    // emission
    reward: u64,          // full GTS reward of a round in the current step
    step_rounds: u64,     // settled rounds per step
    decay_ppm: u64,       // reward cut at the end of each step
    step_count: u64,      // settled rounds so far in the current step
    full_reward_deploy: u64,
    committed: u64,       // GTS assigned to settled rounds so far (never above the cap)
    // settings
    round_ms: u64,
    freeze_ms: u64,
    min_deploy: u64,
    vault_bps: u64,
    buyback_bps: u64,
    ml_odds: u64,
    ml_share_bps: u64,
    refine_fee_bps: u64,
    paused: bool,
}

/// Dynamic field on the Board: SUI a round received from the Wealth Fund (only rounds that hit).
public struct JackpotKey has copy, drop, store { round_id: u64 }
/// Dynamic field on the Board: the Miner `player` uses in `round_id` (one per address and round).
public struct SeatKey has copy, drop, store { round_id: u64, player: address }
/// Dynamic field on the Board: players of a settled round who have not claimed yet. When the last one
/// claims, the round's RoundInfo is removed (its storage deposit is refunded to that claimer).
/// Rounds settled before this field existed keep their RoundInfo.
public struct RoundLeftKey has copy, drop, store { round_id: u64 }
/// Dynamic field on the Board: one player's unrefined balance. Removed when it is withdrawn.
public struct UnrefinedKey has copy, drop, store { player: address }
public struct Unrefined has store, drop { amount: u64, bonus: u64, snap: u256 }

/// Dynamic field on the Board: the Wealth Fund tickets of the current draw (`epoch`, bumped on payout).
/// Entries `TicketKey { epoch, i }` hold cumulative ranges: entry i owns tickets [end(i-1), end(i)).
public struct TicketsKey has copy, drop, store {}
public struct Tickets has store { epoch: u64, total: u64, count: u64 }
public struct TicketKey has copy, drop, store { epoch: u64, i: u64 }
public struct TicketEntry has store, drop { player: address, end: u64 }
/// Dynamic field on the Board: one player's tickets in `epoch` (for display).
public struct PlayerTicketsKey has copy, drop, store { epoch: u64, player: address }

/// Dynamic field on the Board: the Wealth Fund's share of every round's losing pot, in bps.
public struct FundBpsKey has copy, drop, store {}

/// Dynamic field on the Board: the first round settled by v5 (rounds 21-30: GTS by SUI lost, floor cap,
/// no fair split).
public struct V5FromKey has copy, drop, store {}
/// Dynamic field on the Board: the first round settled by v8 (GTS by SUI deployed again, no floor cap).
public struct V8FromKey has copy, drop, store {}
/// Dynamic field on the Board: the first round settled by v9 (fair split back, no reserve).
public struct V9FromKey has copy, drop, store {}
/// Dynamic field on the Board: the first round settled by v10 (no fair split: winners keep it all).
public struct V10FromKey has copy, drop, store {}
/// Dynamic field on the Board (v10): the most squares one player may deposit on in a round.
public struct MaxTilesKey has copy, drop, store {}

/// Dynamic field on the Board (v6): when `player`'s 7-day withdraw clock started (ms): their last
/// withdrawal, or when they first mined. Holders from before v6 without one use `RefineFromKey`.
public struct RefineClockKey has copy, drop, store { player: address }
/// Dynamic field on the Board (v6): time of the first round settled by v6 (ms).
public struct RefineFromKey has copy, drop, store {}

/// Dynamic field on the Board (v11): SUI saved for liquidity, waiting for a draw.
public struct LiquidityKey has copy, drop, store {}
/// Dynamic field on the Board (v11): GTS left from liquidity adds, burned with the next buyback (v16).
public struct BoughtKey has copy, drop, store {}
/// Dynamic object fields on the Board (v11): the Cetus positions locked for good, `i` from 0.
public struct LpKey has copy, drop, store { i: u64 }
/// Dynamic field on the Board (v11): how many positions are locked.
public struct LpCountKey has copy, drop, store {}

/// Dynamic field on the Board (v12): the GTS paid to stakers, split by stake weight.
public struct GtsYieldKey has copy, drop, store {}
public struct GtsYield has store { rewards: Balance<GTS>, acc: u256, paid_total: u64 }
/// Dynamic field on the Board (v12): one staking position's GTS yield. A position staked before v12 has
/// none until it is touched, which is right: `acc` was 0 then.
public struct GtsPosKey has copy, drop, store { player: address, locked: bool }
public struct GtsPos has store, drop { snap: u256, pending: u64 }

/// Dynamic fields on the Board: the staking pool, and the stakers' share of the losing pot in bps.
public struct StakeKey has copy, drop, store {}
public struct StakeBpsKey has copy, drop, store {}

/// Dynamic field on the Board (v20): the staking `Schedule` (stake warming up, and the queues of
/// warm-ups and locks the draw works through).
public struct ScheduleKey has copy, drop, store {}
/// Most staking queue entries one draw works through.
const STAKE_DUE_PER_DRAW: u64 = 20;

/// Dynamic field on the Board (v15): the `MinterCap` of the immutable supply lock.
public struct MinterKey has copy, drop, store {}

/// Dynamic object field on the Board (v16): the `DailyLimiter` holding the MinterCap for good.
public struct LimiterKey has copy, drop, store {}

/// Dynamic field on the Board (v18): GTS `player` mined that did not fit under the day's mint limit.
/// It is minted to their unrefined balance once there is room again (`claim_owed`, or their next claim).
public struct OwedKey has copy, drop, store { player: address }
/// Dynamic field on the Board (v18): the reference price (a Cetus square-root price) the 2% limit of a
/// draw's buys is measured from: the pool price at the end of the last market step, rising at most 2% a draw.
public struct PriceRefKey has copy, drop, store {}
/// Dynamic field on the Board (v19): when a market draw last found the market usable (ms): the game's
/// Cetus link current, and the pool taking swaps and liquidity. Starts at the first draw after v19.
public struct MarketAliveKey has copy, drop, store {}
/// Dynamic field on the Board, tests only: the pool that stands in for `MARKET_POOL`.
public struct TestPoolKey has copy, drop, store {}

/// Dynamic object field on the Board (v17): the `PullCap` of the immutable Auto Mine vault.
public struct AutoCapKey has copy, drop, store {}
/// Dynamic field on the Board (v17): one player's Auto Mine seat.
public struct AutoKey has copy, drop, store { player: address }
/// The Miner automatic rounds are played with, tickets not yet added to the Wealth Fund draw, and totals.
public struct AutoSeat has store {
    miner: Miner,
    tickets: u64,      // earned in `ticket_epoch`, not in the draw yet
    ticket_epoch: u64,
    claims: u64,       // claims since tickets were last added
    rounds: u64,       // automatic rounds played
    wins: u64,         // of them, rounds that paid SUI
    deployed: u64,     // SUI put on tiles
    fees: u64,         // SUI paid in Auto Mine fees (keeper + buyback)
    won: u64,          // SUI paid back by rounds
    mined: u64,        // GTS mined
}

/// Right to change the settings.
public struct AdminCap has key, store { id: UID }

/// Receipts of the keeper's buyback and liquidity add (before v18). None can be made any more: both
/// now run inside the draw, see `market_step`.
public struct BuybackReceipt { sui: u64 }
public struct LiquidityReceipt { sui: u64 }

/// Per-player miner (owned). Holds the current unclaimed round only.
public struct Miner has key, store {
    id: UID,
    round_id: u64,
    deployed: vector<u64>,
    total_deployed: u64,
}

// ===== Events =====
public struct ParamsChanged has copy, drop {
    ml_odds: u64,
    ml_share_bps: u64,
    vault_bps: u64,
    buyback_bps: u64,
    refine_fee_bps: u64,
    min_deploy: u64,
    round_ms: u64,
    freeze_ms: u64,
    paused: bool,
}

public struct EmissionChanged has copy, drop {
    reward: u64,
    step_rounds: u64,
    decay_ppm: u64,
    step_count: u64,
    full_reward_deploy: u64,
}

public struct Renounced has copy, drop {}

public struct RoundSettled has copy, drop {
    round_id: u64,
    winning_square: u8,
    total_deployed: u64,
    winners_total: u64,
    round_reward: u64,
    losing_pot: u64,
    winners_payout: u64,
    vault_fee: u64,
    buyback_fee: u64,
    dev_fee: u64,
    players: u64,
    committed: u64,
    next_reward: u64,
}

public struct MotherlodeUpdate has copy, drop { round_id: u64, added: u64, paid: u64, balance: u64 }
/// The Wealth Fund was paid to the holder of the drawn ticket.
public struct WealthFundWon has copy, drop { round_id: u64, epoch: u64, winner: address, amount: u64, winner_tickets: u64, total_tickets: u64 }
public struct TicketsAdded has copy, drop { round_id: u64, epoch: u64, player: address, tickets: u64, total: u64 }
public struct MotherlodeReturned has copy, drop { round_id: u64, amount: u64, balance: u64 }
public struct Forfeited has copy, drop { round_id: u64, player: address, to_reserve: u64, to_fund: u64 }
public struct GtsWithdrawn has copy, drop { player: address, amount: u64, fee: u64, bonus: u64, paid: u64, burned: u64 }
public struct Deployed has copy, drop { round_id: u64, player: address, amounts: vector<u64>, total: u64 }
/// `gts`: the GTS the player mined in the round (from v18 part of it may be owed, see `GtsOwed`).
public struct Claimed has copy, drop { round_id: u64, player: address, gts: u64, sui: u64 }
/// Buyback SUI taken by the owner (before v5; closed).
public struct BuybackTaken has copy, drop { amount: u64 }
/// GTS burned through `burn_bought`.
public struct BuybackBurned has copy, drop { amount: u64 }
/// Buyback SUI spent on GTS and the GTS burned for it (v7).
public struct BuybackDone has copy, drop { sui_spent: u64, gts_burned: u64 }
public struct StakingChanged has copy, drop { stake_bps: u64 }
public struct FundBpsChanged has copy, drop { fund_bps: u64 }
public struct MaxTilesChanged has copy, drop { max_tiles: u64 }
/// Buyback SUI spent on GTS, and the GTS kept in the game (v11). `gts_total`: all GTS kept so far.
public struct BuybackKept has copy, drop { sui_spent: u64, gts_kept: u64, gts_total: u64 }
/// GTS bought back and paid to stakers (v12).
public struct GtsYieldAdded has copy, drop { amount: u64, total_weight: u128 }
/// GTS yield claimed by a staker (v12).
public struct GtsYieldClaimed has copy, drop { player: address, gts: u64 }
/// Liquidity SUI added to the Cetus pool as a position locked in the game (v11).
public struct LiquidityLocked has copy, drop { sui_spent: u64, gts_left: u64, position: ID, positions: u64 }
/// SUI paid to whoever settled a round, out of its Wealth Fund share only (v19; before, the liquidity share made up a shortfall).
public struct DrawPaid has copy, drop { round_id: u64, settler: address, amount: u64 }
/// The GTS TreasuryCap was sealed in the immutable supply lock (v15, once).
public struct SupplyLocked has copy, drop { capped_treasury: ID, minted: u64, max: u64 }
/// Half of a withdraw fee shared by everyone still holding unrefined GTS (v16).
public struct WithdrawFeeShared has copy, drop { player: address, amount: u64, holders_total: u64 }
/// The MinterCap was sealed in the immutable daily mint limit (v16, once).
public struct MintRateLimited has copy, drop { limiter: ID, per_day: u64 }
/// The Auto Mine vault's PullCap was stored in the game (v17, once).
public struct AutoInstalled has copy, drop { cap: ID }
/// A player opened their Auto Mine seat (v17).
public struct AutoJoined has copy, drop { player: address }
/// One automatic deposit (v17): `spent` left the player's vault balance, `deployed` of it went on tiles
/// (see the `Deployed` event of the same transaction), the rest is the two fees.
public struct AutoMined has copy, drop { round_id: u64, player: address, strategy: u8, spent: u64, deployed: u64, keeper_fee: u64, buyback_fee: u64 }
/// An automatic round was claimed (v17): `sui` went back to the player's vault balance, `gts` to their unrefined balance.
public struct AutoClaimed has copy, drop { round_id: u64, player: address, sui: u64, gts: u64 }
/// Liquidity added to the Cetus pool by a draw, into a position locked in the game (v18): `sui_swapped`
/// bought the GTS, `gts_added` and `sui_added` went into `position`, `gts_left` waits to be burned.
public struct LiquidityAdded has copy, drop { sui_swapped: u64, sui_added: u64, gts_added: u64, gts_left: u64, position: ID }
/// Trading fees collected from the locked positions and added back to the pool (v18). What could not be
/// paired stays in the game: `sui_left` for the next liquidity add, `gts_left` burned with the next buyback.
public struct FeesCompounded has copy, drop { sui_fees: u64, gts_fees: u64, sui_added: u64, gts_added: u64, sui_left: u64, gts_left: u64 }
/// The market was not usable in a draw for 7 days (v19): `saved` SUI waiting for the buyback and for
/// liquidity moved to the Wealth Fund, and so did `share`, this round's buyback and liquidity shares.
public struct MarketToFund has copy, drop { round_id: u64, saved: u64, share: u64 }
/// The reference price after a draw's market step (v18), a Cetus square-root price.
public struct PriceRefSet has copy, drop { sqrt_price: u128 }
/// GTS a player mined that did not fit under the day's mint limit (v18): `owed` is their whole debt now.
public struct GtsOwed has copy, drop { round_id: u64, player: address, amount: u64, owed: u64 }
/// Owed GTS minted to the player's unrefined balance (v18): `owed` is what is still owed.
public struct OwedPaid has copy, drop { player: address, amount: u64, owed: u64 }
/// The SUI of the old reserve moved to the Wealth Fund (v9, once).
public struct ReserveToFund has copy, drop { amount: u64, balance: u64 }

fun init(ctx: &mut TxContext) {
    transfer::share_object(Board {
        id: object::new(ctx),
        version: VERSION,
        cur_id: 1,
        cur_started: false,
        cur_start_ms: 0,
        cur_end_ms: 0,
        cur_total: 0,
        cur_deployed: zeros(),
        cur_players: 0,
        rounds: table::new<u64, RoundInfo>(ctx),
        pot: balance::zero<SUI>(),
        dev_fees: balance::zero<SUI>(),
        buyback: balance::zero<SUI>(),
        motherlode: balance::zero<SUI>(),
        unrefined: balance::zero<GTS>(),
        unrefined_total: 0,
        acc: 0,
        reward: INITIAL_ROUND_REWARD,
        step_rounds: DEFAULT_STEP_ROUNDS,
        decay_ppm: DEFAULT_DECAY_PPM,
        step_count: 0,
        full_reward_deploy: DEFAULT_FULL_REWARD_DEPLOY,
        committed: 0,
        round_ms: 60_000,
        freeze_ms: 5_000,
        min_deploy: 10_000_000, // 0.01 SUI
        vault_bps: DEFAULT_VAULT_BPS,
        buyback_bps: DEFAULT_BUYBACK_BPS,
        ml_odds: DEFAULT_ML_ODDS,
        ml_share_bps: DEFAULT_ML_SHARE_BPS,
        refine_fee_bps: DEFAULT_REFINE_FEE_BPS,
        paused: false,
    });
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, tx_context::sender(ctx));
}

fun zeros(): vector<u64> {
    let mut v = vector[];
    let mut i = 0;
    while (i < GRID) { vector::push_back(&mut v, 0); i = i + 1; };
    v
}

fun mul_div(a: u64, b: u64, c: u64): u64 { (((a as u128) * (b as u128)) / (c as u128)) as u64 }

fun check_version(board: &mut Board) {
    assert!(board.version <= VERSION, EWrongVersion);
    board.version = VERSION;
}

fun is_bot(a: address): bool {
    a == HOUSE_ADDR || a == BOT1_ADDR || a == BOT2_ADDR || a == BOT3_ADDR || a == MATCHER_ADDR
}

/// No Wealth Fund tickets for house bots.
fun no_tickets(a: address): bool { is_bot(a) || a == SHIELD_ADDR }

/// Fees taken from the losing pot, in bps: creator + buyback + liquidity + stakers + Wealth Fund (+ reserve, 0).
fun fee_bps(board: &Board): u64 { DEV_BPS + board.vault_bps + BUYBACK_BPS + LIQ_BPS + stake_bps(board) + fund_bps(board) }

fun liquidity_mut(board: &mut Board): &mut Balance<SUI> {
    if (!df::exists(&board.id, LiquidityKey {})) { df::add(&mut board.id, LiquidityKey {}, balance::zero<SUI>()) };
    df::borrow_mut<LiquidityKey, Balance<SUI>>(&mut board.id, LiquidityKey {})
}

fun bought_mut(board: &mut Board): &mut Balance<GTS> {
    if (!df::exists(&board.id, BoughtKey {})) { df::add(&mut board.id, BoughtKey {}, balance::zero<GTS>()) };
    df::borrow_mut<BoughtKey, Balance<GTS>>(&mut board.id, BoughtKey {})
}

fun tickets_mut(board: &mut Board): &mut Tickets {
    if (!df::exists(&board.id, TicketsKey {})) {
        df::add(&mut board.id, TicketsKey {}, Tickets { epoch: 0, total: 0, count: 0 });
    };
    df::borrow_mut<TicketsKey, Tickets>(&mut board.id, TicketsKey {})
}

/// Add `n` tickets for `player` in the current draw (merged into the last range if it is theirs).
fun add_tickets(board: &mut Board, round_id: u64, player: address, n: u64) {
    let t = tickets_mut(board);
    let (epoch, count) = (t.epoch, t.count);
    t.total = t.total + n;
    let total = t.total;
    let merge = count > 0 && df::borrow<TicketKey, TicketEntry>(&board.id, TicketKey { epoch, i: count - 1 }).player == player;
    if (merge) {
        df::borrow_mut<TicketKey, TicketEntry>(&mut board.id, TicketKey { epoch, i: count - 1 }).end = total;
    } else {
        df::add(&mut board.id, TicketKey { epoch, i: count }, TicketEntry { player, end: total });
        tickets_mut(board).count = count + 1;
    };
    let pk = PlayerTicketsKey { epoch, player };
    if (df::exists(&board.id, pk)) { let v = df::borrow_mut<PlayerTicketsKey, u64>(&mut board.id, pk); *v = *v + n; }
    else { df::add(&mut board.id, pk, n); };
    event::emit(TicketsAdded { round_id, epoch, player, tickets: n, total });
}

/// Holder of ticket number `r` (< total) of the current draw: binary search over the ranges.
fun ticket_holder(board: &Board, epoch: u64, count: u64, r: u64): address {
    let (mut lo, mut hi) = (0, count - 1);
    while (lo < hi) {
        let mid = (lo + hi) / 2;
        if (df::borrow<TicketKey, TicketEntry>(&board.id, TicketKey { epoch, i: mid }).end > r) { hi = mid } else { lo = mid + 1 };
    };
    df::borrow<TicketKey, TicketEntry>(&board.id, TicketKey { epoch, i: lo }).player
}

/// Full reward of the next settled round: the step reward, never past the cap.
fun next_full_reward(board: &Board): u64 {
    let room = gts::max_supply() - board.committed;
    if (board.reward < room) { board.reward } else { room }
}

/// First round under the v5 rules (u64 max until v5 settles its first round).
fun v5_from(board: &Board): u64 {
    if (df::exists(&board.id, V5FromKey {})) { *df::borrow<V5FromKey, u64>(&board.id, V5FromKey {}) } else { 18_446_744_073_709_551_615 }
}

/// First round under the v9 rules (u64 max until v9 settles its first round).
fun v9_from(board: &Board): u64 {
    if (df::exists(&board.id, V9FromKey {})) { *df::borrow<V9FromKey, u64>(&board.id, V9FromKey {}) } else { 18_446_744_073_709_551_615 }
}

/// First round under the v10 rules (u64 max until v10 settles its first round).
fun v10_from(board: &Board): u64 {
    if (df::exists(&board.id, V10FromKey {})) { *df::borrow<V10FromKey, u64>(&board.id, V10FromKey {}) } else { 18_446_744_073_709_551_615 }
}

/// First round under the v8 GTS rules (u64 max until v8 settles its first round).
fun v8_from(board: &Board): u64 {
    if (df::exists(&board.id, V8FromKey {})) { *df::borrow<V8FromKey, u64>(&board.id, V8FromKey {}) } else { 18_446_744_073_709_551_615 }
}

// ===== Admin =====

/// Change the settings at once. Fee changes apply from the next settle. `buyback_bps` must be 300 (fixed).
public fun set_params(
    _: &AdminCap,
    board: &mut Board,
    ml_odds: u64,
    ml_share_bps: u64,
    vault_bps: u64,
    buyback_bps: u64,
    refine_fee_bps: u64,
    min_deploy: u64,
    round_ms: u64,
    freeze_ms: u64,
    paused: bool,
) {
    check_version(board);
    assert!(ml_odds >= MIN_ODDS && ml_odds <= MAX_ODDS, EBadParams);
    assert!(buyback_bps == BUYBACK_BPS, EBadParams); // fixed (v11)
    assert!(vault_bps == 0, ENoReserve);
    assert!(ml_share_bps <= MAX_ML_SHARE_BPS, EBadParams);
    assert!(DEV_BPS + vault_bps + BUYBACK_BPS + LIQ_BPS + ml_share_bps + stake_bps(board) + fund_bps(board) <= 10_000, EBadParams);
    assert!(refine_fee_bps <= MAX_REFINE_FEE_BPS, EBadParams);
    assert!(min_deploy >= MIN_MIN_DEPLOY && min_deploy <= MAX_MIN_DEPLOY, EBadParams);
    assert!(round_ms >= MIN_ROUND_MS && round_ms <= MAX_ROUND_MS && freeze_ms <= round_ms / 2, EBadParams);
    board.ml_odds = ml_odds;
    board.ml_share_bps = ml_share_bps;
    board.vault_bps = vault_bps;
    board.buyback_bps = buyback_bps;
    board.refine_fee_bps = refine_fee_bps;
    board.min_deploy = min_deploy;
    board.round_ms = round_ms;
    board.freeze_ms = freeze_ms;
    board.paused = paused;
    event::emit(ParamsChanged { ml_odds, ml_share_bps, vault_bps, buyback_bps, refine_fee_bps, min_deploy, round_ms, freeze_ms, paused });
}

/// Lower the emission, from the next settle (v16: only down). The reward per round can only fall, the cut
/// per step can only grow, steps can only get shorter, and the step can only move forward; the SUI needed
/// for the full reward can only grow. So the reward of every future round stays at or below the current
/// schedule. The 1,000,000 cap and the 2,000 GTS a day limit cannot change.
public fun set_emission(
    _: &AdminCap,
    board: &mut Board,
    reward: u64,
    step_rounds: u64,
    decay_ppm: u64,
    step_count: u64,
    full_reward_deploy: u64,
) {
    check_version(board);
    assert!(reward <= MAX_ROUND_REWARD, EBadParams);
    assert!(step_rounds >= 1 && step_count < step_rounds, EBadParams);
    assert!(decay_ppm <= MAX_DECAY_PPM, EBadParams);
    assert!(full_reward_deploy >= MIN_FULL_REWARD_DEPLOY && full_reward_deploy <= MAX_FULL_REWARD_DEPLOY, EBadParams);
    assert!(reward <= board.reward && decay_ppm >= board.decay_ppm && step_rounds <= board.step_rounds, EEmissionUp);
    assert!(step_count >= board.step_count && full_reward_deploy >= board.full_reward_deploy, EEmissionUp);
    board.reward = reward;
    board.step_rounds = step_rounds;
    board.decay_ppm = decay_ppm;
    board.step_count = step_count;
    board.full_reward_deploy = full_reward_deploy;
    event::emit(EmissionChanged { reward, step_rounds, decay_ppm, step_count, full_reward_deploy });
}

/// Give up the AdminCap for good: settings are frozen as they are. The buyback and the liquidity share
/// are fixed and keep running (v11).
public fun renounce(cap: AdminCap, _board: &Board) {
    let AdminCap { id } = cap;
    object::delete(id);
    event::emit(Renounced {});
}

/// Move all SUI of the old reserve into the Wealth Fund (v9, once: the reserve is then empty for good).
public fun reserve_to_fund(_: &AdminCap, board: &mut Board, treasury: &mut Treasury) {
    check_version(board);
    let b = gts::vault_take_all(treasury);
    let amount = balance::value(&b);
    balance::join(&mut board.motherlode, b);
    event::emit(ReserveToFund { amount, balance: balance::value(&board.motherlode) });
}

/// Seal the GTS TreasuryCap in the immutable supply lock for good (v15, once). The old Treasury is deleted,
/// so from here GTS can only be minted through the `CappedTreasury`, never past 1,000,000 in total.
public fun lock_supply(_: &AdminCap, board: &mut Board, treasury: Treasury, ctx: &mut TxContext) {
    check_version(board);
    let (cap, minted) = gts::release(treasury);
    let m = capped::lock(cap, minted, gts::max_supply(), ctx);
    event::emit(SupplyLocked { capped_treasury: capped::treasury_of(&m), minted, max: gts::max_supply() });
    df::add(&mut board.id, MinterKey {}, m);
}

/// Seal the MinterCap in the immutable daily mint limit for good (v16, once): from here at most 2,000 GTS
/// can be minted per UTC day, by anyone, through any code.
public fun limit_mint_rate(_: &AdminCap, board: &mut Board, ctx: &mut TxContext) {
    check_version(board);
    let m: MinterCap<GTS> = df::remove(&mut board.id, MinterKey {});
    let l = daily::wrap(m, DAILY_MINT_MAX, ctx);
    event::emit(MintRateLimited { limiter: object::id(&l), per_day: DAILY_MINT_MAX });
    dof::add(&mut board.id, LimiterKey {}, l);
}

/// Mint `amount` GTS through the daily mint limit and the supply lock (clamped to the 1,000,000 cap;
/// aborts past 2,000 GTS in a UTC day).
fun mint_gts(board: &mut Board, t: &mut CappedTreasury<GTS>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    daily::mint(dof::borrow_mut<LimiterKey, DailyLimiter<GTS>>(&mut board.id, LimiterKey {}), t, amount, clock, ctx)
}

/// Set the stakers' share of the losing pot (bps), creating the staking pool the first time.
public fun set_staking(_: &AdminCap, board: &mut Board, bps: u64, ctx: &mut TxContext) {
    check_version(board);
    assert!(bps <= MAX_STAKE_BPS, EBadParams);
    assert!(DEV_BPS + board.vault_bps + BUYBACK_BPS + LIQ_BPS + board.ml_share_bps + bps + fund_bps(board) <= 10_000, EBadParams);
    if (!df::exists(&board.id, StakeKey {})) {
        df::add(&mut board.id, StakeKey {}, staking::new(ctx));
        df::add(&mut board.id, StakeBpsKey {}, 0u64);
    };
    *df::borrow_mut<StakeBpsKey, u64>(&mut board.id, StakeBpsKey {}) = bps;
    event::emit(StakingChanged { stake_bps: bps });
}

/// Set the Wealth Fund's share of every round's losing pot (bps), on top of the no-winner share.
public fun set_fund_bps(_: &AdminCap, board: &mut Board, bps: u64) {
    check_version(board);
    assert!(bps <= MAX_FUND_BPS, EBadParams);
    assert!(DEV_BPS + board.vault_bps + BUYBACK_BPS + LIQ_BPS + board.ml_share_bps + stake_bps(board) + bps <= 10_000, EBadParams);
    if (df::exists(&board.id, FundBpsKey {})) { *df::borrow_mut<FundBpsKey, u64>(&mut board.id, FundBpsKey {}) = bps }
    else { df::add(&mut board.id, FundBpsKey {}, bps) };
    event::emit(FundBpsChanged { fund_bps: bps });
}

/// Set the most squares one player may deposit on in a round (1 to 25).
public fun set_max_tiles(_: &AdminCap, board: &mut Board, n: u64) {
    check_version(board);
    assert!(n >= 1 && n <= GRID, EBadParams);
    if (df::exists(&board.id, MaxTilesKey {})) { *df::borrow_mut<MaxTilesKey, u64>(&mut board.id, MaxTilesKey {}) = n }
    else { df::add(&mut board.id, MaxTilesKey {}, n) };
    event::emit(MaxTilesChanged { max_tiles: n });
}

fun max_tiles(board: &Board): u64 {
    if (df::exists(&board.id, MaxTilesKey {})) { *df::borrow<MaxTilesKey, u64>(&board.id, MaxTilesKey {}) } else { GRID }
}

fun fund_bps(board: &Board): u64 {
    if (df::exists(&board.id, FundBpsKey {})) { *df::borrow<FundBpsKey, u64>(&board.id, FundBpsKey {}) } else { 0 }
}

fun stake_bps(board: &Board): u64 {
    if (df::exists(&board.id, StakeBpsKey {})) { *df::borrow<StakeBpsKey, u64>(&board.id, StakeBpsKey {}) } else { 0 }
}

fun pool_mut(board: &mut Board): &mut StakePool {
    assert!(df::exists(&board.id, StakeKey {}), ENoStaking);
    df::borrow_mut<StakeKey, StakePool>(&mut board.id, StakeKey {})
}

// ===== Staking (see `staking`) =====

/// Take the staking Schedule out of the Board (created the first time); `schedule_put` puts it back.
fun schedule_take(board: &mut Board, ctx: &mut TxContext): Schedule {
    if (!df::exists(&board.id, ScheduleKey {})) { df::add(&mut board.id, ScheduleKey {}, staking::new_schedule(ctx)) };
    df::remove(&mut board.id, ScheduleKey {})
}
fun schedule_put(board: &mut Board, s: Schedule) { df::add(&mut board.id, ScheduleKey {}, s) }

/// Stake GTS: flexible (1x) or locked for 7 days (1.5x). New stake starts earning one hour later (v20).
/// Yield is paid in SUI from every round.
public fun stake(board: &mut Board, gts: Coin<GTS>, locked: bool, clock: &Clock, ctx: &mut TxContext) {
    check_version(board);
    settle_gts_both(board, tx_context::sender(ctx));
    let mut s = schedule_take(board, ctx);
    staking::stake(pool_mut(board), &mut s, gts, locked, clock, ctx);
    schedule_put(board, s);
}

/// Take staked GTS out: flexible any time, locked once its 7 days have passed.
public fun unstake(board: &mut Board, amount: u64, locked: bool, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    check_version(board);
    settle_gts_both(board, tx_context::sender(ctx));
    let mut s = schedule_take(board, ctx);
    let out = staking::unstake(pool_mut(board), &mut s, amount, locked, clock, ctx);
    schedule_put(board, s);
    out
}

/// Claim all SUI yield of the sender.
public fun claim_yield(board: &mut Board, ctx: &mut TxContext): Coin<SUI> {
    check_version(board);
    staking::claim(pool_mut(board), ctx)
}

/// Claim all GTS yield of the sender (v12): their part of the GTS bought back.
public fun claim_gts(board: &mut Board, ctx: &mut TxContext): Coin<GTS> {
    check_version(board);
    let player = tx_context::sender(ctx);
    settle_gts_both(board, player);
    let mut total = 0;
    let mut i = 0;
    while (i < 2) {
        let key = GtsPosKey { player, locked: i == 1 };
        if (df::exists(&board.id, key)) {
            let w = staking::weight(pool_ref(board), player, i == 1);
            let pos = df::borrow_mut<GtsPosKey, GtsPos>(&mut board.id, key);
            total = total + pos.pending;
            pos.pending = 0;
            if (w == 0) { let _: GtsPos = df::remove(&mut board.id, key); };
        };
        i = i + 1;
    };
    if (total > 0) { event::emit(GtsYieldClaimed { player, gts: total }); };
    coin::from_balance(balance::split(&mut gts_yield_mut(board).rewards, total), ctx)
}

/// Bring `player`'s stake up to now: an ended lock drops back to 1x, a finished warm-up starts earning.
/// Anyone may call it. The draw does the same for everyone that is due (v20), so nothing depends on it.
public fun poke(board: &mut Board, player: address, clock: &Clock) {
    check_version(board);
    if (!df::exists(&board.id, ScheduleKey {})) { return }; // made by the first draw or stake after v20
    settle_gts_both(board, player);
    let mut s: Schedule = df::remove(&mut board.id, ScheduleKey {});
    staking::poke(pool_mut(board), &mut s, player, clock);
    schedule_put(board, s);
}

/// The staking step of a draw (v20): work through the warm-ups and lock ends that are due, at most
/// `STAKE_DUE_PER_DRAW` of them, before the round's share is paid to stakers. It does not depend on the
/// outcome of the draw.
fun stake_step(board: &mut Board, now: u64, ctx: &mut TxContext) {
    if (!df::exists(&board.id, StakeKey {})) { return };
    // Nothing due (the usual case): the Schedule is only read.
    if (df::exists(&board.id, ScheduleKey {})) {
        let (due, _) = staking::next_due(df::borrow<ScheduleKey, Schedule>(&board.id, ScheduleKey {}), now);
        if (!due) { return };
    };
    let mut s = schedule_take(board, ctx);
    let mut n = 0;
    while (n < STAKE_DUE_PER_DRAW) {
        let (due, player) = staking::next_due(&s, now);
        if (!due) { break };
        settle_gts_both(board, player);
        staking::run_due(pool_mut(board), &mut s, now);
        n = n + 1;
    };
    schedule_put(board, s);
}

/// Put a 7-day lock made before v20 on the queue the draw works through. Anyone may call it; it changes
/// nothing else. Returns whether it was queued.
public fun queue_lock(board: &mut Board, player: address, ctx: &mut TxContext): bool {
    check_version(board);
    let mut s = schedule_take(board, ctx);
    let ok = staking::enqueue_lock(pool_ref(board), &mut s, player);
    schedule_put(board, s);
    ok
}

fun pool_ref(board: &Board): &StakePool { df::borrow<StakeKey, StakePool>(&board.id, StakeKey {}) }

fun gts_yield_mut(board: &mut Board): &mut GtsYield {
    if (!df::exists(&board.id, GtsYieldKey {})) {
        df::add(&mut board.id, GtsYieldKey {}, GtsYield { rewards: balance::zero<GTS>(), acc: 0, paid_total: 0 });
    };
    df::borrow_mut<GtsYieldKey, GtsYield>(&mut board.id, GtsYieldKey {})
}

fun gts_acc(board: &Board): u256 {
    if (df::exists(&board.id, GtsYieldKey {})) { df::borrow<GtsYieldKey, GtsYield>(&board.id, GtsYieldKey {}).acc } else { 0 }
}

fun gts_earned(w: u128, acc: u256, snap: u256): u64 { (((w as u256) * (acc - snap)) / REFINE_SCALE) as u64 }

/// Bring one position's GTS yield up to now at its current weight. Called before its weight changes.
fun settle_gts(board: &mut Board, player: address, locked: bool) {
    let w = staking::weight(pool_ref(board), player, locked);
    let acc = gts_acc(board);
    let key = GtsPosKey { player, locked };
    if (!df::exists(&board.id, key)) {
        if (w == 0) { df::add(&mut board.id, key, GtsPos { snap: acc, pending: 0 }); return };
        df::add(&mut board.id, key, GtsPos { snap: 0, pending: 0 });
    };
    let pos = df::borrow_mut<GtsPosKey, GtsPos>(&mut board.id, key);
    pos.pending = pos.pending + gts_earned(w, acc, pos.snap);
    pos.snap = acc;
}

fun settle_gts_both(board: &mut Board, player: address) {
    settle_gts(board, player, false);
    settle_gts(board, player, true);
}

// ===== Play =====

/// Create a miner object (once per player).
public fun new_miner(ctx: &mut TxContext): Miner {
    Miner { id: object::new(ctx), round_id: 0, deployed: zeros(), total_deployed: 0 }
}

entry fun create_miner(ctx: &mut TxContext) {
    transfer::public_transfer(new_miner(ctx), tx_context::sender(ctx));
}

/// Deploy SUI onto squares for the current round. `amounts` has 25 entries summing to `payment`.
public fun deploy(
    board: &mut Board,
    miner: &mut Miner,
    payment: Coin<SUI>,
    amounts: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(board);
    deploy_as(board, miner, tx_context::sender(ctx), payment, amounts, clock)
}

/// `deploy` for `player` (the sender, or the owner of an Auto Mine seat).
fun deploy_as(board: &mut Board, miner: &mut Miner, player: address, payment: Coin<SUI>, amounts: vector<u64>, clock: &Clock) {
    assert!(vector::length(&amounts) == GRID, EBadLen);
    assert!(!board.paused, EPaused);
    let now = clock::timestamp_ms(clock);

    if (!board.cur_started) {
        board.cur_start_ms = now;
        board.cur_end_ms = now + board.round_ms;
        board.cur_started = true;
    };
    assert!(now < board.cur_end_ms, ERoundEnded);
    assert!(now <= board.cur_end_ms - board.freeze_ms, EFrozen);
    assert!(miner.round_id == 0 || miner.round_id == board.cur_id, EUnclaimed);

    let seat = SeatKey { round_id: board.cur_id, player };
    if (df::exists(&board.id, seat)) {
        assert!(*df::borrow<SeatKey, ID>(&board.id, seat) == object::id(miner), EOneMinerPerRound);
    } else {
        df::add(&mut board.id, seat, object::id(miner));
    };

    let mut sum = 0u64;
    let mut i = 0;
    while (i < GRID) {
        let a = *vector::borrow(&amounts, i);
        if (a > 0) { assert!(a >= board.min_deploy, EBelowMin); };
        sum = sum + a;
        i = i + 1;
    };
    assert!(sum > 0, ENothingDeployed);
    assert!(coin::value(&payment) == sum, EAmountMismatch);

    if (miner.round_id == 0) {
        miner.round_id = board.cur_id;
        board.cur_players = board.cur_players + 1;
    };

    i = 0;
    let mut tiles = 0;
    while (i < GRID) {
        let a = *vector::borrow(&amounts, i);
        if (a > 0) {
            let bd = vector::borrow_mut(&mut board.cur_deployed, i);
            *bd = *bd + a;
            let md = vector::borrow_mut(&mut miner.deployed, i);
            *md = *md + a;
        };
        if (*vector::borrow(&miner.deployed, i) > 0) { tiles = tiles + 1; };
        i = i + 1;
    };
    assert!(tiles <= max_tiles(board), ETooManyTiles);
    board.cur_total = board.cur_total + sum;
    miner.total_deployed = miner.total_deployed + sum;
    balance::join(&mut board.pot, coin::into_balance(payment));
    event::emit(Deployed { round_id: board.cur_id, player, amounts, total: sum });
}

/// Replaced by `settle_v2` (v15: the old Treasury is gone).
entry fun settle(_board: &mut Board, _treasury: &mut Treasury, _r: &Random, _clock: &Clock, _ctx: &mut TxContext) {
    abort EUseLockedSupply
}

/// The plain draw, kept as a fallback for when the market draw `settle_v3` cannot run (the game's Cetus
/// link out of date): draw the winner, take fees, assign the GTS reward, archive, start the next. It does
/// not touch the market. It pays no draw reward while the market works; once the market has not been
/// usable in a draw for 6 hours it pays up to 0.004 SUI (see `PLAIN_DRAW_REWARD_MAX`).
/// `entry` + non-`public` so it cannot be composed/aborted based on the outcome. Mints nothing: the
/// round's GTS is minted when players claim.
entry fun settle_v2(board: &mut Board, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    check_version(board);
    let now = clock::timestamp_ms(clock);
    let draw_max = if (now > market_alive_at(board, now) + PLAIN_DRAW_AFTER_MS) { PLAIN_DRAW_REWARD_MAX } else { 0 };
    let odds = board.ml_odds;
    settle_with_odds(board, r, clock, odds, draw_max, ctx)
}

/// The draw (v18): first the market step on the Cetus GTS/SUI pool with the SUI saved by earlier rounds
/// (liquidity add, buyback and burn, see `market_step`), then the same draw as `settle_v2`, with the draw
/// reward. Anyone may call it. The market step runs before the winner is drawn and uses nothing of this
/// round, so what it costs and does cannot depend on the outcome of the draw.
entry fun settle_v3(
    board: &mut Board,
    config: &GlobalConfig,
    pool: &mut CetusPool<GTS, SUI>,
    treasury: &mut CappedTreasury<GTS>,
    r: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(board);
    assert!(board.cur_started, ENotStarted);
    assert!(clock::timestamp_ms(clock) >= board.cur_end_ms, ERoundNotEnded);
    market_step(board, config, pool, treasury, clock, ctx);
    let odds = board.ml_odds;
    settle_with_odds(board, r, clock, odds, DRAW_REWARD_MAX, ctx)
}

/// When a market draw last found the market usable (ms); starts now the first time it is asked.
fun market_alive_at(board: &mut Board, now: u64): u64 {
    if (!df::exists(&board.id, MarketAliveKey {})) { df::add(&mut board.id, MarketAliveKey {}, now) };
    *df::borrow<MarketAliveKey, u64>(&board.id, MarketAliveKey {})
}

/// `draw_max`: the most the drawer is paid, out of the round's Wealth Fund share.
fun settle_with_odds(board: &mut Board, r: &Random, clock: &Clock, odds: u64, draw_max: u64, ctx: &mut TxContext) {
    check_version(board);
    assert!(board.cur_started, ENotStarted);
    assert!(clock::timestamp_ms(clock) >= board.cur_end_ms, ERoundNotEnded);
    // The market not usable for 7 days: its two shares, and what they saved, go to the Wealth Fund (v19).
    let now = clock::timestamp_ms(clock);
    let market_dead = now > market_alive_at(board, now) + MARKET_DEAD_MS;
    stake_step(board, now, ctx);

    if (!df::exists(&board.id, V5FromKey {})) { df::add(&mut board.id, V5FromKey {}, board.cur_id) };
    if (!df::exists(&board.id, RefineFromKey {})) { df::add(&mut board.id, RefineFromKey {}, clock::timestamp_ms(clock)) };
    if (!df::exists(&board.id, V8FromKey {})) { df::add(&mut board.id, V8FromKey {}, board.cur_id) };
    if (!df::exists(&board.id, V9FromKey {})) { df::add(&mut board.id, V9FromKey {}, board.cur_id) };
    if (!df::exists(&board.id, V10FromKey {})) { df::add(&mut board.id, V10FromKey {}, board.cur_id) };

    let mut gen = random::new_generator(r, ctx);
    let rng = random::generate_u64(&mut gen);
    let winning = ((rng % GRID) as u8);
    // Drawn on every round, hit or not, so both paths cost about the same gas.
    let hit = random::generate_u64_in_range(&mut gen, 0, odds - 1) == 0;
    let (t_epoch, t_total, t_count) = if (df::exists(&board.id, TicketsKey {})) {
        let t = df::borrow<TicketsKey, Tickets>(&board.id, TicketsKey {});
        (t.epoch, t.total, t.count)
    } else { (0, 0, 0) };
    let ticket = random::generate_u64_in_range(&mut gen, 0, if (t_total > 0) { t_total - 1 } else { 0 });

    let winners_total = *vector::borrow(&board.cur_deployed, (winning as u64));
    let losing_pot = board.cur_total - winners_total;

    let vault_full = mul_div(losing_pot, board.vault_bps, 10_000);
    let dev_part = mul_div(losing_pot, DEV_BPS, 10_000);
    board.buyback_bps = BUYBACK_BPS;
    let buyback_full = mul_div(losing_pot, BUYBACK_BPS, 10_000);
    let liq_full = mul_div(losing_pot, LIQ_BPS, 10_000);
    let stake_part = mul_div(losing_pot, stake_bps(board), 10_000);
    let fund_part = mul_div(losing_pot, fund_bps(board), 10_000);
    // No reserve (v9): any reserve share goes to the Wealth Fund with its own share. The drawer is paid
    // from the Wealth Fund share only (v19): the buyback and the liquidity share always stay whole.
    let fund_full = vault_full + fund_part;
    let draw_reward = if (fund_full < draw_max) { fund_full } else { draw_max };
    let market_share = buyback_full + liq_full;
    let buyback_part = if (market_dead) { 0 } else { buyback_full };
    let liq_part = if (market_dead) { 0 } else { liq_full };
    let mut fund_in = fund_full - draw_reward + if (market_dead) { market_share } else { 0 };
    let mut losing_after_fee = losing_pot - vault_full - dev_part - buyback_full - liq_full - stake_part - fund_part;

    // Stakers' share: split among everyone staked now, or to the Wealth Fund when nobody is.
    if (stake_part > 0) {
        let part = balance::split(&mut board.pot, stake_part);
        let round_id = board.cur_id;
        let pool = df::borrow_mut<StakeKey, StakePool>(&mut board.id, StakeKey {});
        if (staking::has_stakers(pool)) { staking::reward(pool, round_id, part) }
        else { balance::join(&mut board.pot, part); fund_in = fund_in + stake_part; };
    };
    if (dev_part > 0) { balance::join(&mut board.dev_fees, balance::split(&mut board.pot, dev_part)); };
    if (buyback_part > 0) { balance::join(&mut board.buyback, balance::split(&mut board.pot, buyback_part)); };
    if (liq_part > 0) { let b = balance::split(&mut board.pot, liq_part); balance::join(liquidity_mut(board), b); };
    if (draw_reward > 0) {
        let settler = tx_context::sender(ctx);
        transfer::public_transfer(coin::from_balance(balance::split(&mut board.pot, draw_reward), ctx), settler);
        event::emit(DrawPaid { round_id: board.cur_id, settler, amount: draw_reward });
    };

    if (market_dead) {
        let mut saved = balance::withdraw_all(&mut board.buyback);
        balance::join(&mut saved, balance::withdraw_all(liquidity_mut(board)));
        event::emit(MarketToFund { round_id: board.cur_id, saved: balance::value(&saved), share: market_share });
        balance::join(&mut board.motherlode, saved);
    };

    // Wealth Fund: every round adds its share; with no one on the winning square the whole rest goes
    // to it too. Then, in any round, a 1 in `odds` chance it is paid to the holder of the drawn ticket.
    if (winners_total == 0) {
        fund_in = fund_in + losing_after_fee;
        losing_after_fee = 0;
    };
    let ml_added = fund_in;
    let mut ml_paid = 0;
    if (fund_in > 0) { balance::join(&mut board.motherlode, balance::split(&mut board.pot, fund_in)); };
    if (hit && t_total > 0 && balance::value(&board.motherlode) > 0) {
        let winner = ticket_holder(board, t_epoch, t_count, ticket);
        let winner_tickets = *df::borrow<PlayerTicketsKey, u64>(&board.id, PlayerTicketsKey { epoch: t_epoch, player: winner });
        ml_paid = balance::value(&board.motherlode);
        let fund = balance::withdraw_all(&mut board.motherlode);
        transfer::public_transfer(coin::from_balance(fund, ctx), winner);
        let t = tickets_mut(board);
        t.epoch = t_epoch + 1;
        t.total = 0;
        t.count = 0;
        event::emit(WealthFundWon { round_id: board.cur_id, epoch: t_epoch, winner, amount: ml_paid, winner_tickets, total_tickets: t_total });
    };
    event::emit(MotherlodeUpdate { round_id: board.cur_id, added: ml_added, paid: ml_paid, balance: balance::value(&board.motherlode) });

    // GTS: the step reward (scaled down below `full_reward_deploy`), shared by SUI deployed. Then the decay.
    let full = next_full_reward(board);
    let reward = if (board.cur_total >= board.full_reward_deploy) { full }
        else { mul_div(full, board.cur_total, board.full_reward_deploy) };
    board.committed = board.committed + reward;
    board.step_count = board.step_count + 1;
    if (board.step_count >= board.step_rounds) {
        board.step_count = 0;
        board.reward = mul_div(board.reward, PPM - board.decay_ppm, PPM);
    };

    table::add(&mut board.rounds, board.cur_id, RoundInfo {
        total_deployed: board.cur_total,
        deployed: board.cur_deployed,
        winning_square: winning,
        losing_pot_after_fee: losing_after_fee,
        winners_total,
        round_reward: reward,
        rng,
    });
    if (board.cur_players > 0) { df::add(&mut board.id, RoundLeftKey { round_id: board.cur_id }, board.cur_players) };

    event::emit(RoundSettled {
        round_id: board.cur_id,
        winning_square: winning,
        total_deployed: board.cur_total,
        winners_total,
        round_reward: reward,
        losing_pot,
        winners_payout: losing_after_fee,
        vault_fee: 0,
        buyback_fee: buyback_part,
        dev_fee: dev_part,
        players: board.cur_players,
        committed: board.committed,
        next_reward: next_full_reward(board),
    });

    board.cur_id = board.cur_id + 1;
    board.cur_started = false;
    board.cur_total = 0;
    board.cur_deployed = zeros();
    board.cur_players = 0;
}

fun earned(amount: u64, acc: u256, snap: u256): u64 { (((amount as u256) * (acc - snap)) / REFINE_SCALE) as u64 }

/// Start of the 7-day clock after `add` GTS joins `held` GTS whose clock started at `start` (v18): the
/// average of the two starts weighted by the amounts, the new GTS starting `now`. GTS held longer than
/// the 7 days counts as held exactly 7 days, so a balance that is already free cannot carry new GTS out
/// with it. With nothing held the clock starts now.
fun blended_start(start: u64, held: u64, add: u64, now: u64): u64 {
    if (held == 0 || start == 0) { return now };
    let floor = if (now > REFINE_WINDOW_MS) { now - REFINE_WINDOW_MS } else { 0 };
    let s = if (start > now) { now } else if (start < floor) { floor } else { start };
    ((((s as u128) * (held as u128) + (now as u128) * (add as u128)) / ((held as u128) + (add as u128))) as u64)
}

/// Add mined GTS to `player`'s unrefined balance. Their 7-day withdraw clock moves to the weighted
/// average of the GTS they hold and the GTS added now (`blended_start`).
fun add_unrefined(board: &mut Board, player: address, gts: Balance<GTS>, now: u64) {
    let amount = balance::value(&gts);
    let acc = board.acc;
    let key = UnrefinedKey { player };
    if (!df::exists(&board.id, key)) {
        df::add(&mut board.id, key, Unrefined { amount: 0, bonus: 0, snap: acc });
    };
    let held = df::borrow<UnrefinedKey, Unrefined>(&board.id, key).amount;
    let start = blended_start(refine_start(board, player), held, amount, now);
    let ck = RefineClockKey { player };
    if (df::exists(&board.id, ck)) { *df::borrow_mut<RefineClockKey, u64>(&mut board.id, ck) = start }
    else { df::add(&mut board.id, ck, start) };
    let u = df::borrow_mut<UnrefinedKey, Unrefined>(&mut board.id, key);
    u.bonus = u.bonus + earned(u.amount, acc, u.snap);
    u.snap = acc;
    u.amount = u.amount + amount;
    board.unrefined_total = board.unrefined_total + amount;
    balance::join(&mut board.unrefined, gts);
}

fun mint_room(board: &Board, clock: &Clock): u64 {
    daily::room_today(dof::borrow<LimiterKey, DailyLimiter<GTS>>(&board.id, LimiterKey {}), clock)
}

fun owed(board: &Board, player: address): u64 {
    let k = OwedKey { player };
    if (df::exists(&board.id, k)) { *df::borrow<OwedKey, u64>(&board.id, k) } else { 0 }
}

/// Mint up to `amount` GTS into `player`'s unrefined balance, as much as today's mint limit has room
/// for. Returns what was asked for and did not fit.
fun mint_unrefined(board: &mut Board, treasury: &mut CappedTreasury<GTS>, player: address, amount: u64, clock: &Clock, ctx: &mut TxContext): u64 {
    let room = mint_room(board, clock);
    let take = if (amount < room) { amount } else { room };
    if (take > 0) {
        // Clamped by the 1,000,000 cap in the supply lock; past it nothing more can ever be minted.
        let c = mint_gts(board, treasury, take, clock, ctx);
        if (coin::value(&c) > 0) { add_unrefined(board, player, coin::into_balance(c), clock::timestamp_ms(clock)) }
        else { coin::destroy_zero(c) };
    };
    amount - take
}

/// Mint the GTS `player` is owed, as far as today's mint limit has room. Returns the GTS still owed.
fun pay_owed(board: &mut Board, treasury: &mut CappedTreasury<GTS>, player: address, clock: &Clock, ctx: &mut TxContext): u64 {
    let was = owed(board, player);
    if (was == 0) { return 0 };
    let left = mint_unrefined(board, treasury, player, was, clock, ctx);
    if (left < was) {
        let k = OwedKey { player };
        if (left == 0) { let _: u64 = df::remove(&mut board.id, k); }
        else { *df::borrow_mut<OwedKey, u64>(&mut board.id, k) = left };
        event::emit(OwedPaid { player, amount: was - left, owed: left });
    };
    left
}

/// Mint the GTS the sender is owed from days when the mint limit was full (v18). Only the player can
/// call it for themselves (v19; `player` must be the sender): minting moves their withdraw clock, so
/// nobody else may choose when. Owed GTS is also minted by the player's next claim. Does nothing while
/// there is no room today.
public fun claim_owed(board: &mut Board, treasury: &mut CappedTreasury<GTS>, player: address, clock: &Clock, ctx: &mut TxContext) {
    check_version(board);
    assert!(player == tx_context::sender(ctx), ENotYours);
    pay_owed(board, treasury, player, clock, ctx);
}

/// Replaced by `claim_v2` (v15: the old Treasury is gone).
public fun claim(_board: &mut Board, _miner: &mut Miner, _treasury: &mut Treasury, _ctx: &mut TxContext): (Coin<GTS>, Coin<SUI>) {
    abort EUseLockedSupply
}

/// Replaced by `claim_v3` (v16: minting needs the clock for the daily limit).
public fun claim_v2(_board: &mut Board, _miner: &mut Miner, _treasury: &mut CappedTreasury<GTS>, _ctx: &mut TxContext): (Coin<GTS>, Coin<SUI>) {
    abort EUseClaimV3
}

/// Claim a settled round: GTS mining reward (everyone) + SUI winnings (if on the winning square).
/// Mined GTS goes to the unrefined balance, for house bots too (v18), so the GTS coin returned is always
/// empty. GTS that does not fit under today's mint limit is owed (see `claim_owed`); the SUI is paid
/// either way. Returns (GTS, SUI).
public fun claim_v3(
    board: &mut Board,
    miner: &mut Miner,
    treasury: &mut CappedTreasury<GTS>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<GTS>, Coin<SUI>) {
    check_version(board);
    let (g, s, _, _) = claim_as(board, miner, tx_context::sender(ctx), true, treasury, clock, ctx);
    (g, s)
}

/// `claim_v3` for `player`. With `add_tickets_now` false the Wealth Fund tickets are not added to the draw
/// but returned (Auto Mine adds them in batches). Returns (GTS, SUI, tickets not added, GTS mined: minted
/// now or owed).
fun claim_as(
    board: &mut Board,
    miner: &mut Miner,
    player: address,
    add_tickets_now: bool,
    treasury: &mut CappedTreasury<GTS>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<GTS>, Coin<SUI>, u64, u64) {
    assert!(miner.round_id != 0, ENothingToClaim);
    assert!(table::contains(&board.rounds, miner.round_id), ENotSettled);
    let round_id = miner.round_id;
    let info = table::borrow(&board.rounds, round_id);
    let (round_reward, round_total, w) = (info.round_reward, info.total_deployed, (info.winning_square as u64));
    let (pot_after_fee, winners_total) = (info.losing_pot_after_fee, info.winners_total);

    let v5 = round_id >= v5_from(board);
    // Rounds settled by v9 keep the fair split; from v10 winners keep their whole share (the v5 branch).
    let v9 = round_id >= v9_from(board) && round_id < v10_from(board);
    let my_win = *vector::borrow(&miner.deployed, w);
    // v5-v7: GTS by SUI lost in the round; before v5 and from v8: by SUI deployed.
    let gts_amt = if (v5 && round_id < v8_from(board)) {
        let lost_total = round_total - winners_total;
        if (lost_total == 0) { 0 } else { mul_div(round_reward, miner.total_deployed - my_win, lost_total) }
    } else if (round_total == 0) { 0 } else { mul_div(round_reward, miner.total_deployed, round_total) };
    // The round's GTS goes to the unrefined balance, for house bots too (v18). The day's mint limit
    // never blocks a claim (v18): GTS already owed is minted first, then this round's; what does not fit
    // today is owed and minted once there is room (`claim_owed`, or the player's next claim), and the
    // SUI below is paid either way.
    let owed_before = pay_owed(board, treasury, player, clock, ctx);
    let short = if (owed_before > 0) { gts_amt } else { mint_unrefined(board, treasury, player, gts_amt, clock, ctx) };
    if (short > 0) {
        let k = OwedKey { player };
        if (df::exists(&board.id, k)) { let v = df::borrow_mut<OwedKey, u64>(&mut board.id, k); *v = *v + short; }
        else { df::add(&mut board.id, k, short) };
        event::emit(GtsOwed { round_id, player, amount: short, owed: owed_before + short });
    };
    let mined_amt = gts_amt;
    let gts_coin = coin::zero<GTS>(ctx);

    // SUI: own stake on the winning square back, plus a share of the losing pot in proportion to it.
    // Rounds settled by v9 (and before v5) kept only the part of that share matching the part of the
    // round deposit on the winning square, the rest went to the Wealth Fund. Rounds 21-32 (v5-v8) and
    // from v10 keep it all.
    let sui_coin = if (v9 && my_win > 0) {
        let share = mul_div(pot_after_fee, my_win, winners_total);
        let kept = mul_div(share, my_win, miner.total_deployed);
        let to_fund = share - kept;
        if (to_fund > 0) {
            balance::join(&mut board.motherlode, balance::split(&mut board.pot, to_fund));
            event::emit(MotherlodeReturned { round_id, amount: to_fund, balance: balance::value(&board.motherlode) });
            event::emit(Forfeited { round_id, player, to_reserve: 0, to_fund });
        };
        coin::from_balance(balance::split(&mut board.pot, my_win + kept), ctx)
    } else if (v5 && my_win > 0) {
        coin::from_balance(balance::split(&mut board.pot, my_win + mul_div(pot_after_fee, my_win, winners_total)), ctx)
    } else if (my_win > 0 && winners_total > 0) {
        let share = mul_div(pot_after_fee, my_win, winners_total);
        let jk = JackpotKey { round_id };
        let jackpot = if (df::exists(&board.id, jk)) { mul_div(*df::borrow<JackpotKey, u64>(&board.id, jk), my_win, winners_total) } else { 0 };
        let pot_share = share - jackpot;
        let my_total = miner.total_deployed;
        let pot_kept = mul_div(pot_share, my_win, my_total);
        let jackpot_kept = if (is_bot(player)) { 0 } else { mul_div(jackpot, my_win, my_total) };
        // No reserve from v9: what used to go to it goes to the Wealth Fund.
        let to_fund = jackpot - jackpot_kept + pot_share - pot_kept;
        let to_reserve = 0;
        if (to_fund > 0) {
            let part = balance::split(&mut board.pot, to_fund);
            balance::join(&mut board.motherlode, part);
            event::emit(MotherlodeReturned { round_id, amount: to_fund, balance: balance::value(&board.motherlode) });
        };
        if (to_reserve > 0 || to_fund > 0) { event::emit(Forfeited { round_id, player, to_reserve, to_fund }); };
        coin::from_balance(balance::split(&mut board.pot, my_win + pot_kept + jackpot_kept), ctx)
    } else {
        coin::zero<SUI>(ctx)
    };

    // Wealth Fund tickets: the fee paid on the SUI lost this round (none for house bots).
    let n = mul_div(miner.total_deployed - my_win, fee_bps(board), 10_000);
    let mut owed = 0;
    if (n > 0 && !no_tickets(player)) {
        if (add_tickets_now) { add_tickets(board, round_id, player, n) } else { owed = n };
    };

    let seat = SeatKey { round_id, player };
    if (df::exists(&board.id, seat) && *df::borrow<SeatKey, ID>(&board.id, seat) == object::id(miner)) {
        let _: ID = df::remove(&mut board.id, seat);
    };

    // Last claimer of the round: the RoundInfo is no longer needed (the RoundSettled event keeps it).
    let lk = RoundLeftKey { round_id };
    if (df::exists(&board.id, lk)) {
        let left = df::borrow_mut<RoundLeftKey, u64>(&mut board.id, lk);
        *left = *left - 1;
        if (*left == 0) {
            let _: u64 = df::remove(&mut board.id, lk);
            let RoundInfo { total_deployed: _, deployed: _, winning_square: _, losing_pot_after_fee: _,
                winners_total: _, round_reward: _, rng: _ } = table::remove(&mut board.rounds, round_id);
        };
    };

    event::emit(Claimed { round_id, player, gts: mined_amt, sui: coin::value(&sui_coin) });

    miner.round_id = 0;
    miner.total_deployed = 0;
    miner.deployed = zeros();

    (gts_coin, sui_coin, owed, mined_amt)
}

/// Replaced by `claim_sui_v2` (v15: the old Treasury is gone).
public fun claim_sui(_board: &mut Board, _miner: &mut Miner, _treasury: &mut Treasury, _ctx: &mut TxContext): Coin<SUI> {
    abort EUseLockedSupply
}

/// Replaced by `claim_sui_v3` (v16: minting needs the clock for the daily limit).
public fun claim_sui_v2(_board: &mut Board, _miner: &mut Miner, _treasury: &mut CappedTreasury<GTS>, _ctx: &mut TxContext): Coin<SUI> {
    abort EUseClaimV3
}

/// `claim_v3` that sends any GTS to the sender and returns the SUI.
public fun claim_sui_v3(board: &mut Board, miner: &mut Miner, treasury: &mut CappedTreasury<GTS>, clock: &Clock, ctx: &mut TxContext): Coin<SUI> {
    let (g, s) = claim_v3(board, miner, treasury, clock, ctx);
    if (coin::value(&g) == 0) { coin::destroy_zero(g) } else { transfer::public_transfer(g, tx_context::sender(ctx)) };
    s
}

/// Replaced by `withdraw_gts_v6` (the fee depends on the time).
public fun withdraw_gts(_board: &mut Board, _treasury: &mut Treasury, _ctx: &mut TxContext): Coin<GTS> {
    abort EUseWithdrawV6
}

/// When `player`'s 7-day withdraw clock started (ms); 0 if it has not started.
fun refine_start(board: &Board, player: address): u64 {
    let ck = RefineClockKey { player };
    if (df::exists(&board.id, ck)) { *df::borrow<RefineClockKey, u64>(&board.id, ck) }
    else if (df::exists(&board.id, RefineFromKey {})) { *df::borrow<RefineFromKey, u64>(&board.id, RefineFromKey {}) }
    else { 0 }
}

/// Withdraw fee in bps at `now`: `refine_fee_bps` right after the clock starts, falling linearly to 0
/// after 7 days. The full fee while no clock has started.
fun fee_bps_at(board: &Board, player: address, now: u64): u64 {
    let start = refine_start(board, player);
    if (start == 0) { return board.refine_fee_bps };
    let end = start + REFINE_WINDOW_MS;
    if (now >= end) { return 0 };
    let left = if (now > start) { end - now } else { REFINE_WINDOW_MS };
    mul_div(board.refine_fee_bps, left, REFINE_WINDOW_MS)
}

/// Replaced by `withdraw_gts_v7` (v15: the old Treasury is gone).
public fun withdraw_gts_v6(_board: &mut Board, _treasury: &mut Treasury, _clock: &Clock, _ctx: &mut TxContext): Coin<GTS> {
    abort EUseLockedSupply
}

/// Withdraw the whole unrefined balance plus the holder bonus (the shared half of other players' withdraw
/// fees). Of the fee (see `fee_bps_at`) half is burned and half shared by everyone still holding (v16);
/// the 7-day clock restarts now.
public fun withdraw_gts_v7(board: &mut Board, treasury: &mut CappedTreasury<GTS>, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    check_version(board);
    let player = tx_context::sender(ctx);
    let key = UnrefinedKey { player };
    assert!(df::exists(&board.id, key), ENothingToWithdraw);
    let now = clock::timestamp_ms(clock);
    let fee_bps = fee_bps_at(board, player, now);
    let Unrefined { amount, bonus, snap } = df::remove(&mut board.id, key);
    let bonus = bonus + earned(amount, board.acc, snap);
    let fee = mul_div(amount, fee_bps, 10_000);
    board.unrefined_total = board.unrefined_total - amount;
    let out = balance::split(&mut board.unrefined, amount - fee + bonus);
    // Half the fee to everyone still holding unrefined GTS (it stays in `unrefined`), half burned (v16).
    let holders = board.unrefined_total;
    let shared = if (holders > 0) { fee / 2 } else { 0 };
    let burned = fee - shared;
    if (shared > 0) {
        board.acc = board.acc + (shared as u256) * REFINE_SCALE / (holders as u256);
        event::emit(WithdrawFeeShared { player, amount: shared, holders_total: holders });
    };
    if (burned > 0) { capped::burn(treasury, coin::from_balance(balance::split(&mut board.unrefined, burned), ctx)) };
    let ck = RefineClockKey { player };
    if (df::exists(&board.id, ck)) { *df::borrow_mut<RefineClockKey, u64>(&mut board.id, ck) = now }
    else { df::add(&mut board.id, ck, now) };
    event::emit(GtsWithdrawn { player, amount, fee, bonus, paid: amount - fee + bonus, burned });
    coin::from_balance(out, ctx)
}

// ===== Auto Mine (v17, see `auto_vault::vault`) =====

/// Store the Auto Mine vault's only PullCap in the game for good (once). No function returns it.
public fun auto_install(_: &AdminCap, board: &mut Board, cap: PullCap) {
    check_version(board);
    assert!(!dof::exists(&board.id, AutoCapKey {}), EAutoInstalled);
    event::emit(AutoInstalled { cap: object::id(&cap) });
    dof::add(&mut board.id, AutoCapKey {}, cap);
}

/// Open the sender's Auto Mine seat (once per player; a second call does nothing).
public fun auto_join(board: &mut Board, ctx: &mut TxContext) {
    check_version(board);
    let player = tx_context::sender(ctx);
    if (df::exists(&board.id, AutoKey { player })) { return };
    df::add(&mut board.id, AutoKey { player }, AutoSeat {
        miner: new_miner(ctx), tickets: 0, ticket_epoch: 0, claims: 0, rounds: 0, wins: 0, deployed: 0, fees: 0, won: 0, mined: 0,
    });
    event::emit(AutoJoined { player });
}

/// Play the round for each of `players` by their Auto Mine plan. Anyone may call it; the caller is paid
/// 1% of every deposit it makes. For each player: first the last automatic round is claimed (SUI won to
/// their vault balance, mined GTS to their unrefined balance), then, if their plan is ready, the round is
/// played. A player who cannot be played now is skipped, never an abort. `entry` + non-`public`, like the
/// draw: the tiles are picked with `sui::random` and cannot be chosen or retried by the caller.
entry fun auto_run(
    board: &mut Board,
    vault: &mut Vault,
    treasury: &mut CappedTreasury<GTS>,
    players: vector<address>,
    r: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(board);
    assert!(dof::exists(&board.id, AutoCapKey {}), ENoAuto);
    let mut gen = random::new_generator(r, ctx);
    let mut keeper = balance::zero<SUI>();
    let mut i = 0;
    let n = vector::length(&players);
    while (i < n) {
        let player = *vector::borrow(&players, i);
        if (df::exists(&board.id, AutoKey { player })) {
            auto_claim(board, vault, treasury, player, clock, ctx);
            auto_deploy(board, vault, player, &mut gen, &mut keeper, clock, ctx);
        };
        i = i + 1;
    };
    if (balance::value(&keeper) > 0) { transfer::public_transfer(coin::from_balance(keeper, ctx), tx_context::sender(ctx)) }
    else { balance::destroy_zero(keeper) };
}

/// Add the sender's waiting Wealth Fund tickets to the draw now.
public fun auto_flush(board: &mut Board, ctx: &TxContext) {
    check_version(board);
    let player = tx_context::sender(ctx);
    if (!df::exists(&board.id, AutoKey { player })) { return };
    let mut seat: AutoSeat = df::remove(&mut board.id, AutoKey { player });
    let round_id = board.cur_id;
    auto_add_tickets(board, &mut seat, player, round_id);
    df::add(&mut board.id, AutoKey { player }, seat);
}

fun ticket_epoch(board: &Board): u64 {
    if (df::exists(&board.id, TicketsKey {})) { df::borrow<TicketsKey, Tickets>(&board.id, TicketsKey {}).epoch } else { 0 }
}

/// Whether adding tickets for `player` now extends the last range (no new storage).
fun tickets_merge(board: &Board, player: address): bool {
    if (!df::exists(&board.id, TicketsKey {})) { return false };
    let t = df::borrow<TicketsKey, Tickets>(&board.id, TicketsKey {});
    t.count > 0 && df::borrow<TicketKey, TicketEntry>(&board.id, TicketKey { epoch: t.epoch, i: t.count - 1 }).player == player
}

/// Tickets earned before the last Wealth Fund payout are gone, like every ticket of that draw.
fun auto_drop_old_tickets(board: &Board, seat: &mut AutoSeat) {
    let epoch = ticket_epoch(board);
    if (seat.ticket_epoch != epoch) { seat.tickets = 0; seat.ticket_epoch = epoch; };
}

fun auto_add_tickets(board: &mut Board, seat: &mut AutoSeat, player: address, round_id: u64) {
    auto_drop_old_tickets(board, seat);
    if (seat.tickets > 0) { add_tickets(board, round_id, player, seat.tickets) };
    seat.tickets = 0;
    seat.claims = 0;
}

/// Whether `player`'s plan still has a round to play (the vault's 20 seconds between rounds aside).
fun auto_live(vault: &Vault, player: address): bool {
    let (on, _, per_round, rounds_left, keep, target, _) = vault::plan_of(vault, player);
    let bal = vault::balance_of(vault, player);
    on && rounds_left > 0 && per_round >= AUTO_MIN_ROUND && bal >= per_round && bal - per_round >= keep && (target == 0 || bal < target)
}

/// Claim `player`'s last automatic round, if it is settled. The day's GTS mint limit never holds it up
/// (v18): GTS that does not fit today is owed to the player, like in `claim_v3`.
fun auto_claim(board: &mut Board, vault: &mut Vault, treasury: &mut CappedTreasury<GTS>, player: address, clock: &Clock, ctx: &mut TxContext) {
    let mut seat: AutoSeat = df::remove(&mut board.id, AutoKey { player });
    let round_id = seat.miner.round_id;
    let settled = round_id != 0 && table::contains(&board.rounds, round_id);
    if (settled) {
        let (g, s, owed, mined) = claim_as(board, &mut seat.miner, player, false, treasury, clock, ctx);
        if (coin::value(&g) == 0) { coin::destroy_zero(g) } else { transfer::public_transfer(g, player) };
        let sui = coin::value(&s);
        if (sui > 0) {
            seat.wins = seat.wins + 1;
            seat.won = seat.won + sui;
            vault::credit(vault, player, coin::into_balance(s));
        } else { coin::destroy_zero(s) };
        seat.mined = seat.mined + mined;
        auto_drop_old_tickets(board, &mut seat);
        seat.tickets = seat.tickets + owed;
        seat.claims = seat.claims + 1;
        event::emit(AutoClaimed { round_id, player, sui, gts: mined });
    };
    // Tickets go into the draw every AUTO_TICKET_BATCH claims, at once when that only extends the last
    // range, and whenever the plan has no round left to play (off, out of rounds or balance, target reached).
    if (seat.tickets > 0 && (seat.claims >= AUTO_TICKET_BATCH || !auto_live(vault, player) || tickets_merge(board, player))) {
        let at = if (round_id != 0) { round_id } else { board.cur_id };
        auto_add_tickets(board, &mut seat, player, at);
    };
    df::add(&mut board.id, AutoKey { player }, seat);
}

/// Play the current round for `player` if their plan is ready and the strategy allows it now.
fun auto_deploy(board: &mut Board, vault: &mut Vault, player: address, gen: &mut RandomGenerator, keeper: &mut Balance<SUI>, clock: &Clock, ctx: &mut TxContext) {
    if (board.paused || !vault::ready(vault, player, clock)) { return };
    let (_, strategy, spent, _, _, _, _) = vault::plan_of(vault, player);
    if (spent < AUTO_MIN_ROUND || strategy > AUTO_HUNTER) { return };
    let now = clock::timestamp_ms(clock);
    // A live round takes deposits until `freeze_ms` before its end; with no round live this deposit starts one.
    if (board.cur_started && now + board.freeze_ms > board.cur_end_ms) { return };
    if (strategy == AUTO_HUNTER && (!board.cur_started || now + board.freeze_ms + AUTO_HUNT_MS < board.cur_end_ms)) { return };
    // One miner per player and round: not in a round the player already plays themselves.
    if (df::exists(&board.id, SeatKey { round_id: board.cur_id, player })) { return };

    let tiles = if (strategy == AUTO_SNIPER) { 1 } else if (AUTO_SPREAD_TILES < max_tiles(board)) { AUTO_SPREAD_TILES } else { max_tiles(board) };
    let keeper_fee = mul_div(spent, AUTO_KEEPER_BPS, 10_000);
    let per = (spent - keeper_fee - mul_div(spent, AUTO_BUYBACK_BPS, 10_000)) / tiles;
    if (per < board.min_deploy) { return };

    let mut seat: AutoSeat = df::remove(&mut board.id, AutoKey { player });
    // The last round must be claimed first (it waits for its draw).
    if (seat.miner.round_id == 0) {
        let mut funds = vault::pull(vault, dof::borrow<AutoCapKey, PullCap>(&board.id, AutoCapKey {}), player, clock);
        balance::join(keeper, balance::split(&mut funds, keeper_fee));
        let deployed = per * tiles;
        let pay = coin::from_balance(balance::split(&mut funds, deployed), ctx);
        // The buyback fee, with the few mist left by the split over the tiles.
        let buyback_fee = balance::value(&funds);
        balance::join(&mut board.buyback, funds);
        let amounts = if (strategy == AUTO_HUNTER) { emptiest_tiles(&board.cur_deployed, tiles, per, gen) } else { random_tiles(tiles, per, gen) };
        deploy_as(board, &mut seat.miner, player, pay, amounts, clock);
        seat.rounds = seat.rounds + 1;
        seat.deployed = seat.deployed + deployed;
        seat.fees = seat.fees + keeper_fee + buyback_fee;
        event::emit(AutoMined { round_id: board.cur_id, player, strategy, spent, deployed, keeper_fee, buyback_fee });
    };
    df::add(&mut board.id, AutoKey { player }, seat);
}

/// `per` on each of `tiles` different tiles, drawn at random.
fun random_tiles(tiles: u64, per: u64, gen: &mut RandomGenerator): vector<u64> {
    let mut v = zeros();
    let mut picked = 0;
    while (picked < tiles) {
        let i = random::generate_u64_in_range(gen, 0, GRID - 1);
        if (*vector::borrow(&v, i) == 0) {
            *vector::borrow_mut(&mut v, i) = per;
            picked = picked + 1;
        };
    };
    v
}

/// `per` on each of the `tiles` tiles holding the least SUI. Ties go to the first one from a random start.
fun emptiest_tiles(deployed: &vector<u64>, tiles: u64, per: u64, gen: &mut RandomGenerator): vector<u64> {
    let mut v = zeros();
    let start = random::generate_u64_in_range(gen, 0, GRID - 1);
    let mut picked = 0;
    while (picked < tiles) {
        let mut best = GRID;
        let mut low = 0;
        let mut j = 0;
        while (j < GRID) {
            let i = (start + j) % GRID;
            let d = *vector::borrow(deployed, i);
            if (*vector::borrow(&v, i) == 0 && (best == GRID || d < low)) { best = i; low = d; };
            j = j + 1;
        };
        *vector::borrow_mut(&mut v, best) = per;
        picked = picked + 1;
    };
    v
}

/// Send accrued creator fees to DEV_ADDR. Anyone may call; funds can only go to DEV_ADDR.
entry fun withdraw_dev_fees(board: &mut Board, ctx: &mut TxContext) {
    check_version(board);
    let amt = balance::value(&board.dev_fees);
    if (amt > 0) {
        transfer::public_transfer(coin::from_balance(balance::split(&mut board.dev_fees, amt), ctx), DEV_ADDR);
    };
}

/// Closed (v5): the owner cannot take the buyback SUI. Only the draw spends it, on GTS that is burned (`settle_v3`).
public fun take_buyback(_: &AdminCap, _board: &mut Board, _ctx: &mut TxContext): Coin<SUI> {
    abort EBuybackOff
}

/// Closed (v18): the buyback runs inside the draw, see `settle_v3`. No address can take the buyback SUI.
public fun buyback_take(_board: &mut Board, _ctx: &mut TxContext): (Coin<SUI>, BuybackReceipt) {
    abort EInDraw
}

/// Closed (v11): the GTS bought is kept, not burned; see `buyback_keep`.
public fun buyback_burn(_board: &mut Board, _treasury: &mut Treasury, receipt: BuybackReceipt, _gts: Coin<GTS>, _left: Coin<SUI>) {
    let BuybackReceipt { sui: _ } = receipt;
    abort EUseBuybackKeep
}

/// Replaced by `buyback_burn_v2` (v16: the GTS bought is burned, not paid to stakers).
public fun buyback_keep(_board: &mut Board, receipt: BuybackReceipt, _gts: Coin<GTS>, _left: Coin<SUI>) {
    let BuybackReceipt { sui: _ } = receipt;
    abort EUseBuybackBurn
}

/// Closed (v18) with `buyback_take`: no receipt can be made any more.
public fun buyback_burn_v2(_board: &mut Board, _treasury: &mut CappedTreasury<GTS>, receipt: BuybackReceipt, _gts: Coin<GTS>, _left: Coin<SUI>, _ctx: &mut TxContext) {
    let BuybackReceipt { sui: _ } = receipt;
    abort EInDraw
}

/// Closed (v18): the liquidity add runs inside the draw, see `settle_v3`. No address can take the liquidity SUI.
public fun liquidity_take(_board: &mut Board, _ctx: &mut TxContext): (Coin<SUI>, LiquidityReceipt) {
    abort EInDraw
}

/// Closed (v18) with `liquidity_take`: no receipt can be made any more. Positions already locked stay
/// locked, and the draw adds to them.
public fun liquidity_lock<P: key + store>(_board: &mut Board, receipt: LiquidityReceipt, _position: P, _left_sui: Coin<SUI>, _left_gts: Coin<GTS>) {
    let LiquidityReceipt { sui: _ } = receipt;
    abort EInDraw
}

// ===== Market (v18): buyback, liquidity and trading fees on the Cetus GTS/SUI pool, inside the game =====

fun market_pool(board: &Board): address {
    if (df::exists(&board.id, TestPoolKey {})) { *df::borrow<TestPoolKey, address>(&board.id, TestPoolKey {}) } else { MARKET_POOL }
}

fun min128(a: u128, b: u128): u128 { if (a < b) { a } else { b } }

/// The highest square-root price a buy may reach: 2% in price above `base`.
fun price_cap(base: u128): u128 { min128(base * PRICE_CAP_NUM / PRICE_CAP_DEN, tick_math::max_sqrt_price()) }

/// The market step of a draw. Uses only SUI saved by earlier rounds.
///
/// The 2% limit: buys may lift the pool price at most 2% above the reference price, or above the price
/// now if that is lower. The reference is the pool price at the end of the last market step, and it
/// rises at most 2% from one step to the next (it falls freely). So lifting the pool price just before a
/// draw does not move the limit: the draw then simply buys less, or nothing, and the SUI waits. The very
/// first step only records the price.
///
/// The buyback and the liquidity add share that room, and take turns going first (liquidity first in
/// even rounds, the buyback first in odd ones), so neither can keep the other waiting when the limit is
/// tight. Nothing here aborts over a full limit, a paused pool or dust amounts: that part is skipped and
/// its SUI stays saved for a later draw.
fun market_step(board: &mut Board, config: &GlobalConfig, pool: &mut CetusPool<GTS, SUI>, treasury: &mut CappedTreasury<GTS>, clock: &Clock, ctx: &mut TxContext) {
    assert!(object::id_address(pool) == market_pool(board), EWrongPool);
    // The market counts as usable only if the game's Cetus link is still current (this aborts if Cetus has
    // retired it, and the round is then drawn with `settle_v2`) and the pool takes swaps and liquidity.
    // A step that merely skips a paused pool does not count (v19).
    cetus_config::checked_package_version(config);
    let now = clock::timestamp_ms(clock);
    market_alive_at(board, now);
    if (cetus_pool::is_allow_swap(pool) && cetus_pool::is_allow_add_liquidity(pool) && cetus_pool::liquidity(pool) > 0) {
        *df::borrow_mut<MarketAliveKey, u64>(&mut board.id, MarketAliveKey {}) = now;
    };
    let price = cetus_pool::current_sqrt_price(pool);
    if (!df::exists(&board.id, PriceRefKey {})) {
        df::add(&mut board.id, PriceRefKey {}, price);
        event::emit(PriceRefSet { sqrt_price: price });
        return
    };
    let reference = *df::borrow<PriceRefKey, u128>(&board.id, PriceRefKey {});
    let limit = price_cap(min128(reference, price));
    if (board.cur_id % 2 == 0) {
        market_liquidity(board, config, pool, limit, clock);
        market_buyback(board, config, pool, treasury, limit, clock, ctx);
    } else {
        market_buyback(board, config, pool, treasury, limit, clock, ctx);
        market_liquidity(board, config, pool, limit, clock);
    };
    let next = min128(cetus_pool::current_sqrt_price(pool), price_cap(reference));
    if (next != reference) {
        *df::borrow_mut<PriceRefKey, u128>(&mut board.id, PriceRefKey {}) = next;
        event::emit(PriceRefSet { sqrt_price: next });
    };
}

/// Buy GTS on the pool with up to `amount` of `funds`, never lifting the price past `limit`. Returns the
/// GTS bought (none when the pool takes no swaps, the limit leaves no real room, or `amount` is dust).
fun buy_gts(config: &GlobalConfig, pool: &mut CetusPool<GTS, SUI>, funds: &mut Balance<SUI>, amount: u64, limit: u128, clock: &Clock): Balance<GTS> {
    let price = cetus_pool::current_sqrt_price(pool);
    if (amount < MARKET_BUY_MIN / 5 || !cetus_pool::is_allow_swap(pool) || cetus_pool::liquidity(pool) == 0
        || price * PRICE_ROOM_NUM / PRICE_CAP_DEN > limit) {
        return balance::zero<GTS>()
    };
    // SUI in (coin B), GTS out (coin A), exact input; the swap stops at `limit` and takes only what it used.
    let (gts, none, receipt) = cetus_pool::flash_swap<GTS, SUI>(config, pool, false, true, amount, limit, clock);
    balance::destroy_zero(none);
    let pay = cetus_pool::swap_pay_amount(&receipt);
    cetus_pool::repay_flash_swap<GTS, SUI>(config, pool, balance::zero<GTS>(), balance::split(funds, pay), receipt);
    gts
}

/// Add as much of `gts` and `sui` as pairs up at the pool price to the first locked position. Returns
/// (GTS added, SUI added); the rest stays in the two balances. Adds nothing when the pool takes no
/// liquidity, no position is locked, or the amounts are dust.
fun add_to_pool(board: &mut Board, config: &GlobalConfig, pool: &mut CetusPool<GTS, SUI>, gts: &mut Balance<GTS>, sui: &mut Balance<SUI>, clock: &Clock): (u64, u64) {
    let (g, s) = (balance::value(gts), balance::value(sui));
    if (g == 0 || s == 0 || lp_positions(board) == 0 || !cetus_pool::is_allow_add_liquidity(pool)) { return (0, 0) };
    let position = dof::borrow_mut<LpKey, Position>(&mut board.id, LpKey { i: 0 });
    if (cetus_position::pool_id(position) != object::id(pool)) { return (0, 0) };
    let (lower, upper) = cetus_position::tick_range(position);
    let (tick, price) = (cetus_pool::current_tick_index(pool), cetus_pool::current_sqrt_price(pool));
    if (price <= tick_math::get_sqrt_price_at_tick(lower) || price >= tick_math::get_sqrt_price_at_tick(upper)) { return (0, 0) };
    // All the GTS if the SUI covers its match, else all the SUI if the GTS covers its match.
    let (liq_a, _, need_sui) = cetus_pool::get_liquidity_from_amount(lower, upper, tick, price, g, true);
    let (fix_gts, amount) = if (liq_a > 0 && need_sui <= s) { (true, g) } else {
        let (liq_b, need_gts, _) = cetus_pool::get_liquidity_from_amount(lower, upper, tick, price, s, false);
        if (liq_b == 0 || need_gts > g) { return (0, 0) };
        (false, s)
    };
    let receipt = cetus_pool::add_liquidity_fix_coin<GTS, SUI>(config, pool, position, amount, fix_gts, clock);
    let (pay_gts, pay_sui) = cetus_pool::add_liquidity_pay_amount(&receipt);
    cetus_pool::repay_add_liquidity<GTS, SUI>(config, pool, balance::split(gts, pay_gts), balance::split(sui, pay_sui), receipt);
    (pay_gts, pay_sui)
}

/// Liquidity: once `MARKET_LIQ_MIN` SUI is saved, 49% of it buys GTS (within the 2% limit), and the GTS
/// with the matching SUI goes into the first locked position. SUI not used stays saved for the next
/// draw; GTS not used is burned with the next buyback.
fun market_liquidity(board: &mut Board, config: &GlobalConfig, pool: &mut CetusPool<GTS, SUI>, limit: u128, clock: &Clock) {
    let saved = liquidity_value(board);
    if (saved < MARKET_LIQ_MIN || lp_positions(board) == 0 || !cetus_pool::is_allow_add_liquidity(pool)) { return };
    let mut sui = balance::withdraw_all(liquidity_mut(board));
    let mut gts = buy_gts(config, pool, &mut sui, saved * LIQ_BUY_PCT / 100, limit, clock);
    let sui_swapped = saved - balance::value(&sui);
    let (gts_added, sui_added) = add_to_pool(board, config, pool, &mut gts, &mut sui, clock);
    let gts_left = balance::value(&gts);
    balance::join(liquidity_mut(board), sui);
    balance::join(bought_mut(board), gts);
    if (sui_swapped > 0) {
        event::emit(LiquidityAdded { sui_swapped, sui_added, gts_added, gts_left, position: lp_position_id(board, 0) });
    };
}

/// Buyback and burn: once `MARKET_BUY_MIN` SUI is saved, all of it buys GTS (within the 2% limit) and
/// the GTS is burned for good, with any GTS left from liquidity. SUI the limit left unspent stays saved.
fun market_buyback(board: &mut Board, config: &GlobalConfig, pool: &mut CetusPool<GTS, SUI>, treasury: &mut CappedTreasury<GTS>, limit: u128, clock: &Clock, ctx: &mut TxContext) {
    let saved = balance::value(&board.buyback);
    let mut gts = if (saved >= MARKET_BUY_MIN) { buy_gts(config, pool, &mut board.buyback, saved, limit, clock) } else { balance::zero<GTS>() };
    let sui_spent = saved - balance::value(&board.buyback);
    balance::join(&mut gts, balance::withdraw_all(bought_mut(board)));
    let gts_burned = balance::value(&gts);
    if (gts_burned == 0) { balance::destroy_zero(gts); return };
    capped::burn(treasury, coin::from_balance(gts, ctx));
    event::emit(BuybackDone { sui_spent, gts_burned });
}

/// Collect the trading fees the locked positions `from` to `to - 1` have earned and add them back to
/// the pool (v18). Anyone may call it; it pays the caller nothing and nothing leaves the game. The GTS
/// fees are paired with SUI fees and, if those are short, with SUI saved for liquidity. SUI that cannot
/// be paired stays saved for the next liquidity add; GTS that cannot is burned with the next buyback.
public fun compound_fees(board: &mut Board, config: &GlobalConfig, pool: &mut CetusPool<GTS, SUI>, from: u64, to: u64, clock: &Clock) {
    check_version(board);
    assert!(object::id_address(pool) == market_pool(board), EWrongPool);
    // Only while the pool price is within 2% of the reference price of the draws (v19), so nobody can
    // move the price, have the game add liquidity at that price, and move it back. Otherwise it does
    // nothing: the fees stay in the positions for a later call.
    if (!df::exists(&board.id, PriceRefKey {})) { return };
    let reference = *df::borrow<PriceRefKey, u128>(&board.id, PriceRefKey {});
    let price = cetus_pool::current_sqrt_price(pool);
    if (price > price_cap(reference) || reference > price_cap(price)) { return };
    let n = lp_positions(board);
    let end = if (to < n) { to } else { n };
    let mut gts = balance::zero<GTS>();
    let mut sui = balance::zero<SUI>();
    let mut i = from;
    while (i < end) {
        let position = dof::borrow<LpKey, Position>(&board.id, LpKey { i });
        let (a, b) = cetus_pool::collect_fee<GTS, SUI>(config, pool, position, true);
        balance::join(&mut gts, a);
        balance::join(&mut sui, b);
        i = i + 1;
    };
    let (gts_fees, sui_fees) = (balance::value(&gts), balance::value(&sui));
    balance::join(&mut sui, balance::withdraw_all(liquidity_mut(board)));
    let (gts_added, sui_added) = add_to_pool(board, config, pool, &mut gts, &mut sui, clock);
    let (gts_left, sui_left) = (balance::value(&gts), balance::value(&sui));
    balance::join(liquidity_mut(board), sui);
    balance::join(bought_mut(board), gts);
    if (gts_fees > 0 || sui_fees > 0) {
        event::emit(FeesCompounded { sui_fees, gts_fees, sui_added, gts_added, sui_left, gts_left });
    };
}

/// Replaced by `supply_lock::capped::burn`, where anyone may burn their own GTS (v15: the old Treasury is gone).
public fun burn_bought(_treasury: &mut Treasury, _gts: Coin<GTS>, _ctx: &mut TxContext) {
    abort EUseLockedSupply
}

// ===== Views =====
public fun current_round(board: &Board): u64 { board.cur_id }
public fun current_end_ms(board: &Board): u64 { board.cur_end_ms }
public fun current_total(board: &Board): u64 { board.cur_total }
public fun pot_value(board: &Board): u64 { balance::value(&board.pot) }
public fun dev_fees_value(board: &Board): u64 { balance::value(&board.dev_fees) }
public fun buyback_value(board: &Board): u64 { balance::value(&board.buyback) }
public fun motherlode_value(board: &Board): u64 { balance::value(&board.motherlode) }
public fun motherlode_paid(board: &Board, round_id: u64): u64 {
    let k = JackpotKey { round_id };
    if (df::exists(&board.id, k)) { *df::borrow<JackpotKey, u64>(&board.id, k) } else { 0 }
}
/// (Wealth Fund odds, Wealth Fund share, reserve, buyback, creator, withdraw fee) in bps except odds, and paused.
public fun current_params(board: &Board): (u64, u64, u64, u64, u64, u64, bool) {
    (board.ml_odds, board.ml_share_bps, board.vault_bps, BUYBACK_BPS, DEV_BPS, board.refine_fee_bps, board.paused)
}
/// Liquidity share of the losing pot in bps (fixed, v11).
public fun liquidity_bps(): u64 { LIQ_BPS }
/// SUI saved for liquidity, waiting for a draw.
public fun liquidity_value(board: &Board): u64 {
    if (df::exists(&board.id, LiquidityKey {})) { balance::value(df::borrow<LiquidityKey, Balance<SUI>>(&board.id, LiquidityKey {})) } else { 0 }
}
/// GTS left from liquidity adds, waiting to be burned with the next buyback.
public fun bought_value(board: &Board): u64 {
    if (df::exists(&board.id, BoughtKey {})) { balance::value(df::borrow<BoughtKey, Balance<GTS>>(&board.id, BoughtKey {})) } else { 0 }
}
/// How many Cetus positions are locked in the game.
public fun lp_positions(board: &Board): u64 {
    if (df::exists(&board.id, LpCountKey {})) { *df::borrow<LpCountKey, u64>(&board.id, LpCountKey {}) } else { 0 }
}
/// ID of locked position `i` (from 0).
public fun lp_position_id(board: &Board, i: u64): ID { *dof::id(&board.id, LpKey { i }).borrow() }
/// (step reward, rounds per step, decay ppm, rounds into the step, full-reward deposit, GTS committed).
public fun emission(board: &Board): (u64, u64, u64, u64, u64, u64) {
    (board.reward, board.step_rounds, board.decay_ppm, board.step_count, board.full_reward_deploy, board.committed)
}
/// ID of the DailyLimiter (v16) that holds the right to mint GTS.
public fun mint_limiter_id(board: &Board): ID { *dof::id(&board.id, LimiterKey {}).borrow() }
/// (GTS that can still be minted today, the daily limit) (v16).
public fun mint_room_today(board: &Board, clock: &Clock): (u64, u64) {
    let l = dof::borrow<LimiterKey, DailyLimiter<GTS>>(&board.id, LimiterKey {});
    (daily::room_today(l, clock), daily::per_day(l))
}
/// GTS `player` is owed: mined, waiting for room under the daily mint limit (v18).
public fun owed_of(board: &Board, player: address): u64 { owed(board, player) }
/// The market (v18): (the Cetus pool, the reference square-root price the 2% limit is measured from (0
/// before the first market draw), least saved SUI for a buyback, least saved SUI for a liquidity add).
public fun market(board: &Board): (address, u128, u64, u64) {
    let reference = if (df::exists(&board.id, PriceRefKey {})) { *df::borrow<PriceRefKey, u128>(&board.id, PriceRefKey {}) } else { 0 };
    (market_pool(board), reference, MARKET_BUY_MIN, MARKET_LIQ_MIN)
}
/// The market's clock (v19): (when a market draw last found the market usable in ms, 0 before the first
/// draw after v19; ms without it after which the plain draw pays; ms without it after which the buyback
/// and liquidity SUI go to the Wealth Fund).
public fun market_alive(board: &Board): (u64, u64, u64) {
    let at = if (df::exists(&board.id, MarketAliveKey {})) { *df::borrow<MarketAliveKey, u64>(&board.id, MarketAliveKey {}) } else { 0 };
    (at, PLAIN_DRAW_AFTER_MS, MARKET_DEAD_MS)
}
/// Most SUI paid to whoever draws a round: (market draw, plain draw once the market has been down 6 hours).
public fun draw_rewards(): (u64, u64) { (DRAW_REWARD_MAX, PLAIN_DRAW_REWARD_MAX) }
/// Full GTS reward of the round now open.
public fun current_reward(board: &Board): u64 { next_full_reward(board) }
public fun unrefined_of(board: &Board, player: address): (u64, u64) {
    let key = UnrefinedKey { player };
    if (!df::exists(&board.id, key)) { return (0, 0) };
    let u = df::borrow<UnrefinedKey, Unrefined>(&board.id, key);
    (u.amount, u.bonus + earned(u.amount, board.acc, u.snap))
}
public fun unrefined_total(board: &Board): u64 { board.unrefined_total }
/// v6: (when `player`'s 7-day withdraw clock started in ms (0 = not yet), window ms, fee in bps now).
public fun withdraw_clock(board: &Board, player: address, clock: &Clock): (u64, u64, u64) {
    (refine_start(board, player), REFINE_WINDOW_MS, fee_bps_at(board, player, clock::timestamp_ms(clock)))
}
/// Wealth Fund draw: (epoch, total tickets).
public fun wealth_tickets(board: &Board): (u64, u64) {
    if (!df::exists(&board.id, TicketsKey {})) { return (0, 0) };
    let t = df::borrow<TicketsKey, Tickets>(&board.id, TicketsKey {});
    (t.epoch, t.total)
}
/// `player`'s tickets in the current Wealth Fund draw.
public fun tickets_of(board: &Board, player: address): u64 {
    let (epoch, _) = wealth_tickets(board);
    let pk = PlayerTicketsKey { epoch, player };
    if (df::exists(&board.id, pk)) { *df::borrow<PlayerTicketsKey, u64>(&board.id, pk) } else { 0 }
}
/// Wealth Fund's share of every round's losing pot in bps.
public fun wealth_fund_bps(board: &Board): u64 { fund_bps(board) }
public fun max_tiles_per_player(board: &Board): u64 { max_tiles(board) }
/// Stakers' share of the losing pot in bps (0 before staking is set up).
public fun staking_bps(board: &Board): u64 { stake_bps(board) }
/// (GTS staked, total weight in tenths, SUI paid to stakers so far, SUI waiting to be claimed).
public fun staking_totals(board: &Board): (u64, u128, u64, u64) {
    if (!df::exists(&board.id, StakeKey {})) { return (0, 0, 0, 0) };
    staking::totals(df::borrow<StakeKey, StakePool>(&board.id, StakeKey {}))
}
/// (GTS paid to stakers so far, GTS waiting to be claimed) from the buyback (v12).
public fun staking_gts_totals(board: &Board): (u64, u64) {
    if (!df::exists(&board.id, GtsYieldKey {})) { return (0, 0) };
    let y = df::borrow<GtsYieldKey, GtsYield>(&board.id, GtsYieldKey {});
    (y.paid_total, balance::value(&y.rewards))
}
/// GTS claimable by `player` from both positions (v12).
public fun staking_gts_of(board: &Board, player: address): u64 {
    if (!df::exists(&board.id, StakeKey {})) { return 0 };
    let acc = gts_acc(board);
    let mut total = 0;
    let mut i = 0;
    while (i < 2) {
        let w = staking::weight(pool_ref(board), player, i == 1);
        let key = GtsPosKey { player, locked: i == 1 };
        total = total + if (df::exists(&board.id, key)) {
            let pos = df::borrow<GtsPosKey, GtsPos>(&board.id, key);
            pos.pending + gts_earned(w, acc, pos.snap)
        } else { gts_earned(w, acc, 0) };
        i = i + 1;
    };
    total
}
/// Staking times (v20): (ms new stake waits before it earns, ms a lock lasts).
public fun staking_times(): (u64, u64) { (staking::warm_ms(), staking::lock_ms()) }
/// (GTS of one of `player`'s positions still warming up, when it starts earning in ms) (v20).
public fun staking_warming(board: &Board, player: address, locked: bool): (u64, u64) {
    if (!df::exists(&board.id, ScheduleKey {})) { return (0, 0) };
    staking::warming_of(df::borrow<ScheduleKey, Schedule>(&board.id, ScheduleKey {}), player, locked)
}
/// Staking queue entries waiting for a draw: (warm-ups, lock ends) (v20).
public fun staking_queued(board: &Board): (u64, u64) {
    if (!df::exists(&board.id, ScheduleKey {})) { return (0, 0) };
    staking::queued(df::borrow<ScheduleKey, Schedule>(&board.id, ScheduleKey {}))
}
/// (GTS staked, locked until (ms, 0 if flexible), SUI claimable) of one of `player`'s positions.
public fun staking_position(board: &Board, player: address, locked: bool): (u64, u64, u64) {
    if (!df::exists(&board.id, StakeKey {})) { return (0, 0, 0) };
    staking::position(df::borrow<StakeKey, StakePool>(&board.id, StakeKey {}), player, locked)
}

/// Auto Mine fees in bps of every automatic deposit (keeper, buyback), and the least SUI a round (v17).
public fun auto_terms(): (u64, u64, u64) { (AUTO_KEEPER_BPS, AUTO_BUYBACK_BPS, AUTO_MIN_ROUND) }
public fun auto_installed(board: &Board): bool { dof::exists(&board.id, AutoCapKey {}) }
public fun auto_joined(board: &Board, player: address): bool { df::exists(&board.id, AutoKey { player }) }
/// `player`'s Auto Mine seat: (round waiting to be claimed (0 = none), SUI on each tile in it, tickets not
/// in the draw yet, rounds, winning rounds, SUI deployed, SUI paid in fees, SUI won, GTS mined).
public fun auto_seat(board: &Board, player: address): (u64, vector<u64>, u64, u64, u64, u64, u64, u64, u64) {
    let s = df::borrow<AutoKey, AutoSeat>(&board.id, AutoKey { player });
    let tickets = if (s.ticket_epoch == ticket_epoch(board)) { s.tickets } else { 0 };
    (s.miner.round_id, s.miner.deployed, tickets, s.rounds, s.wins, s.deployed, s.fees, s.won, s.mined)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun auto_run_for_testing(board: &mut Board, vault: &mut Vault, treasury: &mut CappedTreasury<GTS>, players: vector<address>, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    auto_run(board, vault, treasury, players, r, clock, ctx)
}

/// The draw of `settle_v3` (with the draw reward) without its market step.
#[test_only]
public fun settle_for_testing(board: &mut Board, _treasury: &mut CappedTreasury<GTS>, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    let odds = board.ml_odds;
    settle_with_odds(board, r, clock, odds, DRAW_REWARD_MAX, ctx)
}

#[test_only]
public fun settle_with_odds_for_testing(
    board: &mut Board, _treasury: &mut CappedTreasury<GTS>, r: &Random, clock: &Clock, odds: u64, ctx: &mut TxContext,
) { settle_with_odds(board, r, clock, odds, DRAW_REWARD_MAX, ctx) }

/// The plain draw `settle_v2`.
#[test_only]
public fun settle_plain_for_testing(board: &mut Board, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    settle_v2(board, r, clock, ctx)
}

/// The market draw `settle_v3`.
#[test_only]
public fun settle_market_for_testing(
    board: &mut Board, config: &GlobalConfig, pool: &mut CetusPool<GTS, SUI>, treasury: &mut CappedTreasury<GTS>, r: &Random, clock: &Clock, ctx: &mut TxContext,
) { settle_v3(board, config, pool, treasury, r, clock, ctx) }

/// Only the market step of `settle_v3`.
#[test_only]
public fun market_step_for_testing(
    board: &mut Board, config: &GlobalConfig, pool: &mut CetusPool<GTS, SUI>, treasury: &mut CappedTreasury<GTS>, clock: &Clock, ctx: &mut TxContext,
) { market_step(board, config, pool, treasury, clock, ctx) }

/// Make `pool` the market pool of this test.
#[test_only]
public fun set_market_pool_for_testing(board: &mut Board, pool: address) {
    if (df::exists(&board.id, TestPoolKey {})) { *df::borrow_mut<TestPoolKey, address>(&mut board.id, TestPoolKey {}) = pool }
    else { df::add(&mut board.id, TestPoolKey {}, pool) };
}

/// Lock a position in the game, as the keeper's liquidity add did before v18.
#[test_only]
public fun lock_position_for_testing<P: key + store>(board: &mut Board, position: P) {
    if (!df::exists(&board.id, LpCountKey {})) { df::add(&mut board.id, LpCountKey {}, 0u64) };
    let n = *df::borrow<LpCountKey, u64>(&board.id, LpCountKey {});
    dof::add(&mut board.id, LpKey { i: n }, position);
    *df::borrow_mut<LpCountKey, u64>(&mut board.id, LpCountKey {}) = n + 1;
}

/// Add SUI to the saved buyback and liquidity balances, and GTS to the GTS waiting to be burned.
#[test_only]
public fun fund_market_for_testing(board: &mut Board, buyback: Coin<SUI>, liquidity: Coin<SUI>, bought: Coin<GTS>) {
    balance::join(&mut board.buyback, coin::into_balance(buyback));
    balance::join(liquidity_mut(board), coin::into_balance(liquidity));
    balance::join(bought_mut(board), coin::into_balance(bought));
}

#[test_only]
public fun blended_start_for_testing(start: u64, held: u64, add: u64, now: u64): u64 { blended_start(start, held, add, now) }

#[test_only]
public fun round_info_exists_for_testing(board: &Board, round_id: u64): bool { table::contains(&board.rounds, round_id) }

#[test_only]
public fun winning_square_for_testing(board: &Board, round_id: u64): u64 {
    (table::borrow(&board.rounds, round_id).winning_square as u64)
}

#[test_only]
public fun ticket_holder_for_testing(board: &Board, r: u64): address {
    let t = df::borrow<TicketsKey, Tickets>(&board.id, TicketsKey {});
    ticket_holder(board, t.epoch, t.count, r)
}

#[test_only]
public fun mint_for_testing(board: &mut Board, t: &mut CappedTreasury<GTS>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    mint_gts(board, t, amount, clock, ctx)
}

#[test_only]
public fun set_committed_for_testing(board: &mut Board, committed: u64) { board.committed = committed }
