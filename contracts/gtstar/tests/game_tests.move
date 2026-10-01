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

/// Setup with the supply locked (v15) and the daily mint limit (v16), as on mainnet.
fun setup(sc: &mut Scenario) {
    setup_unlocked(sc);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    let treasury = ts::take_shared<Treasury>(sc);
    game::lock_supply(&admin, &mut board, treasury, ts::ctx(sc));
    game::limit_mint_rate(&admin, &mut board, ts::ctx(sc));
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
    let (g, s) = game::claim_v3(board, m, treasury, clk, ts::ctx(sc));
    let (gv, sv) = (coin::value(&g), coin::value(&s));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    (gv, sv)
}

/// Launch settings: 1 GTS per round, halved once a step has mined what 15,658 full rounds mint, full reward at 1 SUI.
#[test]
fun test_launch_emission() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let board = ts::take_shared<Board>(&sc);
    let (reward, step, decay, count, full, committed) = game::emission(&board);
    assert!(reward == GTS1 && step == 15_658 && decay == 500_000 && count == 0 && full == SUI1 && committed == 0, 1);
    let (mined, until) = game::emission_step(&board);
    assert!(mined == 0 && until == 15_658 * GTS1, 4);
    assert!(game::current_reward(&board) == GTS1, 2);
    assert!(gts::max_supply() == 1_000_000 * GTS1, 3);
    ts::return_shared(board);
    ts::end(sc);
}

/// A round with a winner: creator 1%, buyback 3%, liquidity 2%, the draw share 3% in this test (all of
/// it to the drawer), winners 91% (no stakers in this test). The winner keeps the whole share, even spread over every tile (no fair split from v10).
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
    let share = losing * 91 / 100;
    assert!(s == per + share, 1);
    assert!(game::dev_fees_value(&board) == losing / 100, 2);
    assert!(game::buyback_value(&board) == losing * 3 / 100, 3);
    assert!(game::liquidity_value(&board) == losing * 2 / 100, 10);
    // The whole draw share went to the drawer: a round with a winner adds nothing to the Wealth Fund.
    assert!(game::motherlode_value(&board) == 0, 4);
    assert!(game::pot_value(&board) == 0, 5);
    assert!(g == 0 && game::unrefined_total(&board) == GTS1, 6); // 2.5 SUI >= 1 SUI: full 1 GTS
    assert!(capped::minted(&treasury) == GTS1, 7);
    let (_, _, _, count, _, committed) = game::emission(&board);
    assert!(count == GTS1 && committed == GTS1, 8); // the step counts the GTS mined

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

/// The halving: the reward is cut in half once the step has mined what 15,658 full rounds mint at the
/// current reward (15,658 GTS, then 7,829, ...), and what was mined past the step counts toward the next.
#[test]
fun test_halving_by_gts_mined() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));

    // Two full rounds short of the first halving.
    game::set_reward_for_testing(&mut board, GTS1, 15_658 * GTS1 - 2 * GTS1);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::current_reward(&board) == GTS1, 1);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::current_reward(&board) == GTS1 / 2, 2);
    let (mined, until) = game::emission_step(&board);
    assert!(mined == 0 && until == 7_829 * GTS1, 3); // the second step is half as long

    // The second step ends in the middle of a round: the part mined past it starts the third step.
    game::set_reward_for_testing(&mut board, GTS1 / 2, 7_829 * GTS1 - GTS1 * 3 / 4);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::current_reward(&board) == GTS1 / 2, 4);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::current_reward(&board) == GTS1 / 4, 5);
    let (mined, until) = game::emission_step(&board);
    assert!(mined == GTS1 / 4 && until == 3_914 * GTS1 + GTS1 / 2, 6);
    assert!(game::unrefined_total(&board) == 3 * GTS1, 7); // 1 + 1 + 0.5 + 0.5 mined in these four rounds

    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A small round moves the halving only by the GTS it mined: rounds with little SUI cannot hurry it.
#[test]
fun test_small_rounds_do_not_hurry_the_halving() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::set_reward_for_testing(&mut board, GTS1, 15_658 * GTS1 - GTS1);
    // Three rounds of 0.25 SUI mine 0.25 GTS each: still short of the halving.
    let mut i = 0u64;
    while (i < 3) {
        play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 10_000_000);
        i = i + 1;
    };
    assert!(game::current_reward(&board) == GTS1, 1);
    let (mined, _) = game::emission_step(&board);
    assert!(mined == 15_658 * GTS1 - GTS1 / 4, 2);
    // The fourth reaches it.
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 10_000_000);
    assert!(game::current_reward(&board) == GTS1 / 2, 3);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The last halvings: the reward reaches zero and the rounds keep being played and drawn, mining nothing.
#[test]
fun test_halving_ends_at_zero() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::set_reward_for_testing(&mut board, 1, 15_657); // the smallest reward, one round short of its halving
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::current_reward(&board) == 0 && game::unrefined_total(&board) == 1, 1);
    let (_, s) = play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(s > 0 && game::unrefined_total(&board) == 1 && game::pot_value(&board) == 0, 2);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The move to the halving, at the first call after the upgrade: every GTS mined so far counts toward
