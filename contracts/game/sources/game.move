/// GTStar core game: a 5x5 grid, 60s rounds, on Sui.
///
/// This package is upgradeable (bug fixes, improvements). The token, its supply
/// schedule and the SUI reserve live in the separate, immutable `gts_token`
/// package, so no upgrade can mint beyond the published schedule or touch the reserve.
///
/// Each round players deploy SUI onto squares. At settlement one winning square
/// is drawn with `sui::random`. SUI from losing squares (minus a 5% fee) is split
/// PROPORTIONALLY among everyone on the winning square (fairer than ORE's single
/// winner). Separately, a halving GTS emission is split among ALL participants —
/// winners and losers alike ("rewards everyone").
///
/// Motherlode: when no one is on the winning square, the winners' pot (after the 5% fee) is
/// split: MOTHERLODE_SHARE_BPS rolls into the Motherlode, the rest goes to the GTS reserve. Every round that has a winner also has a
/// 1 in MOTHERLODE_ODDS chance (drawn with `sui::random`) to pay the whole Motherlode to the
/// winning square, split like the normal pot. The GTStar House wallet never keeps any of it.
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
/// stretch the schedule; the total never changes. Stakers receive an extra 10% on top, streamed.
/// Rounds last at least a minute, so this stays inside the token's time-based ceiling, and the
/// 7-period total (571,896.875 GTS) is below that ceiling's final value (572,003.2 GTS).
const INITIAL_ROUND_REWARD: u64 = 1_000_000_000;   // 1 GTS / round
const STAKER_SHARE_BPS: u64 = 1_000;               // +10% of the round reward, to stakers
const HALVING_ROUNDS: u64 = 262_000;
const EMISSION_PERIODS: u64 = 7;

/// Creator/dev reward: 1% of the losing pot each round, accrued on the Board and
/// paid out (permissionlessly) only to this address via `withdraw_dev_fees`.
const DEV_ADDR: address = @0xa19b2d37f95ca4c48efafb2cd01d0f97f33852457daa27cfba3de37fdec24d4b;

/// Chance per round with a winner that the Motherlode pays out: 1 in MOTHERLODE_ODDS.
const MOTHERLODE_ODDS: u64 = 25;
/// Share of a no-winner round's pot (after the 5% fee) that rolls into the Motherlode;
/// the rest goes to the GTS reserve.
const MOTHERLODE_SHARE_BPS: u64 = 5_000;
/// GTStar House wallet (see the site): its share of a Motherlode payout goes back to the Motherlode.
const HOUSE_ADDR: address = @0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a;

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

/// One-time launch step: hand the game its minting right and start the emission clock.
public fun install(board: &mut Board, cap: MinterCap, treasury: &mut Treasury, clock: &Clock) {
    assert!(option::is_none(&board.minter), EAlreadyInstalled);
    gts::start(treasury, &cap, clock);
    board.genesis_ms = clock::timestamp_ms(clock);
    option::fill(&mut board.minter, cap);
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
    assert!(vector::length(&amounts) == GRID, EBadLen);
    assert!(option::is_some(&board.minter), ENotInstalled);
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
    settle_with_odds(board, treasury, pool, r, clock, MOTHERLODE_ODDS, ctx)
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
            ml_added = losing_after_fee * MOTHERLODE_SHARE_BPS / 10_000;
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

    let reward = reward_for_round(board.cur_id);
    // Stakers earn +10% of the round reward in GTS, streamed over 7 days.
    let staker_reward = reward * STAKER_SHARE_BPS / 10_000;
    if (staker_reward > 0) {
        let c = gts::mint(treasury, option::borrow(&board.minter), staker_reward, clock, ctx);
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
    assert!(miner.round_id != 0, ENothingToClaim);
    assert!(table::contains(&board.rounds, miner.round_id), ENotSettled);
    let info = table::borrow(&board.rounds, miner.round_id);

    // GTS mining reward — proportional to this miner's share of the round (everyone earns).
    let gts_amt = if (info.total_deployed == 0) { 0 }
        else { (((info.round_reward as u128) * (miner.total_deployed as u128)) / (info.total_deployed as u128)) as u64 };
    let gts_coin = gts::mint(treasury, option::borrow(&board.minter), gts_amt, clock, ctx);

    // SUI winnings if the miner had stake on the winning square.
    let w = (info.winning_square as u64);
    let my_win = *vector::borrow(&miner.deployed, w);
    let sui_coin = if (my_win > 0 && info.winners_total > 0) {
        let share = (((info.losing_pot_after_fee as u128) * (my_win as u128)) / (info.winners_total as u128)) as u64;
        let mut payout = my_win + share; // own stake back + share of the losing pot (and any Motherlode)
        let jk = JackpotKey { round_id: miner.round_id };
        if (tx_context::sender(ctx) == HOUSE_ADDR && df::exists(&board.id, jk)) {
            // The House never keeps Motherlode SUI: its share goes back into the Motherlode.
            let jackpot = *df::borrow<JackpotKey, u64>(&board.id, jk);
            let back = (((jackpot as u128) * (my_win as u128)) / (info.winners_total as u128)) as u64;
            if (back > 0) {
                payout = payout - back;
                let part = balance::split(&mut board.pot, back);
                let ml = df::borrow_mut<MotherlodeKey, Balance<SUI>>(&mut board.id, MotherlodeKey {});
                balance::join(ml, part);
                event::emit(MotherlodeReturned { round_id: miner.round_id, amount: back, balance: balance::value(ml) });
            };
        };
        coin::from_balance(balance::split(&mut board.pot, payout), ctx)
    } else {
        coin::zero<SUI>(ctx)
    };

    event::emit(Claimed {
        round_id: miner.round_id,
        player: tx_context::sender(ctx),
        gts: coin::value(&gts_coin),
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

/// Send accrued creator fees to DEV_ADDR. Anyone may call; funds can only go to DEV_ADDR.
entry fun withdraw_dev_fees(board: &mut Board, ctx: &mut TxContext) {
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
public fun installed(board: &Board): bool { option::is_some(&board.minter) }
public fun current_reward(board: &Board, _clock: &Clock): u64 {
    if (option::is_none(&board.minter)) { 0 } else { reward_for_round(board.cur_id) }
}

#[test_only]
public fun reward_for_round_for_testing(round_id: u64): u64 { reward_for_round(round_id) }

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
