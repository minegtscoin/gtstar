/// GTS staking with real yield: stakers share `stake_bps` of every round's losing pot, paid in SUI.
/// Nothing is minted. Two ways to stake:
///  - flexible: weight 1x, withdraw any time;
///  - locked for 7 days: weight 1.5x, withdraw once the lock ends. Adding to it restarts the lock.
/// Each round's SUI is split by weight among everyone staked at that moment. When a lock ends its weight
/// drops back to 1x as soon as anyone calls `poke` for it (the keeper does), or the owner touches it.
/// With nobody staked, the stakers' share goes to the Wealth Fund.
///
/// The pool lives in a dynamic field of the game Board, so rounds pay it without extra arguments.
module gtstar::staking;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};
use gtstar::gts::GTS;

const LOCK_MS: u64 = 7 * 86_400_000;
/// Weights in tenths: flexible 1x, locked 1.5x.
const FLEX_W: u128 = 10;
const LOCK_W: u128 = 15;
const SCALE: u256 = 1_000_000_000_000_000_000;

const EZero: u64 = 1;
const ETooMuch: u64 = 2;
const ELocked: u64 = 3;
const ENoStake: u64 = 4;

public struct Position has store, drop {
    amount: u64,
    weight: u128,
    locked_until: u64, // 0 for flexible
    snap: u256,
    pending: u64,
}

public struct PosKey has copy, drop, store { player: address, locked: bool }

public struct Pool has store {
    staked: Balance<GTS>,
    rewards: Balance<SUI>,
    total_amount: u64,
    total_weight: u128,
    acc: u256, // SUI per weight unit, scaled by SCALE
    paid_total: u64,
    positions: Table<PosKey, Position>,
}

public struct Staked has copy, drop { player: address, locked: bool, amount: u64, total: u64, locked_until: u64 }
public struct Unstaked has copy, drop { player: address, locked: bool, amount: u64, total: u64 }
public struct YieldClaimed has copy, drop { player: address, sui: u64 }
public struct LockEnded has copy, drop { player: address, amount: u64 }
public struct StakeRewarded has copy, drop { round_id: u64, amount: u64, total_weight: u128 }

public(package) fun new(ctx: &mut TxContext): Pool {
    Pool {
        staked: balance::zero(), rewards: balance::zero(), total_amount: 0, total_weight: 0, acc: 0, paid_total: 0,
        positions: table::new(ctx),
    }
}

/// True if a round's stakers' share has anyone to go to.
public(package) fun has_stakers(p: &Pool): bool { p.total_weight > 0 }

/// A round's stakers' share, split by weight among everyone staked now.
public(package) fun reward(p: &mut Pool, round_id: u64, b: Balance<SUI>) {
    let amount = balance::value(&b);
    p.acc = p.acc + (amount as u256) * SCALE / (p.total_weight as u256);
    p.paid_total = p.paid_total + amount;
    balance::join(&mut p.rewards, b);
    event::emit(StakeRewarded { round_id, amount, total_weight: p.total_weight });
}

fun earned(pos: &Position, acc: u256): u64 { (((pos.weight as u256) * (acc - pos.snap)) / SCALE) as u64 }

fun settle_pos(pos: &mut Position, acc: u256) {
    pos.pending = pos.pending + earned(pos, acc);
    pos.snap = acc;
}

fun weight_of(amount: u64, locked: bool): u128 { (amount as u128) * (if (locked) { LOCK_W } else { FLEX_W }) }

/// Drop an ended lock back to 1x.
fun expire(p: &mut Pool, player: address, now: u64) {
    let key = PosKey { player, locked: true };
    if (!table::contains(&p.positions, key)) { return };
    let acc = p.acc;
    let pos = table::borrow_mut(&mut p.positions, key);
    if (pos.weight <= weight_of(pos.amount, false) || now < pos.locked_until) { return };
    settle_pos(pos, acc);
    let new_w = weight_of(pos.amount, false);
    p.total_weight = p.total_weight - pos.weight + new_w;
    pos.weight = new_w;
    event::emit(LockEnded { player, amount: pos.amount });
}

