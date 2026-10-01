#[test_only]
module gtstar::auto_tests;

use sui::test_scenario::{Self as ts, Scenario};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::clock::{Self, Clock};
use sui::random::{Self, Random};
use gtstar::gts::{Self, Treasury, GTS};
use supply_lock::capped::CappedTreasury;
use auto_vault::vault::{Self, Vault, PullCap};
use gtstar::game::{Self, Board, AdminCap};

const OWNER: address = @0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e;
const KEEPER: address = @0x22390096d8def0638c92f86da60683e37d1a7f00b4b22fcb359952db300c3549;
const BOB: address = @0xB0B;
const ALICE: address = @0xA11CE;
const CAROL: address = @0xCA501;
const SUI1: u64 = 1_000_000_000;
const ROUND: u64 = 50_000_000;      // 0.05 SUI a round
const ON_TILES: u64 = 49_000_000;   // what is left after 1% + 1%
const FEE: u64 = 500_000;           // each fee
const SPREAD: u8 = 0;
const SNIPER: u8 = 1;
const HUNTER: u8 = 2;
const NO_JACKPOT: u64 = 1_000_000;
const T0: u64 = 100_000;            // clock at the start of every test

/// The game as on mainnet (supply lock, daily mint limit, 5 tiles, minimum 0.0005 SUI a tile, Wealth
/// Fund 3%) with the Auto Mine vault installed.
fun setup(sc: &mut Scenario): Clock {
    random::create_for_testing(ts::ctx(sc));
    ts::next_tx(sc, @0x0);
    let mut rs = ts::take_shared<Random>(sc);
    random::update_randomness_state_for_testing(&mut rs, 0, x"0A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20212223242526272829", ts::ctx(sc));
    ts::return_shared(rs);
    ts::next_tx(sc, OWNER);
    gts::init_for_testing(ts::ctx(sc));
    game::init_for_testing(ts::ctx(sc));
    vault::init_for_testing(ts::ctx(sc));
    ts::next_tx(sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    let treasury = ts::take_shared<Treasury>(sc);
    game::set_fund_bps(&admin, &mut board, 300);
    game::lock_supply(&admin, &mut board, treasury, ts::ctx(sc));
    game::limit_mint_rate(&admin, &mut board, ts::ctx(sc));
    game::set_max_tiles(&admin, &mut board, 5);
    set_min(&admin, &mut board, 500_000, false);
    assert!(!game::auto_installed(&board), 900);
    game::auto_install(&admin, &mut board, ts::take_from_sender<PullCap>(sc));
    assert!(game::auto_installed(&board), 901);
    ts::return_to_sender(sc, admin);
    ts::return_shared(board);
    ts::next_tx(sc, OWNER);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, T0);
    clk
}

fun set_min(admin: &AdminCap, board: &mut Board, min: u64, paused: bool) {
    game::set_params(admin, board, 1_000, 1_950, 0, 300, 1_000, min, 60_000, 5_000, paused);
}

/// Deposit, open the seat and start a plan, as the site does in one transaction.
fun start(sc: &mut Scenario, who: address, deposit: u64, strategy: u8, per_round: u64, rounds: u64) {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let mut v = ts::take_shared<Vault>(sc);
    game::auto_join(&mut board, ts::ctx(sc));
    vault::deposit(&mut v, coin::mint_for_testing<SUI>(deposit, ts::ctx(sc)), ts::ctx(sc));
    vault::start(&mut v, strategy, per_round, rounds, 0, 0, ts::ctx(sc));
    ts::return_shared(board); ts::return_shared(v);
}