/// the first halving, the cut per step becomes one half, and it happens once.
#[test]
fun test_halving_starts_with_what_was_mined() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    ts::next_tx(&mut sc, BOB);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    // As on mainnet before the upgrade: 77 GTS mined, 2,101 rounds into the step, 1.425% cut.
    game::set_committed_for_testing(&mut board, 77 * GTS1);
    game::before_halving_for_testing(&mut board, 2_101);
    let (_, _, decay, count, _, _) = game::emission(&board);
    assert!(decay == 14_250 && count == 2_101, 1);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    let (reward, step, decay, count, _, committed) = game::emission(&board);
    assert!(reward == GTS1 && step == 15_658 && decay == 500_000, 2);
    assert!(committed == 78 * GTS1 && count == 78 * GTS1, 3);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    let (_, _, _, count, _, _) = game::emission(&board);
    assert!(count == 79 * GTS1, 4);
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

/// No one on the winning tile: creator 1%, the draw share's 3% (all of it to the drawer), the
/// buyback's full 3% and liquidity's full 2%, and the whole rest to the Wealth Fund.
/// Nothing to a reserve.
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
            assert!(game::buyback_value(&board) - buy_before == amt * 3 / 100, 2);
            assert!(game::liquidity_value(&board) - liq_before == amt * 2 / 100, 7); // whole: the drawer is paid from the fund share only
            assert!(game::motherlode_value(&board) - fund_before == amt * 91 / 100, 3);
            done = true;
        };
        let (g, s) = game::claim_v3(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
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
    let (g, s) = game::claim_v3(board, &mut m, treasury, clk, ts::ctx(sc));
    let sv = coin::value(&s);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, who);
    (sv, w)
}

/// Tickets are the fee paid on the SUI lost: 9% (creator 1 + buyback 3 + liquidity 2 + Wealth Fund 3)
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
        if (w != 0) { expected = expected + SUI1 * 9 / 100 };
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
    assert!(tickets == per * 24 * 9 / 100, 1);
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
        let (g, s) = game::claim_v3(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
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
    assert!(lost == amt * 24 * 9 / 100, 1); // together they lost only the 9% fee on 24 tiles
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

/// A house bot's mined GTS goes to its unrefined balance like any player's (v18): nothing is paid to
/// its wallet at the claim, and it runs the same 7-day clock and withdraw fee.
#[test]
fun test_bots_mine_like_players() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, HOUSE);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let (g, _) = play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(g == 0, 1);
    let (u, _) = game::unrefined_of(&board, HOUSE);
    assert!(u == GTS1, 2);
    let (start, _, fee) = game::withdraw_clock(&board, HOUSE, &clk);
    assert!(start == clock::timestamp_ms(&clk) && fee == 1_000, 3);
    let out = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&out) == GTS1 * 9 / 10, 4);
    coin::burn_for_testing(out);
    transfer::public_transfer(m, HOUSE);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Ticket ranges in order of claim: Bob [0, 216M), Alice [216M, 648M), Bob [648M, 864M).
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
    assert!(game::tickets_of(&board, BOB) == 432_000_000 && game::tickets_of(&board, ALICE) == 432_000_000, 1);
    assert!(game::ticket_holder_for_testing(&board, 0) == BOB, 2);
    assert!(game::ticket_holder_for_testing(&board, 215_999_999) == BOB, 3);
    assert!(game::ticket_holder_for_testing(&board, 216_000_000) == ALICE, 4);
    assert!(game::ticket_holder_for_testing(&board, 647_999_999) == ALICE, 5);
    assert!(game::ticket_holder_for_testing(&board, 648_000_000) == BOB, 6);
    assert!(game::ticket_holder_for_testing(&board, 863_999_999) == BOB, 7);
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
    // The whole fund. This round's own 3% share (0.0072 SUI) is under the 0.008 SUI draw reward, so all
    // of it went to the drawer.
    assert!(coin::value(&won) == fund, 2);
    assert!(game::motherlode_value(&board) < fund, 1);
    coin::burn_for_testing(won);
    assert!(alice_back < per * 25, 3); // no jackpot for the winning tile
    let (epoch, total) = game::wealth_tickets(&board);
    assert!(epoch == 1 && game::tickets_of(&board, BOB) == 0, 4);
    // Alice's tickets from the hitting round were claimed after the draw: they count for the next one.
    assert!(game::tickets_of(&board, ALICE) == per * 24 * 9 / 100 && total == per * 24 * 9 / 100, 5);
    assert!(game::pot_value(&board) == 0, 6);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

const DAY: u64 = 86_400_000;

/// Right after mining the withdraw fee is 10%: half is burned (supply falls) and half goes to everyone
/// still holding unrefined GTS (Alice); it falls linearly to 5% at 3.5 days and 0 at 7 days from the
/// player's own clock. The last holder to leave has nobody to share with.
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
    // Bob withdraws at once: ~10% fee, half burned, half to Alice.
    ts::next_tx(&mut sc, BOB);
    let supply0 = capped::total_supply(&treasury);
    let fee_now = { let (_, _, f) = game::withdraw_clock(&board, BOB, &clk); f };
    let gb = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    let fee = GTS1 * fee_now / 10_000;
    let shared = fee / 2;
    assert!(coin::value(&gb) == GTS1 - fee, 2);
    assert!(capped::total_supply(&treasury) == supply0 - (fee - shared), 3);
    let (a_amt, a_bonus) = game::unrefined_of(&board, ALICE);
    assert!(a_amt == GTS1 && a_bonus == shared, 4);
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
    assert!(coin::value(&ga) == GTS1 + shared, 7);
    assert!(capped::total_supply(&treasury) == supply1, 8);
    assert!(game::unrefined_total(&board) == 0, 9);
    coin::burn_for_testing(gb); coin::burn_for_testing(ga);
    transfer::public_transfer(mb, BOB); transfer::public_transfer(ma, ALICE);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The clock is weighted by amount: 1 GTS mined 4 days into a 1 GTS balance's clock leaves both with