public(package) fun stake(p: &mut Pool, gts: Coin<GTS>, locked: bool, clock: &Clock, ctx: &TxContext) {
    let amount = coin::value(&gts);
    assert!(amount > 0, EZero);
    let player = tx_context::sender(ctx);
    let now = clock::timestamp_ms(clock);
    expire(p, player, now);
    let key = PosKey { player, locked };
    let acc = p.acc;
    if (!table::contains(&p.positions, key)) {
        table::add(&mut p.positions, key, Position { amount: 0, weight: 0, locked_until: 0, snap: acc, pending: 0 });
    };
    let pos = table::borrow_mut(&mut p.positions, key);
    settle_pos(pos, acc);
    pos.amount = pos.amount + amount;
    // Adding to a locked stake restarts the 7-day lock for all of it, at 1.5x.
    if (locked) { pos.locked_until = now + LOCK_MS };
    let new_w = weight_of(pos.amount, locked);
    p.total_weight = p.total_weight - pos.weight + new_w;
    pos.weight = new_w;
    p.total_amount = p.total_amount + amount;
    balance::join(&mut p.staked, coin::into_balance(gts));
    event::emit(Staked { player, locked, amount, total: pos.amount, locked_until: pos.locked_until });
}

public(package) fun unstake(p: &mut Pool, amount: u64, locked: bool, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    assert!(amount > 0, EZero);
    let player = tx_context::sender(ctx);
    let now = clock::timestamp_ms(clock);
    expire(p, player, now);
    let key = PosKey { player, locked };
    assert!(table::contains(&p.positions, key), ENoStake);
    let acc = p.acc;
    let pos = table::borrow_mut(&mut p.positions, key);
    assert!(amount <= pos.amount, ETooMuch);
    assert!(!locked || now >= pos.locked_until, ELocked);
    settle_pos(pos, acc);
    pos.amount = pos.amount - amount;
    // An ended lock has already dropped to 1x in `expire`.
    let new_w = weight_of(pos.amount, locked && now < pos.locked_until);
    p.total_weight = p.total_weight - pos.weight + new_w;
    pos.weight = new_w;
    p.total_amount = p.total_amount - amount;
    let left = pos.amount;
    event::emit(Unstaked { player, locked, amount, total: left });
    coin::from_balance(balance::split(&mut p.staked, amount), ctx)
}

/// All SUI yield of the sender, from both positions. Empty positions are removed.
public(package) fun claim(p: &mut Pool, ctx: &mut TxContext): Coin<SUI> {
    let player = tx_context::sender(ctx);
    let acc = p.acc;
    let mut total = 0;
    let keys = vector[PosKey { player, locked: false }, PosKey { player, locked: true }];
    let mut i = 0;
    while (i < 2) {
        let key = *vector::borrow(&keys, i);
        if (table::contains(&p.positions, key)) {
            let pos = table::borrow_mut(&mut p.positions, key);
            settle_pos(pos, acc);
            total = total + pos.pending;
            pos.pending = 0;
            if (pos.amount == 0) { table::remove(&mut p.positions, key); };
        };
        i = i + 1;
    };
    if (total > 0) { event::emit(YieldClaimed { player, sui: total }); };
    coin::from_balance(balance::split(&mut p.rewards, total), ctx)
}

public(package) fun poke(p: &mut Pool, player: address, clock: &Clock) { expire(p, player, clock::timestamp_ms(clock)) }

// ===== Views =====

/// (total GTS staked, total weight in tenths, SUI paid to stakers so far, SUI waiting to be claimed).
public(package) fun totals(p: &Pool): (u64, u128, u64, u64) { (p.total_amount, p.total_weight, p.paid_total, balance::value(&p.rewards)) }

/// (amount, locked_until, SUI claimable) of one position; zeros when there is none.
public(package) fun position(p: &Pool, player: address, locked: bool): (u64, u64, u64) {
    let key = PosKey { player, locked };
    if (!table::contains(&p.positions, key)) { return (0, 0, 0) };
    let pos = table::borrow(&p.positions, key);
    (pos.amount, pos.locked_until, pos.pending + earned(pos, p.acc))
}

public fun lock_ms(): u64 { LOCK_MS }
