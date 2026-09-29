/// GTStar game (relaunch): a 5x5 grid, 60s rounds, on Sui.
///
/// Rounds: players deploy SUI onto squares, one winning square is drawn with `sui::random`, and the
/// losing pot pays: creator DEV_BPS (1%, fixed), reserve `vault_bps`, buyback `buyback_bps`, Wealth
/// Fund `fund_bps` (every round, see `set_fund_bps`), and the rest to the winners by their stake on the
/// winning square (from v5 there is no cut for spread deposits). With no one on the winning square the rest is split between the
/// Wealth Fund (`ml_share_bps` of the losing pot) and the reserve. Every round has a 1 in `ml_odds`
/// chance to pay the whole Wealth Fund to one ticket, drawn by weight. Tickets: every mist of fee a
/// player paid (creator + reserve + buyback + stakers + Wealth Fund, on the SUI they lost) since the last payout is
/// one ticket, added when the round is claimed. Fees cannot be won back through a second wallet, so
/// tickets always cost real SUI. House bots get no tickets. Tickets reset after each payout.
///
/// Emission, by rounds played (not by time): each settled round mints `reward` GTS (1 GTS at launch),
/// shared by everyone in the round by SUI deployed (win or lose); the full reward needs
/// `full_reward_deploy` SUI in the round, less scales it down, so with 1 GTS per 1 SUI a player mines
/// exactly the SUI they deployed while the round holds at most 1 SUI. (Rounds settled by v5-v7 were
/// shared by SUI lost and capped by the floor; v8 removes both.) Every `step_rounds` settled rounds (15,658) the reward drops by
/// `decay_ppm` (1.425%). Mining stops for good once 1,000,000 GTS have been assigned to rounds.
/// No staker or other mint: the round reward is the only source of GTS.
///
/// Mined GTS waits in the player's unrefined balance. From v6 withdrawing it is free once 7 days have
/// passed since the player's last withdrawal (or first mining); before that the fee falls linearly from
/// `refine_fee_bps` to 0 over the 7 days, and the fee GTS is burned (supply falls, the floor rises).
///
/// Buyback (v7): `buyback_bps` of every losing pot is saved in the game. Only the keeper may take it
/// (`buyback_take`), and the same transaction must burn GTS for it (`buyback_burn` closes the receipt),
/// so supply falls and the floor rises. `BuybackDone` shows the SUI spent and the GTS burned.
///
/// The owner holds the AdminCap (settings change at once, each fee within its own cap)
/// and the UpgradeCap. `renounce` destroys the
/// AdminCap for good. Fixed: the creator fee (1%), the 1,000,000 cap, and no address can be blocked
/// from playing, claiming or withdrawing. A pause only stops new deposits.
#[allow(lint(self_transfer))]
module gtstar::game;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event;
use sui::random::{Self, Random};
use sui::sui::SUI;
use sui::table::{Self, Table};
use gtstar::gts::{Self, Treasury, GTS};
use gtstar::staking::{Self, Pool as StakePool};

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

// Default settings (see `set_params`).
const DEFAULT_VAULT_BPS: u64 = 400;        // 4% reserve
const DEFAULT_BUYBACK_BPS: u64 = 0;        // buyback off until set (v7)
const DEFAULT_ML_ODDS: u64 = 1_000;        // Wealth Fund: 1 in 1000
const DEFAULT_ML_SHARE_BPS: u64 = 1_950;   // 19.5% of a no-winner round
const DEFAULT_REFINE_FEE_BPS: u64 = 1_000; // 10%

