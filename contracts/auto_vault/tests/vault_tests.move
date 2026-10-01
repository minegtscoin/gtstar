#[test_only]
module auto_vault::vault_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::sui::SUI;
use auto_vault::vault::{Self, Vault, PullCap};

const GAME: address = @0x6A3E;
const BOB: address = @0xB0B;
const ALICE: address = @0xA11CE;
const SUI1: u64 = 1_000_000_000;

fun setup(sc: &mut Scenario): Clock {
    ts::next_tx(sc, GAME);
    vault::init_for_testing(ts::ctx(sc));
    ts::next_tx(sc, GAME);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, 1_000_000);
    clk
}

fun deposit(sc: &mut Scenario, who: address, amount: u64) {
    ts::next_tx(sc, who);
    let mut v = ts::take_shared<Vault>(sc);
    vault::deposit(&mut v, coin::mint_for_testing<SUI>(amount, ts::ctx(sc)), ts::ctx(sc));
    ts::return_shared(v);
}

fun start(sc: &mut Scenario, who: address, per_round: u64, rounds: u64, keep: u64, target: u64) {
    ts::next_tx(sc, who);
    let mut v = ts::take_shared<Vault>(sc);
    vault::start(&mut v, 2, per_round, rounds, keep, target, ts::ctx(sc));
    ts::return_shared(v);
}

/// One pull by the cap holder; returns the SUI taken.
fun pull(sc: &mut Scenario, player: address, clk: &Clock): u64 {
    ts::next_tx(sc, GAME);
    let mut v = ts::take_shared<Vault>(sc);
    let cap = ts::take_from_sender<PullCap>(sc);
    let b = vault::pull(&mut v, &cap, player, clk);
    let n = balance::value(&b);
    balance::destroy_for_testing(b);
    ts::return_to_sender(sc, cap);
    ts::return_shared(v);
    n
}

fun is_ready(sc: &mut Scenario, player: address, clk: &Clock): bool {
    ts::next_tx(sc, GAME);
    let v = ts::take_shared<Vault>(sc);
    let r = vault::ready(&v, player, clk);
    ts::return_shared(v);
    r
}

/// Deposit, withdraw part, withdraw the rest: the player gets every mist back, plan on or off.
#[test]
fun test_deposit_and_withdraw_any_time() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    start(&mut sc, BOB, SUI1 / 20, 100, 0, 0);
    ts::next_tx(&mut sc, BOB);
    let mut v = ts::take_shared<Vault>(&sc);
    assert!(vault::balance_of(&v, BOB) == SUI1 && vault::is_on(&v, BOB), 1);
    // With the plan on.
    let c = vault::withdraw(&mut v, SUI1 / 4, ts::ctx(&mut sc));
    assert!(coin::value(&c) == SUI1 / 4 && vault::balance_of(&v, BOB) == SUI1 * 3 / 4, 2);
    coin::burn_for_testing(c);
    vault::stop(&mut v, ts::ctx(&mut sc));
    // With the plan off: everything left.
    let c = vault::withdraw_all(&mut v, ts::ctx(&mut sc));
    assert!(coin::value(&c) == SUI1 * 3 / 4 && vault::balance_of(&v, BOB) == 0, 3);
    coin::burn_for_testing(c);
    let (dep, wd, spent, ret, rounds) = vault::totals_of(&v, BOB);
    assert!(dep == SUI1 && wd == SUI1 && spent == 0 && ret == 0 && rounds == 0, 4);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// A pull takes exactly the per-round amount, counts the round and waits 20 seconds before the next.
#[test]
fun test_pull_amount_and_gap() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    start(&mut sc, BOB, SUI1 / 20, 3, 0, 0);
    assert!(pull(&mut sc, BOB, &clk) == SUI1 / 20, 1);
    assert!(!is_ready(&mut sc, BOB, &clk), 2);
    clock::increment_for_testing(&mut clk, 19_999);
    assert!(!is_ready(&mut sc, BOB, &clk), 3);
    clock::increment_for_testing(&mut clk, 1);
    assert!(is_ready(&mut sc, BOB, &clk), 4);
    assert!(pull(&mut sc, BOB, &clk) == SUI1 / 20, 5);
    ts::next_tx(&mut sc, BOB);
    let v = ts::take_shared<Vault>(&sc);
    let (on, strategy, per, left, _, _, last) = vault::plan_of(&v, BOB);
    assert!(on && strategy == 2 && per == SUI1 / 20 && left == 1 && last == clock::timestamp_ms(&clk), 6);
    let (_, _, spent, _, rounds) = vault::totals_of(&v, BOB);
    assert!(spent == SUI1 / 10 && rounds == 2 && vault::balance_of(&v, BOB) == SUI1 * 9 / 10, 7);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// After the last round the plan turns itself off.
#[test]
fun test_rounds_run_out() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    start(&mut sc, BOB, SUI1 / 20, 2, 0, 0);
    pull(&mut sc, BOB, &clk);
    clock::increment_for_testing(&mut clk, 60_000);
    pull(&mut sc, BOB, &clk);
    clock::increment_for_testing(&mut clk, 60_000);
    assert!(!is_ready(&mut sc, BOB, &clk), 1);
    ts::next_tx(&mut sc, BOB);
    let v = ts::take_shared<Vault>(&sc);
    assert!(!vault::is_on(&v, BOB) && vault::balance_of(&v, BOB) == SUI1 * 9 / 10, 2);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// A pull never leaves less than `keep` in the account.
