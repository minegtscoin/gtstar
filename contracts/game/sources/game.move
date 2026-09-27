/// GTStar core game: a 5x5 grid, 60s rounds, on Sui.
///
/// This package is upgradeable (bug fixes, improvements). The token, its emission ceiling
/// and the SUI reserve live in the separate, immutable `gts_token` package. The game holds
/// the MinterCap and the Board's SUI (pot, Motherlode, creator fees), so an upgrade could
/// mint up to that ceiling and move the Board's SUI: the UpgradeCap is the trust point.
///
/// Each round players deploy SUI onto squares. At settlement one winning square
/// is drawn with `sui::random`. SUI from losing squares (minus a 5% fee) is split
/// PROPORTIONALLY among everyone on the winning square (fairer than ORE's single
/// winner). Separately, a halving GTS emission is split among ALL participants —
/// winners and losers alike ("rewards everyone").
///
/// Since v7 a winner's share of the pot is also scaled by the part of their own round deposit
/// that sat on the winning square: covering many squares cannot collect the whole pot. The
/// part they do not keep goes to the GTS reserve (and any Motherlode part back to it).
/// One address may use only one Miner per round, so the rule cannot be dodged with extra Miners.
///
/// Motherlode (shown to players as the Wealth Fund): when no one is on the winning square,
/// MOTHERLODE_SHARE_BPS of the losing pot rolls into it, 1% goes to the creator and the rest to
/// the GTS reserve. Every round that has a winner also has a 1 in MOTHERLODE_ODDS chance (drawn
/// with `sui::random`) to pay the whole Motherlode to the winning square, split like the normal
/// pot. No GTStar House bot (House, Bot 1-3, Matcher) ever keeps any of it: its share goes back.
///
/// Unrefined GTS (since v8, like ORE): mined GTS is not paid out at claim. It waits on the Board in
/// the player's unrefined balance. Withdrawing it costs REFINE_FEE_BPS (10%), and that fee is shared
/// among everyone still holding unrefined GTS, in proportion to their balance: whoever sells at once
/// pays the players who wait. If nobody else is holding, the fee is burned for the reserve (redeem +
/// vault_add), so the floor rises. The House bots burn or pool their GTS, so they are paid at claim as
/// before: they never pay the fee and never take a share of it.
///
/// Settings: the owner's AdminCap can change the game settings at once, only inside fixed bounds
/// (odds, never better than 1 in MIN_ODDS, the Motherlode share, the reserve fee, the minimum deposit, round timing, pause). The
/// creator fee can only go down from 1%. Nothing here can mint GTS or move the pot, the
/// Motherlode or the reserve; a pause only stops new deposits (settle and claim always work).
module gtstar::game;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::dynamic_field as df;
use sui::event;
use sui::random::{Self, Random};
use sui::sui::SUI;
use sui::table::{Self, Table};
use gts_token::gts::{Self, Treasury, GTS, MinterCap};
use gtstar::staking::{Self, StakePool};

// ===== Constants =====
const GRID: u64 = 25;
/// Round-based emission (like Bitcoin blocks): 1 GTS per round to miners, halving every
/// 262,000 rounds (~6 months at one round a minute), 7 periods, then zero. Quiet weeks only
/// stretch the schedule. Stakers receive an extra 10% on top, streamed.
/// Rounds last at least a minute, so this stays inside the token's time-based ceiling, and the
/// 7-period total (571,896.875 GTS) is below that ceiling's final value (572,003.2 GTS).
/// Since v6 the full reward needs FULL_REWARD_DEPLOY SUI in the round; smaller rounds get a
/// proportional part and the rest is never minted, so cheap rounds cannot dilute the reserve.
const INITIAL_ROUND_REWARD: u64 = 1_000_000_000;   // 1 GTS / round
const STAKER_SHARE_BPS: u64 = 1_000;               // +10% of the round reward, to stakers
const HALVING_ROUNDS: u64 = 262_000;
const EMISSION_PERIODS: u64 = 7;
/// SUI a round needs for the full GTS reward (1 SUI). About 4% of a round reaches the reserve,
/// so at 1 GTS per SUI every new GTS brings roughly its floor price with it.
const FULL_REWARD_DEPLOY: u64 = 1_000_000_000;

/// Creator/dev reward: 1% of the losing pot each round, accrued on the Board and
/// paid out (permissionlessly) only to this address via `withdraw_dev_fees`.
const DEV_ADDR: address = @0xa19b2d37f95ca4c48efafb2cd01d0f97f33852457daa27cfba3de37fdec24d4b;

/// Default chance per round with a winner that the Motherlode pays out: 1 in MOTHERLODE_ODDS
/// (about once every 500 rounds, so it grows into a real jackpot). Adjustable, see `set_params`.
const MOTHERLODE_ODDS: u64 = 500;
/// Default share of a no-winner round's losing pot that rolls into the Motherlode (19.5%). The
/// creator keeps its 1% and the rest (79.5%, including the usual 4%) goes to the GTS reserve.
const MOTHERLODE_SHARE_BPS: u64 = 1_950;
/// The only address that can take the AdminCap, once (the deployer).
const OWNER_ADDR: address = @0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e;
// Bounds for `set_params`.
/// The Motherlode odds can never be set better than 1 in MIN_ODDS, so it can never be made to pay
/// out at once.
const MIN_ODDS: u64 = 500;
const MAX_ODDS: u64 = 1_000_000;
const MAX_VAULT_BPS: u64 = 2_000;          // reserve fee up to 20%
const MAX_DEV_BPS: u64 = 100;              // creator fee never above 1%
const MIN_MIN_DEPLOY: u64 = 1_000_000;     // 0.001 SUI
const MAX_MIN_DEPLOY: u64 = 10_000_000_000; // 10 SUI
const MIN_ROUND_MS: u64 = 30_000;
const MAX_ROUND_MS: u64 = 3_600_000;
/// GTStar House wallet (see the site): its share of a Motherlode payout goes back to the Motherlode.
const HOUSE_ADDR: address = @0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a;

/// Share of an unrefined balance kept back at withdrawal and given to the players still holding (10%).
const REFINE_FEE_BPS: u64 = 1_000;
/// Precision of the per-GTS fee accumulator.
const REFINE_SCALE: u256 = 1_000_000_000_000_000_000;
/// The other House bots (Bot 1, Bot 2, Bot 3, Matcher; see the site). With HOUSE_ADDR they get mined
/// GTS at claim, stay out of the unrefined balances and return any Motherlode share.
const BOT1_ADDR: address = @0xab4deb30e34487f75bf5632038e46d419c6238b4ea52d35f3ad3421a5bb268fa;
const BOT2_ADDR: address = @0x779b49acf4db04d835440c12ffe24929de505a9b8112b4040da5103d225b37e7;
const BOT3_ADDR: address = @0x0b8d118f954c90a87abc2b3e07c408681efed88b552ebcd94fc5cb292f3c9dc4;
const MATCHER_ADDR: address = @0x2a869532f55594a9ffed4a5d7ee2a48cf5c857ac740090d39c733e0279b6a8de;

/// Package version. Every call that changes the Board runs `check_version`, which blocks all
/// older versions of this package (see there). Bump it on every upgrade.
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
const ENotInstalled: u64 = 12;
const EAlreadyInstalled: u64 = 13;
const EWrongVersion: u64 = 14;
const EOneMinerPerRound: u64 = 15;
const ENotOwner: u64 = 16;
const EAdminTaken: u64 = 17;
const EBadParams: u64 = 18;
const EPaused: u64 = 19;
const ENothingToWithdraw: u64 = 20;


/// Archived, settled round.
public struct RoundInfo has store {
    total_deployed: u64,
    deployed: vector<u64>,       // per-square totals
    winning_square: u8,
    losing_pot_after_fee: u64,   // SUI to split among winners
    winners_total: u64,          // total SUI on winning square
    round_reward: u64,           // GTS emitted this round
    rng: u64,
}

/// The game board (shared).
public struct Board has key {
    id: UID,
    cur_id: u64,
    cur_started: bool,
    cur_start_ms: u64,
    cur_end_ms: u64,
    cur_total: u64,
    cur_deployed: vector<u64>,
    cur_players: u64,
    genesis_ms: u64,  // set at install (emission itself counts rounds)
    minter: Option<MinterCap>,
    rounds: Table<u64, RoundInfo>,
    pot: Balance<SUI>,
    dev_fees: Balance<SUI>,
    // config
    round_ms: u64,
    freeze_ms: u64,
    min_deploy: u64,
    vault_bps: u64,
    stakers_bps: u64,
    dev_bps: u64,
}

/// Dynamic field on the Board holding the Motherlode (Balance<SUI>).
public struct MotherlodeKey has copy, drop, store {}
/// Dynamic field on the Board: SUI a round received from the Motherlode (only rounds that hit).
public struct JackpotKey has copy, drop, store { round_id: u64 }
/// Dynamic field on the Board holding the MinterCap (since v5; versions 1-4 kept it in `minter`).
public struct MinterKey has copy, drop, store {}
/// Dynamic field on the Board: the newest package version that has used it.
public struct VersionKey has copy, drop, store {}
/// Dynamic field on the Board: the first round paid with the v7 split (see `claim`).
public struct FairFromKey has copy, drop, store {}
/// Dynamic field on the Board: the Miner `player` uses in `round_id` (one per address and round).
/// Removed when that Miner claims the round.
public struct SeatKey has copy, drop, store { round_id: u64, player: address }
/// Dynamic field on the Board: adjustable settings that are not Board fields (see `set_params`).
public struct ParamsKey has copy, drop, store {}
public struct Params has copy, drop, store { ml_odds: u64, ml_share_bps: u64, paused: bool }
/// Dynamic field on the Board: set once the AdminCap has been taken.
public struct AdminKey has copy, drop, store {}

