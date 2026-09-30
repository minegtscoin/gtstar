#[test_only]
module gtstar::game_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::coin;
use sui::sui::SUI;
use sui::clock::{Self, Clock};
use sui::random::{Self, Random};
use gtstar::gts::{Self, Treasury, GTS};
use supply_lock::capped::{Self, CappedTreasury};
use gtstar::game::{Self, Board, AdminCap, Miner};

const OWNER: address = @0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e;
const BOB: address = @0xB0B;
const ALICE: address = @0xA11CE;
const GTS1: u64 = 1_000_000_000;
const SUI1: u64 = 1_000_000_000;

/// Setup with the supply locked, as on mainnet from v15.
fun setup(sc: &mut Scenario) {
    setup_unlocked(sc);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    let treasury = ts::take_shared<Treasury>(sc);
    game::lock_supply(&admin, &mut board, treasury, ts::ctx(sc));
    ts::return_to_sender(sc, admin);
    ts::return_shared(board);
    ts::next_tx(sc, OWNER);
}

/// Setup before the supply lock (the old Treasury still exists).
fun setup_unlocked(sc: &mut Scenario) {
    random::create_for_testing(ts::ctx(sc));
    ts::next_tx(sc, @0x0);
    let mut rs = ts::take_shared<Random>(sc);
    random::update_randomness_state_for_testing(&mut rs, 0, x"0A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20212223242526272829", ts::ctx(sc));
    ts::return_shared(rs);
    ts::next_tx(sc, OWNER);
    gts::init_for_testing(ts::ctx(sc));
    game::init_for_testing(ts::ctx(sc));
    // Wealth Fund 3% of every losing pot: 8% fees in all with creator 1%, buyback 1%, liquidity 3%.
    ts::next_tx(sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    game::set_fund_bps(&admin, &mut board, 300);
    ts::return_to_sender(sc, admin);
    ts::return_shared(board);
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
fun play_round(sc: &mut Scenario, board: &mut Board, treasury: &mut CappedTreasury<GTS>, rs: &Random, clk: &mut Clock, m: &mut Miner, per: u64): (u64, u64) {
    let t = clock::timestamp_ms(clk) + 1_000;
    clock::set_for_testing(clk, t);
    game::deploy(board, m, coin::mint_for_testing<SUI>(per * 25, ts::ctx(sc)), all_tiles(per), clk, ts::ctx(sc));
    clock::set_for_testing(clk, t + 61_000);
    game::settle_for_testing(board, treasury, rs, clk, ts::ctx(sc));
    let (g, s) = game::claim_v2(board, m, treasury, ts::ctx(sc));
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

/// A round with a winner: creator 1%, buyback 2%, liquidity 1%, Wealth Fund 4% (0.005 of it to the
/// drawer), winners 92%. The winner keeps the whole share, even spread over every tile (no fair split from v10).
/// 1 GTS mined into the unrefined balance. No reserve. Every mist is accounted for.
#[test]
fun test_round_with_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));

    let per = 100_000_000;
    let (g, s) = play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, per);
    let losing = per * 24;
    let share = losing * 92 / 100;
    assert!(s == per + share, 1);
    assert!(game::dev_fees_value(&board) == losing / 100, 2);
    assert!(game::buyback_value(&board) == losing / 100, 3);
    assert!(game::liquidity_value(&board) == losing * 3 / 100, 10);
    // Fund share minus 0.005 SUI to the drawer; nothing forfeited.
    assert!(game::motherlode_value(&board) == losing * 3 / 100 - 5_000_000, 4);
    assert!(game::pot_value(&board) == 0, 5);
    assert!(g == 0 && game::unrefined_total(&board) == GTS1, 6); // 2.5 SUI >= 1 SUI: full 1 GTS
    assert!(capped::minted(&treasury) == GTS1, 7);
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
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 10_000_000);
    assert!(game::unrefined_total(&board) == GTS1 / 4, 1);
    let (_, _, _, _, _, committed) = game::emission(&board);
    assert!(committed == GTS1 / 4 && capped::minted(&treasury) == GTS1 / 4, 2);
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
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
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
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
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

/// No one on the winning tile: creator 1%, the Wealth Fund's 4% (all of it to the drawer here:
/// 0.004 < 0.005, and 0.001 more from the liquidity's 1%), the buyback's full 2%, and the whole rest to the
/// Wealth Fund. Nothing to a reserve.
#[test]
fun test_round_without_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
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
        let fund_before = game::motherlode_value(&board);
        let buy_before = game::buyback_value(&board);
        let liq_before = game::liquidity_value(&board);
        let dev_before = game::dev_fees_value(&board);
        game::settle_for_testing(&mut board, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
        let round = game::current_round(&board) - 1;
        if (game::winning_square_for_testing(&board, round) != 0) {
            assert!(game::dev_fees_value(&board) - dev_before == amt / 100, 1);
            assert!(game::buyback_value(&board) - buy_before == amt / 100, 2);
            assert!(game::liquidity_value(&board) - liq_before == amt * 3 / 100 - 2_000_000, 7);
            assert!(game::motherlode_value(&board) - fund_before == amt * 92 / 100, 3);
            done = true;
        };
        let (g, s) = game::claim_v2(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
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
fun round_as(sc: &mut Scenario, who: address, board: &mut Board, treasury: &mut CappedTreasury<GTS>, rs: &Random, clk: &mut Clock, amounts: vector<u64>, odds: u64): u64 {
    let (sv, _) = round_as_w(sc, who, board, treasury, rs, clk, amounts, odds);
    sv
}

/// round_as that also returns the winning tile (read before the claim: the last claim removes the RoundInfo).
fun round_as_w(sc: &mut Scenario, who: address, board: &mut Board, treasury: &mut CappedTreasury<GTS>, rs: &Random, clk: &mut Clock, amounts: vector<u64>, odds: u64): (u64, u64) {
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
    let w = game::winning_square_for_testing(board, game::current_round(board) - 1);
    ts::next_tx(sc, who);
    let (g, s) = game::claim_v2(board, &mut m, treasury, ts::ctx(sc));
    let sv = coin::value(&s);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, who);
    (sv, w)
}

/// Tickets are the fee paid on the SUI lost: 8% (creator 1 + buyback 2 + liquidity 1 + Wealth Fund 4)
/// of a lost deposit,
/// nothing for a round won. Odds of a million keep the fund from paying during the test.
#[test]
fun test_tickets_are_fee_paid() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut expected = 0u64;
    let mut n = 0u64;
    while (n < 8) {
        let (_, w) = round_as_w(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(0, SUI1), 1_000_000);
        if (w != 0) { expected = expected + SUI1 * 8 / 100 };
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
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let per = 400_000_000; // 10 SUI in all
    let back = round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(per), 1_000_000);
    let tickets = game::tickets_of(&board, BOB);
    assert!(tickets == per * 24 * 8 / 100, 1);
    assert!(tickets <= per * 25 - back, 2);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// 25 wallets of one owner, one tile each (the only way to cover the board with the 5-tile limit; a limit
/// works per wallet): the winner takes the others' losses, so together they only lose
/// the fees. Their tickets equal exactly those fees: a ticket
/// always costs one mist of real SUI, a second wallet makes it no cheaper. GTS goes by SUI deployed:
/// all 25 wallets share the round reward equally, the same total one wallet on every tile would mine.
#[test]
fun test_sybil_wallets_pay_full_price() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
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
    let mut back = 0u64;
    let mut tickets = 0u64;
    let mut mined = 0u64;
    while (!vector::is_empty(&miners)) {
        let mut m = vector::pop_back(&mut miners);
        let i = vector::length(&miners);
        let who = sui::address::from_u256((0x5000 + i) as u256);
        ts::next_tx(&mut sc, who);
        let (g, s) = game::claim_v2(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
        back = back + coin::value(&s);
        coin::burn_for_testing(g); coin::burn_for_testing(s);
        tickets = tickets + game::tickets_of(&board, who);
        let (u, _) = game::unrefined_of(&board, who);
        assert!(u == GTS1 / 25, 3);
        mined = mined + u;
        transfer::public_transfer(m, who);
    };
    vector::destroy_empty(miners);
    let lost = amt * 25 - back;
    assert!(lost == amt * 24 * 8 / 100, 1); // together they lost only the 8% fee on 24 tiles
    assert!(tickets == lost, 2);
    assert!(mined == GTS1 / 25 * 25, 4);
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
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
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

/// Ticket ranges in order of claim: Bob [0, 192M), Alice [192M, 576M), Bob [576M, 768M).
#[test]
fun test_ticket_ranges() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(100_000_000), 1_000_000);
    round_as(&mut sc, ALICE, &mut board, &mut treasury, &rs, &mut clk, all_tiles(200_000_000), 1_000_000);
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(100_000_000), 1_000_000);
    assert!(game::tickets_of(&board, BOB) == 384_000_000 && game::tickets_of(&board, ALICE) == 384_000_000, 1);
    assert!(game::ticket_holder_for_testing(&board, 0) == BOB, 2);
    assert!(game::ticket_holder_for_testing(&board, 191_999_999) == BOB, 3);
    assert!(game::ticket_holder_for_testing(&board, 192_000_000) == ALICE, 4);
    assert!(game::ticket_holder_for_testing(&board, 575_999_999) == ALICE, 5);
    assert!(game::ticket_holder_for_testing(&board, 576_000_000) == BOB, 6);
    assert!(game::ticket_holder_for_testing(&board, 767_999_999) == BOB, 7);
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
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    // Fill the fund with Bob's no-winner rounds on tile 0.
    while (game::motherlode_value(&board) == 0) {
        round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(0, SUI1), 1_000_000);
    };
    let fund = game::motherlode_value(&board);
    let per = 10_000_000;
    let alice_back = round_as(&mut sc, ALICE, &mut board, &mut treasury, &rs, &mut clk, all_tiles(per), 1);
    ts::next_tx(&mut sc, BOB);
    let won = ts::take_from_sender<coin::Coin<SUI>>(&sc);
    // The whole fund, with this round's 3% share in it (minus 0.005 to the drawer). What Alice's spread
    // deposit forfeits at claim starts the next fund.
    assert!(coin::value(&won) == fund + per * 24 * 3 / 100 - 5_000_000, 2);
    assert!(game::motherlode_value(&board) < fund, 1);
    coin::burn_for_testing(won);
    assert!(alice_back < per * 25, 3); // no jackpot for the winning tile
    let (epoch, total) = game::wealth_tickets(&board);
    assert!(epoch == 1 && game::tickets_of(&board, BOB) == 0, 4);
    // Alice's tickets from the hitting round were claimed after the draw: they count for the next one.
    assert!(game::tickets_of(&board, ALICE) == per * 24 * 8 / 100 && total == per * 24 * 8 / 100, 5);
    assert!(game::pot_value(&board) == 0, 6);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

const DAY: u64 = 86_400_000;

/// Right after mining the withdraw fee is 10% and burned (supply falls, nobody else gets it); it falls
/// linearly to 5% at 3.5 days and 0 at 7 days from the player's own clock.
#[test]
fun test_withdraw_fee_decays_and_burns() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut mb = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut mb, 100_000_000);
    ts::next_tx(&mut sc, ALICE);
    let mut ma = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut ma, 100_000_000);
    let (b_start, window, b_fee) = game::withdraw_clock(&board, BOB, &clk);
    assert!(b_start > 0 && window == 7 * DAY && b_fee > 990 && b_fee <= 1_000, 1);
    // Bob withdraws at once: ~10% burned, Alice gets nothing from it.
    ts::next_tx(&mut sc, BOB);
    let supply0 = capped::total_supply(&treasury);
    let fee_now = { let (_, _, f) = game::withdraw_clock(&board, BOB, &clk); f };
    let gb = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    let burned = GTS1 * fee_now / 10_000;
    assert!(coin::value(&gb) == GTS1 - burned, 2);
    assert!(capped::total_supply(&treasury) == supply0 - burned + 0, 3);
    let (a_amt, a_bonus) = game::unrefined_of(&board, ALICE);
    assert!(a_amt == GTS1 && a_bonus == 0, 4);
    // Alice at 3.5 days after her clock: 5%.
    let (a_start, _, _) = game::withdraw_clock(&board, ALICE, &clk);
    clock::set_for_testing(&mut clk, a_start + 7 * DAY / 2);
    let (_, _, a_fee) = game::withdraw_clock(&board, ALICE, &clk);
    assert!(a_fee == 500, 5);
    // And 0 at 7 days.
    clock::set_for_testing(&mut clk, a_start + 7 * DAY);
    let (_, _, a_fee) = game::withdraw_clock(&board, ALICE, &clk);
    assert!(a_fee == 0, 6);
    ts::next_tx(&mut sc, ALICE);
    let supply1 = capped::total_supply(&treasury);
    let ga = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&ga) == GTS1, 7);
    assert!(capped::total_supply(&treasury) == supply1, 8);
    assert!(game::unrefined_total(&board) == 0, 9);
    coin::burn_for_testing(gb); coin::burn_for_testing(ga);
    transfer::public_transfer(mb, BOB); transfer::public_transfer(ma, ALICE);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The clock restarts on a withdrawal, not on new mining: mining more during the 7 days keeps the
/// countdown, and the next withdrawal after 7 days is free for everything mined meanwhile.
#[test]
fun test_withdraw_clock_restarts_on_withdraw_only() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut mb = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut mb, 100_000_000);
    let (s0, _, _) = game::withdraw_clock(&board, BOB, &clk);
    clock::set_for_testing(&mut clk, s0 + 7 * DAY);
    let g1 = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&g1) == GTS1, 1);
    let t1 = s0 + 7 * DAY;
    let (s1, _, f1) = game::withdraw_clock(&board, BOB, &clk);
    assert!(s1 == t1 && f1 == 1_000, 2);
    // Mine again 3 days later: the clock stays at the withdrawal.
    clock::set_for_testing(&mut clk, t1 + 3 * DAY);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut mb, 100_000_000);
    let (s2, _, _) = game::withdraw_clock(&board, BOB, &clk);
    assert!(s2 == t1, 3);
    let (mined, _) = game::unrefined_of(&board, BOB);
    clock::set_for_testing(&mut clk, t1 + 7 * DAY);
    let g2 = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&g2) == mined && mined > 0, 4);
    coin::burn_for_testing(g1); coin::burn_for_testing(g2);
    transfer::public_transfer(mb, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The old withdraw (no clock) is closed.
#[test, expected_failure(abort_code = game::EUseWithdrawV6)]
fun test_old_withdraw_closed() {
    let mut sc = ts::begin(@0x0);
    setup_unlocked(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let g = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g);
    abort 0
}

/// Settings change at once with the AdminCap.
#[test]
fun test_set_params_instant() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 500, 1_000, 0, 100, 500, 5_000_000, 90_000, 10_000, true);
    let (odds, share, vault, buyback, dev, refine, paused) = game::current_params(&board);
    assert!(odds == 500 && share == 1_000 && vault == 0 && buyback == 100 && dev == 100 && refine == 500 && paused, 1);
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);
    ts::end(sc);
}

/// No reserve: its share must stay 0.
#[test, expected_failure(abort_code = game::ENoReserve)]
fun test_no_reserve_share() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 1, 100, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// Each other fee has its own cap: no-winner Wealth Fund 30%, Wealth Fund odds at least 1 in 100.

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_no_winner_share_cap() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 3_001, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_odds_floor() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 99, 1_950, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// The highest settings the caps allow are accepted.
#[test]
fun test_caps_at_limit() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 100, 3_000, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_staking(&admin, &mut board, 500, ts::ctx(&mut sc));
    game::set_fund_bps(&admin, &mut board, 1_000);
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);
    ts::end(sc);
}

/// The buyback is fixed at 2%: no other value is accepted.
#[test, expected_failure(abort_code = game::EBadParams)]
fun test_buyback_fixed() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 301, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

const KEEPER: address = @0x22390096d8def0638c92f86da60683e37d1a7f00b4b22fcb359952db300c3549;

/// Buyback 1%: every losing pot saves 1%; the keeper spends it and the GTS bought stays in the game.
#[test]
fun test_buyback_saved_and_kept() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
    ts::return_to_sender(&sc, admin);
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, SUI1);
    // 24 SUI lost: 1% = 0.24 SUI saved, the drawer is paid from the Wealth Fund share.
    assert!(game::buyback_value(&board) == 240_000_000, 1);

    ts::next_tx(&mut sc, KEEPER);
    let (mut sui, receipt) = game::buyback_take(&mut board, ts::ctx(&mut sc));
    assert!(coin::value(&sui) == 240_000_000 && game::buyback_value(&board) == 0, 2);
    // Spend 0.16 SUI on "the market", return the rest.
    coin::burn_for_testing(coin::split(&mut sui, 160_000_000, ts::ctx(&mut sc)));
    let bought = coin::mint_for_testing<gts::GTS>(1_000, ts::ctx(&mut sc));
    game::buyback_keep(&mut board, receipt, bought, sui);
    assert!(game::buyback_value(&board) == 80_000_000, 3);
    assert!(game::bought_value(&board) == 1_000, 4);

    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Only the keeper may take the buyback SUI.
#[test, expected_failure(abort_code = game::ENotBuyer)]
fun test_buyback_keeper_only() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let (c, _r) = game::buyback_take(&mut board, ts::ctx(&mut sc));
    coin::burn_for_testing(c);
    abort 0
}

/// The receipt cannot be closed without GTS.
#[test, expected_failure(abort_code = game::ENothingBought)]
fun test_buyback_needs_gts() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
    ts::return_to_sender(&sc, admin);
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, SUI1);
    ts::next_tx(&mut sc, KEEPER);
    let (sui, receipt) = game::buyback_take(&mut board, ts::ctx(&mut sc));
    game::buyback_keep(&mut board, receipt, coin::zero<gts::GTS>(ts::ctx(&mut sc)), sui);
    abort 0
}

/// Stand-in for a Cetus position in tests.
public struct FakePosition has key, store { id: UID }

/// Liquidity 1%: every losing pot saves 1%; the keeper takes it, and the position is locked in the game
/// with the SUI and GTS not used kept there too.
#[test]
fun test_liquidity_saved_and_locked() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, SUI1);
    // 24 SUI lost: 3% = 0.72 SUI saved.
    assert!(game::liquidity_value(&board) == 720_000_000 && game::liquidity_bps() == 300, 1);

    ts::next_tx(&mut sc, KEEPER);
    let (mut sui, receipt) = game::liquidity_take(&mut board, ts::ctx(&mut sc));
    assert!(coin::value(&sui) == 720_000_000 && game::liquidity_value(&board) == 0, 2);
    // 0.71 SUI into "the pool", 0.01 SUI and 5 GTS mist not used.
    coin::burn_for_testing(coin::split(&mut sui, 710_000_000, ts::ctx(&mut sc)));
    let pos = FakePosition { id: object::new(ts::ctx(&mut sc)) };
    let pid = object::id(&pos);
    game::liquidity_lock_for_testing(&mut board, receipt, pos, sui, coin::mint_for_testing<gts::GTS>(5, ts::ctx(&mut sc)));
    assert!(game::liquidity_value(&board) == 10_000_000, 3);
    assert!(game::bought_value(&board) == 5, 4);
    assert!(game::lp_positions(&board) == 1 && game::lp_position_id(&board, 0) == pid, 5);

    // A second add locks a second position next to the first.
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, SUI1);
    ts::next_tx(&mut sc, KEEPER);
    let (mut sui, receipt) = game::liquidity_take(&mut board, ts::ctx(&mut sc));
    assert!(coin::value(&sui) == 730_000_000, 6);
    coin::burn_for_testing(coin::split(&mut sui, 730_000_000, ts::ctx(&mut sc)));
    let pos = FakePosition { id: object::new(ts::ctx(&mut sc)) };
    game::liquidity_lock_for_testing(&mut board, receipt, pos, sui, coin::zero<gts::GTS>(ts::ctx(&mut sc)));
    assert!(game::lp_positions(&board) == 2 && game::liquidity_value(&board) == 0, 7);

    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Only the keeper may take the liquidity SUI.
#[test, expected_failure(abort_code = game::ENotBuyer)]
fun test_liquidity_keeper_only() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let (c, _r) = game::liquidity_take(&mut board, ts::ctx(&mut sc));
    coin::burn_for_testing(c);
    abort 0
}

/// Only a Cetus position closes the receipt: any other object is refused.
#[test, expected_failure(abort_code = game::ENotPosition)]
fun test_liquidity_needs_cetus_position() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, SUI1);
    ts::next_tx(&mut sc, KEEPER);
    let (mut sui, receipt) = game::liquidity_take(&mut board, ts::ctx(&mut sc));
    coin::burn_for_testing(coin::split(&mut sui, 1_000, ts::ctx(&mut sc)));
    let pos = FakePosition { id: object::new(ts::ctx(&mut sc)) };
    game::liquidity_lock(&mut board, receipt, pos, sui, coin::zero<gts::GTS>(ts::ctx(&mut sc)));
    abort 0
}

/// The keeper cannot hand all the SUI back: some must go into the pool.
#[test, expected_failure(abort_code = game::EAmountMismatch)]
fun test_liquidity_must_be_used() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, SUI1);
    ts::next_tx(&mut sc, KEEPER);
    let (sui, receipt) = game::liquidity_take(&mut board, ts::ctx(&mut sc));
    let pos = FakePosition { id: object::new(ts::ctx(&mut sc)) };
    game::liquidity_lock_for_testing(&mut board, receipt, pos, sui, coin::zero<gts::GTS>(ts::ctx(&mut sc)));
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
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 100, 1_000, 10_000_000, 60_000, 5_000, true);
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
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
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

/// GTS cannot be redeemed for SUI.
#[test, expected_failure(abort_code = gtstar::gts::ENoReserve)]
fun test_redeem_closed() {
    let mut sc = ts::begin(@0x0);
    setup_unlocked(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let g = coin::mint_for_testing<GTS>(GTS1, ts::ctx(&mut sc));
    let s = gts::redeem(&mut treasury, g, ts::ctx(&mut sc));
    coin::burn_for_testing(s);
    abort 0
}

/// The SUI left in the old reserve moves to the Wealth Fund once; the reserve is then empty.
#[test]
fun test_reserve_to_fund() {
    let mut sc = ts::begin(@0x0);
    setup_unlocked(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    gts::vault_fill_for_testing(&mut treasury, SUI1, ts::ctx(&mut sc));
    let before = game::motherlode_value(&board);
    game::reserve_to_fund(&admin, &mut board, &mut treasury);
    assert!(gts::vault_value(&treasury) == 0, 1);
    assert!(game::motherlode_value(&board) == before + SUI1, 2);
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Anyone may burn their own GTS: supply falls.
#[test]
fun test_burn_own_gts() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    let g = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    let supply = capped::total_supply(&treasury);
    let amt = coin::value(&g);
    capped::burn(&mut treasury, g);
    assert!(capped::total_supply(&treasury) == supply - amt, 1);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The drawer is paid up to 0.005 SUI out of the round's Wealth Fund share.
#[test]
fun test_draw_reward() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
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
    let (g, s) = game::claim_v2(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    assert!(game::pot_value(&board) == 0, 2);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A small round: the drawer's reward takes the whole Wealth Fund share, yet the buyback still gets its full 2%.
#[test]
fun test_draw_reward_keeps_buyback() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let amounts = vector[10_000_000, 10_000_000, 10_000_000, 10_000_000, 10_000_000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(50_000_000, ts::ctx(&mut sc)), amounts, &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 62_000);
    ts::next_tx(&mut sc, ALICE);
    game::settle_for_testing(&mut board, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
    // Losing pot is 0.05 SUI, or 0.04 when one of the five tiles won: 1% of it, untouched.
    let bb = game::buyback_value(&board);
    assert!(bb == 500_000 || bb == 400_000, 1);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

const CAROL: address = @0xCA501;

/// Staking set up: Wealth Fund 4% (from `setup`), buyback 2%, liquidity 1%, stakers 3%.
fun setup_staking(sc: &mut Scenario) {
    setup(sc);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
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
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(sc);
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

/// With nobody staked, the stakers' share goes to the Wealth Fund; the drawer is paid from the fund share.
#[test]
fun test_no_stakers_to_fund() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    carol_round(&mut sc, 10);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let losing = 2_400_000_000;
    // Fund 3% + stakers 3%, minus 0.005 to the drawer (Carol); nothing forfeited.
    assert!(game::motherlode_value(&board) == losing * 6 / 100 - 5_000_000, 1);
    assert!(game::buyback_value(&board) == losing / 100 && game::pot_value(&board) == 0, 2);
    assert!(game::liquidity_value(&board) == losing * 3 / 100, 4);
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
/// to the fund (minus 0.005 to the drawer), nothing forfeited, and the player's tickets equal the 7% fee
/// paid (creator 1 + buyback 1 + liquidity 3 + fund 2).
#[test]
fun test_fund_share_every_round() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    game::set_params(&admin, &mut board, 100, 1_950, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_fund_bps(&admin, &mut board, 200);
    assert!(game::wealth_fund_bps(&board) == 200, 1);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let per = 100_000_000;
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(per), 1_000_000);
    let losing = per * 24;
    assert!(game::motherlode_value(&board) == losing * 2 / 100 - 5_000_000, 2);
    assert!(game::buyback_value(&board) == losing / 100 && game::liquidity_value(&board) == losing * 3 / 100, 3);
    assert!(game::dev_fees_value(&board) == losing / 100, 4);
    assert!(game::tickets_of(&board, BOB) == losing * 7 / 100, 5);
    assert!(game::pot_value(&board) == 0, 7);
    ts::return_to_address(OWNER, admin);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A round with no winner: after creator 1%, buyback 1% and liquidity 3%, the fund's 2% (minus 0.005 to
/// the drawer) and the whole rest go to the fund.
#[test]
fun test_fund_share_no_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    game::set_params(&admin, &mut board, 100, 1_950, 0, 100, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_fund_bps(&admin, &mut board, 200);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut done = false;
    while (!done) {
        let before = game::motherlode_value(&board);
        let (_, w) = round_as_w(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(0, SUI1), 1_000_000);
        if (w != 0) {
            assert!(game::motherlode_value(&board) - before == SUI1 * 95 / 100 - 5_000_000, 1);
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

/// GTS goes by SUI deployed, win or lose: Alice on every tile (0.1 each) and Bob with 1 SUI on tile 0
/// share the round reward by what each deployed.
#[test]
fun test_gts_by_deposit() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
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
    let alice_in = 25 * 100_000_000;
    let bob_in = SUI1;
    let (g, s) = game::claim_v2(&mut board, &mut mb, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    ts::next_tx(&mut sc, ALICE);
    let (g, s) = game::claim_v2(&mut board, &mut ma, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    let total = alice_in + bob_in;
    let (a, _) = game::unrefined_of(&board, ALICE);
    let (b, _) = game::unrefined_of(&board, BOB);
    assert!(a == (((GTS1 as u128) * (alice_in as u128) / (total as u128)) as u64), 1);
    assert!(b == (((GTS1 as u128) * (bob_in as u128) / (total as u128)) as u64), 2);
    transfer::public_transfer(ma, ALICE); transfer::public_transfer(mb, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A round where nobody lost (everything on the winning tile) still mines GTS and pays the stake back.
#[test]
fun test_nobody_lost_still_mines() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut done = false;
    let mut tries = 0;
    while (!done && tries < 200) {
        let (_, _, _, _, _, before) = game::emission(&board);
        let (back, w) = round_as_w(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(7, SUI1), 1_000_000);
        if (w == 7) {
            let (_, _, _, _, _, after) = game::emission(&board);
            assert!(after - before == GTS1 && back == SUI1, 1);
            done = true;
        };
        tries = tries + 1;
    };
    assert!(done, 2);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The rule players see: alone in a round, 0.25 SUI deployed (0.01 on every tile) mines exactly 0.25 GTS.
#[test]
fun test_sui_in_equals_gts_mined() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(40_000_000), 1_000_000);
    round_as(&mut sc, ALICE, &mut board, &mut treasury, &rs, &mut clk, all_tiles(10_000_000), 1_000_000);
    let (a, _) = game::unrefined_of(&board, ALICE);
    assert!(a == 250_000_000, 1);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

fun set_tiles(sc: &mut Scenario, n: u64) {
    ts::next_tx(sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    game::set_max_tiles(&admin, &mut board, n);
    assert!(game::max_tiles_per_player(&board) == n, 100);
    ts::return_to_sender(sc, admin);
    ts::return_shared(board);
}

fun five_tiles(per: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0;
    while (k < 25) { vector::push_back(&mut v, if (k < 5) { per } else { 0 }); k = k + 1; };
    v
}

/// With the limit at 5, five tiles are fine and a sixth in a later deposit of the same round aborts.
#[test, expected_failure(abort_code = game::ETooManyTiles)]
fun test_max_tiles_across_deposits() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    set_tiles(&mut sc, 5);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let per = 10_000_000;
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(per * 5, ts::ctx(&mut sc)), five_tiles(per), &clk, ts::ctx(&mut sc));
    // More on a tile already held is fine.
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(per, ts::ctx(&mut sc)), one_tile(0, per), &clk, ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(per, ts::ctx(&mut sc)), one_tile(5, per), &clk, ts::ctx(&mut sc));
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
    ts::end(sc);
}

/// Six tiles in one deposit abort.
#[test, expected_failure(abort_code = game::ETooManyTiles)]
fun test_max_tiles_one_deposit() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    set_tiles(&mut sc, 5);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let per = 10_000_000;
    let mut v = five_tiles(per);
    *vector::borrow_mut(&mut v, 24) = per;
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(per * 6, ts::ctx(&mut sc)), v, &clk, ts::ctx(&mut sc));
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
    ts::end(sc);
}

/// The limit is between 1 and 25.
#[test, expected_failure(abort_code = game::EBadParams)]
fun test_max_tiles_bounds() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    set_tiles(&mut sc, 26);
    ts::end(sc);
}

/// Five tiles, one wins: the winner gets their stake back plus the whole winners' share of the losing
/// pot, nothing forfeited to the Wealth Fund.
#[test]
fun test_five_tiles_full_win() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    set_tiles(&mut sc, 5);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let per = 100_000_000;
    // Alice covers the other 20 tiles in 4 wallets of 5, Bob the first 5: someone always wins.
    let mut bob = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut bob, coin::mint_for_testing<SUI>(per * 5, ts::ctx(&mut sc)), five_tiles(per), &clk, ts::ctx(&mut sc));
    let mut others = vector[];
    let mut w = 1;
    while (w < 5) {
        let who = sui::address::from_u256((0x7000 + w) as u256);
        ts::next_tx(&mut sc, who);
        let mut m = game::new_miner(ts::ctx(&mut sc));
        let mut v = vector[];
        let mut k = 0;
        while (k < 25) { vector::push_back(&mut v, if (k >= w * 5 && k < w * 5 + 5) { per } else { 0 }); k = k + 1; };
        game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(per * 5, ts::ctx(&mut sc)), v, &clk, ts::ctx(&mut sc));
        vector::push_back(&mut others, m);
        w = w + 1;
    };
    clock::set_for_testing(&mut clk, 62_000);
    ts::next_tx(&mut sc, OWNER);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &rs, &clk, 1_000_000, ts::ctx(&mut sc));
    let fund_before = game::motherlode_value(&board);
    let losing = per * 24;
    let share = losing * 92 / 100;
    ts::next_tx(&mut sc, BOB);
    let (g, s) = game::claim_v2(&mut board, &mut bob, &mut treasury, ts::ctx(&mut sc));
    let mut paid = coin::value(&s);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(bob, BOB);
    w = 4;
    while (!vector::is_empty(&others)) {
        let mut m = vector::pop_back(&mut others);
        let who = sui::address::from_u256((0x7000 + w) as u256);
        ts::next_tx(&mut sc, who);
        let (g, s) = game::claim_v2(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
        paid = paid + coin::value(&s);
        coin::burn_for_testing(g); coin::burn_for_testing(s);
        transfer::public_transfer(m, who);
        w = w - 1;
    };
    vector::destroy_empty(others);
    // Exactly one wallet won: its tile's stake back plus the whole share.
    assert!(paid == per + share, 1);
    assert!(game::motherlode_value(&board) == fund_before, 2);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The keeper's buyback: takes the saved SUI, hands back `gts` bought GTS, spends it all.
fun buyback_as_keeper(sc: &mut Scenario, gts: u64) {
    ts::next_tx(sc, KEEPER);
    let mut board = ts::take_shared<Board>(sc);
    let (sui, receipt) = game::buyback_take(&mut board, ts::ctx(sc));
    coin::burn_for_testing(sui);
    game::buyback_keep(&mut board, receipt, coin::mint_for_testing<gts::GTS>(gts, ts::ctx(sc)), coin::zero<SUI>(ts::ctx(sc)));
    ts::return_shared(board);
}

fun claim_gts_as(sc: &mut Scenario, who: address): u64 {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let c = game::claim_gts(&mut board, ts::ctx(sc));
    let v = coin::value(&c);
    coin::burn_for_testing(c);
    ts::return_shared(board);
    v
}

/// The GTS bought back goes to the stakers by weight, like their SUI: flexible 1x, locked 1.5x (40% / 60%).
/// Someone who stakes after a buyback gets nothing from it.
#[test]
fun test_buyback_gts_to_stakers() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    stake_as(&mut sc, BOB, GTS1, true, 1);
    carol_round(&mut sc, 10);
    buyback_as_keeper(&mut sc, 1_000_000);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    assert!(game::staking_gts_of(&board, ALICE) == 400_000 && game::staking_gts_of(&board, BOB) == 600_000, 1);
    assert!(game::bought_value(&board) == 0, 2);
    ts::return_shared(board);
    stake_as(&mut sc, CAROL, GTS1, false, 20);
    assert!(claim_gts_as(&mut sc, CAROL) == 0, 3);
    assert!(claim_gts_as(&mut sc, ALICE) == 400_000, 4);
    assert!(claim_gts_as(&mut sc, ALICE) == 0, 5);
    // Second buyback: Alice 10, Bob 15, Carol 10 tenths of weight.
    carol_round(&mut sc, 30);
    buyback_as_keeper(&mut sc, 3_500_000);
    assert!(claim_gts_as(&mut sc, ALICE) == 1_000_000, 6);
    assert!(claim_gts_as(&mut sc, BOB) == 600_000 + 1_500_000, 7);
    assert!(claim_gts_as(&mut sc, CAROL) == 1_000_000, 8);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let (paid, waiting) = game::staking_gts_totals(&board);
    assert!(paid == 4_500_000 && waiting == 0, 9);
    ts::return_shared(board);
    ts::end(sc);
}

/// With nobody staked the bought GTS waits in the game, then goes to the stakers with the next buyback.
#[test]
fun test_buyback_gts_waits_for_stakers() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    carol_round(&mut sc, 10);
    buyback_as_keeper(&mut sc, 1_000);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    assert!(game::bought_value(&board) == 1_000, 1);
    ts::return_shared(board);
    stake_as(&mut sc, ALICE, GTS1, false, 20);
    carol_round(&mut sc, 30);
    buyback_as_keeper(&mut sc, 500);
    assert!(claim_gts_as(&mut sc, ALICE) == 1_500, 2);
    ts::end(sc);
}

/// Unstaking keeps the GTS already earned.
#[test]
fun test_gts_yield_survives_unstake() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    carol_round(&mut sc, 10);
    buyback_as_keeper(&mut sc, 7_000);
    ts::next_tx(&mut sc, ALICE);
    let mut board = ts::take_shared<Board>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let c = game::unstake(&mut board, GTS1, false, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(c);
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
    assert!(claim_gts_as(&mut sc, ALICE) == 7_000, 1);
    ts::end(sc);
}

/// The RoundInfo stays until the last player of the round has claimed, then it is removed; the claims
/// before and after pay the same as without the removal.
#[test]
fun test_round_info_removed_after_last_claim() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    ts::next_tx(&mut sc, ALICE);
    let mut ma = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut ma, coin::mint_for_testing<SUI>(SUI1, ts::ctx(&mut sc)), one_tile(0, SUI1), &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, BOB);
    let mut mb = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut mb, coin::mint_for_testing<SUI>(SUI1, ts::ctx(&mut sc)), one_tile(1, SUI1), &clk, ts::ctx(&mut sc));
    // Bob tops up in the same round with the same Miner: still one player.
    game::deploy(&mut board, &mut mb, coin::mint_for_testing<SUI>(SUI1, ts::ctx(&mut sc)), one_tile(2, SUI1), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 62_000);
    game::settle_for_testing(&mut board, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
    let round = game::current_round(&board) - 1;
    assert!(game::round_info_exists_for_testing(&board, round), 1);
    let (g, s) = game::claim_v2(&mut board, &mut mb, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    assert!(game::round_info_exists_for_testing(&board, round), 2);
    ts::next_tx(&mut sc, ALICE);
    let (g, s) = game::claim_v2(&mut board, &mut ma, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    assert!(!game::round_info_exists_for_testing(&board, round), 3);
    // Everything paid out: only rounding dust may stay in the pot.
    assert!(game::pot_value(&board) < 100, 4);
    transfer::public_transfer(ma, ALICE); transfer::public_transfer(mb, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The minimum deposit can go down to 0.0005 SUI, not below.
#[test]
fun test_min_deploy_floor_ok() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 100, 1_000, 500_000, 60_000, 5_000, false);
    ts::return_shared(board);
    ts::return_to_sender(&sc, admin);
    ts::end(sc);
}

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_min_deploy_floor() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 100, 1_000, 499_999, 60_000, 5_000, false);
    abort 0
}

/// The supply lock: the old Treasury is gone, everything minted before carries over, the cap is 1,000,000.
#[test]
fun test_lock_supply() {
    let mut sc = ts::begin(@0x0);
    setup_unlocked(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let treasury = ts::take_shared<Treasury>(&sc);
    assert!(gts::minted(&treasury) == 0, 1);
    game::lock_supply(&admin, &mut board, treasury, ts::ctx(&mut sc));
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);
    ts::next_tx(&mut sc, BOB);
    assert!(!ts::has_most_recent_shared<Treasury>(), 2);
    let t = ts::take_shared<CappedTreasury<GTS>>(&sc);
    assert!(capped::max(&t) == gts::max_supply() && capped::minted(&t) == 0 && capped::room(&t) == gts::max_supply(), 3);
    ts::return_shared(t);
    ts::end(sc);
}

/// Near the cap, a claim mints only what is left; nothing past 1,000,000, ever.
#[test]
fun test_locked_supply_never_past_cap() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    // Two rounds: the second one mints more than its reward would allow only if the lock failed.
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(capped::minted(&treasury) == GTS1, 1);
    game::set_committed_for_testing(&mut board, gts::max_supply() - GTS1 / 10);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(capped::minted(&treasury) == GTS1 + GTS1 / 10, 2);
    assert!(capped::minted(&treasury) <= capped::max(&treasury), 3);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The old Treasury functions are closed once the supply is locked.
#[test, expected_failure(abort_code = game::EUseLockedSupply)]
fun test_old_claim_closed() {
    let mut sc = ts::begin(@0x0);
    setup_unlocked(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    abort 0
}
