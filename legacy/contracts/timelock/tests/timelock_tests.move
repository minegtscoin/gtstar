#[test_only]
module gtstar_timelock::timelock_tests;

use sui::clock;
use sui::package;
use sui::test_scenario as ts;
use gtstar_timelock::timelock;

const DIGEST: vector<u8> = x"0101010101010101010101010101010101010101010101010101010101010101";

#[test]
fun test_upgrade_after_delay() {
    let mut sc = ts::begin(@0xA);
    let cap = package::test_publish(object::id_from_address(@0x1234), ts::ctx(&mut sc));
    let mut tl = timelock::lock_for_testing(cap, ts::ctx(&mut sc));
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    timelock::announce(&mut tl, package::compatible_policy(), DIGEST, &clk);
    assert!(timelock::ready_ms(&tl) == 1_000 + timelock::delay_ms(), 0);
    clock::set_for_testing(&mut clk, 1_000 + timelock::delay_ms());
    let ticket = timelock::authorize(&mut tl, &clk);
    let receipt = package::test_upgrade(ticket);
    timelock::commit(&mut tl, receipt);
    assert!(timelock::ready_ms(&tl) == 0, 1);
    clock::destroy_for_testing(clk);
    timelock::destroy_for_testing(tl);
    ts::end(sc);
}

#[test, expected_failure(abort_code = gtstar_timelock::timelock::ETooEarly)]
fun test_upgrade_before_delay_fails() {
    let mut sc = ts::begin(@0xA);
    let cap = package::test_publish(object::id_from_address(@0x1234), ts::ctx(&mut sc));
    let mut tl = timelock::lock_for_testing(cap, ts::ctx(&mut sc));
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    timelock::announce(&mut tl, package::compatible_policy(), DIGEST, &clk);
    clock::set_for_testing(&mut clk, 1_000 + timelock::delay_ms() - 1);
    let ticket = timelock::authorize(&mut tl, &clk);
    let _receipt = package::test_upgrade(ticket);
    abort 0
}

#[test, expected_failure(abort_code = gtstar_timelock::timelock::ENothingAnnounced)]
fun test_upgrade_without_announce_fails() {
    let mut sc = ts::begin(@0xA);
    let cap = package::test_publish(object::id_from_address(@0x1234), ts::ctx(&mut sc));
    let mut tl = timelock::lock_for_testing(cap, ts::ctx(&mut sc));
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let ticket = timelock::authorize(&mut tl, &clk);
    let _receipt = package::test_upgrade(ticket);
    abort 0
}

#[test, expected_failure(abort_code = gtstar_timelock::timelock::ENothingAnnounced)]
fun test_cancel_blocks_upgrade() {
    let mut sc = ts::begin(@0xA);
    let cap = package::test_publish(object::id_from_address(@0x1234), ts::ctx(&mut sc));
    let mut tl = timelock::lock_for_testing(cap, ts::ctx(&mut sc));
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    timelock::announce(&mut tl, package::compatible_policy(), DIGEST, &clk);
    timelock::cancel(&mut tl);
    clock::set_for_testing(&mut clk, timelock::delay_ms() * 2);
    let ticket = timelock::authorize(&mut tl, &clk);
    let _receipt = package::test_upgrade(ticket);
    abort 0
}

#[test, expected_failure(abort_code = gtstar_timelock::timelock::EAlreadyAnnounced)]
fun test_second_announce_rejected() {
    let mut sc = ts::begin(@0xA);
    let cap = package::test_publish(object::id_from_address(@0x1234), ts::ctx(&mut sc));
    let mut tl = timelock::lock_for_testing(cap, ts::ctx(&mut sc));
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    timelock::announce(&mut tl, package::compatible_policy(), DIGEST, &clk);
    timelock::announce(&mut tl, package::compatible_policy(), DIGEST, &clk);
    abort 0
}