/// Dynamic field on the Board holding all unrefined GTS (since v8).
public struct RefineryKey has copy, drop, store {}
/// `total`: unrefined GTS of all players. `acc`: fee GTS earned per unrefined GTS so far, scaled by REFINE_SCALE.
public struct Refinery has store { gts: Balance<GTS>, total: u64, acc: u256 }
/// Dynamic field on the Board: one player's unrefined balance. Removed when it is withdrawn.
public struct UnrefinedKey has copy, drop, store { player: address }
/// `amount`: mined GTS waiting. `bonus`: fee GTS earned up to `snap` (the accumulator when last updated).
public struct Unrefined has store, drop { amount: u64, bonus: u64, snap: u256 }

/// Right to change the game settings within the bounds above.
public struct AdminCap has key, store { id: UID }

public struct ParamsChanged has copy, drop {
    ml_odds: u64,
    ml_share_bps: u64,
    vault_bps: u64,
    dev_bps: u64,
    min_deploy: u64,
    round_ms: u64,
    freeze_ms: u64,
    paused: bool,
}

/// Per-player miner (owned). Holds the current unclaimed round only.
public struct Miner has key, store {
    id: UID,
    round_id: u64,          // 0 = idle/claimed
    deployed: vector<u64>,
    total_deployed: u64,
}

// ===== Events =====
public struct RoundSettled has copy, drop {
    round_id: u64,
    winning_square: u8,
    total_deployed: u64,
    winners_total: u64,
    round_reward: u64,
    losing_pot: u64,
    winners_payout: u64,  // losing pot after fees, split across the winning tile
    vault_fee: u64,
    staker_reward: u64,   // GTS minted to the staking stream
    dev_fee: u64,
    players: u64,
}

/// Emitted on every settle by this version: SUI added to / paid from the Motherlode, and what is left.
public struct MotherlodeUpdate has copy, drop {
    round_id: u64,
    added: u64,
    paid: u64,
    balance: u64,
}

/// The GTStar House's share of a Motherlode payout, returned to the Motherlode at claim.
public struct MotherlodeReturned has copy, drop {
    round_id: u64,
    amount: u64,
    balance: u64,
}

/// Winnings a player did not keep at claim (v7 split, or the House's Motherlode share):
/// `to_reserve` went to the GTS reserve, `to_fund` back to the Motherlode.
public struct Forfeited has copy, drop {
    round_id: u64,
    player: address,
    to_reserve: u64,
    to_fund: u64,
}

/// A player withdrew their unrefined balance: `paid` = amount - fee + bonus. The fee went to the
/// other holders, or was `burned` for the reserve when nobody else was holding.
public struct GtsWithdrawn has copy, drop {
    player: address,
    amount: u64,
    fee: u64,
    bonus: u64,
    paid: u64,
    burned: u64,
}

public struct Deployed has copy, drop {
    round_id: u64,
    player: address,
    amounts: vector<u64>,
    total: u64,
}

public struct Claimed has copy, drop {
    round_id: u64,
    player: address,
    gts: u64,
    sui: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(Board {
        id: object::new(ctx),
        cur_id: 1, // round ids start at 1; 0 is the "idle/claimed" sentinel on Miner

        cur_started: false,
        cur_start_ms: 0,
        cur_end_ms: 0,
        cur_total: 0,
        cur_deployed: zeros(),
        cur_players: 0,
        genesis_ms: 0,
        minter: option::none(),
        rounds: table::new<u64, RoundInfo>(ctx),
        pot: balance::zero<SUI>(),
        dev_fees: balance::zero<SUI>(),
        round_ms: 60_000,
        freeze_ms: 5_000,
        min_deploy: 10_000_000,     // 0.01 SUI
        vault_bps: 400,             // 4% -> reserve (backs GTS)
        stakers_bps: 0,             // stakers are paid in GTS emission, not SUI
        dev_bps: 100,               // 1% -> creator  (winners keep 95%)
    });
}

fun zeros(): vector<u64> {
    let mut v = vector[];
    let mut i = 0;
    while (i < GRID) { vector::push_back(&mut v, 0); i = i + 1; };
    v
}

/// Miner reward for round `round_id` (ids start at 1).
fun reward_for_round(round_id: u64): u64 {
    if (round_id == 0) { return 0 };
    let epoch = (round_id - 1) / HALVING_ROUNDS;
    if (epoch >= EMISSION_PERIODS) { 0 } else { INITIAL_ROUND_REWARD >> (epoch as u8) }
}

