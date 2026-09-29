#[test_only]
module gtstar::game_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::coin;
use sui::sui::SUI;
use sui::clock::{Self, Clock};
use sui::random::{Self, Random};
use gtstar::gts::{Self, Treasury};
use gtstar::game::{Self, Board, AdminCap, Miner};

const OWNER: address = @0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e;
const BOB: address = @0xB0B;
const ALICE: address = @0xA11CE;
const GTS1: u64 = 1_000_000_000;
const SUI1: u64 = 1_000_000_000;

fun setup(sc: &mut Scenario) {
    random::create_for_testing(ts::ctx(sc));
    ts::next_tx(sc, @0x0);
    let mut rs = ts::take_shared<Random>(sc);
    random::update_randomness_state_for_testing(&mut rs, 0, x"0A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20212223242526272829", ts::ctx(sc));
    ts::return_shared(rs);
    ts::next_tx(sc, OWNER);
    gts::init_for_testing(ts::ctx(sc));
    game::init_for_testing(ts::ctx(sc));
    ts::next_tx(sc, OWNER);
}

fun all_tiles(per: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0;
    while (k < 25) { vector::push_back(&mut v, per); k = k + 1; };
    v
}

fun one_tile(i: u64, amt: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0;
    while (k < 25) { vector::push_back(&mut v, if (k == i) { amt } else { 0 }); k = k + 1; };
    v
}

/// One full round by the sender: deploy `per` on every tile, settle, claim. Returns (GTS, SUI) values.
fun play_round(sc: &mut Scenario, board: &mut Board, treasury: &mut Treasury, rs: &Random, clk: &mut Clock, m: &mut Miner, per: u64): (u64, u64) {
    let t = clock::timestamp_ms(clk) + 1_000;
    clock::set_for_testing(clk, t);
    game::deploy(board, m, coin::mint_for_testing<SUI>(per * 25, ts::ctx(sc)), all_tiles(per), clk, ts::ctx(sc));
    clock::set_for_testing(clk, t + 61_000);
    game::settle_for_testing(board, treasury, rs, clk, ts::ctx(sc));
    let (g, s) = game::claim(board, m, treasury, ts::ctx(sc));
    let (gv, sv) = (coin::value(&g), coin::value(&s));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    (gv, sv)
}

/// Launch settings: 1 GTS per round, 15,658 rounds per step, 1.425% cut, full reward at 1 SUI.
#[test]
fun test_launch_emission() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let board = ts::take_shared<Board>(&sc);
    let (reward, step, decay, count, full, committed) = game::emission(&board);
    assert!(reward == GTS1 && step == 15_658 && decay == 14_250 && count == 0 && full == SUI1 && committed == 0, 1);
    assert!(game::current_reward(&board) == GTS1, 2);
    assert!(gts::max_supply() == 1_000_000 * GTS1, 3);
    ts::return_shared(board);
    ts::end(sc);
}

/// A round with a winner: creator 1%, reserve 4% (0.005 of it to the drawer), no buyback, winners 95%,
/// kept whole even when spread over every tile. 1 GTS mined into the unrefined balance, all for the SUI
/// lost. Every mist is accounted for.
#[test]
fun test_round_with_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));

    let per = 100_000_000;
    let (g, s) = play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, per);
    let losing = per * 24;
    assert!(s == per + losing * 95 / 100, 1);
    assert!(game::dev_fees_value(&board) == losing / 100, 2);
    assert!(game::buyback_value(&board) == 0, 3);
    assert!(gts::vault_value(&treasury) == losing * 4 / 100 - 5_000_000, 4); // 0.005 SUI to the drawer
    assert!(game::pot_value(&board) == 0, 5);
    assert!(g == 0 && game::unrefined_total(&board) == GTS1, 6); // 2.5 SUI >= 1 SUI: full 1 GTS
    assert!(gts::minted(&treasury) == GTS1, 7);
    let (_, _, _, count, _, committed) = game::emission(&board);
    assert!(count == 1 && committed == GTS1, 8);

    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Below the full-reward deposit the reward scales down: 0.25 SUI in the round mints 0.25 GTS.
#[test]
fun test_small_round_scales_reward() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 10_000_000);
    assert!(game::unrefined_total(&board) == GTS1 / 4, 1);
    let (_, _, _, _, _, committed) = game::emission(&board);
    assert!(committed == GTS1 / 4 && gts::minted(&treasury) == GTS1 / 4, 2);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The reward drops by 1.425% at the end of every step, and only then.
#[test]
fun test_decay_every_step() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    // Step of 3 rounds so the test is short; same code path as 15,658.
    game::set_emission(&admin, &mut board, GTS1, 3, 14_250, 0, SUI1);
    ts::return_to_sender(&sc, admin);
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));

    let mut i = 0;
    while (i < 3) {
        assert!(game::current_reward(&board) == GTS1, 1);
        play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
        i = i + 1;
    };
    let r1 = 985_750_000; // 1 GTS x 0.98575
    assert!(game::current_reward(&board) == r1, 2);
    i = 0;
    while (i < 3) {
        play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
        i = i + 1;
    };
    let r2 = (((r1 as u128) * 985_750 / 1_000_000) as u64);
    assert!(game::current_reward(&board) == r2, 3);
    let (_, _, _, count, _, committed) = game::emission(&board);
    assert!(count == 0 && committed == 3 * GTS1 + 3 * r1, 4);
    assert!(game::unrefined_total(&board) == committed, 5);

    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Mining stops exactly at 1,000,000 GTS: the last round gets only what is left, then zero.
#[test]
fun test_cap_stops_mining() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let cap = gts::max_supply();
    game::set_committed_for_testing(&mut board, cap - GTS1 / 10); // 0.1 GTS left
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));

    assert!(game::current_reward(&board) == GTS1 / 10, 1);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::unrefined_total(&board) == GTS1 / 10, 2);
    assert!(game::current_reward(&board) == 0, 3);
    let (_, _, _, _, _, committed) = game::emission(&board);
    assert!(committed == cap, 4);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::unrefined_total(&board) == GTS1 / 10, 5);

    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// No one on the winning tile: creator 1%, reserve 4% (all of it to the drawer here: 0.004 < 0.005),
/// Wealth Fund 19.5%, the rest to the reserve.
#[test]
fun test_round_without_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let amt = 100_000_000;
    let mut t = 1_000;
    // Find a round whose winning tile is not tile 0 (deterministic randomness, bounded search).
    let mut done = false;
    let mut tries = 0;
    while (!done && tries < 10) {
        let mut m = game::new_miner(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, t);
        game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(amt, ts::ctx(&mut sc)), one_tile(0, amt), &clk, ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, t + 61_000);
        let vault_before = gts::vault_value(&treasury);
        let fund_before = game::motherlode_value(&board);
        let buy_before = game::buyback_value(&board);
        let dev_before = game::dev_fees_value(&board);
        game::settle_for_testing(&mut board, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
        let round = game::current_round(&board) - 1;
        if (game::winning_square_for_testing(&board, round) != 0) {
            assert!(game::dev_fees_value(&board) - dev_before == amt / 100, 1);
            assert!(game::buyback_value(&board) - buy_before == 0, 2);
            assert!(game::motherlode_value(&board) - fund_before == amt * 1_950 / 10_000, 3);
            assert!(gts::vault_value(&treasury) - vault_before == amt - amt / 100 - amt * 4 / 100 - amt * 1_950 / 10_000, 4);
            done = true;
        };
        let (g, s) = game::claim(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
        coin::burn_for_testing(g); coin::burn_for_testing(s);
        transfer::public_transfer(m, BOB);
        t = t + 100_000;
        tries = tries + 1;
    };
    assert!(done, 5);
    assert!(game::pot_value(&board) == 0, 6);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// One round by `who` alone with `amounts`, settled by OWNER, claimed by `who`. Returns the SUI paid back.
fun round_as(sc: &mut Scenario, who: address, board: &mut Board, treasury: &mut Treasury, rs: &Random, clk: &mut Clock, amounts: vector<u64>, odds: u64): u64 {
    let t = clock::timestamp_ms(clk) + 100_000;
    ts::next_tx(sc, who);
    let mut m = game::new_miner(ts::ctx(sc));
    let mut sum = 0u64;
    let mut k = 0;
    while (k < 25) { sum = sum + *vector::borrow(&amounts, k); k = k + 1; };
    clock::set_for_testing(clk, t);
    game::deploy(board, &mut m, coin::mint_for_testing<SUI>(sum, ts::ctx(sc)), amounts, clk, ts::ctx(sc));
    clock::set_for_testing(clk, t + 61_000);
    ts::next_tx(sc, OWNER);
    game::settle_with_odds_for_testing(board, treasury, rs, clk, odds, ts::ctx(sc));
    ts::next_tx(sc, who);
    let (g, s) = game::claim(board, &mut m, treasury, ts::ctx(sc));
    let sv = coin::value(&s);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, who);
    sv
}

/// Tickets are the fee paid on the SUI lost: 5% (creator 1 + reserve 4) of a lost deposit,
/// nothing for a round won. Odds of a million keep the fund from paying during the test.
#[test]
fun test_tickets_are_fee_paid() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut expected = 0u64;
    let mut n = 0u64;
    while (n < 8) {
        round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(0, SUI1), 1_000_000);
        let round = game::current_round(&board) - 1;
        if (game::winning_square_for_testing(&board, round) != 0) { expected = expected + SUI1 / 20 };
        n = n + 1;
    };
    assert!(expected > 0, 1);
    assert!(game::tickets_of(&board, BOB) == expected, 2);
    let (epoch, total) = game::wealth_tickets(&board);
    assert!(epoch == 0 && total == expected, 3);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Whale on all 25 tiles: tickets only for the 24 losing tiles' fee, far below what the whale lost.
#[test]
fun test_whale_tickets_below_loss() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let per = 400_000_000; // 10 SUI in all
    let back = round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(per), 1_000_000);
    let tickets = game::tickets_of(&board, BOB);
    assert!(tickets == per * 24 / 20, 1);
    assert!(tickets <= per * 25 - back, 2);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// 25 wallets of one owner, one tile each (the cheapest way to cover the board): the winner takes the
/// others' losses, so together they only lose the fees. Their tickets equal exactly those fees: a ticket
/// always costs one mist of real SUI, a second wallet makes it no cheaper. GTS goes by SUI lost too:
/// the winning wallet mines none, the 24 others share the round reward equally, the same total one
/// wallet on every tile would mine.
#[test]
fun test_sybil_wallets_pay_full_price() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let amt = 100_000_000;
    clock::set_for_testing(&mut clk, 1_000);
    let mut miners = vector[];
    let mut i = 0;
    while (i < 25) {
        let who = sui::address::from_u256((0x5000 + i) as u256);
        ts::next_tx(&mut sc, who);
        let mut m = game::new_miner(ts::ctx(&mut sc));
        game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(amt, ts::ctx(&mut sc)), one_tile(i, amt), &clk, ts::ctx(&mut sc));
        vector::push_back(&mut miners, m);
        i = i + 1;
    };
    clock::set_for_testing(&mut clk, 62_000);
    ts::next_tx(&mut sc, OWNER);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &rs, &clk, 1_000_000, ts::ctx(&mut sc));
    let w = game::winning_square_for_testing(&board, 1);
    let mut back = 0u64;
    let mut tickets = 0u64;
    let mut mined = 0u64;
    while (!vector::is_empty(&miners)) {
        let mut m = vector::pop_back(&mut miners);
        let i = vector::length(&miners);
        let who = sui::address::from_u256((0x5000 + i) as u256);
        ts::next_tx(&mut sc, who);
        let (g, s) = game::claim(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
        back = back + coin::value(&s);
        coin::burn_for_testing(g); coin::burn_for_testing(s);
        tickets = tickets + game::tickets_of(&board, who);
        let (u, _) = game::unrefined_of(&board, who);
        assert!(u == if (i == w) { 0 } else { GTS1 / 24 }, 3);
        mined = mined + u;
        transfer::public_transfer(m, who);
    };
    vector::destroy_empty(miners);
    let lost = amt * 25 - back;
    assert!(lost == amt * 24 / 20, 1); // together they lost only the 5% fee on 24 tiles
    assert!(tickets == lost, 2);
    assert!(mined == GTS1 / 24 * 24, 4);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

const SHIELD: address = @0xadf4446b0340e1b8d4c0abde15da3381db54057a1e4bda533cc3c8ca1abbc077;
const HOUSE: address = @0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a;

/// House bots and the Shield bot get no tickets.
#[test]
fun test_bots_get_no_tickets() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    round_as(&mut sc, SHIELD, &mut board, &mut treasury, &rs, &mut clk, all_tiles(100_000_000), 1_000_000);
    round_as(&mut sc, HOUSE, &mut board, &mut treasury, &rs, &mut clk, all_tiles(100_000_000), 1_000_000);
    assert!(game::tickets_of(&board, SHIELD) == 0 && game::tickets_of(&board, HOUSE) == 0, 1);
    let (_, total) = game::wealth_tickets(&board);
    assert!(total == 0, 2);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Ticket ranges in order of claim: Bob [0, 120M), Alice [120M, 360M), Bob [360M, 480M).
#[test]
fun test_ticket_ranges() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(100_000_000), 1_000_000);
    round_as(&mut sc, ALICE, &mut board, &mut treasury, &rs, &mut clk, all_tiles(200_000_000), 1_000_000);
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(100_000_000), 1_000_000);
    assert!(game::tickets_of(&board, BOB) == 240_000_000 && game::tickets_of(&board, ALICE) == 240_000_000, 1);
    assert!(game::ticket_holder_for_testing(&board, 0) == BOB, 2);
    assert!(game::ticket_holder_for_testing(&board, 119_999_999) == BOB, 3);
    assert!(game::ticket_holder_for_testing(&board, 120_000_000) == ALICE, 4);
    assert!(game::ticket_holder_for_testing(&board, 359_999_999) == ALICE, 5);
    assert!(game::ticket_holder_for_testing(&board, 360_000_000) == BOB, 6);
    assert!(game::ticket_holder_for_testing(&board, 479_999_999) == BOB, 7);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// When the fund hits (odds 1 forces it) it goes whole to a ticket holder, not to the round's winning