fun run_as(sc: &mut Scenario, who: address, players: vector<address>, clk: &Clock) {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let mut v = ts::take_shared<Vault>(sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(sc);
    let rs = ts::take_shared<Random>(sc);
    game::auto_run_for_testing(&mut board, &mut v, &mut treasury, players, &rs, clk, ts::ctx(sc));
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(v); ts::return_shared(treasury);
}

fun run(sc: &mut Scenario, players: vector<address>, clk: &Clock) { run_as(sc, KEEPER, players, clk) }

/// Draw the live round (the clock moves past its end first). Returns the winning tile.
fun draw(sc: &mut Scenario, clk: &mut Clock, odds: u64): u64 {
    ts::next_tx(sc, OWNER);
    let mut board = ts::take_shared<Board>(sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(sc);
    let rs = ts::take_shared<Random>(sc);
    let round = game::current_round(&board);
    clock::set_for_testing(clk, game::current_end_ms(&board) + 1_000);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &rs, clk, odds, ts::ctx(sc));
    let w = game::winning_square_for_testing(&board, round);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    w
}

fun vault_balance(sc: &mut Scenario, who: address): u64 {
    ts::next_tx(sc, who);
    let v = ts::take_shared<Vault>(sc);
    let b = vault::balance_of(&v, who);
    ts::return_shared(v);
    b
}

/// SUI the address received as coins so far (all burned).
fun received(sc: &mut Scenario, who: address): u64 {
    ts::next_tx(sc, who);
    let mut total = 0;
    while (ts::has_most_recent_for_address<Coin<SUI>>(who)) {
        let c = ts::take_from_address<Coin<SUI>>(sc, who);
        total = total + coin::value(&c);
        coin::burn_for_testing(c);
    };
    total
}

fun tiles_of(deployed: &vector<u64>): u64 {
    let mut n = 0;
    let mut i = 0;
    while (i < 25) { if (*vector::borrow(deployed, i) > 0) { n = n + 1 }; i = i + 1; };
    n
}

fun one_tile(i: u64, amt: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0;
    while (k < 25) { vector::push_back(&mut v, if (k == i) { amt } else { 0 }); k = k + 1; };
    v
}

/// Spread: 0.05 SUI leaves the vault, 1% goes to the caller, 1% to the buyback, and 0.049 goes on 5
/// tiles in the player's name. The next run claims the round: the 0.049 SUI on tiles mined 0.049 GTS
/// into the player's unrefined balance, and SUI won goes back to their vault balance.
#[test]
fun test_spread_round() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SPREAD, ROUND, 100);
    run(&mut sc, vector[BOB], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1 - ROUND, 1);
    assert!(received(&mut sc, KEEPER) == FEE, 2);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    assert!(game::current_total(&board) == ON_TILES && game::buyback_value(&board) == FEE && game::pot_value(&board) == ON_TILES, 3);
    let (round, deployed, tickets, rounds, wins, on_tiles, fees, won, mined) = game::auto_seat(&board, BOB);
    assert!(round == 1 && rounds == 1 && wins == 0 && on_tiles == ON_TILES && fees == 2 * FEE && won == 0 && mined == 0 && tickets == 0, 4);
    assert!(tiles_of(&deployed) == 5, 5);
    let mut i = 0;
    while (i < 25) { let d = *vector::borrow(&deployed, i); assert!(d == 0 || d == ON_TILES / 5, 6); i = i + 1; };
    ts::return_shared(board);

    let w = draw(&mut sc, &mut clk, NO_JACKPOT);
    let won_tile = *vector::borrow(&deployed, w) > 0;
    run(&mut sc, vector[BOB], &clk);
    // Alone in the round: a win pays the stake on the tile back plus 91% of the other four tiles.
    let back = if (won_tile) { ON_TILES / 5 + (ON_TILES * 4 / 5) * 91 / 100 } else { 0 };
    assert!(vault_balance(&mut sc, BOB) == SUI1 - 2 * ROUND + back, 7);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (unrefined, _) = game::unrefined_of(&board, BOB);
    assert!(unrefined == ON_TILES, 8); // every SUI on tiles mines the same GTS, win or lose
    let (round, _, _, rounds, wins, on_tiles, fees, won, mined) = game::auto_seat(&board, BOB);
    assert!(round == 2 && rounds == 2 && on_tiles == 2 * ON_TILES && fees == 4 * FEE && mined == ON_TILES, 9);
    assert!(won == back && wins == (if (won_tile) { 1 } else { 0 }), 10);
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Sniper: the whole 0.049 SUI on one tile.
#[test]
fun test_sniper_one_tile() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SNIPER, ROUND, 100);
    run(&mut sc, vector[BOB], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (_, deployed, _, _, _, on_tiles, _, _, _) = game::auto_seat(&board, BOB);
    assert!(tiles_of(&deployed) == 1 && on_tiles == ON_TILES && game::current_total(&board) == ON_TILES, 1);
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Hunter: nothing before the last 10 seconds of deposits, then the 5 tiles holding the least SUI, and
/// nothing once deposits are closed.
#[test]
fun test_hunter_late_and_emptiest() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, HUNTER, ROUND, 100);
    // No round live: a Hunter never starts one.
    run(&mut sc, vector[BOB], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1, 1);
    // Four wallets fill tiles 1-20 (5 each); the round ends 60s from now, deposits close at 55s.
    let mut w = 0;
    while (w < 4) {
        let who = sui::address::from_u256((0x7000 + w) as u256);
        ts::next_tx(&mut sc, who);
        let mut board = ts::take_shared<Board>(&sc);
        let mut m = game::new_miner(ts::ctx(&mut sc));
        let mut v = vector[];
        let mut k = 0;
        while (k < 25) { vector::push_back(&mut v, if (k >= w * 5 && k < w * 5 + 5) { 10_000_000 } else { 0 }); k = k + 1; };
        game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(50_000_000, ts::ctx(&mut sc)), v, &clk, ts::ctx(&mut sc));
        transfer::public_transfer(m, who);
        ts::return_shared(board);
        w = w + 1;
    };
    // 44.9s in: still too early.
    clock::set_for_testing(&mut clk, T0 + 44_900);
    run(&mut sc, vector[BOB], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1, 2);
    // 49s in: deployed. The five empty tiles are 21-25.
    clock::set_for_testing(&mut clk, T0 + 49_000);
    run(&mut sc, vector[BOB], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1 - ROUND, 3);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (round, deployed, _, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
    assert!(round == 1 && tiles_of(&deployed) == 5, 4);
    let mut i = 20;
    while (i < 25) { assert!(*vector::borrow(&deployed, i) == ON_TILES / 5, 5); i = i + 1; };
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Hunter after deposits closed: skipped, nothing leaves the vault.
#[test]
fun test_no_deposit_after_freeze() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, HUNTER, ROUND, 100);
    start(&mut sc, ALICE, SUI1, SPREAD, ROUND, 100);
    run(&mut sc, vector[ALICE], &clk);             // round live, ends 60s from now
    clock::set_for_testing(&mut clk, T0 + 55_001); // deposits closed at 55s
    run(&mut sc, vector[BOB], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1, 1);
    clock::set_for_testing(&mut clk, T0 + 69_000); // ended, not drawn yet
    run(&mut sc, vector[BOB, ALICE], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1 && vault_balance(&mut sc, ALICE) == SUI1 - ROUND, 2);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Every reason to skip a player leaves their balance untouched and never aborts the run: below 0.05 a