/// The round reward scaled by the SUI deployed: full at FULL_REWARD_DEPLOY or more.
fun scaled_reward(base: u64, total: u64): u64 {
    if (total >= FULL_REWARD_DEPLOY) { base }
    else { (((base as u128) * (total as u128)) / (FULL_REWARD_DEPLOY as u128)) as u64 }
}

/// Only the latest package version may change the Board. Versions 1-4 read the MinterCap from
/// `board.minter`, so the first call by v5 moves it into a field they do not know: from then on
/// they abort in deploy, settle and claim. From v5 on, each version records itself in VersionKey
/// and refuses to run once a newer version has.
fun check_version(board: &mut Board) {
    if (option::is_some(&board.minter)) {
        let cap = option::extract(&mut board.minter);
        df::add(&mut board.id, MinterKey {}, cap);
    };
    if (!df::exists(&board.id, VersionKey {})) {
        df::add(&mut board.id, VersionKey {}, VERSION);
    };
    let v = df::borrow_mut<VersionKey, u64>(&mut board.id, VersionKey {});
    assert!(*v <= VERSION, EWrongVersion);
    *v = VERSION;
    if (!df::exists(&board.id, ParamsKey {})) {
        df::add(&mut board.id, ParamsKey {}, Params { ml_odds: MOTHERLODE_ODDS, ml_share_bps: MOTHERLODE_SHARE_BPS, paused: false });
    };
    // v7 split: from the first round that no older version can have taken deposits for.
    if (!df::exists(&board.id, FairFromKey {})) {
        let from = if (board.cur_started) { board.cur_id + 1 } else { board.cur_id };
        df::add(&mut board.id, FairFromKey {}, from);
    };
    if (!df::exists(&board.id, RefineryKey {})) {
        df::add(&mut board.id, RefineryKey {}, Refinery { gts: balance::zero<GTS>(), total: 0, acc: 0 });
    };
}

/// House bots: paid mined GTS at claim, outside the unrefined balances.
fun is_bot(a: address): bool {
    a == HOUSE_ADDR || a == BOT1_ADDR || a == BOT2_ADDR || a == BOT3_ADDR || a == MATCHER_ADDR
}

fun refinery(board: &Board): &Refinery { df::borrow<RefineryKey, Refinery>(&board.id, RefineryKey {}) }

/// Fee GTS earned by `amount` unrefined GTS since the accumulator was at `snap`.
fun earned(amount: u64, acc: u256, snap: u256): u64 { (((amount as u256) * (acc - snap)) / REFINE_SCALE) as u64 }

/// Add mined GTS to `player`'s unrefined balance.
fun add_unrefined(board: &mut Board, player: address, gts: Balance<GTS>) {
    let amount = balance::value(&gts);
    let acc = refinery(board).acc;
    let key = UnrefinedKey { player };
    if (!df::exists(&board.id, key)) {
        df::add(&mut board.id, key, Unrefined { amount: 0, bonus: 0, snap: acc });
    };
    let u = df::borrow_mut<UnrefinedKey, Unrefined>(&mut board.id, key);
    u.bonus = u.bonus + earned(u.amount, acc, u.snap);
    u.snap = acc;
    u.amount = u.amount + amount;
    let r = df::borrow_mut<RefineryKey, Refinery>(&mut board.id, RefineryKey {});
    r.total = r.total + amount;
    balance::join(&mut r.gts, gts);
}

fun fair_from(board: &Board): u64 {
    if (df::exists(&board.id, FairFromKey {})) { *df::borrow<FairFromKey, u64>(&board.id, FairFromKey {}) }
    else { 18_446_744_073_709_551_615 }
}

fun params(board: &Board): Params { *df::borrow<ParamsKey, Params>(&board.id, ParamsKey {}) }

/// The owner takes the AdminCap, once.
entry fun take_admin(board: &mut Board, ctx: &mut TxContext) {
    check_version(board);
    assert!(tx_context::sender(ctx) == OWNER_ADDR, ENotOwner);
    assert!(!df::exists(&board.id, AdminKey {}), EAdminTaken);
    df::add(&mut board.id, AdminKey {}, true);
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, OWNER_ADDR);
}

/// Change the game settings at once, inside the fixed bounds. Fee changes apply from the next settle.
public fun set_params(
    _: &AdminCap,
    board: &mut Board,
    ml_odds: u64,
    ml_share_bps: u64,
    vault_bps: u64,
    dev_bps: u64,
    min_deploy: u64,
    round_ms: u64,
    freeze_ms: u64,
    paused: bool,
) {
    check_version(board);
    assert!(ml_odds >= MIN_ODDS && ml_odds <= MAX_ODDS, EBadParams);
    assert!(vault_bps <= MAX_VAULT_BPS && dev_bps <= MAX_DEV_BPS, EBadParams);
    assert!(ml_share_bps + vault_bps + dev_bps <= 10_000, EBadParams);
    assert!(min_deploy >= MIN_MIN_DEPLOY && min_deploy <= MAX_MIN_DEPLOY, EBadParams);
    assert!(round_ms >= MIN_ROUND_MS && round_ms <= MAX_ROUND_MS && freeze_ms <= round_ms / 2, EBadParams);
    *df::borrow_mut<ParamsKey, Params>(&mut board.id, ParamsKey {}) = Params { ml_odds, ml_share_bps, paused };
    board.vault_bps = vault_bps;
    board.dev_bps = dev_bps;
    board.min_deploy = min_deploy;
    board.round_ms = round_ms;
    board.freeze_ms = freeze_ms;
    event::emit(ParamsChanged { ml_odds, ml_share_bps, vault_bps, dev_bps, min_deploy, round_ms, freeze_ms, paused });
}

fun mul_div(a: u64, b: u64, c: u64): u64 { (((a as u128) * (b as u128)) / (c as u128)) as u64 }

fun has_minter(board: &Board): bool {
    option::is_some(&board.minter) || df::exists(&board.id, MinterKey {})
}

fun minter(board: &Board): &MinterCap { df::borrow<MinterKey, MinterCap>(&board.id, MinterKey {}) }

/// One-time launch step: hand the game its minting right and start the emission clock.
public fun install(board: &mut Board, cap: MinterCap, treasury: &mut Treasury, clock: &Clock) {
    check_version(board);
    assert!(!has_minter(board), EAlreadyInstalled);
    gts::start(treasury, &cap, clock);
    board.genesis_ms = clock::timestamp_ms(clock);
    df::add(&mut board.id, MinterKey {}, cap);
}

/// Create a miner object (once per player).
public fun new_miner(ctx: &mut TxContext): Miner {
    Miner { id: object::new(ctx), round_id: 0, deployed: zeros(), total_deployed: 0 }
}

entry fun create_miner(ctx: &mut TxContext) {
    transfer::public_transfer(new_miner(ctx), tx_context::sender(ctx));
}

/// Deploy SUI onto squares for the current round.
/// `amounts` is a length-25 vector; `payment` value must equal the sum.
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
    assert!(has_minter(board), ENotInstalled);
    assert!(!params(board).paused, EPaused);
    let now = clock::timestamp_ms(clock);

    // Lazy-start the round on first deploy.
    if (!board.cur_started) {
        board.cur_start_ms = now;
        board.cur_end_ms = now + board.round_ms;
        board.cur_started = true;
    };
    assert!(now < board.cur_end_ms, ERoundEnded);                 // must settle first
    assert!(now <= board.cur_end_ms - board.freeze_ms, EFrozen);  // no last-second sniping
    assert!(miner.round_id == 0 || miner.round_id == board.cur_id, EUnclaimed);

    // One Miner per address per round, so a player's deposits are all counted together at claim.
    let seat = SeatKey { round_id: board.cur_id, player: tx_context::sender(ctx) };
    if (df::exists(&board.id, seat)) {
        assert!(*df::borrow<SeatKey, ID>(&board.id, seat) == object::id(miner), EOneMinerPerRound);
    } else {
        df::add(&mut board.id, seat, object::id(miner));
    };

    // Validate amounts.
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

    // Record positions.
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

/// Settle the ended round: draw the winner, take fees, archive, start the next.
/// `entry` + non-`public` so it cannot be composed/aborted based on the outcome.
entry fun settle(
    board: &mut Board,
    treasury: &mut Treasury,
    pool: &mut StakePool,
    r: &Random,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    check_version(board);
    let odds = params(board).ml_odds;
    let odds = if (odds < MIN_ODDS) { MIN_ODDS } else { odds };
    settle_with_odds(board, treasury, pool, r, clock, odds, ctx)
}

fun settle_with_odds(
    board: &mut Board,
    treasury: &mut Treasury,
    pool: &mut StakePool,
    r: &Random,
    clock: &Clock,
    odds: u64,
    ctx: &mut TxContext,
) {
    check_version(board);
    assert!(board.cur_started, ENotStarted);
    assert!(clock::timestamp_ms(clock) >= board.cur_end_ms, ERoundNotEnded);

    let mut gen = random::new_generator(r, ctx);
    let rng = random::generate_u64(&mut gen);
    let winning = ((rng % GRID) as u8);

    let winners_total = *vector::borrow(&board.cur_deployed, (winning as u64));
    let losing_pot = board.cur_total - winners_total;

    let mut vault_part = losing_pot * board.vault_bps / 10_000;
    let dev_part = losing_pot * board.dev_bps / 10_000;
    let mut losing_after_fee = losing_pot - vault_part - dev_part;

    if (vault_part > 0) { gts::vault_add(treasury, balance::split(&mut board.pot, vault_part)); };
    if (dev_part > 0) { balance::join(&mut board.dev_fees, balance::split(&mut board.pot, dev_part)); };

    // Motherlode: with no one on the winning square the winners' pot is split between it and
    // the reserve; with a winner there is a 1 in MOTHERLODE_ODDS chance it is paid out.
    if (!df::exists(&board.id, MotherlodeKey {})) {
        df::add(&mut board.id, MotherlodeKey {}, balance::zero<SUI>());
    };
    let mut ml_added = 0;
    let mut ml_paid = 0;
    if (winners_total == 0) {
        if (losing_after_fee > 0) {
            // The bounds keep this within losing_after_fee (share + fees <= 100%).
            ml_added = losing_pot * params(board).ml_share_bps / 10_000;
            let to_vault = losing_after_fee - ml_added;
            if (ml_added > 0) {
                let part = balance::split(&mut board.pot, ml_added);
                balance::join(df::borrow_mut<MotherlodeKey, Balance<SUI>>(&mut board.id, MotherlodeKey {}), part);
            };
            if (to_vault > 0) {
                gts::vault_add(treasury, balance::split(&mut board.pot, to_vault));
                vault_part = vault_part + to_vault;
            };
            losing_after_fee = 0;
        };
    } else {
        let hit = random::generate_u64_in_range(&mut gen, 0, odds - 1) == 0;
        let ml = df::borrow_mut<MotherlodeKey, Balance<SUI>>(&mut board.id, MotherlodeKey {});
        if (hit && balance::value(ml) > 0) {
            ml_paid = balance::value(ml);
            balance::join(&mut board.pot, balance::withdraw_all(ml));
            losing_after_fee = losing_after_fee + ml_paid;
            df::add(&mut board.id, JackpotKey { round_id: board.cur_id }, ml_paid);
        };
    };
    event::emit(MotherlodeUpdate {
        round_id: board.cur_id,
        added: ml_added,
        paid: ml_paid,
        balance: balance::value(df::borrow<MotherlodeKey, Balance<SUI>>(&board.id, MotherlodeKey {})),
    });

    let reward = scaled_reward(reward_for_round(board.cur_id), board.cur_total);
    // Stakers earn +10% of the round reward in GTS, streamed over 7 days.
    let staker_reward = reward * STAKER_SHARE_BPS / 10_000;
    if (staker_reward > 0) {
        let c = gts::mint(treasury, minter(board), staker_reward, clock, ctx);
        staking::add_rewards(pool, coin::into_balance(c), clock);
    };
    let deployed_copy = board.cur_deployed;

    table::add(&mut board.rounds, board.cur_id, RoundInfo {
        total_deployed: board.cur_total,
        deployed: deployed_copy,
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
        staker_reward,
        dev_fee: dev_part,
        players: board.cur_players,
    });

    // Start next round (lazy).
    board.cur_id = board.cur_id + 1;
    board.cur_started = false;
    board.cur_total = 0;
    board.cur_deployed = zeros();
    board.cur_players = 0;
}