/// the average, 2 days in (5 days left), not the old clock's 3 days left.
#[test]
fun test_withdraw_clock_weighted_by_amount() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut mb = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut mb, 100_000_000);
    let (s0, _, f0) = game::withdraw_clock(&board, BOB, &clk);
    assert!(s0 == clock::timestamp_ms(&clk) && f0 == 1_000, 1); // the first GTS starts its clock at the claim
    clock::set_for_testing(&mut clk, s0 + 4 * DAY - 62_000);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut mb, 100_000_000);
    let now = clock::timestamp_ms(&clk);
    assert!(now == s0 + 4 * DAY, 2);
    let (s1, _, f1) = game::withdraw_clock(&board, BOB, &clk);
    assert!(s1 == s0 + 2 * DAY, 3);              // (1 GTS x 4 days old + 1 GTS x new) / 2
    assert!(f1 == 1_000 * 5 / 7, 4);             // 5 of the 7 days left
    // Free 5 days later, for both.
    clock::set_for_testing(&mut clk, now + 5 * DAY);
    let g = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&g) == 2 * GTS1, 5);
    coin::burn_for_testing(g);
    transfer::public_transfer(mb, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Waiting out the 7 days with a small balance frees nothing mined later: old GTS counts as 7 days old
/// at most, so 1 GTS held for 30 days plus 1 new GTS is 3.5 days from free, and the new GTS pays its fee.
#[test]
fun test_withdraw_clock_old_balance_frees_nothing_new() {
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
    clock::set_for_testing(&mut clk, s0 + 30 * DAY);
    let (_, _, free) = game::withdraw_clock(&board, BOB, &clk);
    assert!(free == 0, 1);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut mb, 100_000_000);
    let now = clock::timestamp_ms(&clk);
    let (s1, _, f1) = game::withdraw_clock(&board, BOB, &clk);
    assert!(s1 == now - 7 * DAY / 2 && f1 == 500, 2);
    let g = game::withdraw_gts_v7(&mut board, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&g) == 2 * GTS1 - 2 * GTS1 * 5 / 100, 3); // 5% of the whole balance: nobody else holds, all burned
    // The withdrawal took everything: the next GTS starts a full 7 days.
    clock::set_for_testing(&mut clk, now + 3 * DAY);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut mb, 100_000_000);
    let (s2, _, f2) = game::withdraw_clock(&board, BOB, &clk);
    assert!(s2 == clock::timestamp_ms(&clk) && f2 == 1_000, 4);
    coin::burn_for_testing(g);
    transfer::public_transfer(mb, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The weighted start itself: 5 GTS with 3 days left plus 1 new GTS leaves 3.67 days for all 6; a large
/// new amount on a small old one is almost a new clock; nothing held starts now.
#[test]
fun test_blended_start() {
    let now = 100 * DAY;
    let s = game::blended_start_for_testing(now - 4 * DAY, 5 * GTS1, GTS1, now);
    assert!(s == now - 4 * DAY * 5 / 6, 1);
    assert!(s + 7 * DAY - now == 7 * DAY - 4 * DAY * 5 / 6, 2); // 3 days 16 hours left
    assert!(game::blended_start_for_testing(now - 50 * DAY, GTS1 / 1000, 1_000 * GTS1, now) > now - 1_000, 3);
    assert!(game::blended_start_for_testing(now - 50 * DAY, GTS1, GTS1, now) == now - 7 * DAY / 2, 4);
    assert!(game::blended_start_for_testing(now - DAY, 0, GTS1, now) == now, 5);
    assert!(game::blended_start_for_testing(0, GTS1, GTS1, now) == now, 6);
    assert!(game::blended_start_for_testing(now + 60_000, GTS1, GTS1, now) == now, 7); // a clock set a moment ahead counts as now
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
    game::set_params(&admin, &mut board, 500, 1_000, 0, 300, 500, 5_000_000, 90_000, 10_000, true);
    let (odds, share, vault, buyback, dev, refine, paused) = game::current_params(&board);
    assert!(odds == 500 && share == 1_000 && vault == 0 && buyback == 300 && dev == 100 && refine == 500 && paused, 1);
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
    game::set_params(&admin, &mut board, 1_000, 1_950, 1, 300, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// Each other fee has its own cap: no-winner Wealth Fund 30%, Wealth Fund odds at least 1 in 100.

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_no_winner_share_cap() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 1_000, 3_001, 0, 300, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

#[test, expected_failure(abort_code = game::EBadParams)]
fun test_odds_floor() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 99, 1_950, 0, 300, 1_000, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// The highest settings the caps allow are accepted.
#[test]
fun test_caps_at_limit() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 100, 3_000, 0, 300, 1_000, 10_000_000, 60_000, 5_000, false);
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

/// Buyback 3%: every losing pot saves 3% in the game (spent by the market draw, see market_tests).
#[test]
fun test_buyback_saved() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, SUI1);
    // 24 SUI lost: 3% = 0.72 SUI saved for the buyback, 2% = 0.48 SUI for liquidity.
    assert!(game::buyback_value(&board) == 720_000_000, 1);
    assert!(game::liquidity_value(&board) == 480_000_000 && game::liquidity_bps() == 200, 2);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Nobody can take the buyback SUI any more, the old keeper included: it is only spent inside the draw.
#[test, expected_failure(abort_code = game::EInDraw)]
fun test_buyback_take_closed() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, KEEPER);
    let mut board = ts::take_shared<Board>(&sc);
    let (c, _r) = game::buyback_take(&mut board, ts::ctx(&mut sc));
    coin::burn_for_testing(c);
    abort 0
}