// Bounds.
const MIN_ODDS: u64 = 100;
const MAX_ODDS: u64 = 1_000_000;
const MAX_REFINE_FEE_BPS: u64 = 5_000;
// Each fee has its own cap (v5).
const MAX_VAULT_BPS: u64 = 1_500;    // reserve 15%
const MAX_STAKE_BPS: u64 = 500;      // stakers 5%
const MAX_FUND_BPS: u64 = 1_000;     // Wealth Fund, every round, 10%
const MAX_ML_SHARE_BPS: u64 = 3_000; // Wealth Fund, no-winner round, 30%
const MAX_BUYBACK_BPS: u64 = 300;    // buyback 3% (v7)
const MIN_MIN_DEPLOY: u64 = 1_000_000;      // 0.001 SUI
const MAX_MIN_DEPLOY: u64 = 10_000_000_000; // 10 SUI
const MIN_ROUND_MS: u64 = 30_000;
const MAX_ROUND_MS: u64 = 3_600_000;
const MAX_ROUND_REWARD: u64 = 10_000_000_000; // 10 GTS
const MAX_DECAY_PPM: u64 = 500_000;
const MIN_FULL_REWARD_DEPLOY: u64 = 1_000_000;         // 0.001 SUI
const MAX_FULL_REWARD_DEPLOY: u64 = 1_000_000_000_000; // 1,000 SUI

/// House bots: paid mined GTS at claim, outside the unrefined balances, and never keep Wealth Fund SUI.
const HOUSE_ADDR: address = @0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a;
const BOT1_ADDR: address = @0xab4deb30e34487f75bf5632038e46d419c6238b4ea52d35f3ad3421a5bb268fa;
const BOT2_ADDR: address = @0x779b49acf4db04d835440c12ffe24929de505a9b8112b4040da5103d225b37e7;
const BOT3_ADDR: address = @0x0b8d118f954c90a87abc2b3e07c408681efed88b552ebcd94fc5cb292f3c9dc4;
const MATCHER_ADDR: address = @0x2a869532f55594a9ffed4a5d7ee2a48cf5c857ac740090d39c733e0279b6a8de;
/// Shield bot: no Wealth Fund tickets either.
const SHIELD_ADDR: address = @0xadf4446b0340e1b8d4c0abde15da3381db54057a1e4bda533cc3c8ca1abbc077;
/// Keeper: the only address that may spend the buyback SUI, and only on GTS that is then burned (v7).
const BUYER_ADDR: address = @0x22390096d8def0638c92f86da60683e37d1a7f00b4b22fcb359952db300c3549;

/// Draw reward: whoever settles a round is paid up to this much SUI (0.005) out of the round's reserve
/// share, then its buyback share (v7: reserve first), so the draw pays for its own gas.
const DRAW_REWARD_MAX: u64 = 5_000_000;

/// Precision of the per-GTS withdraw-fee accumulator.
const REFINE_SCALE: u256 = 1_000_000_000_000_000_000;

/// v6: the withdraw fee falls to 0 over this long after the last withdrawal (7 days).
const REFINE_WINDOW_MS: u64 = 604_800_000;

/// Package version: only the latest version may change the Board. Bump it on every upgrade.
const VERSION: u64 = 8;

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
const EBuybackOpen: u64 = 21;
const ENoStaking: u64 = 22;
const EBuybackOff: u64 = 23;
const EUseWithdrawV6: u64 = 24;
const ENotBuyer: u64 = 25;
const ENoBuyback: u64 = 26;
const ENothingBought: u64 = 27;

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

/// Dynamic field on the Board: the first round settled by v5 (GTS by SUI lost, floor cap, no spread cut).
public struct V5FromKey has copy, drop, store {}
/// Dynamic field on the Board: the first round settled by v8 (GTS by SUI deployed again, no floor cap).
public struct V8FromKey has copy, drop, store {}

/// Dynamic field on the Board (v6): when `player`'s 7-day withdraw clock started (ms): their last
/// withdrawal, or when they first mined. Holders from before v6 without one use `RefineFromKey`.
public struct RefineClockKey has copy, drop, store { player: address }
/// Dynamic field on the Board (v6): time of the first round settled by v6 (ms).
public struct RefineFromKey has copy, drop, store {}

/// Dynamic fields on the Board: the staking pool, and the stakers' share of the losing pot in bps.
public struct StakeKey has copy, drop, store {}
public struct StakeBpsKey has copy, drop, store {}

/// Right to change the settings.
public struct AdminCap has key, store { id: UID }

