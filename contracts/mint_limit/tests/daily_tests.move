#[test_only]
module mint_limit::daily_tests;

use sui::clock;
use sui::coin;
use sui::test_scenario as ts;
use supply_lock::capped::{Self, CappedTreasury};
use mint_limit::daily;

public struct TOK has drop {}

const A: address = @0xA;
const DAY: u64 = 86_400_000;

#[test]
fun limits_each_utc_day_and_resets() {
    let mut s = ts::begin(A);
    let cap = coin::create_treasury_cap_for_testing<TOK>(ts::ctx(&mut s));
    let m = capped::lock(cap, 0, 1_000, ts::ctx(&mut s));
    let mut l = daily::wrap(m, 100, ts::ctx(&mut s));
    ts::next_tx(&mut s, A);
    let mut t = ts::take_shared<CappedTreasury<TOK>>(&s);
    let mut clk = clock::create_for_testing(ts::ctx(&mut s));
    clock::set_for_testing(&mut clk, 10 * DAY + 5);
    let a = daily::mint(&mut l, &mut t, 60, &clk, ts::ctx(&mut s));
    let b = daily::mint(&mut l, &mut t, 40, &clk, ts::ctx(&mut s));
    assert!(coin::value(&a) == 60 && coin::value(&b) == 40 && daily::room_today(&l, &clk) == 0);
    // Last millisecond of the same UTC day: still full.
    clock::set_for_testing(&mut clk, 11 * DAY - 1);
    assert!(daily::room_today(&l, &clk) == 0);
    // Next UTC day: a fresh 100.
    clock::set_for_testing(&mut clk, 11 * DAY);
    assert!(daily::room_today(&l, &clk) == 100);
    let c = daily::mint(&mut l, &mut t, 100, &clk, ts::ctx(&mut s));
    assert!(coin::value(&c) == 100 && daily::minted_total(&l) == 200 && capped::minted(&t) == 200);
    transfer::public_transfer(a, A); transfer::public_transfer(b, A); transfer::public_transfer(c, A);
    transfer::public_transfer(l, A);
    clock::destroy_for_testing(clk);
    ts::return_shared(t);
    ts::end(s);
}

#[test, expected_failure(abort_code = daily::EDailyLimit)]
fun over_the_daily_limit_aborts() {
    let mut s = ts::begin(A);
    let cap = coin::create_treasury_cap_for_testing<TOK>(ts::ctx(&mut s));
    let m = capped::lock(cap, 0, 1_000, ts::ctx(&mut s));
    let mut l = daily::wrap(m, 100, ts::ctx(&mut s));
    ts::next_tx(&mut s, A);
    let mut t = ts::take_shared<CappedTreasury<TOK>>(&s);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    let a = daily::mint(&mut l, &mut t, 100, &clk, ts::ctx(&mut s));
    let b = daily::mint(&mut l, &mut t, 1, &clk, ts::ctx(&mut s));
    transfer::public_transfer(a, A); transfer::public_transfer(b, A); transfer::public_transfer(l, A);
    clock::destroy_for_testing(clk);
    ts::return_shared(t);
    ts::end(s);
}

#[test]
fun total_cap_still_applies() {
    let mut s = ts::begin(A);
    let cap = coin::create_treasury_cap_for_testing<TOK>(ts::ctx(&mut s));
    let m = capped::lock(cap, 950, 1_000, ts::ctx(&mut s));
    let mut l = daily::wrap(m, 100, ts::ctx(&mut s));
    ts::next_tx(&mut s, A);
    let mut t = ts::take_shared<CappedTreasury<TOK>>(&s);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    let a = daily::mint(&mut l, &mut t, 80, &clk, ts::ctx(&mut s));
    assert!(coin::value(&a) == 50 && capped::minted(&t) == 1_000 && daily::room_today(&l, &clk) == 50);
    transfer::public_transfer(a, A); transfer::public_transfer(l, A);
    clock::destroy_for_testing(clk);
    ts::return_shared(t);
    ts::end(s);
}

#[test, expected_failure(abort_code = daily::EZeroLimit)]
fun zero_limit_rejected() {
    let mut s = ts::begin(A);
    let cap = coin::create_treasury_cap_for_testing<TOK>(ts::ctx(&mut s));
    let m = capped::lock(cap, 0, 1_000, ts::ctx(&mut s));
    let l = daily::wrap(m, 0, ts::ctx(&mut s));
    transfer::public_transfer(l, A);
    ts::end(s);
}