/// Nor the liquidity SUI.
#[test, expected_failure(abort_code = game::EInDraw)]
fun test_liquidity_take_closed() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, KEEPER);
    let mut board = ts::take_shared<Board>(&sc);
    let (c, _r) = game::liquidity_take(&mut board, ts::ctx(&mut sc));
    coin::burn_for_testing(c);
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
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 300, 1_000, 10_000_000, 60_000, 5_000, true);
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
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 300, 1_000, 10_000_000, 60_000, 5_000, false);
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

/// The drawer is paid the round's whole draw share (3% of the losing pot in this test), however large.
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
    assert!(coin::value(&paid) == SUI1 * 3 / 100, 1);
    coin::burn_for_testing(paid);
    assert!(game::motherlode_value(&board) == SUI1 * 91 / 100, 3); // nobody was on the winning tile
    ts::next_tx(&mut sc, BOB);
    let (g, s) = game::claim_v3(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    assert!(game::pot_value(&board) == 0, 2);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// One round by BOB on every tile, drawn by ALICE with the plain draw at `t`. Returns what ALICE was paid.
fun plain_round(sc: &mut Scenario, board: &mut Board, treasury: &mut CappedTreasury<GTS>, rs: &Random, clk: &mut Clock, m: &mut Miner, t: u64): u64 {
    ts::next_tx(sc, BOB);
    clock::set_for_testing(clk, t - 61_000);
    game::deploy(board, m, coin::mint_for_testing<SUI>(25 * SUI1, ts::ctx(sc)), all_tiles(SUI1), clk, ts::ctx(sc));
    clock::set_for_testing(clk, t);
    ts::next_tx(sc, ALICE);
    game::settle_plain_for_testing(board, rs, clk, ts::ctx(sc));
    ts::next_tx(sc, ALICE);
    let paid = if (ts::has_most_recent_for_sender<coin::Coin<SUI>>(sc)) {
        let c = ts::take_from_sender<coin::Coin<SUI>>(sc);
        let v = coin::value(&c);
        coin::burn_for_testing(c);
        v
    } else { 0 };
    ts::next_tx(sc, BOB);
    let (g, s) = game::claim_v3(board, m, treasury, clk, ts::ctx(sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    paid
}

const HOUR: u64 = 3_600_000;

/// The plain draw (the fallback without the market step) pays the drawer nothing while the market works,
/// so nobody gains by picking it: the draw share goes to the Wealth Fund. After 6 hours without a usable
/// market it pays half the draw share (the other half to the Wealth Fund), so rounds keep being drawn.
#[test]
fun test_plain_draw_pays_only_after_six_hours() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    // The market's clock starts at the first draw.
    assert!(plain_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000) == 0, 1);
    assert!(game::motherlode_value(&board) == 24 * SUI1 * 3 / 100, 2);
    assert!(game::liquidity_value(&board) == 24 * SUI1 * 2 / 100 && game::buyback_value(&board) == 24 * SUI1 * 3 / 100, 3);
    let (alive, after, dead) = game::market_alive(&board);
    assert!(alive == 100_000 && after == 6 * HOUR && dead == 7 * 24 * HOUR, 4);
    // Exactly 6 hours later: still nothing.
    assert!(plain_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000 + 6 * HOUR) == 0, 5);
    // Past 6 hours (a round later): half the draw share, out of that share only.
    let fund = game::motherlode_value(&board);
    let half = 24 * SUI1 * 3 / 100 / 2;
    assert!(plain_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 162_000 + 6 * HOUR) == half, 6);
    assert!(game::motherlode_value(&board) == fund + half, 7);
    assert!(game::liquidity_value(&board) == 3 * 24 * SUI1 * 2 / 100 && game::buyback_value(&board) == 3 * 24 * SUI1 * 3 / 100, 8);
    let (pct_market, pct_plain) = game::draw_rewards();
    assert!(pct_market == 100 && pct_plain == 50, 9);
    assert!(game::pot_value(&board) == 0, 10);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// 7 days without a usable market: the SUI saved for the buyback and for liquidity moves to the Wealth
/// Fund, and so do those two shares of every round from then on. Nothing is left stuck in the game.
#[test]
fun test_dead_market_goes_to_wealth_fund() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let losing = 24 * SUI1;
    plain_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000);
    // Exactly 7 days later the shares are still saved.
    plain_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000 + 7 * 24 * HOUR);
    assert!(game::buyback_value(&board) == 2 * losing * 3 / 100 && game::liquidity_value(&board) == 2 * losing * 2 / 100, 1);
    let fund = game::motherlode_value(&board);
    // Past 7 days: everything saved (2 rounds x 5%) and this round's 5% go to the fund with its own 3%.
    let paid = plain_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 162_000 + 7 * 24 * HOUR);
    let half = losing * 3 / 100 / 2;
    assert!(paid == half, 2);
    assert!(game::buyback_value(&board) == 0 && game::liquidity_value(&board) == 0, 3);
    assert!(game::motherlode_value(&board) == fund + 2 * losing * 5 / 100 + losing * 8 / 100 - half, 4);
    // And the round after.
    let fund = game::motherlode_value(&board);
    plain_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 224_000 + 7 * 24 * HOUR);
    assert!(game::buyback_value(&board) == 0 && game::liquidity_value(&board) == 0, 5);
    assert!(game::motherlode_value(&board) == fund + losing * 8 / 100 - half, 6);
    assert!(game::pot_value(&board) == 0, 7);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A small round: the drawer's reward is the whole draw share and nothing else: the buyback
/// keeps its full 3% and liquidity its full 2%.
#[test]
fun test_draw_reward_from_fund_share_only() {
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
    // Losing pot is 0.05 SUI, or 0.04 when one of the five tiles won.
    let bb = game::buyback_value(&board);
    assert!(bb == 1_500_000 || bb == 1_200_000, 1);
    let losing = bb * 100 / 3;
    assert!(game::liquidity_value(&board) == losing * 2 / 100, 2);
    ts::next_tx(&mut sc, ALICE);
    let paid = ts::take_from_sender<coin::Coin<SUI>>(&sc);
    assert!(coin::value(&paid) == losing * 3 / 100, 3); // the whole draw share
    coin::burn_for_testing(paid);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

const CAROL: address = @0xCA501;

/// Staking set up: the draw share 3% (from `setup`), buyback 3%, liquidity 2%, stakers 3%.
fun setup_staking(sc: &mut Scenario) {
    setup(sc);
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 300, 1_000, 10_000_000, 60_000, 5_000, false);
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

/// A 7-day lock made while the lock was offered: earning 1.5x at once, its end queued.
fun old_lock_as(sc: &mut Scenario, who: address, amt: u64, now: u64) {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, now);
    game::old_lock_for_testing(&mut board, coin::mint_for_testing<gtstar::gts::GTS>(amt, ts::ctx(sc)), &clk, ts::ctx(sc));
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
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

/// Stakers share the stakers' 3% by the GTS they staked (once their hour of warm-up is over): 1 GTS and
/// 3 GTS get 25% and 75%.
#[test]
fun test_staking_yield_split() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    stake_as(&mut sc, BOB, 3 * GTS1, false, 1);
    carol_round(&mut sc, HOUR);
    let pot = 72_000_000; // 3% of 2.4 SUI
    assert!(claim_yield_as(&mut sc, ALICE) == pot / 4, 1);
    assert!(claim_yield_as(&mut sc, BOB) == pot * 3 / 4, 2);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let (amount, weight, paid, waiting) = game::staking_totals(&board);
    assert!(amount == 4 * GTS1 && weight == (40 * GTS1 as u128) && paid == pot && waiting == 0, 3);
    assert!(game::pot_value(&board) == 0, 4);
    ts::return_shared(board);
    ts::end(sc);
}

/// With nobody staked, the stakers' share goes to the Wealth Fund; the drawer is paid the draw share.
#[test]
fun test_no_stakers_to_fund() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    carol_round(&mut sc, 10);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let losing = 2_400_000_000;
    // The stakers' 3%; the draw share's 3% went to the drawer (Carol).
    assert!(game::motherlode_value(&board) == losing * 3 / 100, 1);
    assert!(game::buyback_value(&board) == losing * 3 / 100 && game::pot_value(&board) == 0, 2);
    assert!(game::liquidity_value(&board) == losing * 2 / 100, 4);
    ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The 7-day lock is closed: no new lock can be made.
#[test, expected_failure(abort_code = gtstar::staking::ENoLock)]
fun test_no_new_lock() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, BOB, GTS1, true, 1);
    abort 0
}

/// A lock made while the lock was offered can leave at any time, long before its 7 days are over, and
/// what its owner leaves staked counts 1x from then on.
#[test]
fun test_old_lock_can_leave_any_time() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    old_lock_as(&mut sc, BOB, 2 * GTS1, 1);
    assert!(totals_weight(&mut sc) == (30 * GTS1 as u128), 1);
    assert!(unstake_as(&mut sc, BOB, GTS1, true, HOUR) == GTS1, 2);
    assert!(totals_weight(&mut sc) == (10 * GTS1 as u128), 3);
    assert!(unstake_as(&mut sc, BOB, GTS1, true, 2 * HOUR) == GTS1, 4);
    assert!(totals_weight(&mut sc) == 0, 5);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let (amount, _, _, _) = game::staking_totals(&board);
    assert!(amount == 0, 6);
    ts::return_shared(board);
    ts::end(sc);
}

fun totals_weight(sc: &mut Scenario): u128 {
    ts::next_tx(sc, OWNER);
    let board = ts::take_shared<Board>(sc);
    let (_, weight, _, _) = game::staking_totals(&board);
    ts::return_shared(board);
    weight
}

fun unstake_as(sc: &mut Scenario, who: address, amt: u64, locked: bool, now: u64): u64 {
    ts::next_tx(sc, who);
    let mut board = ts::take_shared<Board>(sc);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, now);
    let g = game::unstake(&mut board, amt, locked, &clk, ts::ctx(sc));
    let v = coin::value(&g);
    coin::burn_for_testing(g);
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
    v
}

/// An old lock that nobody touches: the first draw after its 7 days drops it to 1x by itself, and the
/// GTS can leave.
#[test]
fun test_old_lock_ends_in_the_draw() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    old_lock_as(&mut sc, BOB, GTS1, 1);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    carol_round(&mut sc, HOUR);
    assert!(totals_weight(&mut sc) == (25 * GTS1 as u128), 1);
    let week = 7 * 86_400_000 + 2;
    carol_round(&mut sc, week);
    assert!(totals_weight(&mut sc) == (20 * GTS1 as u128), 3);
    claim_yield_as(&mut sc, ALICE); claim_yield_as(&mut sc, BOB);
    carol_round(&mut sc, week + 200_000);
    assert!(claim_yield_as(&mut sc, ALICE) == claim_yield_as(&mut sc, BOB), 4);
    assert!(unstake_as(&mut sc, BOB, GTS1, true, week + 400_000) == GTS1, 5);
    ts::end(sc);
}