/// Hot potato from `buyback_take`: the transaction only succeeds once `buyback_burn` burns GTS for it.
public struct BuybackReceipt { sui: u64 }

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
public struct Claimed has copy, drop { round_id: u64, player: address, gts: u64, sui: u64 }
/// Buyback SUI taken by the owner to buy GTS on the market.
public struct BuybackTaken has copy, drop { amount: u64 }
/// GTS bought back and burned.
public struct BuybackBurned has copy, drop { amount: u64 }
/// Buyback SUI spent on GTS and the GTS burned for it (v7).
public struct BuybackDone has copy, drop { sui_spent: u64, gts_burned: u64 }
public struct StakingChanged has copy, drop { stake_bps: u64 }
public struct FundBpsChanged has copy, drop { fund_bps: u64 }
/// SUI paid to whoever settled a round, out of its reserve share, then its buyback share.
public struct DrawPaid has copy, drop { round_id: u64, settler: address, amount: u64 }

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

/// Fees taken from the losing pot, in bps: creator + reserve + buyback + stakers + Wealth Fund.
fun fee_bps(board: &Board): u64 { DEV_BPS + board.vault_bps + board.buyback_bps + stake_bps(board) + fund_bps(board) }

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

/// First round under the v8 GTS rules (u64 max until v8 settles its first round).
fun v8_from(board: &Board): u64 {
    if (df::exists(&board.id, V8FromKey {})) { *df::borrow<V8FromKey, u64>(&board.id, V8FromKey {}) } else { 18_446_744_073_709_551_615 }
}

// ===== Admin =====

/// Change the settings at once. Fee changes apply from the next settle.
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
    assert!(buyback_bps <= MAX_BUYBACK_BPS, EBadParams);
    assert!(vault_bps <= MAX_VAULT_BPS && ml_share_bps <= MAX_ML_SHARE_BPS, EBadParams);
    assert!(DEV_BPS + vault_bps + buyback_bps + ml_share_bps + stake_bps(board) + fund_bps(board) <= 10_000, EBadParams);
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

/// Change the emission at once, from the next settle. The 1,000,000 cap cannot change.
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
    board.reward = reward;
    board.step_rounds = step_rounds;
    board.decay_ppm = decay_ppm;
    board.step_count = step_count;
    board.full_reward_deploy = full_reward_deploy;
    event::emit(EmissionChanged { reward, step_rounds, decay_ppm, step_count, full_reward_deploy });
}

/// Give up the AdminCap for good: settings are frozen as they are. The buyback must be off and empty.
public fun renounce(cap: AdminCap, board: &Board) {
    assert!(board.buyback_bps == 0 && balance::value(&board.buyback) == 0, EBuybackOpen);
    let AdminCap { id } = cap;
    object::delete(id);
    event::emit(Renounced {});
}

