#[test_only]
module supply_lock::capped_tests;

use sui::coin;
use sui::test_scenario as ts;
use supply_lock::capped::{Self, CappedTreasury, MinterCap};

public struct TOK has drop {}

const A: address = @0xA;

fun setup(minted: u64, max: u64): ts::Scenario {
    let mut s = ts::begin(A);
    let mut cap = coin::create_treasury_cap_for_testing<TOK>(ts::ctx(&mut s));
    let c = coin::mint(&mut cap, minted, ts::ctx(&mut s));
    transfer::public_transfer(c, A);
    let m = capped::lock(cap, minted, max, ts::ctx(&mut s));
    transfer::public_transfer(m, A);
    ts::next_tx(&mut s, A);
    s
}

#[test]
fun mints_up_to_max_and_never_past() {
    let mut s = setup(30, 100);
    let mut t = ts::take_shared<CappedTreasury<TOK>>(&s);
    let m = ts::take_from_sender<MinterCap<TOK>>(&s);
    assert!(capped::minted(&t) == 30 && capped::max(&t) == 100 && capped::room(&t) == 70);
    let a = capped::mint(&mut t, &m, 50, ts::ctx(&mut s));
    assert!(coin::value(&a) == 50);
    // Asking for more than the room gives only the room.
    let b = capped::mint(&mut t, &m, 1_000, ts::ctx(&mut s));
    assert!(coin::value(&b) == 20 && capped::minted(&t) == 100);
    // Full: nothing more, ever.
    let c = capped::mint(&mut t, &m, 1, ts::ctx(&mut s));
    assert!(coin::value(&c) == 0);
    // Burning does not free up room.
    capped::burn(&mut t, a);
    assert!(capped::total_supply(&t) == 50 && capped::room(&t) == 0);
    let d = capped::mint(&mut t, &m, 10, ts::ctx(&mut s));
    assert!(coin::value(&d) == 0);
    transfer::public_transfer(b, A);
    coin::destroy_zero(c);
    coin::destroy_zero(d);
    ts::return_to_sender(&s, m);
    ts::return_shared(t);
    ts::end(s);
}

#[test, expected_failure(abort_code = capped::EOverMax)]
fun lock_rejects_minted_below_supply() {
    let mut s = ts::begin(A);
    let mut cap = coin::create_treasury_cap_for_testing<TOK>(ts::ctx(&mut s));
    let c = coin::mint(&mut cap, 10, ts::ctx(&mut s));
    transfer::public_transfer(c, A);
    let m = capped::lock(cap, 9, 100, ts::ctx(&mut s));
    transfer::public_transfer(m, A);
    ts::end(s);
}

#[test, expected_failure(abort_code = capped::EOverMax)]
fun lock_rejects_minted_above_max() {
    let mut s = ts::begin(A);
    let cap = coin::create_treasury_cap_for_testing<TOK>(ts::ctx(&mut s));
    let m = capped::lock(cap, 101, 100, ts::ctx(&mut s));
    transfer::public_transfer(m, A);
    ts::end(s);
}

#[test, expected_failure(abort_code = capped::EWrongMinter)]
fun minter_of_another_treasury_cannot_mint() {
    let mut s = setup(0, 100);
    let cap2 = coin::create_treasury_cap_for_testing<TOK>(ts::ctx(&mut s));
    let other = capped::lock(cap2, 0, 100, ts::ctx(&mut s));
    ts::next_tx(&mut s, A);
    let ids = ts::ids_for_sender<MinterCap<TOK>>(&s);
    let first = *vector::borrow(&ids, 0);
    let m = ts::take_from_sender_by_id<MinterCap<TOK>>(&s, first);
    // Take the treasury the other minter does not belong to.
    let t_id = capped::treasury_of(&m);
    let mut t = ts::take_shared_by_id<CappedTreasury<TOK>>(&s, t_id);
    let c = capped::mint(&mut t, &other, 1, ts::ctx(&mut s));
    transfer::public_transfer(c, A);
    transfer::public_transfer(other, A);
    ts::return_to_sender(&s, m);
    ts::return_shared(t);
    ts::end(s);
}