#[test]
fun test_keep_is_never_touched() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1 / 10);              // 0.1
    start(&mut sc, BOB, SUI1 / 20, 100, SUI1 / 20, 0); // 0.05 a round, keep 0.05
    assert!(pull(&mut sc, BOB, &clk) == SUI1 / 20, 1);
    clock::increment_for_testing(&mut clk, 60_000);
    assert!(!is_ready(&mut sc, BOB, &clk), 2);       // 0.05 left = keep
    // More SUI makes it ready again.
    deposit(&mut sc, BOB, SUI1 / 20);
    assert!(is_ready(&mut sc, BOB, &clk), 3);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Winnings are credited to the balance; reaching the target turns the plan off for good.
#[test]
fun test_credit_and_target() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    start(&mut sc, BOB, SUI1 / 20, 100, 0, SUI1 * 3 / 2); // stop at 1.5
    pull(&mut sc, BOB, &clk);
    ts::next_tx(&mut sc, ALICE);
    let mut v = ts::take_shared<Vault>(&sc);
    vault::credit(&mut v, BOB, balance::create_for_testing<SUI>(SUI1 / 10));
    assert!(vault::is_on(&v, BOB) && vault::balance_of(&v, BOB) == SUI1 * 21 / 20, 1);
    vault::credit(&mut v, BOB, balance::create_for_testing<SUI>(SUI1 / 2));
    assert!(!vault::is_on(&v, BOB) && vault::balance_of(&v, BOB) == SUI1 * 31 / 20, 2);
    let (_, _, _, ret, _) = vault::totals_of(&v, BOB);
    assert!(ret == SUI1 * 6 / 10, 3);
    ts::return_shared(v);
    // Still off after the player takes the profit out.
    ts::next_tx(&mut sc, BOB);
    let mut v = ts::take_shared<Vault>(&sc);
    coin::burn_for_testing(vault::withdraw(&mut v, SUI1, ts::ctx(&mut sc)));
    ts::return_shared(v);
    clock::increment_for_testing(&mut clk, 60_000);
    assert!(!is_ready(&mut sc, BOB, &clk), 4);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// A credit to an address with no account opens one, with the plan off.
#[test]
fun test_credit_opens_account() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    ts::next_tx(&mut sc, ALICE);
    let mut v = ts::take_shared<Vault>(&sc);
    vault::credit(&mut v, BOB, balance::create_for_testing<SUI>(SUI1));
    assert!(vault::has_account(&v, BOB) && !vault::is_on(&v, BOB) && vault::balance_of(&v, BOB) == SUI1, 1);
    ts::return_shared(v);
    ts::next_tx(&mut sc, BOB);
    let mut v = ts::take_shared<Vault>(&sc);
    coin::burn_for_testing(vault::withdraw_all(&mut v, ts::ctx(&mut sc)));
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Nothing can be pulled once the player stops the plan.
#[test, expected_failure(abort_code = vault::ENotReady)]
fun test_no_pull_after_stop() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    start(&mut sc, BOB, SUI1 / 20, 100, 0, 0);
    ts::next_tx(&mut sc, BOB);
    let mut v = ts::take_shared<Vault>(&sc);
    vault::stop(&mut v, ts::ctx(&mut sc));
    ts::return_shared(v);
    pull(&mut sc, BOB, &clk);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Nothing can be pulled from a player who never started a plan.
#[test, expected_failure(abort_code = vault::ENotReady)]
fun test_no_pull_without_plan() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    pull(&mut sc, BOB, &clk);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Nothing can be pulled twice within 20 seconds.
#[test, expected_failure(abort_code = vault::ENotReady)]
fun test_no_pull_within_gap() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    start(&mut sc, BOB, SUI1 / 20, 100, 0, 0);
    pull(&mut sc, BOB, &clk);
    clock::increment_for_testing(&mut clk, 10_000);
    pull(&mut sc, BOB, &clk);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Nothing can be pulled once the balance is below the per-round amount.
#[test, expected_failure(abort_code = vault::ENotReady)]
fun test_no_pull_past_balance() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1 / 25);          // 0.04
    start(&mut sc, BOB, SUI1 / 20, 100, 0, 0); // 0.05 a round
    pull(&mut sc, BOB, &clk);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// A player cannot withdraw more than their own balance, whatever others hold.
#[test, expected_failure(abort_code = vault::EInsufficient)]
fun test_withdraw_only_own_balance() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    deposit(&mut sc, ALICE, SUI1 / 10);
    ts::next_tx(&mut sc, ALICE);
    let mut v = ts::take_shared<Vault>(&sc);
    coin::burn_for_testing(vault::withdraw(&mut v, SUI1 / 2, ts::ctx(&mut sc)));
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// A plan needs an amount and at least one round.
#[test, expected_failure(abort_code = vault::EBadPlan)]
fun test_plan_needs_amount() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    deposit(&mut sc, BOB, SUI1);
    start(&mut sc, BOB, 0, 100, 0, 0);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}