/// Claim a settled round: GTS mining reward (everyone) + SUI winnings (if on winning square).
/// Returns (GTS coin, SUI coin). Either may be zero-value.
public fun claim(
    board: &mut Board,
    miner: &mut Miner,
    treasury: &mut Treasury,
    clock: &Clock,
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

    // GTS mining reward — proportional to this miner's share of the round (everyone earns).
    let gts_amt = if (round_total == 0) { 0 } else { mul_div(round_reward, miner.total_deployed, round_total) };
    let mined = gts::mint(treasury, minter(board), gts_amt, clock, ctx);
    let mined_amt = coin::value(&mined);
    // v8: it goes to the unrefined balance (the House bots get it here, as before).
    let gts_coin = if (mined_amt == 0 || is_bot(player)) { mined } else {
        add_unrefined(board, player, coin::into_balance(mined));
        coin::zero<GTS>(ctx)
    };

    // SUI winnings if the miner had stake on the winning square: own stake back plus a share of
    // the losing pot (and any Motherlode) in proportion to the stake on the winning square.
    let my_win = *vector::borrow(&miner.deployed, w);
    let sui_coin = if (my_win > 0 && winners_total > 0) {
        let share = mul_div(pot_after_fee, my_win, winners_total);
        let jk = JackpotKey { round_id };
        // The Motherlode is part of the pot, so its part of the share is never above the share.
        let jackpot = if (df::exists(&board.id, jk)) { mul_div(*df::borrow<JackpotKey, u64>(&board.id, jk), my_win, winners_total) } else { 0 };
        let pot_share = share - jackpot;
        // v7: keep only the part of the round deposit that was on the winning square, e.g. 0.01 of
        // 0.25 SUI spread over all 25 squares keeps 1/25 of the share.
        let fair = round_id >= fair_from(board);
        let my_total = miner.total_deployed;
        let pot_kept = if (fair) { mul_div(pot_share, my_win, my_total) } else { pot_share };
        // No House bot (House, Bot 1-3, Matcher) ever keeps Motherlode SUI.
        let jackpot_kept = if (is_bot(player)) { 0 }
            else if (fair) { mul_div(jackpot, my_win, my_total) } else { jackpot };
        let to_reserve = pot_share - pot_kept;
        let to_fund = jackpot - jackpot_kept;
        if (to_reserve > 0) { gts::vault_add(treasury, balance::split(&mut board.pot, to_reserve)); };
        if (to_fund > 0) {
            let part = balance::split(&mut board.pot, to_fund);
            let ml = df::borrow_mut<MotherlodeKey, Balance<SUI>>(&mut board.id, MotherlodeKey {});
            balance::join(ml, part);
            event::emit(MotherlodeReturned { round_id, amount: to_fund, balance: balance::value(ml) });
        };
        if (to_reserve > 0 || to_fund > 0) { event::emit(Forfeited { round_id, player, to_reserve, to_fund }); };
        coin::from_balance(balance::split(&mut board.pot, my_win + pot_kept + jackpot_kept), ctx)
    } else {
        coin::zero<SUI>(ctx)
    };

    // The round's seat is no longer needed (storage rebate to the claimer).
    let seat = SeatKey { round_id, player };
    if (df::exists(&board.id, seat) && *df::borrow<SeatKey, ID>(&board.id, seat) == object::id(miner)) {
        let _: ID = df::remove(&mut board.id, seat);
    };

    event::emit(Claimed {
        round_id,
        player,
        gts: mined_amt, // GTS mined (since v8 usually added to the unrefined balance)
        sui: coin::value(&sui_coin),
    });

    // Reset miner for the next round.
    miner.round_id = 0;
    miner.total_deployed = 0;
    let mut i = 0;
    while (i < GRID) {
        let md = vector::borrow_mut(&mut miner.deployed, i);
        *md = 0;
        i = i + 1;
    };

    (gts_coin, sui_coin)
}

/// Claim a settled round and get its SUI. The mined GTS goes to the unrefined balance (a House bot
/// is sent its GTS). Same as `claim` without the empty GTS coin.
public fun claim_sui(
    board: &mut Board,
    miner: &mut Miner,
    treasury: &mut Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    let (g, s) = claim(board, miner, treasury, clock, ctx);
    if (coin::value(&g) == 0) { coin::destroy_zero(g) } else { transfer::public_transfer(g, tx_context::sender(ctx)) };
    s
}

/// Withdraw the whole unrefined balance: it minus REFINE_FEE_BPS, plus the bonus earned from other
/// players' fees. The fee is shared among everyone still holding, or burned for the reserve if nobody is.
public fun withdraw_gts(board: &mut Board, treasury: &mut Treasury, ctx: &mut TxContext): Coin<GTS> {
    check_version(board);
    let player = tx_context::sender(ctx);
    let key = UnrefinedKey { player };
    assert!(df::exists(&board.id, key), ENothingToWithdraw);
    let Unrefined { amount, bonus, snap } = df::remove(&mut board.id, key);
    let r = df::borrow_mut<RefineryKey, Refinery>(&mut board.id, RefineryKey {});
    let bonus = bonus + earned(amount, r.acc, snap);
    let fee = mul_div(amount, REFINE_FEE_BPS, 10_000);
    r.total = r.total - amount;
    let paid = amount - fee + bonus;
    let out = balance::split(&mut r.gts, paid);
    let mut burned = 0;
    if (fee > 0) {
        if (r.total > 0) {
            r.acc = r.acc + (fee as u256) * REFINE_SCALE / (r.total as u256);
        } else if (gts::vault_value(treasury) > 0) {
            // Nobody left to share it: burn it and put its reserve share straight back.
            let sui_out = gts::redeem(treasury, coin::from_balance(balance::split(&mut r.gts, fee), ctx), ctx);
            gts::vault_add(treasury, coin::into_balance(sui_out));
            burned = fee;
        };
    };
    event::emit(GtsWithdrawn { player, amount, fee, bonus, paid, burned });
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

// ===== Views =====
public fun current_round(board: &Board): u64 { board.cur_id }
public fun current_end_ms(board: &Board): u64 { board.cur_end_ms }
public fun current_total(board: &Board): u64 { board.cur_total }
public fun pot_value(board: &Board): u64 { balance::value(&board.pot) }
public fun dev_fees_value(board: &Board): u64 { balance::value(&board.dev_fees) }
public fun genesis_ms(board: &Board): u64 { board.genesis_ms }
public fun motherlode_value(board: &Board): u64 {
    if (df::exists(&board.id, MotherlodeKey {})) {
        balance::value(df::borrow<MotherlodeKey, Balance<SUI>>(&board.id, MotherlodeKey {}))
    } else { 0 }
}
/// SUI round `round_id` received from the Motherlode (0 if it did not hit).
public fun motherlode_paid(board: &Board, round_id: u64): u64 {
    let k = JackpotKey { round_id };
    if (df::exists(&board.id, k)) { *df::borrow<JackpotKey, u64>(&board.id, k) } else { 0 }
}
public fun installed(board: &Board): bool { has_minter(board) }
/// Current settings: (Motherlode odds, Motherlode share in bps, paused).
public fun current_params(board: &Board): (u64, u64, bool) {
    if (df::exists(&board.id, ParamsKey {})) { let p = params(board); (p.ml_odds, p.ml_share_bps, p.paused) }
    else { (MOTHERLODE_ODDS, MOTHERLODE_SHARE_BPS, false) }
}
/// First round paid with the v7 split (u64 max until v7 has run).
public fun fair_from_round(board: &Board): u64 { fair_from(board) }
/// Full reward of the current round (paid in full at FULL_REWARD_DEPLOY SUI deployed).
public fun current_reward(board: &Board, _clock: &Clock): u64 {
    if (!has_minter(board)) { 0 } else { reward_for_round(board.cur_id) }
}
public fun full_reward_deploy(): u64 { FULL_REWARD_DEPLOY }
/// `player`'s unrefined GTS and the bonus earned so far (what `withdraw_gts` adds on top of it minus the fee).
public fun unrefined_of(board: &Board, player: address): (u64, u64) {
    let key = UnrefinedKey { player };
    if (!df::exists(&board.id, key) || !df::exists(&board.id, RefineryKey {})) { return (0, 0) };
    let u = df::borrow<UnrefinedKey, Unrefined>(&board.id, key);
    (u.amount, u.bonus + earned(u.amount, refinery(board).acc, u.snap))
}
/// Unrefined GTS of all players together.
public fun unrefined_total(board: &Board): u64 {
    if (df::exists(&board.id, RefineryKey {})) { refinery(board).total } else { 0 }
}
public fun refine_fee_bps(): u64 { REFINE_FEE_BPS }

#[test_only]
public fun reward_for_round_for_testing(round_id: u64): u64 { reward_for_round(round_id) }

#[test_only]
public fun scaled_reward_for_testing(base: u64, total: u64): u64 { scaled_reward(base, total) }

#[test_only]
public fun version_for_testing(board: &Board): u64 {
    if (df::exists(&board.id, VersionKey {})) { *df::borrow<VersionKey, u64>(&board.id, VersionKey {}) } else { 0 }
}

#[test_only]
public fun set_version_for_testing(board: &mut Board, v: u64) {
    *df::borrow_mut<VersionKey, u64>(&mut board.id, VersionKey {}) = v;
}

#[test_only]
/// Installs the way versions 1-4 did (MinterCap in `board.minter`), to test the v5 migration.
public fun install_legacy_for_testing(board: &mut Board, cap: MinterCap, treasury: &mut Treasury, clock: &Clock) {
    gts::start(treasury, &cap, clock);
    board.genesis_ms = clock::timestamp_ms(clock);
    option::fill(&mut board.minter, cap);
}

#[test_only]
public fun legacy_minter_for_testing(board: &Board): bool { option::is_some(&board.minter) }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun settle_for_testing(
    board: &mut Board, treasury: &mut Treasury, pool: &mut StakePool,
    r: &Random, clock: &Clock, ctx: &mut TxContext,
) { settle(board, treasury, pool, r, clock, ctx) }

#[test_only]
public fun settle_with_odds_for_testing(
    board: &mut Board, treasury: &mut Treasury, pool: &mut StakePool,
    r: &Random, clock: &Clock, odds: u64, ctx: &mut TxContext,
) { settle_with_odds(board, treasury, pool, r, clock, odds, ctx) }

#[test_only]
public fun winning_square_for_testing(board: &Board, round_id: u64): u64 {
    (table::borrow(&board.rounds, round_id).winning_square as u64)
}

#[test_only]
public fun seat_exists_for_testing(board: &Board, round_id: u64, player: address): bool {
    df::exists(&board.id, SeatKey { round_id, player })
}

#[test_only]
public fun set_fair_from_for_testing(board: &mut Board, round_id: u64) {
    *df::borrow_mut<FairFromKey, u64>(&mut board.id, FairFromKey {}) = round_id;
}

#[test_only]
public fun motherlode_odds_for_testing(): u64 { MOTHERLODE_ODDS }

#[test_only]
public fun take_admin_for_testing(board: &mut Board, ctx: &mut TxContext) { take_admin(board, ctx) }
