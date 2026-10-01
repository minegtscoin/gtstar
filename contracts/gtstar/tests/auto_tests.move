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

/// A player as Auto Mine left them: a seat, a balance in the vault and a plan that is still on.
fun start(sc: &mut Scenario, who: address, deposit: u64, per_round: u64, rounds: u64) {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let mut v = ts::take_shared<Vault>(sc);
    game::auto_seat_for_testing(&mut board, who, ts::ctx(sc));
    vault::deposit(&mut v, coin::mint_for_testing<SUI>(deposit, ts::ctx(sc)), ts::ctx(sc));
    vault::start(&mut v, 0, per_round, rounds, 0, 0, ts::ctx(sc));
    ts::return_shared(board); ts::return_shared(v);
}

/// An automatic round played from `who`'s seat before Auto Mine closed: `per` on each of tiles 0 to 4.
fun old_auto_round(sc: &mut Scenario, who: address, per: u64, clk: &Clock) {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let amounts = vector[per, per, per, per, per, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    game::auto_deploy_for_testing(&mut board, who, coin::mint_for_testing<SUI>(5 * per, ts::ctx(sc)), amounts, clk);
    ts::return_shared(board);
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

/// Auto Mine is closed: no new seat can be opened.
#[test, expected_failure(abort_code = game::EAutoClosed)]
fun test_join_closed() {
    let mut sc = ts::begin(@0x0);
    let _clk = setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    game::auto_join(&mut board, ts::ctx(&mut sc));
    abort 0
}

/// A plan that is still on, with SUI in the vault: `auto_run` plays no round and takes nothing. The
/// balance stays whole, no round starts, the caller is paid nothing, and the player can withdraw it all.
#[test]
fun test_run_plays_nothing() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, 50_000_000, 10);
    clock::set_for_testing(&mut clk, T0 + 30_000);
    run(&mut sc, vector[BOB, ALICE], &clk); // Alice has no seat: skipped
    run_as(&mut sc, CAROL, vector[BOB], &clk);
    assert!(vault_balance(&mut sc, BOB) == SUI1, 1);
    assert!(received(&mut sc, KEEPER) == 0 && received(&mut sc, CAROL) == 0, 2);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let mut v = ts::take_shared<Vault>(&sc);
    assert!(game::current_round(&board) == 1 && game::current_total(&board) == 0 && game::buyback_value(&board) == 0, 3);
    let (round, _, _, rounds, _, _, _, _, _) = game::auto_seat(&board, BOB);
    assert!(round == 0 && rounds == 0, 4);
    let out = vault::withdraw_all(&mut v, ts::ctx(&mut sc));
    assert!(coin::value(&out) == SUI1, 5);
    coin::burn_for_testing(out);
    ts::return_shared(board); ts::return_shared(v);
    clock::destroy_for_testing(clk);
    ts::end(sc);
}

/// An automatic round played before Auto Mine closed is still claimed by `auto_run`, for its player: the
/// SUI won goes to their vault balance, the GTS to their unrefined balance, the tickets into the draw at
/// once. Nothing else is taken from the vault, and the game's pot ends empty.
#[test]
fun test_run_claims_old_rounds() {
    let mut sc = ts::begin(@0x0);
    let mut clk = setup(&mut sc);
    start(&mut sc, BOB, SUI1, 50_000_000, 100);
    let per = 10_000_000;
    let (mut won, mut lost, mut n) = (0u64, 0u64, 0u64);
    while ((won == 0 || lost == 0) && n < 60) {
        clock::set_for_testing(&mut clk, T0 + n * 200_000 + 1_000);
        old_auto_round(&mut sc, BOB, per, &clk);
        let before = vault_balance(&mut sc, BOB);
        let w = draw(&mut sc, &mut clk, NO_JACKPOT);
        run(&mut sc, vector[BOB], &clk);
        let after = vault_balance(&mut sc, BOB);
        ts::next_tx(&mut sc, BOB);
        let board = ts::take_shared<Board>(&sc);
        let (round, _, tickets, _, _, _, _, _, _) = game::auto_seat(&board, BOB);
        assert!(round == 0 && tickets == 0, 1); // claimed, and no ticket left waiting
        ts::return_shared(board);
        if (w < 5) {
            // Tile back plus 91% of the four lost tiles (creator 1, buyback 3, liquidity 2, draw share 3).
            assert!(after - before == per + 4 * per * 91 / 100, 2);
            won = won + 1;
        } else {
            assert!(after == before, 3);
            lost = lost + 1;
        };
        n = n + 1;
    };
    assert!(won > 0 && lost > 0, 4);
    assert!(received(&mut sc, KEEPER) == 0, 5);
    ts::next_tx(&mut sc, BOB);
    let board = ts::take_shared<Board>(&sc);
    let (unrefined, _) = game::unrefined_of(&board, BOB);
    // Every round held 0.05 SUI of the 1 SUI a full reward needs: 0.05 GTS a round.
    assert!(unrefined == n * 50_000_000, 6);
    // Tickets: the 9% fee on the SUI lost in every round.
    assert!(game::tickets_of(&board, BOB) == (won * 4 + lost * 5) * per * 9 / 100, 7);
    assert!(game::pot_value(&board) == 0, 8);
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