/// Set the stakers' share of the losing pot (bps), creating the staking pool the first time.
public fun set_staking(_: &AdminCap, board: &mut Board, bps: u64, ctx: &mut TxContext) {
    check_version(board);
    assert!(bps <= MAX_STAKE_BPS, EBadParams);
    assert!(DEV_BPS + board.vault_bps + board.buyback_bps + board.ml_share_bps + bps + fund_bps(board) <= 10_000, EBadParams);
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
    assert!(DEV_BPS + board.vault_bps + board.buyback_bps + board.ml_share_bps + stake_bps(board) + bps <= 10_000, EBadParams);
    if (df::exists(&board.id, FundBpsKey {})) { *df::borrow_mut<FundBpsKey, u64>(&mut board.id, FundBpsKey {}) = bps }
    else { df::add(&mut board.id, FundBpsKey {}, bps) };
    event::emit(FundBpsChanged { fund_bps: bps });
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

/// Stake GTS: flexible (1x) or locked for 7 days (1.5x). Yield is paid in SUI from every round.
public fun stake(board: &mut Board, gts: Coin<GTS>, locked: bool, clock: &Clock, ctx: &mut TxContext) {
    check_version(board);
    staking::stake(pool_mut(board), gts, locked, clock, ctx)
}

/// Take staked GTS out: flexible any time, locked once its 7 days have passed.
public fun unstake(board: &mut Board, amount: u64, locked: bool, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    check_version(board);
    staking::unstake(pool_mut(board), amount, locked, clock, ctx)
}

/// Claim all SUI yield of the sender.
public fun claim_yield(board: &mut Board, ctx: &mut TxContext): Coin<SUI> {
    check_version(board);
    staking::claim(pool_mut(board), ctx)
}

/// Drop `player`'s ended lock back to 1x. Anyone may call it.
public fun poke(board: &mut Board, player: address, clock: &Clock) {
    check_version(board);
    staking::poke(pool_mut(board), player, clock)
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

    let seat = SeatKey { round_id: board.cur_id, player: tx_context::sender(ctx) };
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
    while (i < GRID) {
        let a = *vector::borrow(&amounts, i);
        if (a > 0) {
            let bd = vector::borrow_mut(&mut board.cur_deployed, i);
            *bd = *bd + a;
            let md = vector::borrow_mut(&mut miner.deployed, i);
            *md = *md + a;
        };
        i = i + 1;
    };
    board.cur_total = board.cur_total + sum;
    miner.total_deployed = miner.total_deployed + sum;
    balance::join(&mut board.pot, coin::into_balance(payment));
    event::emit(Deployed { round_id: board.cur_id, player: tx_context::sender(ctx), amounts, total: sum });
}

/// Settle the ended round: draw the winner, take fees, assign the GTS reward, archive, start the next.
/// `entry` + non-`public` so it cannot be composed/aborted based on the outcome.
entry fun settle(board: &mut Board, treasury: &mut Treasury, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    let odds = board.ml_odds;
    settle_with_odds(board, treasury, r, clock, odds, ctx)
}

fun settle_with_odds(board: &mut Board, treasury: &mut Treasury, r: &Random, clock: &Clock, odds: u64, ctx: &mut TxContext) {
    check_version(board);
    assert!(board.cur_started, ENotStarted);
    assert!(clock::timestamp_ms(clock) >= board.cur_end_ms, ERoundNotEnded);

    if (!df::exists(&board.id, V5FromKey {})) { df::add(&mut board.id, V5FromKey {}, board.cur_id) };
    if (!df::exists(&board.id, RefineFromKey {})) { df::add(&mut board.id, RefineFromKey {}, clock::timestamp_ms(clock)) };
    if (!df::exists(&board.id, V8FromKey {})) { df::add(&mut board.id, V8FromKey {}, board.cur_id) };

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
    let buyback_full = mul_div(losing_pot, board.buyback_bps, 10_000);
    let stake_part = mul_div(losing_pot, stake_bps(board), 10_000);
    let fund_part = mul_div(losing_pot, fund_bps(board), 10_000);
    // The drawer is paid from the reserve share first, then from the buyback share.
    let from_vault = if (vault_full < DRAW_REWARD_MAX) { vault_full } else { DRAW_REWARD_MAX };
    let rest = DRAW_REWARD_MAX - from_vault;
    let from_buyback = if (buyback_full < rest) { buyback_full } else { rest };
    let draw_reward = from_buyback + from_vault;
    let buyback_part = buyback_full - from_buyback;
    let mut vault_part = vault_full - from_vault;
    let mut losing_after_fee = losing_pot - vault_full - dev_part - buyback_full - stake_part - fund_part;

    // Stakers' share: split among everyone staked now, or to the reserve when nobody is.
    if (stake_part > 0) {
        let part = balance::split(&mut board.pot, stake_part);
        let round_id = board.cur_id;
        let pool = df::borrow_mut<StakeKey, StakePool>(&mut board.id, StakeKey {});
        if (staking::has_stakers(pool)) { staking::reward(pool, round_id, part) }
        else { balance::join(&mut board.pot, part); vault_part = vault_part + stake_part; };
    };
    if (vault_part > 0) { gts::vault_add(treasury, balance::split(&mut board.pot, vault_part)); };
    if (dev_part > 0) { balance::join(&mut board.dev_fees, balance::split(&mut board.pot, dev_part)); };
    if (buyback_part > 0) { balance::join(&mut board.buyback, balance::split(&mut board.pot, buyback_part)); };
    if (draw_reward > 0) {
        let settler = tx_context::sender(ctx);
        transfer::public_transfer(coin::from_balance(balance::split(&mut board.pot, draw_reward), ctx), settler);
        event::emit(DrawPaid { round_id: board.cur_id, settler, amount: draw_reward });
    };

    // Wealth Fund: with no one on the winning square the rest is split between it and the reserve.
    // Then, in any round, a 1 in `odds` chance it is paid to the holder of the drawn ticket.
    // Every round first adds its `fund_bps` share.
    let mut ml_added = fund_part;
    let mut ml_paid = 0;
    if (fund_part > 0) { balance::join(&mut board.motherlode, balance::split(&mut board.pot, fund_part)); };
    if (winners_total == 0) {
        if (losing_after_fee > 0) {
            // set_params keeps this within losing_after_fee.
            let no_winner_part = mul_div(losing_pot, board.ml_share_bps, 10_000);
            ml_added = ml_added + no_winner_part;
            let to_vault = losing_after_fee - no_winner_part;
            if (no_winner_part > 0) { balance::join(&mut board.motherlode, balance::split(&mut board.pot, no_winner_part)); };
            if (to_vault > 0) {
                gts::vault_add(treasury, balance::split(&mut board.pot, to_vault));
                vault_part = vault_part + to_vault;
            };
            losing_after_fee = 0;
        };
    };
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

    event::emit(RoundSettled {
        round_id: board.cur_id,
        winning_square: winning,
        total_deployed: board.cur_total,
        winners_total,
        round_reward: reward,
        losing_pot,
        winners_payout: losing_after_fee,
        vault_fee: vault_part,
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

fun add_unrefined(board: &mut Board, player: address, gts: Balance<GTS>, ctx: &TxContext) {
    let amount = balance::value(&gts);
    let acc = board.acc;
    let key = UnrefinedKey { player };
    if (!df::exists(&board.id, key)) {
        df::add(&mut board.id, key, Unrefined { amount: 0, bonus: 0, snap: acc });
    };
    // Start the 7-day clock the first time (the end of the last round is "now" enough here).
    let ck = RefineClockKey { player };
    if (!df::exists(&board.id, ck)) {
        let now = tx_context::epoch_timestamp_ms(ctx);
        let t = if (board.cur_end_ms > now) { board.cur_end_ms } else { now };
        df::add(&mut board.id, ck, t);
    };
    let u = df::borrow_mut<UnrefinedKey, Unrefined>(&mut board.id, key);
    u.bonus = u.bonus + earned(u.amount, acc, u.snap);
    u.snap = acc;
    u.amount = u.amount + amount;
    board.unrefined_total = board.unrefined_total + amount;
    balance::join(&mut board.unrefined, gts);
}

/// Claim a settled round: GTS mining reward (everyone) + SUI winnings (if on the winning square).
/// Mined GTS goes to the unrefined balance (a House bot gets it here). Returns (GTS, SUI).
public fun claim(
    board: &mut Board,
    miner: &mut Miner,
    treasury: &mut Treasury,
    ctx: &mut TxContext,
): (Coin<GTS>, Coin<SUI>) {
    check_version(board);
    assert!(miner.round_id != 0, ENothingToClaim);
    assert!(table::contains(&board.rounds, miner.round_id), ENotSettled);
    let round_id = miner.round_id;
    let player = tx_context::sender(ctx);
    let info = table::borrow(&board.rounds, round_id);
    let (round_reward, round_total, w) = (info.round_reward, info.total_deployed, (info.winning_square as u64));
    let (pot_after_fee, winners_total) = (info.losing_pot_after_fee, info.winners_total);

    let v5 = round_id >= v5_from(board);
    let my_win = *vector::borrow(&miner.deployed, w);
    // v5-v7: GTS by SUI lost in the round; before v5 and from v8: by SUI deployed.
    let gts_amt = if (v5 && round_id < v8_from(board)) {
        let lost_total = round_total - winners_total;
        if (lost_total == 0) { 0 } else { mul_div(round_reward, miner.total_deployed - my_win, lost_total) }
    } else if (round_total == 0) { 0 } else { mul_div(round_reward, miner.total_deployed, round_total) };
    let mined = gts::mint(treasury, gts_amt, ctx);
    let mined_amt = coin::value(&mined);
    let gts_coin = if (mined_amt == 0 || is_bot(player)) { mined } else {
        add_unrefined(board, player, coin::into_balance(mined), ctx);
        coin::zero<GTS>(ctx)
    };

    // SUI: own stake on the winning square back, plus a share of the losing pot in proportion to it.
    // Before v5 also any Wealth Fund, and only the part of the round deposit on that square was kept.
    let sui_coin = if (v5 && my_win > 0) {
        coin::from_balance(balance::split(&mut board.pot, my_win + mul_div(pot_after_fee, my_win, winners_total)), ctx)
    } else if (my_win > 0 && winners_total > 0) {
        let share = mul_div(pot_after_fee, my_win, winners_total);
        let jk = JackpotKey { round_id };
        let jackpot = if (df::exists(&board.id, jk)) { mul_div(*df::borrow<JackpotKey, u64>(&board.id, jk), my_win, winners_total) } else { 0 };
        let pot_share = share - jackpot;
        let my_total = miner.total_deployed;
        let pot_kept = mul_div(pot_share, my_win, my_total);
        let jackpot_kept = if (is_bot(player)) { 0 } else { mul_div(jackpot, my_win, my_total) };
        let to_reserve = pot_share - pot_kept;
        let to_fund = jackpot - jackpot_kept;
        if (to_reserve > 0) { gts::vault_add(treasury, balance::split(&mut board.pot, to_reserve)); };
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
    if (n > 0 && !no_tickets(player)) { add_tickets(board, round_id, player, n) };

    let seat = SeatKey { round_id, player };
    if (df::exists(&board.id, seat) && *df::borrow<SeatKey, ID>(&board.id, seat) == object::id(miner)) {
        let _: ID = df::remove(&mut board.id, seat);
    };

    event::emit(Claimed { round_id, player, gts: mined_amt, sui: coin::value(&sui_coin) });

    miner.round_id = 0;
    miner.total_deployed = 0;
    miner.deployed = zeros();

    (gts_coin, sui_coin)
}

/// `claim` that sends any GTS to the sender and returns the SUI.
public fun claim_sui(board: &mut Board, miner: &mut Miner, treasury: &mut Treasury, ctx: &mut TxContext): Coin<SUI> {
    let (g, s) = claim(board, miner, treasury, ctx);
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

/// Withdraw the whole unrefined balance plus any holder bonus earned before v6. The fee (see
/// `fee_bps_at`) is burned; the 7-day clock restarts now.
public fun withdraw_gts_v6(board: &mut Board, treasury: &mut Treasury, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
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
    if (fee > 0) { gts::burn(treasury, coin::from_balance(balance::split(&mut board.unrefined, fee), ctx)) };
    let ck = RefineClockKey { player };
    if (df::exists(&board.id, ck)) { *df::borrow_mut<RefineClockKey, u64>(&mut board.id, ck) = now }
    else { df::add(&mut board.id, ck, now) };
    event::emit(GtsWithdrawn { player, amount, fee, bonus, paid: amount - fee + bonus, burned: fee });
    coin::from_balance(out, ctx)
}

/// Send accrued creator fees to DEV_ADDR. Anyone may call; funds can only go to DEV_ADDR.
entry fun withdraw_dev_fees(board: &mut Board, ctx: &mut TxContext) {
    check_version(board);
    let amt = balance::value(&board.dev_fees);
    if (amt > 0) {
        transfer::public_transfer(coin::from_balance(balance::split(&mut board.dev_fees, amt), ctx), DEV_ADDR);
    };
}

/// Off from v5: the buyback share is fixed at 0, so no SUI can be taken from the game.
public fun take_buyback(_: &AdminCap, _board: &mut Board, _ctx: &mut TxContext): Coin<SUI> {
    abort EBuybackOff
}

/// Buyback, step 1 (keeper only): take all the saved buyback SUI to buy GTS in the same transaction.
public fun buyback_take(board: &mut Board, ctx: &mut TxContext): (Coin<SUI>, BuybackReceipt) {
    check_version(board);
    assert!(tx_context::sender(ctx) == BUYER_ADDR, ENotBuyer);
    let sui = balance::value(&board.buyback);
    assert!(sui > 0, ENoBuyback);
    (coin::from_balance(balance::withdraw_all(&mut board.buyback), ctx), BuybackReceipt { sui })
}

/// Buyback, step 2: burn the GTS bought and return any SUI not spent. Closes the receipt.
public fun buyback_burn(board: &mut Board, treasury: &mut Treasury, receipt: BuybackReceipt, gts: Coin<GTS>, left: Coin<SUI>) {
    check_version(board);
    let BuybackReceipt { sui } = receipt;
    let back = coin::value(&left);
    assert!(back <= sui, EAmountMismatch);
    let gts_burned = coin::value(&gts);
    assert!(gts_burned > 0, ENothingBought);
    balance::join(&mut board.buyback, coin::into_balance(left));
    gts::burn(treasury, gts);
    event::emit(BuybackDone { sui_spent: sui - back, gts_burned });
}

/// Burn bought-back GTS: redeem it and put the SUI straight back, so supply falls and the reserve stays.
public fun burn_bought(treasury: &mut Treasury, gts: Coin<GTS>, ctx: &mut TxContext) {
    let amount = coin::value(&gts);
    if (amount == 0) { coin::destroy_zero(gts); return };
    let sui_out = gts::redeem(treasury, gts, ctx);
    gts::vault_add(treasury, coin::into_balance(sui_out));
    event::emit(BuybackBurned { amount });
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
    (board.ml_odds, board.ml_share_bps, board.vault_bps, board.buyback_bps, DEV_BPS, board.refine_fee_bps, board.paused)
}
/// (step reward, rounds per step, decay ppm, rounds into the step, full-reward deposit, GTS committed).
public fun emission(board: &Board): (u64, u64, u64, u64, u64, u64) {
    (board.reward, board.step_rounds, board.decay_ppm, board.step_count, board.full_reward_deploy, board.committed)
}
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
/// Stakers' share of the losing pot in bps (0 before staking is set up).
public fun staking_bps(board: &Board): u64 { stake_bps(board) }
/// (GTS staked, total weight in tenths, SUI paid to stakers so far, SUI waiting to be claimed).
public fun staking_totals(board: &Board): (u64, u128, u64, u64) {
    if (!df::exists(&board.id, StakeKey {})) { return (0, 0, 0, 0) };
    staking::totals(df::borrow<StakeKey, StakePool>(&board.id, StakeKey {}))
}
/// (GTS staked, locked until (ms, 0 if flexible), SUI claimable) of one of `player`'s positions.
public fun staking_position(board: &Board, player: address, locked: bool): (u64, u64, u64) {
    if (!df::exists(&board.id, StakeKey {})) { return (0, 0, 0) };
    staking::position(df::borrow<StakeKey, StakePool>(&board.id, StakeKey {}), player, locked)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun settle_for_testing(board: &mut Board, treasury: &mut Treasury, r: &Random, clock: &Clock, ctx: &mut TxContext) {
    settle(board, treasury, r, clock, ctx)
}

#[test_only]
public fun settle_with_odds_for_testing(
    board: &mut Board, treasury: &mut Treasury, r: &Random, clock: &Clock, odds: u64, ctx: &mut TxContext,
) { settle_with_odds(board, treasury, r, clock, odds, ctx) }

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
public fun set_committed_for_testing(board: &mut Board, committed: u64) { board.committed = committed }
