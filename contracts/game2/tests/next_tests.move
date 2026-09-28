#[test_only]
module gtstar_next::next_tests;

use sui::test_scenario::{Self as ts};
use sui::coin;
use sui::sui::SUI;
use sui::clock;
use sui::random::{Self, Random};
use gts_token::gts::{Self, Treasury, MinterCap};
use gtstar::staking::{Self, StakePool};
use gtstar::game::{Self as first, Board as FirstBoard};
use gtstar_next::game::{Self, Board, AdminCap};

const OWNER: address = @0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e;
const BOB: address = @0xB0B;

/// Token, staking and the first game as on mainnet, then the MintAuth handed to the new game.
fun setup(sc: &mut ts::Scenario) {
    random::create_for_testing(ts::ctx(sc));
    ts::next_tx(sc, @0x0);
    let mut rs = ts::take_shared<Random>(sc);
    random::update_randomness_state_for_testing(&mut rs, 0, x"0A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20212223242526272829", ts::ctx(sc));
    ts::return_shared(rs);

    ts::next_tx(sc, OWNER);
    gts::init_for_testing(ts::ctx(sc));
    staking::init_for_testing(ts::ctx(sc));
    first::init_for_testing(ts::ctx(sc));
    game::init_for_testing(ts::ctx(sc));

    ts::next_tx(sc, OWNER);
    let mut fb = ts::take_shared<FirstBoard>(sc);
    let mut treasury = ts::take_shared<Treasury>(sc);
    let cap = ts::take_from_sender<MinterCap>(sc);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, 1);
    first::install(&mut fb, cap, &mut treasury, &clk);
    first::take_admin_for_testing(&mut fb, ts::ctx(sc));
    clock::destroy_for_testing(clk);
    ts::return_shared(treasury);

    ts::next_tx(sc, OWNER);
    let first_admin = ts::take_from_sender<first::AdminCap>(sc);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    let auth = first::issue_mint_auth(&first_admin, &mut fb, ts::ctx(sc));
    game::install(&admin, &mut board, auth, &mut fb);
    assert!(game::installed(&board) && game::current_round(&board) == first::current_round(&fb) + 1, 900);
    ts::return_to_sender(sc, first_admin);
    ts::return_to_sender(sc, admin);
    ts::return_shared(board);
    ts::return_shared(fb);
}

fun one_tile(i: u64, amt: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0;
    while (k < 25) { vector::push_back(&mut v, if (k == i) { amt } else { 0 }); k = k + 1; };
    v
}

/// A round with a winner: creator 1%, reserve 4%, buyback 5%, winners 90% (kept by the part of the
/// deposit on the winning tile). Every mist is accounted for.
#[test]
fun test_round_with_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut fb = ts::take_shared<FirstBoard>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);

    let per = 100_000_000;
    let mut amounts = vector[];
    let mut i = 0;
    while (i < 25) { vector::push_back(&mut amounts, per); i = i + 1; };
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(per * 25, ts::ctx(&mut sc)), amounts, &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 61_000);
    let vault_before = gts::vault_value(&treasury);
    game::settle_for_testing(&mut board, &mut fb, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut fb, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));

    let losing = per * 24;
    let share = losing * 90 / 100;
    let kept = share / 25;
    assert!(coin::value(&s) == per + kept, 1);
    assert!(game::dev_fees_value(&board) == losing / 100, 2);
    assert!(game::buyback_value(&board) == losing * 5 / 100, 3);
    assert!(gts::vault_value(&treasury) - vault_before == losing * 4 / 100 + (share - kept), 4);
    assert!(game::pot_value(&board) == 0, 5);
    assert!(coin::value(&g) + game::unrefined_total(&board) == 1_000_000_000, 6); // minted via the MintAuth
    assert!(staking::total_rewards_for_testing(&pool) == 100_000_000, 7);

    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(fb); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// No one on the winning tile: creator 1%, reserve 4%, buyback 5%, Wealth Fund 19.5%, the rest (70.5%) to the reserve.
#[test]
fun test_round_without_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut fb = ts::take_shared<FirstBoard>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));

    let amt = 100_000_000;
    let mut t = 1_000;
    let mut guard = 0;
    while (game::motherlode_value(&board) == 0 && guard < 60) {
        clock::set_for_testing(&mut clk, t);
        let mut m = game::new_miner(ts::ctx(&mut sc));
        game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(amt, ts::ctx(&mut sc)), one_tile(0, amt), &clk, ts::ctx(&mut sc));
        clock::set_for_testing(&mut clk, t + 60_000);
        let vault_before = gts::vault_value(&treasury);
        let buyback_before = game::buyback_value(&board);
        let dev_before = game::dev_fees_value(&board);
        game::settle_with_odds_for_testing(&mut board, &mut fb, &mut treasury, &mut pool, &rs, &clk, 1_000_000_000, ts::ctx(&mut sc));
        let (g, s) = game::claim(&mut board, &mut fb, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
        if (coin::value(&s) == 0) {
            assert!(game::motherlode_value(&board) == amt * 1_950 / 10_000, 1);
            assert!(game::buyback_value(&board) - buyback_before == amt * 500 / 10_000, 2);
            assert!(game::dev_fees_value(&board) - dev_before == amt / 100, 3);
            assert!(gts::vault_value(&treasury) - vault_before == amt * 7_450 / 10_000, 4);
        };
        coin::burn_for_testing(g); coin::burn_for_testing(s);
        transfer::public_transfer(m, BOB);
        t = t + 100_000; guard = guard + 1;
    };
    assert!(game::motherlode_value(&board) > 0, 5);
    assert!(game::pot_value(&board) == 0, 6);

    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(fb); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// The owner takes the buyback SUI; bought GTS burned with burn_bought lowers the supply, reserve unchanged.
#[test]
fun test_take_buyback_and_burn() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut fb = ts::take_shared<FirstBoard>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut amounts = vector[];
    let mut i = 0;
    while (i < 25) { vector::push_back(&mut amounts, 100_000_000); i = i + 1; };
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(2_500_000_000, ts::ctx(&mut sc)), amounts, &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut fb, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    let s = game::claim_sui(&mut board, &mut fb, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    let gts_coin = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc)); // stands in for GTS bought on Cetus

    ts::next_tx(&mut sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let bb = game::buyback_value(&board);
    assert!(bb > 0, 1);
    let taken = game::take_buyback(&admin, &mut board, ts::ctx(&mut sc));
    assert!(coin::value(&taken) == bb && game::buyback_value(&board) == 0, 2);

    let supply = gts::total_supply(&treasury);
    let vault = gts::vault_value(&treasury);
    let burn = coin::value(&gts_coin);
    game::burn_bought(&mut treasury, gts_coin, ts::ctx(&mut sc));
    assert!(gts::total_supply(&treasury) == supply - burn, 3);
    assert!(gts::vault_value(&treasury) == vault, 4);

    coin::burn_for_testing(taken); coin::burn_for_testing(s);
    ts::return_to_sender(&sc, admin);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(fb); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// Settings change at once; the fees can never add up to more than the losing pot.
#[test, expected_failure(abort_code = gtstar_next::game::EBadParams)]
fun test_fees_capped() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, OWNER);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 0, 400, 0, 1_000, 10_000_000, 60_000, 5_000, false);
    let (_, _, _, bb, dev, _, _) = game::current_params(&board);
    assert!(bb == 0 && dev == 100, 1);
    game::set_params(&admin, &mut board, 1_000, 1_950, 4_000, 4_000, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}
