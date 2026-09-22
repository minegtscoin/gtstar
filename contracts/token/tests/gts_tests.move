#[test_only]
module gts_token::gts_tests;

use sui::test_scenario::{Self as ts};
use sui::coin;
use sui::sui::SUI;
use sui::balance;
use sui::clock;
use gts_token::gts::{Self, Treasury, MinterCap};

const ADMIN: address = @0xA11CE;
const MIN: u64 = 60_000;
const HALF: u64 = 15_778_800_000;
const G: u64 = 1_790_000_000_000; // genesis used in tests (Sep 2026)

fun setup(sc: &mut ts::Scenario): (Treasury, MinterCap, clock::Clock) {
    gts::init_for_testing(ts::ctx(sc));
    ts::next_tx(sc, ADMIN);
    let t = ts::take_shared<Treasury>(sc);
    let cap = ts::take_from_sender<MinterCap>(sc);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, G);
    (t, cap, clk)
}

fun teardown(sc: ts::Scenario, t: Treasury, cap: MinterCap, clk: clock::Clock) {
    ts::return_shared(t);
    transfer::public_transfer(cap, ADMIN);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Nothing can be minted before the emission clock starts.
#[test]
fun test_no_mint_before_start() {
    let mut sc = ts::begin(ADMIN);
    let (mut t, cap, clk) = setup(&mut sc);
    let c = gts::mint(&mut t, &cap, 1_000_000_000, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&c) == 0, 0);
    coin::burn_for_testing(c);
    teardown(sc, t, cap, clk);
}

/// The ceiling grows at 1.1 GTS per minute and halves every 6 months.
#[test]
fun test_allowance_schedule() {
    let mut sc = ts::begin(ADMIN);
    let (mut t, cap, clk) = setup(&mut sc);
    gts::start(&mut t, &cap, &clk);
    assert!(gts::allowance(&t, G) == 0, 0);
    assert!(gts::allowance(&t, G + MIN) == 1_100_000_000, 1);
    assert!(gts::allowance(&t, G + 10 * MIN) == 11_000_000_000, 2);
    let first = gts::allowance(&t, G + HALF);
    // one more minute in the second period adds 0.55 GTS
    assert!(gts::allowance(&t, G + HALF + MIN) == first + 550_000_000, 3);
    // stops growing on 2030-01-01 and stays far below the hard cap
    let end = gts::allowance(&t, gts::emission_end_ms());
    assert!(gts::allowance(&t, gts::emission_end_ms() + 100 * HALF) == end, 4);
    assert!(end < 600_000_000_000_000, 5);
    teardown(sc, t, cap, clk);
}

/// Minting is clamped to the ceiling, and the clock can only start once.
#[test]
fun test_mint_clamped() {
    let mut sc = ts::begin(ADMIN);
    let (mut t, cap, mut clk) = setup(&mut sc);
    gts::start(&mut t, &cap, &clk);
    clock::set_for_testing(&mut clk, G + MIN);
    let a = gts::mint(&mut t, &cap, 5_000_000_000, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&a) == 1_100_000_000, 0);
    let b = gts::mint(&mut t, &cap, 1, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&b) == 0, 1);
    coin::burn_for_testing(a); coin::burn_for_testing(b);
    teardown(sc, t, cap, clk);
}

#[test, expected_failure(abort_code = gts_token::gts::EAlreadyStarted)]
fun test_start_once() {
    let mut sc = ts::begin(ADMIN);
    let (mut t, cap, clk) = setup(&mut sc);
    gts::start(&mut t, &cap, &clk);
    gts::start(&mut t, &cap, &clk);
    teardown(sc, t, cap, clk);
}

/// Burned GTS never frees room for new minting.
#[test]
fun test_burn_does_not_free_room() {
    let mut sc = ts::begin(ADMIN);
    let (mut t, cap, mut clk) = setup(&mut sc);
    gts::start(&mut t, &cap, &clk);
    clock::set_for_testing(&mut clk, G + MIN);
    let a = gts::mint(&mut t, &cap, 1_100_000_000, &clk, ts::ctx(&mut sc));
    gts::vault_add(&mut t, balance::create_for_testing<SUI>(1_000_000_000));
    let out = gts::redeem(&mut t, a, ts::ctx(&mut sc));
    assert!(coin::value(&out) == 1_000_000_000, 0);
    assert!(gts::total_supply(&t) == 0, 1);
    let b = gts::mint(&mut t, &cap, 1, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&b) == 0, 2);
    coin::burn_for_testing(out); coin::burn_for_testing(b);
    teardown(sc, t, cap, clk);
}

/// Redeem pays a pro-rata share, burns the GTS, and never lowers the floor.
#[test]
fun test_redeem_floor() {
    let mut sc = ts::begin(ADMIN);
    let (mut t, cap, mut clk) = setup(&mut sc);
    gts::start(&mut t, &cap, &clk);
    clock::set_for_testing(&mut clk, G + 100 * MIN);
    let mut g = gts::mint(&mut t, &cap, 100_000_000_000, &clk, ts::ctx(&mut sc));
    gts::vault_add(&mut t, balance::create_for_testing<SUI>(50_000_000_000));
    let floor_before = gts::floor_price_scaled(&t);
    let half = coin::split(&mut g, 50_000_000_000, ts::ctx(&mut sc));
    let out = gts::redeem(&mut t, half, ts::ctx(&mut sc));
    assert!(coin::value(&out) == 25_000_000_000, 0);
    assert!(gts::total_supply(&t) == 50_000_000_000, 1);
    assert!(gts::floor_price_scaled(&t) >= floor_before, 2);
    coin::burn_for_testing(g); coin::burn_for_testing(out);
    teardown(sc, t, cap, clk);
}