/// round, no seat, an unknown strategy, the game paused, already in the round, and playing the round by hand.
#[test]
fun test_skips_never_abort() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    // Below the minimum per round.
    start(&mut sc, BOB, SUI1, SPREAD, ROUND - 1, 100);
    // A plan in the vault but no seat in the game.
    ts::next_tx(&mut sc, ALICE);
    let mut v = ts::take_shared<Vault>(&sc);
    vault::deposit(&mut v, coin::mint_for_testing<SUI>(SUI1, ts::ctx(&mut sc)), ts::ctx(&mut sc));
    vault::start(&mut v, SPREAD, ROUND, 100, 0, 0, ts::ctx(&mut sc));
    ts::return_shared(v);
    // An unknown strategy.
    start(&mut sc, CAROL, SUI1, 3, ROUND, 100);
    run(&mut sc, vector[BOB, ALICE, CAROL, @0xDEAD], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1 && vault_balance(&mut sc, ALICE) == SUI1 && vault_balance(&mut sc, CAROL) == SUI1, 1);
    assert!(received(&mut sc, KEEPER) == 0, 2);

    // Paused: no automatic deposit either.
    start(&mut sc, BOB, 1, SPREAD, ROUND, 100);
    ts::next_tx(&mut sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    set_min(&admin, &mut board, 500_000, true);
    ts::return_shared(board);
    run(&mut sc, vector[BOB], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1 + 1, 3);
    ts::next_tx(&mut sc, OWNER);
    let mut board = ts::take_shared<Board>(&sc);
    set_min(&admin, &mut board, 500_000, false);
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);

    // In: once per round, however often it is run.
    run(&mut sc, vector[BOB, BOB], &clk);
    run(&mut sc, vector[BOB], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1 + 1 - ROUND, 4);

    // ALICE opens her seat but plays this round by hand: the run leaves her alone.
    ts::next_tx(&mut sc, ALICE);
    let mut board = ts::take_shared<Board>(&sc);
    game::auto_join(&mut board, ts::ctx(&mut sc));
    game::auto_join(&mut board, ts::ctx(&mut sc)); // a second call does nothing
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(3, 10_000_000), &clk, ts::ctx(&mut sc));
    transfer::public_transfer(m, ALICE);
    ts::return_shared(board);
    run(&mut sc, vector[ALICE], &clk);
    assert!(vault_balance(&mut sc, ALICE) == SUI1, 5);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// With the minimum per tile above what 5 tiles would get, the plan is skipped (not a smaller deposit).
