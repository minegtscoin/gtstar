/// Auto Mine vault: the SUI a player sets aside for automatic mining, and the plan it is spent by.
///
/// Every player has one account: a SUI balance and a plan (strategy, SUI per round, rounds left, a
/// balance to keep, a balance to stop at). Only the player can change the plan, turn it on or off, and
/// withdraw. `withdraw` has no condition other than the balance: it works at any time, whether the plan
/// is on or off, and nothing in this package can pause, block or delay it.
///
/// The only other way SUI leaves an account is `pull`: the holder of the single `PullCap` (the GTStar
/// game, which keeps it in its Board) takes exactly `per_round` SUI for one round, and only while the
/// plan is on, has rounds left, the balance stays at or above `keep` afterwards and below `target`, and
/// at least 20 seconds have passed since the last pull. So even the cap holder can never take more than
/// the player's own per-round amount, never faster than once every 20 seconds, never more rounds than the
/// player set, and never anything once the player stops the plan or withdraws.
///
/// `credit` puts SUI into an account (the game returns winnings with it). Anyone may call it.
///
/// There is no owner, no admin, no fee and no setting in this package, and exactly one `PullCap` is ever
/// made (at publish). The package is made immutable right after it is published, so these rules never change.
module auto_vault::vault;

use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};

/// Least time between two pulls from one account.
const MIN_GAP_MS: u64 = 20_000;

// Why a plan was turned off.
const BY_PLAYER: u8 = 0;
const ROUNDS_DONE: u8 = 1;
const TARGET_REACHED: u8 = 2;

const ENoAccount: u64 = 1;
const EInsufficient: u64 = 2;
const EBadPlan: u64 = 3;
const ENotReady: u64 = 4;
const EZero: u64 = 5;

/// All accounts (shared).
public struct Vault has key {
    id: UID,
    accounts: Table<address, Account>,
}

public struct Account has store {
    balance: Balance<SUI>,
    on: bool,
    strategy: u8,     // read by the game; any value can be stored
    per_round: u64,   // SUI taken for one round
    rounds_left: u64, // pulls still allowed
    keep: u64,        // a pull never leaves the balance below this
    target: u64,      // the plan turns off once the balance reaches this (0 = no target)
    last_ms: u64,     // time of the last pull
    // lifetime totals
    deposited: u64,
    withdrawn: u64,
    spent: u64,       // pulled for rounds
    returned: u64,    // credited back (winnings)
    rounds: u64,      // pulls so far
}

/// The right to `pull`. One exists, made at publish.
public struct PullCap has key, store { id: UID }

public struct Deposited has copy, drop { player: address, amount: u64, balance: u64 }
public struct Withdrawn has copy, drop { player: address, amount: u64, balance: u64 }
public struct PlanSet has copy, drop { player: address, strategy: u8, per_round: u64, rounds: u64, keep: u64, target: u64 }
public struct Stopped has copy, drop { player: address, reason: u8 }
public struct Pulled has copy, drop { player: address, amount: u64, balance: u64, rounds_left: u64 }
public struct Credited has copy, drop { player: address, amount: u64, balance: u64 }

fun init(ctx: &mut TxContext) {
    transfer::share_object(Vault { id: object::new(ctx), accounts: table::new(ctx) });
    transfer::public_transfer(PullCap { id: object::new(ctx) }, tx_context::sender(ctx));
}

fun account_mut(vault: &mut Vault, player: address): &mut Account {
    if (!table::contains(&vault.accounts, player)) {
        table::add(&mut vault.accounts, player, Account {
            balance: balance::zero(), on: false, strategy: 0, per_round: 0, rounds_left: 0, keep: 0, target: 0,
            last_ms: 0, deposited: 0, withdrawn: 0, spent: 0, returned: 0, rounds: 0,
        });
    };
    table::borrow_mut(&mut vault.accounts, player)
}

// ===== The player =====

/// Add SUI to the sender's account (made on the first deposit).
public fun deposit(vault: &mut Vault, payment: Coin<SUI>, ctx: &TxContext) {
    let amount = coin::value(&payment);
    assert!(amount > 0, EZero);
    let player = tx_context::sender(ctx);
    let a = account_mut(vault, player);
    balance::join(&mut a.balance, coin::into_balance(payment));
    a.deposited = a.deposited + amount;
    event::emit(Deposited { player, amount, balance: balance::value(&a.balance) });
}

/// Take `amount` SUI out of the sender's account. Works at any time.
public fun withdraw(vault: &mut Vault, amount: u64, ctx: &mut TxContext): Coin<SUI> {
    let player = tx_context::sender(ctx);
    assert!(table::contains(&vault.accounts, player), ENoAccount);
    let a = table::borrow_mut(&mut vault.accounts, player);
    assert!(amount > 0, EZero);
    assert!(amount <= balance::value(&a.balance), EInsufficient);
    a.withdrawn = a.withdrawn + amount;
    let out = coin::from_balance(balance::split(&mut a.balance, amount), ctx);
    event::emit(Withdrawn { player, amount, balance: balance::value(&a.balance) });
    out
}