/// tile: Bob holds every ticket, Alice plays the hitting round on all tiles and gets none of it.
/// Tickets then start over.
#[test]
fun test_wealth_fund_pays() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    // Fill the fund with Bob's no-winner rounds on tile 0.
    while (game::motherlode_value(&board) == 0) {
        round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(0, SUI1), 1_000_000);
    };
    let fund = game::motherlode_value(&board);
    let per = 10_000_000;
    let alice_back = round_as(&mut sc, ALICE, &mut board, &mut treasury, &rs, &mut clk, all_tiles(per), 1);
    assert!(game::motherlode_value(&board) == 0, 1);
    ts::next_tx(&mut sc, BOB);
    let won = ts::take_from_sender<coin::Coin<SUI>>(&sc);
    assert!(coin::value(&won) == fund, 2);
    coin::burn_for_testing(won);
    assert!(alice_back < per * 25, 3); // no jackpot for the winning tile
    let (epoch, total) = game::wealth_tickets(&board);
    assert!(epoch == 1 && game::tickets_of(&board, BOB) == 0, 4);
    // Alice's tickets from the hitting round were claimed after the draw: they count for the next one.
    assert!(game::tickets_of(&board, ALICE) == per * 24 / 20 && total == per * 24 / 20, 5);
    assert!(game::pot_value(&board) == 0, 6);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Withdrawing unrefined GTS costs 10%, shared with the players still holding; the last one out has
/// the fee burned for the reserve.
#[test]
fun test_withdraw_fee_shared() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut mb = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut mb, 100_000_000);
    ts::next_tx(&mut sc, ALICE);
    let mut ma = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut ma, 100_000_000);
    // Both hold 1 GTS unrefined. Bob withdraws: pays 0.1, Alice earns it.
    ts::next_tx(&mut sc, BOB);
    let gb = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc));
    assert!(coin::value(&gb) == GTS1 * 9 / 10, 1);
    let (a_amt, a_bonus) = game::unrefined_of(&board, ALICE);
    assert!(a_amt == GTS1 && a_bonus == GTS1 / 10, 2);
    // Alice withdraws last: pays 0.1 (burned), gets 0.9 + 0.1 bonus.
    ts::next_tx(&mut sc, ALICE);
    let supply_before = gts::total_supply(&treasury);
    let ga = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc));
    assert!(coin::value(&ga) == GTS1, 3);
    assert!(gts::total_supply(&treasury) == supply_before - GTS1 / 10, 4);
    assert!(game::unrefined_total(&board) == 0, 5);
    coin::burn_for_testing(gb); coin::burn_for_testing(ga);
    transfer::public_transfer(mb, BOB); transfer::public_transfer(ma, ALICE);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Settings change at once with the AdminCap.
#[test]
fun test_set_params_instant() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 500, 1_000, 800, 0, 500, 5_000_000, 90_000, 10_000, true);
    let (odds, share, vault, buyback, dev, refine, paused) = game::current_params(&board);
    assert!(odds == 500 && share == 1_000 && vault == 800 && buyback == 0 && dev == 100 && refine == 500 && paused, 1);
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);
    ts::end(sc);
}