/// `poke` drops an old lock to 1x at once, whatever time is left on it (anyone may call it).
#[test]
fun test_poke_ends_old_lock() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    old_lock_as(&mut sc, BOB, GTS1, 1);
    assert!(totals_weight(&mut sc) == (15 * GTS1 as u128), 1);
    ts::next_tx(&mut sc, CAROL);
    let mut board = ts::take_shared<Board>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, HOUR);
    game::poke(&mut board, BOB, &clk);
    let (amount, weight, _, _) = game::staking_totals(&board);
    assert!(amount == GTS1 && weight == (10 * GTS1 as u128), 2);
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
    ts::end(sc);
}

/// New stake earns nothing for its first hour: staking just before a round and leaving right after it
/// gets none of that round. The stake that was already earning gets all of it.
#[test]
fun test_stake_warms_up_for_an_hour() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    carol_round(&mut sc, HOUR); // Alice is earning from here on
    let pot = 72_000_000;
    assert!(claim_yield_as(&mut sc, ALICE) == pot, 1);
    // Bob stakes 100 times more a moment before the next round, and leaves right after it.
    let t = 2 * HOUR;
    stake_as(&mut sc, BOB, 100 * GTS1, false, t);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let (warming, at) = game::staking_warming(&board, BOB, false);
    assert!(warming == 100 * GTS1 && at == t + HOUR, 2);
    let (amount, weight, _, _) = game::staking_totals(&board);
    assert!(amount == 101 * GTS1 && weight == (10 * GTS1 as u128), 3); // only Alice's GTS has weight
    ts::return_shared(board);
    carol_round(&mut sc, t);
    assert!(unstake_as(&mut sc, BOB, 100 * GTS1, false, t + 100_000) == 100 * GTS1, 4);
    assert!(claim_yield_as(&mut sc, BOB) == 0, 5);
    assert!(claim_yield_as(&mut sc, ALICE) == pot, 6);
    ts::end(sc);
}

/// After the hour the draw starts the new stake earning by itself.
#[test]
fun test_warm_up_ends_in_the_draw() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    stake_as(&mut sc, BOB, GTS1, false, 1);
    // 59 minutes in: nobody earns yet, so the stakers' share goes to the Wealth Fund.
    carol_round(&mut sc, 59 * 60_000 - 62_000);
    assert!(totals_weight(&mut sc) == 0, 1);
    assert!(claim_yield_as(&mut sc, ALICE) == 0 && claim_yield_as(&mut sc, BOB) == 0, 2);
    // Past the hour: both earn the same.
    carol_round(&mut sc, HOUR);
    assert!(totals_weight(&mut sc) == (20 * GTS1 as u128), 3);
    let pot = 72_000_000;
    assert!(claim_yield_as(&mut sc, ALICE) == pot / 2 && claim_yield_as(&mut sc, BOB) == pot / 2, 4);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let (warming, _) = game::staking_warming(&board, ALICE, false);
    let (warm_q, lock_q) = game::staking_queued(&board);
    assert!(warming == 0 && warm_q == 0 && lock_q == 0, 5);
    let (warm_ms, lock_ms) = game::staking_times();
    assert!(warm_ms == HOUR && lock_ms == 7 * 24 * HOUR, 6);
    ts::return_shared(board);
    ts::end(sc);
}

/// Staking more does not stop what already earns: only the new part warms up, and leaving takes the
/// warming part first.
#[test]
fun test_adding_stake_keeps_the_earning_part() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    carol_round(&mut sc, HOUR);
    let pot = 72_000_000;
    assert!(claim_yield_as(&mut sc, ALICE) == pot, 1);
    let t = 2 * HOUR;
    stake_as(&mut sc, ALICE, 3 * GTS1, false, t);
    assert!(totals_weight(&mut sc) == (10 * GTS1 as u128), 2); // still 1 GTS earning
    carol_round(&mut sc, t);
    assert!(claim_yield_as(&mut sc, ALICE) == pot, 3);
    // Taking 2 GTS out comes from the 3 warming: 1 earning, 1 warming left.
    assert!(unstake_as(&mut sc, ALICE, 2 * GTS1, false, t + 200_000) == 2 * GTS1, 4);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let (warming, _) = game::staking_warming(&board, ALICE, false);
    let (amount, weight, _, _) = game::staking_totals(&board);
    assert!(warming == GTS1 && amount == 2 * GTS1 && weight == (10 * GTS1 as u128), 5);
    ts::return_shared(board);
    // An hour after the second stake both earn.
    carol_round(&mut sc, t + HOUR);
    assert!(totals_weight(&mut sc) == (20 * GTS1 as u128), 6);
    ts::end(sc);
}