#[test]
fun test_skip_below_tile_minimum() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    ts::next_tx(&mut sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    set_min(&admin, &mut board, 10_000_000, false); // 0.01 a tile; Spread would put 0.0098
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);
    start(&mut sc, BOB, SUI1, SPREAD, ROUND, 100);
    start(&mut sc, ALICE, SUI1, SNIPER, ROUND, 100);
    run(&mut sc, vector[BOB, ALICE], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1 && vault_balance(&mut sc, ALICE) == SUI1 - ROUND, 1);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Anyone may run plans, and whoever does is paid the 1%. Two players in one call, one coin to the caller.
#[test]
fun test_anyone_can_run() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SPREAD, ROUND, 100);
    start(&mut sc, ALICE, SUI1, SNIPER, 2 * ROUND, 100);
    run_as(&mut sc, CAROL, vector[BOB, ALICE], &clk);
    assert!(received(&mut sc, CAROL) == 3 * FEE, 1);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    assert!(game::current_total(&board) == 3 * ON_TILES && game::buyback_value(&board) == 3 * FEE, 2);
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Rounds between two automatic players: every mist that left the vaults is on tiles or in a fee, and
/// after both claim the pot holds nothing.
#[test]
fun test_pot_adds_up() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SPREAD, ROUND, 3);
    start(&mut sc, ALICE, SUI1, SNIPER, ROUND, 3);
    let mut n = 0;
    while (n < 3) {
        run(&mut sc, vector[BOB, ALICE], &clk);
        draw(&mut sc, &mut clk, NO_JACKPOT);
        n = n + 1;
    };
    // Both plans are done (3 rounds each) and off; one more run only claims.
    run(&mut sc, vector[BOB, ALICE], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let v = ts::take_shared<Vault>(&sc);
    assert!(!vault::is_on(&v, BOB) && !vault::is_on(&v, ALICE), 1);
    assert!(game::pot_value(&board) == 0 && game::current_total(&board) == 0, 2);
    let (rb, _, _, rounds_b, _, dep_b, fees_b, won_b, mined_b) = game::auto_seat(&board, BOB);
    let (ra, _, _, rounds_a, _, dep_a, fees_a, won_a, mined_a) = game::auto_seat(&board, ALICE);
    assert!(rb == 0 && ra == 0 && rounds_b == 3 && rounds_a == 3, 3);
    assert!(dep_b + fees_b == 3 * ROUND && dep_a + fees_a == 3 * ROUND, 4);
    assert!(vault::balance_of(&v, BOB) == SUI1 - 3 * ROUND + won_b && vault::balance_of(&v, ALICE) == SUI1 - 3 * ROUND + won_a, 5);
    // 0.098 SUI on tiles a round mines 0.098 GTS, split by SUI on tiles: half each.
    let (ub, _) = game::unrefined_of(&board, BOB);
    let (ua, _) = game::unrefined_of(&board, ALICE);
    assert!(ub == mined_b && ua == mined_a && ub == 3 * ON_TILES && ua == 3 * ON_TILES, 6);
    ts::return_shared(board); ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Stop and withdraw at any time: after the player stops, nothing more leaves the vault, the last round
/// is still claimed for them by the next run, and the whole balance comes out.
#[test]
fun test_stop_then_withdraw_everything() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SPREAD, ROUND, 100);
    run(&mut sc, vector[BOB], &clk);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut v = ts::take_shared<Vault>(&sc);
    vault::stop(&mut v, ts::ctx(&mut sc));
    game::auto_flush(&mut board, ts::ctx(&mut sc));
    ts::return_shared(board); ts::return_shared(v);
    draw(&mut sc, &mut clk, NO_JACKPOT);
    run(&mut sc, vector[BOB], &clk);
    run(&mut sc, vector[BOB], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let mut v = ts::take_shared<Vault>(&sc);
    let (round, _, tickets, rounds, _, _, _, won, mined) = game::auto_seat(&board, BOB);
    assert!(round == 0 && rounds == 1 && mined == ON_TILES && tickets == 0, 1);
    let c = vault::withdraw_all(&mut v, ts::ctx(&mut sc));
    assert!(coin::value(&c) == SUI1 - ROUND + won && vault::balance_of(&v, BOB) == 0, 2);
    coin::burn_for_testing(c);
    ts::return_shared(board); ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// When the balance runs out the plan has no round left to play: the last claim puts every waiting
/// ticket in the draw, without the player doing anything.
#[test]
fun test_tickets_added_when_balance_runs_out() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1 / 2, SPREAD, ROUND, 100);
    start(&mut sc, ALICE, SUI1, SPREAD, ROUND, 100);
    let mut n = 0u64;
    let mut bob_lost = 0;
    while (n < 2) {
        run(&mut sc, vector[BOB, ALICE], &clk);
        ts::next_tx(&mut sc, BOB);
        let board = ts::take_shared<Board>(&sc);
        let (_, deployed, waiting, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
        assert!(waiting == bob_lost && game::tickets_of(&board, BOB) == 0, 1);
        ts::return_shared(board);
        let w = draw(&mut sc, &mut clk, NO_JACKPOT);
        bob_lost = bob_lost + (ON_TILES - *vector::borrow(&deployed, w)) * 9 / 100;
        n = n + 1;
    };
    // BOB raises the amount per round above his balance: the plan stays on but cannot play.
    ts::next_tx(&mut sc, BOB);
    let mut v = ts::take_shared<Vault>(&sc);
    vault::start(&mut v, SPREAD, SUI1, 100, 0, 0, ts::ctx(&mut sc));
    ts::return_shared(v);
    run(&mut sc, vector[BOB, ALICE], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let v = ts::take_shared<Vault>(&sc);
    let (round, _, waiting, rounds, _, _, _, _, _) = game::auto_seat(&board, BOB);
    assert!(round == 0 && rounds == 2 && vault::is_on(&v, BOB) && vault::balance_of(&v, BOB) < SUI1, 2);
    assert!(waiting == 0 && game::tickets_of(&board, BOB) == bob_lost && bob_lost > 0, 3);
    ts::return_shared(board); ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// Wealth Fund tickets of automatic rounds wait in the seat and enter the draw at the 10th claim, with
/// nothing lost: the same tickets the player would have got claiming by hand.
#[test]
fun test_tickets_added_every_ten_claims() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SPREAD, ROUND, 100);
    start(&mut sc, ALICE, SUI1, SPREAD, ROUND, 100);
    let mut n = 0;
    let mut bob_lost = 0;
    while (n < 10) {
        run(&mut sc, vector[BOB, ALICE], &clk);
        ts::next_tx(&mut sc, BOB);
        let board = ts::take_shared<Board>(&sc);
        let (_, deployed, waiting, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
        // After n claims nothing is in the draw yet; all of it waits in the seat.
        assert!(game::tickets_of(&board, BOB) == 0, 1);
        assert!(waiting == bob_lost, 2);
        ts::return_shared(board);
        let w = draw(&mut sc, &mut clk, NO_JACKPOT);
        // Tickets: 9% (all fees in this setup) of the SUI lost in the round.
        bob_lost = bob_lost + (ON_TILES - *vector::borrow(&deployed, w)) * 9 / 100;
        n = n + 1;
    };
    // The 10th claim puts all of it in the draw.
    run(&mut sc, vector[BOB, ALICE], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (_, _, waiting, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
    assert!(waiting == 0 && game::tickets_of(&board, BOB) == bob_lost && bob_lost > 0, 3);
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// A player alone: adding their tickets only extends the last range, so after the first batch they
/// enter the draw at every claim.
#[test]
fun test_tickets_added_at_once_when_free() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SNIPER, ROUND, 100);
    // By hand first, so BOB holds the last range of tickets.
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(50_000_000, ts::ctx(&mut sc)), vector[10_000_000, 10_000_000, 10_000_000, 10_000_000, 10_000_000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, T0 + 61_000);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &rs, &clk, NO_JACKPOT, ts::ctx(&mut sc));
    let (g, s) = game::claim_v3(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, BOB);
    let by_hand = game::tickets_of(&board, BOB);
    assert!(by_hand > 0, 1);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);

    run(&mut sc, vector[BOB], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (_, deployed, _, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
    ts::return_shared(board);
    let w = draw(&mut sc, &mut clk, NO_JACKPOT);
    run(&mut sc, vector[BOB], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (_, _, waiting, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
    let lost = ON_TILES - *vector::borrow(&deployed, w);
    assert!(waiting == 0 && game::tickets_of(&board, BOB) == by_hand + lost * 9 / 100, 2);
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// A Wealth Fund payout resets every ticket: tickets still waiting in a seat are gone with it, exactly
/// like tickets already in the draw.
#[test]
fun test_waiting_tickets_reset_with_the_draw() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SPREAD, ROUND, 100);
    start(&mut sc, ALICE, SUI1, SPREAD, ROUND, 100);
    // CAROL plays by hand and claims, so the draw holds tickets and can pay.
    run(&mut sc, vector[BOB, ALICE], &clk);
    ts::next_tx(&mut sc, CAROL);
    let mut board = ts::take_shared<Board>(&sc);
    let mut carol = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut carol, coin::mint_for_testing<SUI>(50_000_000, ts::ctx(&mut sc)), vector[10_000_000, 10_000_000, 10_000_000, 10_000_000, 10_000_000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], &clk, ts::ctx(&mut sc));
    ts::return_shared(board);
    draw(&mut sc, &mut clk, NO_JACKPOT);
    ts::next_tx(&mut sc, CAROL);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let (g, s) = game::claim_v3(&mut board, &mut carol, &mut treasury, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(carol, CAROL);
    assert!(game::tickets_of(&board, CAROL) > 0, 1);
    ts::return_shared(board); ts::return_shared(treasury);
    // BOB's first round is claimed: his tickets wait in the seat.
    run(&mut sc, vector[BOB, ALICE], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (_, _, waiting, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
    assert!(waiting > 0, 2);
    ts::return_shared(board);
    // This round pays the Wealth Fund (odds 1 in 1): a new draw starts.
    draw(&mut sc, &mut clk, 1);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let (epoch, total) = game::wealth_tickets(&board);
    assert!(epoch == 1 && total == 0, 3);
    let (_, _, waiting, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
    assert!(waiting == 0, 4);
    game::auto_flush(&mut board, ts::ctx(&mut sc));
    assert!(game::tickets_of(&board, BOB) == 0, 5);
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// With no room left under today's GTS mint limit the claim waits: the run does not abort, the round
/// stays in the seat, no new round is played, and the next UTC day it is claimed in full.
#[test]
fun test_claim_waits_for_daily_limit() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, SPREAD, ROUND, 100);
    run(&mut sc, vector[BOB], &clk);
    draw(&mut sc, &mut clk, NO_JACKPOT);
    // Today's whole limit is minted.
    ts::next_tx(&mut sc, OWNER);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    coin::burn_for_testing(game::mint_for_testing(&mut board, &mut treasury, 2_000 * 1_000_000_000, &clk, ts::ctx(&mut sc)));
    ts::return_shared(board); ts::return_shared(treasury);
    run(&mut sc, vector[BOB], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (round, _, _, rounds, _, _, _, _, mined) = game::auto_seat(&board, BOB);
    assert!(round == 1 && rounds == 1 && mined == 0, 1);
    ts::return_shared(board);
    assert!(vault_balance(&mut sc, BOB) == SUI1 - ROUND, 2);
    // Next UTC day.
    clock::set_for_testing(&mut clk, 86_400_000 + 5_000);
    run(&mut sc, vector[BOB], &clk);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (round, _, _, rounds, _, _, _, _, mined) = game::auto_seat(&board, BOB);
    assert!(round == 2 && rounds == 2 && mined == ON_TILES, 3);
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// A second PullCap cannot be installed.
#[test, expected_failure(abort_code = game::EAutoInstalled)]
fun test_install_once() {
    let mut sc = ts::begin(@0x0);
    let clk = setup(&mut sc);
    ts::next_tx(&mut sc, OWNER);
    vault::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::auto_install(&admin, &mut board, ts::take_from_sender<PullCap>(&sc));
    ts::return_to_sender(&sc, admin);
    ts::return_shared(board);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}