/// Take the sender's whole balance out. Works at any time.
public fun withdraw_all(vault: &mut Vault, ctx: &mut TxContext): Coin<SUI> {
    let player = tx_context::sender(ctx);
    assert!(table::contains(&vault.accounts, player), ENoAccount);
    let amount = balance::value(&table::borrow(&vault.accounts, player).balance);
    withdraw(vault, amount, ctx)
}

/// Set the sender's plan and turn it on: `per_round` SUI a round for at most `rounds` rounds, never
/// leaving less than `keep` in the account, and off once the balance reaches `target` (0 = no target).
public fun start(vault: &mut Vault, strategy: u8, per_round: u64, rounds: u64, keep: u64, target: u64, ctx: &TxContext) {
    assert!(per_round > 0 && rounds > 0, EBadPlan);
    let player = tx_context::sender(ctx);
    let a = account_mut(vault, player);
    a.on = true;
    a.strategy = strategy;
    a.per_round = per_round;
    a.rounds_left = rounds;
    a.keep = keep;
    a.target = target;
    event::emit(PlanSet { player, strategy, per_round, rounds, keep, target });
}

/// Turn the sender's plan off. The balance stays in the account until it is withdrawn.
public fun stop(vault: &mut Vault, ctx: &TxContext) {
    let player = tx_context::sender(ctx);
    assert!(table::contains(&vault.accounts, player), ENoAccount);
    let a = table::borrow_mut(&mut vault.accounts, player);
    if (a.on) {
        a.on = false;
        event::emit(Stopped { player, reason: BY_PLAYER });
    };
}

// ===== The game =====

/// Whether `pull` would succeed for `player` now.
public fun ready(vault: &Vault, player: address, clock: &Clock): bool {
    if (!table::contains(&vault.accounts, player)) { return false };
    let a = table::borrow(&vault.accounts, player);
    let bal = balance::value(&a.balance);
    a.on && a.rounds_left > 0 && a.per_round > 0
        && bal >= a.per_round && bal - a.per_round >= a.keep
        && (a.target == 0 || bal < a.target)
        && clock::timestamp_ms(clock) >= a.last_ms + MIN_GAP_MS
}

/// Take `player`'s per-round SUI for one round. Aborts unless `ready`.
public fun pull(vault: &mut Vault, _: &PullCap, player: address, clock: &Clock): Balance<SUI> {
    assert!(ready(vault, player, clock), ENotReady);
    let a = table::borrow_mut(&mut vault.accounts, player);
    let amount = a.per_round;
    a.rounds_left = a.rounds_left - 1;
    a.last_ms = clock::timestamp_ms(clock);
    a.spent = a.spent + amount;
    a.rounds = a.rounds + 1;
    let out = balance::split(&mut a.balance, amount);
    event::emit(Pulled { player, amount, balance: balance::value(&a.balance), rounds_left: a.rounds_left });
    if (a.rounds_left == 0) {
        a.on = false;
        event::emit(Stopped { player, reason: ROUNDS_DONE });
    };
    out
}

/// Put SUI into `player`'s account (winnings). Anyone may call it. Reaching the target turns the plan off.
public fun credit(vault: &mut Vault, player: address, funds: Balance<SUI>) {
    let amount = balance::value(&funds);
    let a = account_mut(vault, player);
    balance::join(&mut a.balance, funds);
    a.returned = a.returned + amount;
    let bal = balance::value(&a.balance);
    event::emit(Credited { player, amount, balance: bal });
    if (a.on && a.target > 0 && bal >= a.target) {
        a.on = false;
        event::emit(Stopped { player, reason: TARGET_REACHED });
    };
}

// ===== Views =====

public fun min_gap_ms(): u64 { MIN_GAP_MS }
public fun has_account(vault: &Vault, player: address): bool { table::contains(&vault.accounts, player) }
public fun balance_of(vault: &Vault, player: address): u64 {
    if (!table::contains(&vault.accounts, player)) { return 0 };
    balance::value(&table::borrow(&vault.accounts, player).balance)
}
public fun is_on(vault: &Vault, player: address): bool {
    table::contains(&vault.accounts, player) && table::borrow(&vault.accounts, player).on
}
/// (on, strategy, SUI per round, rounds left, keep, target, time of the last pull).
public fun plan_of(vault: &Vault, player: address): (bool, u8, u64, u64, u64, u64, u64) {
    if (!table::contains(&vault.accounts, player)) { return (false, 0, 0, 0, 0, 0, 0) };
    let a = table::borrow(&vault.accounts, player);
    (a.on, a.strategy, a.per_round, a.rounds_left, a.keep, a.target, a.last_ms)
}
/// Lifetime totals: (deposited, withdrawn, spent on rounds, returned by rounds, rounds).
public fun totals_of(vault: &Vault, player: address): (u64, u64, u64, u64, u64) {
    if (!table::contains(&vault.accounts, player)) { return (0, 0, 0, 0, 0) };
    let a = table::borrow(&vault.accounts, player);
    (a.deposited, a.withdrawn, a.spent, a.returned, a.rounds)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }
