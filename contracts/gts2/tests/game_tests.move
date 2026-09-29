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

/// A round with a winner: creator 1%, reserve 4%, buyback 5%, winners 90% (kept by the part of the
/// deposit on the winning tile). 1 GTS mined into the unrefined balance. Every mist is accounted for.
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
    let share = losing * 90 / 100;
    let kept = share / 25;
    assert!(s == per + kept, 1);
    assert!(game::dev_fees_value(&board) == losing / 100, 2);
    assert!(game::buyback_value(&board) == losing * 5 / 100 - 5_000_000, 3); // 0.005 SUI of it paid to the drawer
    assert!(gts::vault_value(&treasury) == losing * 4 / 100 + (share - kept), 4);
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

/// No one on the winning tile: creator 1%, reserve 4%, buyback 5%, Wealth Fund 19.5%, the rest to the reserve.
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
            assert!(game::buyback_value(&board) - buy_before == 0, 2); // 0.005 buyback all paid to the drawer
            assert!(game::motherlode_value(&board) - fund_before == amt * 1_950 / 10_000, 3);
            assert!(gts::vault_value(&treasury) - vault_before == amt - amt / 100 - amt * 5 / 100 - amt * 1_950 / 10_000, 4);
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

/// Wealth Fund pays the whole balance to the winning tile when it hits (odds 1 forces a hit).
#[test]
fun test_wealth_fund_pays() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    // Fill the fund with no-winner rounds on tile 0 until one misses.
    let amt = 1_000_000_000;
    let mut t = 1_000;
    while (game::motherlode_value(&board) == 0) {
        let mut m = game::new_miner(ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, t);
        game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(amt, ts::ctx(&mut sc)), one_tile(0, amt), &clk, ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, t + 61_000);
        game::settle_for_testing(&mut board, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
        let (g, s) = game::claim(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
        coin::burn_for_testing(g); coin::burn_for_testing(s);
        transfer::public_transfer(m, BOB);
        t = t + 100_000;
    };
    let fund = game::motherlode_value(&board);
    // Every tile covered: always a winner; odds 1 always hits.
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let per = 10_000_000;
    clock::set_for_testing(&mut clk, t);
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(per * 25, ts::ctx(&mut sc)), all_tiles(per), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, t + 61_000);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &rs, &clk, 1, ts::ctx(&mut sc));
    let round = game::current_round(&board) - 1;
    assert!(game::motherlode_paid(&board, round) == fund, 1);
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
    // On 1 of 25 tiles: keeps 1/25 of the jackpot, the rest goes back to the fund.
    let kept = fund / 25;
    assert!(coin::value(&s) >= per + kept - 1, 2);
    assert!(game::motherlode_value(&board) == fund - kept, 3);
    assert!(game::pot_value(&board) == 0, 4);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, BOB);
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

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_fees_over_100_rejected() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 5_000, 4_000, 1_000, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

#[test, expected_failure(abort_code = game::EPaused)]
fun test_pause_stops_deposits() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 400, 500, 1_000, 10_000_000, 60_000, 5_000, true);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// Renounce needs the buyback off and empty; afterwards the AdminCap is gone.
#[test, expected_failure(abort_code = game::EBuybackOpen)]
fun test_renounce_needs_buyback_off() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let board = ts::take_shared<Board>(&sc);
    game::renounce(admin, &board);
    abort 0
}

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
    let share = losing * 90 / 100;
    let kept = share / 25;
    // reserve 6% + stakers 3% + winnings not kept, minus 0.005 to the drawer (Carol).
    assert!(gts::vault_value(&treasury) == losing * 9 / 100 - 5_000_000 + (share - kept), 1);
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