/// Each fee has its own cap: reserve 15%, no-winner Wealth Fund 30%, Wealth Fund odds at least 1 in 100.
#[test, expected_failure(abort_code = game::EBadParams)]
fun test_reserve_cap() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 1_501, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_no_winner_share_cap() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 3_001, 400, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_odds_floor() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 99, 1_950, 400, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// The highest settings the caps allow are accepted.
#[test]
fun test_caps_at_limit() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 100, 3_000, 1_500, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_staking(&admin, &mut board, 500, ts::ctx(&mut sc));
    game::set_fund_bps(&admin, &mut board, 1_000);
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);
    ts::end(sc);
}

/// The buyback is fixed at 0: it cannot be turned on.
#[test, expected_failure(abort_code = game::EBuybackOff)]
fun test_buyback_cannot_turn_on() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 400, 1, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// And no SUI can be taken through it.
#[test, expected_failure(abort_code = game::EBuybackOff)]
fun test_take_buyback_off() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let c = game::take_buyback(&admin, &mut board, ts::ctx(&mut sc));
    coin::burn_for_testing(c);
    abort 0
}

#[test, expected_failure(abort_code = game::EPaused)]
fun test_pause_stops_deposits() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 400, 0, 1_000, 10_000_000, 60_000, 5_000, true);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// Renounce: afterwards the AdminCap is gone.
#[test]
fun test_renounce() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 400, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    game::renounce(admin, &board);
    ts::next_tx(&mut sc, OWNER);
    assert!(!ts::has_most_recent_for_sender<AdminCap>(&sc), 1);
    ts::return_shared(board);
    ts::end(sc);
}

/// One miner per address per round.
#[test, expected_failure(abort_code = game::EOneMinerPerRound)]
fun test_one_miner_per_round() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m1 = game::new_miner(ts::ctx(&mut sc));
    let mut m2 = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m1, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m2, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(1, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// Redeem pays a pro-rata share of the reserve and burns the GTS.
#[test]
fun test_redeem() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    let g = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc)); // last out: fee burned
    let vault = gts::vault_value(&treasury);
    let supply = gts::total_supply(&treasury);
    let amt = coin::value(&g);
    let s = gts::redeem(&mut treasury, g, ts::ctx(&mut sc));
    assert!(gts::total_supply(&treasury) == supply - amt, 2);
    assert!(coin::value(&s) == (((vault as u128) * (amt as u128) / (supply as u128)) as u64), 1);
    coin::burn_for_testing(s);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The drawer is paid up to 0.005 SUI out of the round's buyback share.
#[test]
fun test_draw_reward() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(SUI1, ts::ctx(&mut sc)), one_tile(0, SUI1), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 62_000);
    ts::next_tx(&mut sc, ALICE);
    game::settle_for_testing(&mut board, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ALICE);
    let paid = ts::take_from_sender<coin::Coin<SUI>>(&sc);
    assert!(coin::value(&paid) == 5_000_000, 1);
    coin::burn_for_testing(paid);
    ts::next_tx(&mut sc, BOB);
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    assert!(game::pot_value(&board) == 0, 2);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

const CAROL: address = @0xCA501;

/// Staking set up as planned: reserve 6%, buyback 0, stakers 3%.
fun setup_staking(sc: &mut Scenario) {
    setup(sc);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 600, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_staking(&admin, &mut board, 300, ts::ctx(sc));
    ts::return_to_sender(sc, admin);
    ts::return_shared(board);
}

fun stake_as(sc: &mut Scenario, who: address, amt: u64, locked: bool, now: u64) {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, now);
    game::stake(&mut board, coin::mint_for_testing<gtstar::gts::GTS>(amt, ts::ctx(sc)), locked, &clk, ts::ctx(sc));
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
}

/// Carol plays 0.1 SUI on every tile at `now`: 2.4 SUI losing pot, 3% of it (0.072) to stakers.
fun carol_round(sc: &mut Scenario, now: u64) {
    ts::next_tx(sc, CAROL);
    let mut board = ts::take_shared<Board>(sc);
    let mut treasury = ts::take_shared<Treasury>(sc);
    let rs = ts::take_shared<Random>(sc);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, now);
    let mut m = game::new_miner(ts::ctx(sc));
    play_round(sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    transfer::public_transfer(m, CAROL);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
}

fun claim_yield_as(sc: &mut Scenario, who: address): u64 {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let c = game::claim_yield(&mut board, ts::ctx(sc));
    let v = coin::value(&c);
    coin::burn_for_testing(c);
    ts::return_shared(board);
    v
}

/// Flexible (1x) and locked (1.5x) share the stakers' 3% by weight: 40% / 60%.
#[test]
fun test_staking_yield_split() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    stake_as(&mut sc, BOB, GTS1, true, 1);
    carol_round(&mut sc, 10);
    let pot = 72_000_000; // 3% of 2.4 SUI
    assert!(claim_yield_as(&mut sc, ALICE) == pot * 2 / 5, 1);
    assert!(claim_yield_as(&mut sc, BOB) == pot * 3 / 5, 2);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let (amount, weight, paid, waiting) = game::staking_totals(&board);
    assert!(amount == 2 * GTS1 && weight == (25 * GTS1 as u128) && paid == pot && waiting == 0, 3);
    assert!(game::pot_value(&board) == 0, 4);
    ts::return_shared(board);
    ts::end(sc);
}

/// With nobody staked, the stakers' share goes to the reserve; the drawer is paid from the reserve share.
#[test]
fun test_no_stakers_to_reserve() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    carol_round(&mut sc, 10);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let treasury = ts::take_shared<Treasury>(&sc);
    let losing = 2_400_000_000;
    // reserve 6% + stakers 3%, minus 0.005 to the drawer (Carol).
    assert!(gts::vault_value(&treasury) == losing * 9 / 100 - 5_000_000, 1);
    assert!(game::buyback_value(&board) == 0 && game::pot_value(&board) == 0, 2);
    ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A locked stake cannot leave before 7 days.
#[test, expected_failure(abort_code = gtstar::staking::ELocked)]
fun test_lock_holds() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, BOB, GTS1, true, 1);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 6 * 86_400_000);
    let g = game::unstake(&mut board, GTS1, true, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(g);
    abort 0
}

/// After 7 days: poke drops the lock to 1x, and the GTS can leave.
#[test]
fun test_lock_ends() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, BOB, GTS1, true, 1);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    let week = 7 * 86_400_000 + 2;
    ts::next_tx(&mut sc, CAROL);
    let mut board = ts::take_shared<Board>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, week);
    game::poke(&mut board, BOB, &clk);
    let (_, weight, _, _) = game::staking_totals(&board);
    assert!(weight == (20 * GTS1 as u128), 1);
    ts::return_shared(board);
    carol_round(&mut sc, week);
    // Equal weights now: equal yield.
    assert!(claim_yield_as(&mut sc, ALICE) == claim_yield_as(&mut sc, BOB), 2);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let g = game::unstake(&mut board, GTS1, true, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&g) == GTS1, 3);
    coin::burn_for_testing(g);
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
    ts::end(sc);
}

/// Fees can never pass 100% with the stakers' share included.
#[test, expected_failure(abort_code = game::EBadParams)]
fun test_staking_bounds() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    ts::next_tx(&mut sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_staking(&admin, &mut board, 7_500, ts::ctx(&mut sc));
    abort 0
}

/// Wealth Fund 2% of every round. A round with a winner (all tiles covered) adds 2% of its losing pot
/// to the fund, and the player's tickets equal the 7% fee paid (creator 1 + reserve 4 + fund 2).
#[test]
fun test_fund_share_every_round() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    game::set_params(&admin, &mut board, 100, 1_950, 400, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_fund_bps(&admin, &mut board, 200);
    assert!(game::wealth_fund_bps(&board) == 200, 1);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let per = 100_000_000;
    let vault_before = gts::vault_value(&treasury);
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(per), 1_000_000);
    let losing = per * 24;
    assert!(game::motherlode_value(&board) == losing * 2 / 100, 2);
    assert!(game::buyback_value(&board) == 0, 3);
    assert!(game::dev_fees_value(&board) == losing / 100, 4);
    assert!(game::tickets_of(&board, BOB) == losing * 7 / 100, 5);
    assert!(gts::vault_value(&treasury) > vault_before, 6);
    assert!(game::pot_value(&board) == 0, 7);
    ts::return_to_address(OWNER, admin);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A round with no winner adds both shares: 2% every round plus 19.5% of a no-winner round.
#[test]
fun test_fund_share_no_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    game::set_params(&admin, &mut board, 100, 1_950, 400, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_fund_bps(&admin, &mut board, 200);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut done = false;
    while (!done) {
        let before = game::motherlode_value(&board);
        round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(0, SUI1), 1_000_000);
        let round = game::current_round(&board) - 1;
        if (game::winning_square_for_testing(&board, round) != 0) {
            assert!(game::motherlode_value(&board) - before == SUI1 * 2 / 100 + SUI1 * 1_950 / 10_000, 1);
            done = true;
        };
    };
    assert!(game::pot_value(&board) == 0, 2);
    ts::return_to_address(OWNER, admin);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_fund_bps_bounds() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    // The Wealth Fund's every-round share is capped at 10%.
    game::set_fund_bps(&admin, &mut board, 1_001);
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);
    ts::end(sc);
}

/// Reserve over all GTS in circulation (claimed rounds only here), scaled by 1e18.
fun floor_of(treasury: &Treasury): u128 {
    (gts::vault_value(treasury) as u128) * 1_000_000_000_000_000_000 / (gts::total_supply(treasury) as u128)
}

/// Mining never lowers the floor: after the first round each round mints at most what the SUI it adds
/// to the reserve buys at the floor, through winning and no-winner rounds of different sizes.
#[test]
fun test_floor_never_drops() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(40_000_000), 1_000_000);
    let mut floor = floor_of(&treasury);
    let mut i = 0;
    while (i < 12) {
        let amounts = if (i % 3 == 0) { one_tile(i % 25, SUI1) } else if (i % 3 == 1) { all_tiles(10_000_000) } else { all_tiles(80_000_000) };
        let who = if (i % 2 == 0) { ALICE } else { BOB };
        let (_, _, _, _, _, before) = game::emission(&board);
        round_as(&mut sc, who, &mut board, &mut treasury, &rs, &mut clk, amounts, 1_000_000);
        let (_, _, _, _, _, after) = game::emission(&board);
        assert!(after - before <= GTS1, 1); // never above the schedule
        let f = floor_of(&treasury);
        assert!(f >= floor, 2);
        floor = f;
        i = i + 1;
    };
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// GTS goes by SUI lost: Alice on every tile (0.1 each) and Bob with 1 SUI on tile 0 share the round
/// reward by what each lost; a winning stake mines nothing.
#[test]
fun test_gts_by_loss() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    ts::next_tx(&mut sc, ALICE);
    let mut ma = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut ma, coin::mint_for_testing<SUI>(25 * 100_000_000, ts::ctx(&mut sc)), all_tiles(100_000_000), &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, BOB);
    let mut mb = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut mb, coin::mint_for_testing<SUI>(SUI1, ts::ctx(&mut sc)), one_tile(0, SUI1), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 62_000);
    game::settle_for_testing(&mut board, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
    let w = game::winning_square_for_testing(&board, 1);
    let alice_lost = 24 * 100_000_000;
    let bob_lost = if (w == 0) { 0 } else { SUI1 };
    let (g, s) = game::claim(&mut board, &mut mb, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    ts::next_tx(&mut sc, ALICE);
    let (g, s) = game::claim(&mut board, &mut ma, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    let lost = alice_lost + bob_lost;
    let (a, _) = game::unrefined_of(&board, ALICE);
    let (b, _) = game::unrefined_of(&board, BOB);
    assert!(a == (((GTS1 as u128) * (alice_lost as u128) / (lost as u128)) as u64), 1);
    assert!(b == (((GTS1 as u128) * (bob_lost as u128) / (lost as u128)) as u64), 2);
    transfer::public_transfer(ma, ALICE); transfer::public_transfer(mb, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A round where nobody lost (everything on the winning tile) mints no GTS and pays the stake back.
#[test]
fun test_nobody_lost_no_gts() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut done = false;
    let mut tries = 0;
    while (!done && tries < 200) {
        let (_, _, _, _, _, before) = game::emission(&board);
        let back = round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(7, SUI1), 1_000_000);
        let round = game::current_round(&board) - 1;
        if (game::winning_square_for_testing(&board, round) == 7) {
            let (_, _, _, _, _, after) = game::emission(&board);
            assert!(after == before && back == SUI1, 1);
            done = true;
        };
        tries = tries + 1;
    };
    assert!(done, 2);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}