/// `queue_lock` (for locks made before the queue existed) queues only an old lock that still earns 1.5x
/// and fits the queue's order.
#[test]
fun test_queue_lock() {
    let mut sc = ts::begin(@0x0);
    setup_staking(&mut sc);
    old_lock_as(&mut sc, BOB, GTS1, 1);
    stake_as(&mut sc, ALICE, GTS1, false, 1);
    carol_round(&mut sc, HOUR);
    ts::next_tx(&mut sc, CAROL);
    let mut board = ts::take_shared<Board>(&sc);
    assert!(!game::queue_lock(&mut board, ALICE, ts::ctx(&mut sc)), 1); // no lock
    assert!(!game::queue_lock(&mut board, CAROL, ts::ctx(&mut sc)), 2); // no stake
    assert!(game::queue_lock(&mut board, BOB, ts::ctx(&mut sc)), 3);    // a second entry for the same lock is harmless
    let (_, lock_q) = game::staking_queued(&board);
    assert!(lock_q == 2, 4);
    ts::return_shared(board);
    // Both entries are worked off by the draw after the lock ends; the weight drops once.
    carol_round(&mut sc, 7 * 86_400_000 + 2);
    assert!(totals_weight(&mut sc) == (20 * GTS1 as u128), 5);
    ts::next_tx(&mut sc, OWNER);
    let board = ts::take_shared<Board>(&sc);
    let (_, lock_q) = game::staking_queued(&board);
    assert!(lock_q == 0, 6);
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

/// The draw share at 2%. A round with a winner (all tiles covered) pays all of it to the drawer and adds
/// nothing to the Wealth Fund, and the player's tickets equal the 8% fee paid (creator 1 + buyback 3 +
/// liquidity 2 + draw share 2).
#[test]
fun test_fund_share_every_round() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    game::set_params(&admin, &mut board, 100, 1_950, 0, 300, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_fund_bps(&admin, &mut board, 200);
    assert!(game::wealth_fund_bps(&board) == 200, 1);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let per = 100_000_000;
    round_as(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, all_tiles(per), 1_000_000);
    let losing = per * 24;
    assert!(game::motherlode_value(&board) == 0, 2);
    assert!(game::buyback_value(&board) == losing * 3 / 100 && game::liquidity_value(&board) == losing * 2 / 100, 3);
    assert!(game::dev_fees_value(&board) == losing / 100, 4);
    assert!(game::tickets_of(&board, BOB) == losing * 8 / 100, 5);
    assert!(game::pot_value(&board) == 0, 7);
    ts::return_to_address(OWNER, admin);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// A round with no winner: after creator 1%, buyback 3%, liquidity 2% and the drawer's 2%, the whole
/// rest goes to the Wealth Fund.
#[test]
fun test_fund_share_no_winner() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    game::set_params(&admin, &mut board, 100, 1_950, 0, 300, 1_000, 10_000_000, 60_000, 5_000, false);
    game::set_fund_bps(&admin, &mut board, 200);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut done = false;
    while (!done) {
        let before = game::motherlode_value(&board);
        let (_, w) = round_as_w(&mut sc, BOB, &mut board, &mut treasury, &rs, &mut clk, one_tile(0, SUI1), 1_000_000);
        if (w != 0) {
            assert!(game::motherlode_value(&board) - before == SUI1 * 92 / 100, 1);
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
    // The draw share is capped at 10%.
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
    let (g, s) = game::claim_v3(&mut board, &mut mb, &mut treasury, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    ts::next_tx(&mut sc, ALICE);
    let (g, s) = game::claim_v3(&mut board, &mut ma, &mut treasury, &clk, ts::ctx(&mut sc));
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
    let share = losing * 91 / 100;
    ts::next_tx(&mut sc, BOB);
    let (g, s) = game::claim_v3(&mut board, &mut bob, &mut treasury, &clk, ts::ctx(&mut sc));
    let mut paid = coin::value(&s);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(bob, BOB);
    w = 4;
    while (!vector::is_empty(&others)) {
        let mut m = vector::pop_back(&mut others);
        let who = sui::address::from_u256((0x7000 + w) as u256);
        ts::next_tx(&mut sc, who);
        let (g, s) = game::claim_v3(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
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

/// The emission is fixed: `set_emission` is closed, even to the AdminCap, even for a lower reward.
#[test, expected_failure(abort_code = game::EFinal)]
fun test_emission_cannot_change() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_emission(&admin, &mut board, GTS1 / 2, 15_658, 500_000, 0, SUI1);
    abort 0
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
    let (g, s) = game::claim_v3(&mut board, &mut mb, &mut treasury, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    assert!(game::round_info_exists_for_testing(&board, round), 2);
    ts::next_tx(&mut sc, ALICE);
    let (g, s) = game::claim_v3(&mut board, &mut ma, &mut treasury, &clk, ts::ctx(&mut sc));
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
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 300, 1_000, 500_000, 60_000, 5_000, false);
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
    game::set_params(&admin, &mut board, 1_000, 1_950, 0, 300, 1_000, 499_999, 60_000, 5_000, false);
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

/// The daily mint limit: 2,000 GTS per UTC day, then minting aborts until the next UTC day.
#[test]
fun test_daily_mint_limit() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 5 * 86_400_000 + 1);
    let (room, per_day) = game::mint_room_today(&board, &clk);
    assert!(room == 2_000 * GTS1 && per_day == 2_000 * GTS1, 1);
    let a = game::mint_for_testing(&mut board, &mut treasury, 2_000 * GTS1, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&a) == 2_000 * GTS1, 2);
    let (room, _) = game::mint_room_today(&board, &clk);
    assert!(room == 0, 3);
    clock::set_for_testing(&mut clk, 6 * 86_400_000);
    let (room, _) = game::mint_room_today(&board, &clk);
    assert!(room == 2_000 * GTS1, 4);
    let b = game::mint_for_testing(&mut board, &mut treasury, GTS1, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&b) == GTS1 && capped::minted(&treasury) == 2_001 * GTS1, 5);
    coin::burn_for_testing(a); coin::burn_for_testing(b);
    clock::destroy_for_testing(clk);
    ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Past the day's limit, minting aborts (the claim can be retried the next UTC day).
#[test, expected_failure(abort_code = mint_limit::daily::EDailyLimit)]
fun test_daily_mint_limit_aborts() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let a = game::mint_for_testing(&mut board, &mut treasury, 2_000 * GTS1, &clk, ts::ctx(&mut sc));
    let b = game::mint_for_testing(&mut board, &mut treasury, 1, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(a); coin::burn_for_testing(b);
    abort 0
}

/// With the day's mint limit full a claim still pays its SUI: the GTS is owed, and minted to the player's
/// unrefined balance the next UTC day when they call `claim_owed`.
#[test]
fun test_claim_past_daily_limit_owes_gts() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 5 * 86_400_000);
    // Today's whole limit is used up but for 0.4 GTS.
    coin::burn_for_testing(game::mint_for_testing(&mut board, &mut treasury, 2_000 * GTS1 - 400_000_000, &clk, ts::ctx(&mut sc)));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let (g, s) = play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(g == 0 && s == 100_000_000 + 2_400_000_000 * 91 / 100, 1); // the SUI is paid in full
    let (u, _) = game::unrefined_of(&board, BOB);
    assert!(u == 400_000_000 && game::owed_of(&board, BOB) == 600_000_000, 2); // 0.4 GTS fit, 0.6 GTS owed
    let (room, _) = game::mint_room_today(&board, &clk);
    assert!(room == 0, 3);
    // Same day: nothing to mint yet, and a second round is owed in full.
    game::claim_owed(&mut board, &mut treasury, BOB, &clk, ts::ctx(&mut sc));
    assert!(game::owed_of(&board, BOB) == 600_000_000, 4);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::owed_of(&board, BOB) == 1_600_000_000, 5);
    // Next UTC day: Bob mints it, into his unrefined balance.
    clock::set_for_testing(&mut clk, 6 * 86_400_000 + 1);
    ts::next_tx(&mut sc, BOB);
    game::claim_owed(&mut board, &mut treasury, BOB, &clk, ts::ctx(&mut sc));
    let (u, _) = game::unrefined_of(&board, BOB);
    assert!(u == 2 * GTS1 && game::owed_of(&board, BOB) == 0, 6);
    assert!(capped::minted(&treasury) == 2_000 * GTS1 - 400_000_000 + 2 * GTS1, 8);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// Nobody else can mint a player's owed GTS: it would move that player's withdraw clock.
#[test, expected_failure(abort_code = game::ENotYours)]
fun test_claim_owed_only_by_the_player() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, ALICE);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    game::claim_owed(&mut board, &mut treasury, BOB, &clk, ts::ctx(&mut sc));
    abort 0
}

