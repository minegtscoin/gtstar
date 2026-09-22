/// GTStar staking — stake GTS, earn yield in GTS.
///
/// No lock-ups: deposit, withdraw and claim at any time.
/// Each round mints +10% of its reward to stakers, streamed linearly over 7 days
/// (Synthetix-style reward rate), so staking right before a settlement and
/// leaving right after earns only for the seconds actually staked. If nobody is
/// staked, the stream is paused and nothing is lost.
module gtstar::staking;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use gts_token::gts::GTS;

/// Precision for reward math.
const SCALE: u128 = 1_000_000_000_000;
/// Rewards are streamed over this window.
const REWARD_DURATION_MS: u64 = 7 * 86_400_000;

const EZeroAmount: u64 = 1;
const EInsufficientStake: u64 = 2;
const ENotEmpty: u64 = 3;

public struct Staked has copy, drop { player: address, amount: u64 }
public struct Unstaked has copy, drop { player: address, amount: u64 }
public struct RewardsClaimed has copy, drop { player: address, gts: u64 }

/// Shared pool.
public struct StakePool has key {
    id: UID,
    staked: Balance<GTS>,
    rewards: Balance<GTS>,
    total_staked: u64,
    acc_reward_per_share: u128, // reward GTS per staked GTS unit, scaled by SCALE
    reward_rate: u128,          // reward GTS (base units) per ms, scaled by SCALE
    period_finish: u64,
    last_update: u64,
}

/// Owned stake position. One per player is enough; it can be topped up or drawn down.
public struct StakePosition has key, store {
    id: UID,
    amount: u64,
    acc_snapshot: u128,
    pending: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(StakePool {
        id: object::new(ctx),
        staked: balance::zero<GTS>(),
        rewards: balance::zero<GTS>(),
        total_staked: 0,
        acc_reward_per_share: 0,
        reward_rate: 0,
        period_finish: 0,
        last_update: 0,
    });
}

// ===== Internal accounting =====

fun update(pool: &mut StakePool, now: u64) {
    if (now <= pool.last_update) { return };
    if (pool.total_staked == 0) {
        // Nobody staked: pause the stream by shifting its end forward.
        if (pool.period_finish > pool.last_update) {
            pool.period_finish = now + (pool.period_finish - pool.last_update);
        };
    } else {
        let end = if (now < pool.period_finish) { now } else { pool.period_finish };
        if (end > pool.last_update) {
            let dt = ((end - pool.last_update) as u128);
            pool.acc_reward_per_share = pool.acc_reward_per_share + pool.reward_rate * dt / (pool.total_staked as u128);
        };
    };
    pool.last_update = now;
}

fun settle_position(pool: &StakePool, pos: &mut StakePosition) {
    let delta = pool.acc_reward_per_share - pos.acc_snapshot;
    pos.pending = pos.pending + (((pos.amount as u128) * delta / SCALE) as u64);
    pos.acc_snapshot = pool.acc_reward_per_share;
}

/// Called by the game at settlement to fund staker rewards (streamed over 7 days).
public(package) fun add_rewards(pool: &mut StakePool, reward: Balance<GTS>, clock: &Clock) {
    let now = clock::timestamp_ms(clock);
    update(pool, now);
    let amount = balance::value(&reward);
    balance::join(&mut pool.rewards, reward);
    if (amount == 0) { return };
    let leftover = if (pool.period_finish > now) { ((pool.period_finish - now) as u128) * pool.reward_rate } else { 0 };
    pool.reward_rate = ((amount as u128) * SCALE + leftover) / (REWARD_DURATION_MS as u128);
    pool.period_finish = now + REWARD_DURATION_MS;
    pool.last_update = now;
}

// ===== Public =====

public fun new_position(ctx: &mut TxContext): StakePosition {
    StakePosition { id: object::new(ctx), amount: 0, acc_snapshot: 0, pending: 0 }
}

/// Add GTS to a position.
public fun stake(pool: &mut StakePool, pos: &mut StakePosition, gts: Coin<GTS>, clock: &Clock, ctx: &TxContext) {
    let amount = coin::value(&gts);
    assert!(amount > 0, EZeroAmount);
    update(pool, clock::timestamp_ms(clock));
    settle_position(pool, pos);
    balance::join(&mut pool.staked, coin::into_balance(gts));
    pos.amount = pos.amount + amount;
    pool.total_staked = pool.total_staked + amount;
    event::emit(Staked { player: tx_context::sender(ctx), amount });
}

/// Withdraw GTS from a position at any time.
public fun unstake(pool: &mut StakePool, pos: &mut StakePosition, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    assert!(amount > 0, EZeroAmount);
    assert!(amount <= pos.amount, EInsufficientStake);
    update(pool, clock::timestamp_ms(clock));
    settle_position(pool, pos);
    pos.amount = pos.amount - amount;
    pool.total_staked = pool.total_staked - amount;
    event::emit(Unstaked { player: tx_context::sender(ctx), amount });
    coin::from_balance(balance::split(&mut pool.staked, amount), ctx)
}

/// Claim accrued GTS yield.
public fun claim_rewards(pool: &mut StakePool, pos: &mut StakePosition, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    update(pool, clock::timestamp_ms(clock));
    settle_position(pool, pos);
    let avail = balance::value(&pool.rewards);
    let amt = if (pos.pending > avail) { avail } else { pos.pending };
    pos.pending = pos.pending - amt;
    if (amt > 0) { event::emit(RewardsClaimed { player: tx_context::sender(ctx), gts: amt }); };
    coin::from_balance(balance::split(&mut pool.rewards, amt), ctx)
}

/// Delete an empty position.
public fun close_position(pos: StakePosition) {
    let StakePosition { id, amount, acc_snapshot: _, pending } = pos;
    assert!(amount == 0 && pending == 0, ENotEmpty);
    object::delete(id);
}

// ===== Views =====
public fun total_staked(pool: &StakePool): u64 { pool.total_staked }
public fun position_amount(pos: &StakePosition): u64 { pos.amount }

/// Claimable GTS yield for a position at `now` (read-only estimate).
public fun pending_rewards(pool: &StakePool, pos: &StakePosition, now: u64): u64 {
    let mut acc = pool.acc_reward_per_share;
    if (pool.total_staked > 0 && now > pool.last_update) {
        let end = if (now < pool.period_finish) { now } else { pool.period_finish };
        if (end > pool.last_update) {
            acc = acc + pool.reward_rate * ((end - pool.last_update) as u128) / (pool.total_staked as u128);
        };
    };
    pos.pending + (((pos.amount as u128) * (acc - pos.acc_snapshot) / SCALE) as u64)
}

#[test_only]
public fun total_rewards_for_testing(pool: &StakePool): u64 { balance::value(&pool.rewards) }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun add_rewards_for_testing(pool: &mut StakePool, reward: Balance<GTS>, clock: &Clock) { add_rewards(pool, reward, clock) }
