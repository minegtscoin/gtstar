/// GTS staking with real yield: stakers share `stake_bps` of every round's losing pot, paid in SUI.
/// Nothing is minted. One kind of stake: every staked GTS counts the same, and it can leave at any time.
/// Each round's SUI is split by stake among everyone whose stake is earning at that moment.
/// With nobody earning, the stakers' share goes to the Wealth Fund.
///
/// The 7-day lock at 1.5x is closed: no new lock can be made. A lock made while it was offered counts 1x
/// from the first time it is touched (`poke`, a draw's queue, or its owner), and can leave at any time.
///
/// Warm-up: GTS staked now starts earning one hour later. Until then it
/// has no weight, so nobody can stake just before a large round and leave right after it. Staking more
/// restarts the hour for the part still warming up only; stake that is already earning keeps earning.
/// Unstaking takes the warming part first.
///
/// No keeper needed: the pool keeps a queue of the stakes whose warm-up ends, in order of time (and one
/// of the old locks). Every draw of the game works through the entries that are due (`run_due`), before
/// it pays the round's share, so warm-ups start earning with no one having to call anything; `poke`
/// does the same for one player at any time.
///
/// From game v12 stakers also get the GTS bought back, split by the same weights; the game keeps that
/// accumulator on the Board and reads the weights with `weight`.
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
/// New stake starts earning this long after it is staked (1 hour).
const WARM_MS: u64 = 3_600_000;
/// Weights in tenths: flexible 1x, locked 1.5x.
const FLEX_W: u128 = 10;
const LOCK_W: u128 = 15;
const SCALE: u256 = 1_000_000_000_000_000_000;

const EZero: u64 = 1;
const ETooMuch: u64 = 2;
const ENoStake: u64 = 4;
const ENoLock: u64 = 5;

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

/// What is waiting for a time (game v20): stake warming up, and the two queues the draw works through.
/// Kept next to the Pool in the game Board.
public struct Schedule has store {
    warm: Table<PosKey, Warm>,
    warm_q: Table<u64, Due>,
    warm_head: u64,
    warm_tail: u64,
    lock_q: Table<u64, Due>,
    lock_head: u64,
    lock_tail: u64,
}
/// The part of a position that is not earning yet, and when it starts.
public struct Warm has store, drop { amount: u64, at: u64 }
/// A queue entry: `player`'s position is due at `at`. An entry whose position changed since is skipped.
public struct Due has store, drop { player: address, locked: bool, at: u64 }

/// Stake started earning after its warm-up.
public struct WarmedUp has copy, drop { player: address, locked: bool, amount: u64 }

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

public(package) fun new_schedule(ctx: &mut TxContext): Schedule {
    Schedule { warm: table::new(ctx), warm_q: table::new(ctx), warm_head: 0, warm_tail: 0, lock_q: table::new(ctx), lock_head: 0, lock_tail: 0 }
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

/// GTS of a position still warming up.
fun warming(s: &Schedule, key: PosKey): u64 {
    if (table::contains(&s.warm, key)) { table::borrow(&s.warm, key).amount } else { 0 }
}

/// Set a position's weight for `earning` GTS of it, at 1.5x or 1x. The caller has settled it.
fun set_weight(p: &mut Pool, key: PosKey, earning: u64, boosted: bool) {
    let pos = table::borrow_mut(&mut p.positions, key);
    let new_w = weight_of(earning, boosted);
    p.total_weight = p.total_weight - pos.weight + new_w;
    pos.weight = new_w;
}

/// Drop a lock back to 1x: the 1.5x lock is closed, whatever time was left on it.
fun expire(p: &mut Pool, s: &Schedule, player: address) {
    let key = PosKey { player, locked: true };
    if (!table::contains(&p.positions, key)) { return };
    let acc = p.acc;
    let warm = warming(s, key);
    let pos = table::borrow_mut(&mut p.positions, key);
    let earning = pos.amount - warm;
    if (pos.weight <= weight_of(earning, false)) { return };
    settle_pos(pos, acc);
    let amount = pos.amount;
    set_weight(p, key, earning, false);
    event::emit(LockEnded { player, amount });
}

/// Start earning on the warming part of a position once its hour has passed.
fun warm_up(p: &mut Pool, s: &mut Schedule, key: PosKey, now: u64) {
    if (!table::contains(&s.warm, key) || table::borrow(&s.warm, key).at > now) { return };
    let Warm { amount, at: _ } = table::remove(&mut s.warm, key);
    if (!table::contains(&p.positions, key)) { return };
    let acc = p.acc;
    let pos = table::borrow_mut(&mut p.positions, key);
    settle_pos(pos, acc);
    let all = pos.amount;
    set_weight(p, key, all, false);
    event::emit(WarmedUp { player: key.player, locked: key.locked, amount });
}

/// Bring one player's positions up to `now`: warm-ups that are over start earning, an old lock drops to 1x.
fun refresh(p: &mut Pool, s: &mut Schedule, player: address, now: u64) {
    warm_up(p, s, PosKey { player, locked: false }, now);
    warm_up(p, s, PosKey { player, locked: true }, now);
    expire(p, s, player);
}

public(package) fun stake(p: &mut Pool, s: &mut Schedule, gts: Coin<GTS>, locked: bool, clock: &Clock, ctx: &TxContext) {
    let amount = coin::value(&gts);
    assert!(amount > 0, EZero);
    assert!(!locked, ENoLock);
    let player = tx_context::sender(ctx);
    let now = clock::timestamp_ms(clock);
    refresh(p, s, player, now);
    let key = PosKey { player, locked };
    let acc = p.acc;
    if (!table::contains(&p.positions, key)) {
        table::add(&mut p.positions, key, Position { amount: 0, weight: 0, locked_until: 0, snap: acc, pending: 0 });
    };
    // The new GTS warms up for an hour; with GTS already warming, the hour restarts for all of that part.
    let at = now + WARM_MS;
    if (table::contains(&s.warm, key)) {
        let w = table::borrow_mut(&mut s.warm, key);
        w.amount = w.amount + amount;
        w.at = at;
    } else { table::add(&mut s.warm, key, Warm { amount, at }) };
    table::add(&mut s.warm_q, s.warm_tail, Due { player, locked, at });
    s.warm_tail = s.warm_tail + 1;
    let warm = warming(s, key);
    let pos = table::borrow_mut(&mut p.positions, key);
    settle_pos(pos, acc);
    pos.amount = pos.amount + amount;
    let (total, until) = (pos.amount, pos.locked_until);
    set_weight(p, key, total - warm, false);
    p.total_amount = p.total_amount + amount;
    balance::join(&mut p.staked, coin::into_balance(gts));
    event::emit(Staked { player, locked, amount, total, locked_until: until });
}

public(package) fun unstake(p: &mut Pool, s: &mut Schedule, amount: u64, locked: bool, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    assert!(amount > 0, EZero);
    let player = tx_context::sender(ctx);
    let now = clock::timestamp_ms(clock);
    refresh(p, s, player, now);
    let key = PosKey { player, locked };
    assert!(table::contains(&p.positions, key), ENoStake);
    let acc = p.acc;
    let pos = table::borrow_mut(&mut p.positions, key);
    assert!(amount <= pos.amount, ETooMuch);
    settle_pos(pos, acc);
    pos.amount = pos.amount - amount;
    let left = pos.amount;
    // The warming part leaves first.
    let warm = warming(s, key);
    let still = if (warm > amount) { warm - amount } else { 0 };
    if (warm > 0) {
        if (still == 0) { let _: Warm = table::remove(&mut s.warm, key); }
        else { table::borrow_mut(&mut s.warm, key).amount = still };
    };
    // An old lock has already dropped to 1x in `refresh`.
    set_weight(p, key, left - still, false);
    p.total_amount = p.total_amount - amount;
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

public(package) fun poke(p: &mut Pool, s: &mut Schedule, player: address, clock: &Clock) { refresh(p, s, player, clock::timestamp_ms(clock)) }

/// The player of the next queue entry that is due at `now` (warm-ups first), if there is one.
public(package) fun next_due(s: &Schedule, now: u64): (bool, address) {
    if (s.warm_head < s.warm_tail) {
        let d = table::borrow(&s.warm_q, s.warm_head);
        if (d.at <= now) { return (true, d.player) };
    };
    if (s.lock_head < s.lock_tail) {
        let d = table::borrow(&s.lock_q, s.lock_head);
        if (d.at <= now) { return (true, d.player) };
    };
    (false, @0x0)
}

/// Take the entry `next_due` pointed at off its queue and bring that player's positions up to `now`.
/// An entry made stale by a later stake (the hour or the lock restarted) changes nothing: the newer
/// entry further down the queue does the work when its time comes.
public(package) fun run_due(p: &mut Pool, s: &mut Schedule, now: u64) {
    if (s.warm_head < s.warm_tail && table::borrow(&s.warm_q, s.warm_head).at <= now) {
        let Due { player, locked: _, at: _ } = table::remove(&mut s.warm_q, s.warm_head);
        s.warm_head = s.warm_head + 1;
        refresh(p, s, player, now);
    } else if (s.lock_head < s.lock_tail && table::borrow(&s.lock_q, s.lock_head).at <= now) {
        let Due { player, locked: _, at: _ } = table::remove(&mut s.lock_q, s.lock_head);
        s.lock_head = s.lock_head + 1;
        refresh(p, s, player, now);
    };
}

/// Put a lock made before game v20 on the lock queue, so the draw ends it too. Only while it still fits
/// the queue's order (nothing queued ends later); a lock made from v20 on is queued when it is made.
public(package) fun enqueue_lock(p: &Pool, s: &mut Schedule, player: address): bool {
    let key = PosKey { player, locked: true };
    if (!table::contains(&p.positions, key)) { return false };
    let pos = table::borrow(&p.positions, key);
    if (pos.weight <= weight_of(pos.amount - warming(s, key), false)) { return false };
    if (s.lock_head < s.lock_tail && table::borrow(&s.lock_q, s.lock_tail - 1).at > pos.locked_until) { return false };
    table::add(&mut s.lock_q, s.lock_tail, Due { player, locked: true, at: pos.locked_until });
    s.lock_tail = s.lock_tail + 1;
    true
}

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
public fun warm_ms(): u64 { WARM_MS }

/// (GTS of the position still warming up, when it starts earning in ms); zeros when none.
public(package) fun warming_of(s: &Schedule, player: address, locked: bool): (u64, u64) {
    let key = PosKey { player, locked };
    if (!table::contains(&s.warm, key)) { return (0, 0) };
    let w = table::borrow(&s.warm, key);
    (w.amount, w.at)
}

/// Entries waiting on the two queues: (warm-ups, locks).
public(package) fun queued(s: &Schedule): (u64, u64) { (s.warm_tail - s.warm_head, s.lock_tail - s.lock_head) }

/// Total weight in tenths (0 with nobody staked).
public(package) fun total_weight(p: &Pool): u128 { p.total_weight }

/// Weight in tenths of one position (0 when there is none).
public(package) fun weight(p: &Pool, player: address, locked: bool): u128 {
    let key = PosKey { player, locked };
    if (table::contains(&p.positions, key)) { table::borrow(&p.positions, key).weight } else { 0 }
}

/// A 7-day lock as one made while the lock was offered: already earning at 1.5x, its end on the lock queue.
#[test_only]
public fun old_lock_for_testing(p: &mut Pool, s: &mut Schedule, gts: Coin<GTS>, clock: &Clock, ctx: &TxContext) {
    let amount = coin::value(&gts);
    let player = tx_context::sender(ctx);
    let until = clock::timestamp_ms(clock) + LOCK_MS;
    let key = PosKey { player, locked: true };
    table::add(&mut p.positions, key, Position { amount, weight: weight_of(amount, true), locked_until: until, snap: p.acc, pending: 0 });
    p.total_weight = p.total_weight + weight_of(amount, true);
    p.total_amount = p.total_amount + amount;
    balance::join(&mut p.staked, coin::into_balance(gts));
    table::add(&mut s.lock_q, s.lock_tail, Due { player, locked: true, at: until });
    s.lock_tail = s.lock_tail + 1;
}