/// Owed GTS is minted first by the player's next claim once there is room, then that round's GTS.
#[test]
fun test_owed_gts_paid_by_next_claim() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 5 * 86_400_000);
    coin::burn_for_testing(game::mint_for_testing(&mut board, &mut treasury, 2_000 * GTS1, &clk, ts::ctx(&mut sc)));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    assert!(game::owed_of(&board, BOB) == GTS1 && game::unrefined_total(&board) == 0, 1);
    clock::set_for_testing(&mut clk, 6 * 86_400_000);
    play_round(&mut sc, &mut board, &mut treasury, &rs, &mut clk, &mut m, 100_000_000);
    let (u, _) = game::unrefined_of(&board, BOB);
    assert!(u == 2 * GTS1 && game::owed_of(&board, BOB) == 0, 2);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    ts::end(sc);
}

/// The old claim without the clock is closed from v16.
#[test, expected_failure(abort_code = game::EUseClaimV3)]
fun test_claim_v2_closed() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let (g, s) = game::claim_v2(&mut board, &mut m, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    abort 0
}

/// The final split, as set on mainnet: of the losing pot, creator 1%, buyback and burn 3%, liquidity 2%,
/// stakers 3%, whoever draws the round 1%, and 90% to the winners. Nothing goes to the Wealth Fund in a
/// round with a winner, and every mist is accounted for.
#[test]
fun test_final_split() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let admin = ts::take_from_sender<AdminCap>(&sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&admin, &mut board, 250, 1_950, 0, 300, 1_000, 500_000, 60_000, 5_000, false);
    game::set_staking(&admin, &mut board, 300, ts::ctx(&mut sc));
    game::set_fund_bps(&admin, &mut board, 100);
    // The settings are final once the AdminCap is destroyed.
    game::renounce(admin, &board);
    ts::return_shared(board);
    stake_as(&mut sc, ALICE, GTS1, false, 1);

    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    let per = 100_000_000;
    clock::set_for_testing(&mut clk, HOUR);
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(per * 25, ts::ctx(&mut sc)), all_tiles(per), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, HOUR + 61_000);
    ts::next_tx(&mut sc, CAROL);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &rs, &clk, 1_000_000, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, CAROL);
    let losing = per * 24;
    let paid = ts::take_from_sender<coin::Coin<SUI>>(&sc);
    assert!(coin::value(&paid) == losing / 100, 1);
    coin::burn_for_testing(paid);
    ts::next_tx(&mut sc, BOB);
    let (g, s) = game::claim_v3(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&s) == per + losing * 90 / 100, 2);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    assert!(game::dev_fees_value(&board) == losing / 100, 3);
    assert!(game::buyback_value(&board) == losing * 3 / 100 && game::liquidity_value(&board) == losing * 2 / 100, 4);
    let (_, _, staked_paid, waiting) = game::staking_totals(&board);
    assert!(staked_paid == losing * 3 / 100 && waiting == losing * 3 / 100, 5);
    assert!(game::motherlode_value(&board) == 0 && game::pot_value(&board) == 0, 6);
    assert!(game::tickets_of(&board, BOB) == losing * 10 / 100, 7);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    assert!(claim_yield_as(&mut sc, ALICE) == losing * 3 / 100, 8);
    ts::end(sc);
}
