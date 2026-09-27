#[test_only]
module gtstar::gtstar_tests;

use sui::test_scenario::{Self as ts};
use sui::coin;
use sui::sui::SUI;
use sui::balance;
use sui::clock;
use gts_token::gts::{Self, Treasury, GTS, MinterCap};
use gtstar::staking::{Self, StakePool};
use gtstar::game::{Self, Board};
use sui::random::{Self, Random};

const ADMIN: address = @0xA11CE;
const BOB: address = @0xB0B;
const ALICE: address = @0xA1;

/// Full round: deploy on every square, settle with on-chain randomness, claim.
/// Pot accounting must balance exactly: winnings + fees == deposits.
#[test]
fun test_full_round_accounting() {
    let mut sc = ts::begin(@0x0);
    random::create_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, @0x0);
    let mut rs = ts::take_shared<Random>(&sc);
    random::update_randomness_state_for_testing(&mut rs, 0, x"1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F1F", ts::ctx(&mut sc));
    ts::return_shared(rs);

    ts::next_tx(&mut sc, ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    staking::init_for_testing(ts::ctx(&mut sc));
    game::init_for_testing(ts::ctx(&mut sc));
    install_game(&mut sc);
    ts::next_tx(&mut sc, BOB);

    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);

    let per = 100_000_000; // 0.1 SUI per square
    let mut amounts = vector[];
    let mut i = 0;
    while (i < 25) { vector::push_back(&mut amounts, per); i = i + 1; };
    let mut miner = game::new_miner(ts::ctx(&mut sc));
    let pay = coin::mint_for_testing<SUI>(per * 25, ts::ctx(&mut sc));
    game::deploy(&mut board, &mut miner, pay, amounts, &clk, ts::ctx(&mut sc));

    clock::set_for_testing(&mut clk, 1_000 + 60_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));

    let (g, s) = game::claim(&mut board, &mut miner, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(mined(&board, &g) == 1_000_000_000, 0); // whole miner reward (only player)
    let losing = per * 24;
    let fees = losing * 4 / 100 + losing / 100;
    let share = losing - fees;   // the only winner
    let kept = share / 25;       // 0.1 of the 2.5 SUI deposited was on the winning tile
    assert!(coin::value(&s) == per + kept, 1);
    assert!(gts::vault_value(&treasury) == losing * 4 / 100 + (share - kept), 2);
    assert!(staking::total_rewards_for_testing(&pool) == 100_000_000, 5); // +10% to stakers
    assert!(game::dev_fees_value(&board) == losing / 100, 3);
    assert!(game::pot_value(&board) == 0, 4);

    coin::burn_for_testing(g);
    coin::burn_for_testing(s);
    transfer::public_transfer(miner, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs);
    ts::return_shared(board);
    ts::return_shared(treasury);
    ts::return_shared(pool);
    ts::end(sc);
}

#[test_only]
fun setup_round(sc: &mut ts::Scenario) {
    random::create_for_testing(ts::ctx(sc));
    ts::next_tx(sc, @0x0);
    let mut rs = ts::take_shared<Random>(sc);
    random::update_randomness_state_for_testing(&mut rs, 0, x"0A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20212223242526272829", ts::ctx(sc));
    ts::return_shared(rs);
    ts::next_tx(sc, ADMIN);
    gts::init_for_testing(ts::ctx(sc));
    staking::init_for_testing(ts::ctx(sc));
    game::init_for_testing(ts::ctx(sc));
    install_game(sc);
}

#[test_only]
fun install_game(sc: &mut ts::Scenario) {
    ts::next_tx(sc, ADMIN);
    let mut board = ts::take_shared<Board>(sc);
    let mut treasury = ts::take_shared<Treasury>(sc);
    let cap = ts::take_from_sender<MinterCap>(sc);
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, 1);
    game::install(&mut board, cap, &mut treasury, &clk);
    clock::destroy_for_testing(clk);
    ts::return_shared(board);
    ts::return_shared(treasury);
}

#[test_only]
fun one_tile(i: u64, amt: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0;
    while (k < 25) { vector::push_back(&mut v, if (k == i) { amt } else { 0 }); k = k + 1; };
    v
}

/// Two players, uneven stakes: the pot never pays out more than was deposited,
/// GTS emission never exceeds the round reward, and a second claim is rejected.
#[test]
fun test_two_players_solvency() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);

    let mut a = game::new_miner(ts::ctx(&mut sc));
    let mut b = game::new_miner(ts::ctx(&mut sc));
    let mut all = vector[];
    let mut k = 0;
    while (k < 25) { vector::push_back(&mut all, 33_333_333); k = k + 1; };
    game::deploy(&mut board, &mut a, coin::mint_for_testing<SUI>(33_333_333 * 25, ts::ctx(&mut sc)), all, &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ALICE);
    game::deploy(&mut board, &mut b, coin::mint_for_testing<SUI>(777_777_777, ts::ctx(&mut sc)), one_tile(3, 777_777_777), &clk, ts::ctx(&mut sc));
    let deposits = 33_333_333 * 25 + 777_777_777;

    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));

    let (ga, sa) = game::claim(&mut board, &mut a, &mut treasury, &clk, ts::ctx(&mut sc));
    let (gb, sb) = game::claim(&mut board, &mut b, &mut treasury, &clk, ts::ctx(&mut sc));
    let paid = coin::value(&sa) + coin::value(&sb) + gts::vault_value(&treasury)
        + game::dev_fees_value(&board);
    assert!(paid + game::pot_value(&board) == deposits, 0);   // exact conservation
    assert!(game::pot_value(&board) <= 2, 1);                  // only rounding dust stays
    let minted = mined(&board, &ga) + coin::value(&gb);
    assert!(minted <= 1_000_000_000 && minted >= 1_000_000_000 - 2, 2);

    coin::burn_for_testing(ga); coin::burn_for_testing(sa);
    coin::burn_for_testing(gb); coin::burn_for_testing(sb);
    transfer::public_transfer(a, BOB); transfer::public_transfer(b, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// Claiming the same round twice is rejected.
#[test, expected_failure(abort_code = gtstar::game::ENothingToClaim)]
fun test_double_claim_rejected() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    let (g1, s1) = game::claim(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    let (g2, s2) = game::claim(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(g1); coin::burn_for_testing(s1); coin::burn_for_testing(g2); coin::burn_for_testing(s2);
    abort 0
}

/// Deposits are rejected inside the 5-second freeze window.
#[test, expected_failure(abort_code = gtstar::game::EFrozen)]
fun test_freeze_window() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000 + 57_000);
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(1, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// Payment must equal the sum of tile amounts.
#[test, expected_failure(abort_code = gtstar::game::EAmountMismatch)]
fun test_payment_mismatch() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(5_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// Deposits below the per-tile minimum are rejected.
#[test, expected_failure(abort_code = gtstar::game::EBelowMin)]
fun test_below_min() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(1_000_000, ts::ctx(&mut sc)), one_tile(0, 1_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// Settling before the round ends is rejected.
#[test, expected_failure(abort_code = gtstar::game::ERoundNotEnded)]
fun test_early_settle() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    abort 0
}

const DAY: u64 = 86_400_000;

/// Rewards stream linearly over 7 days; a sole staker earns ~1/7 per day, all of it after 7 days.
#[test]
fun test_staking_stream() {
    let mut sc = ts::begin(ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    staking::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);

    let mut pos = staking::new_position(ts::ctx(&mut sc));
    staking::stake(&mut pool, &mut pos, coin::mint_for_testing<GTS>(100_000_000_000, ts::ctx(&mut sc)), &clk, ts::ctx(&mut sc));
    staking::add_rewards_for_testing(&mut pool, balance::create_for_testing<GTS>(7_000_000_000), &clk);

    clock::increment_for_testing(&mut clk, DAY);
    let r1 = staking::claim_rewards(&mut pool, &mut pos, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&r1) >= 999_000_000 && coin::value(&r1) <= 1_000_000_000, 0);
    clock::increment_for_testing(&mut clk, 10 * DAY);
    let r2 = staking::claim_rewards(&mut pool, &mut pos, &clk, ts::ctx(&mut sc));
    let total = coin::value(&r1) + coin::value(&r2);
    assert!(total <= 7_000_000_000 && total >= 6_999_000_000, 1);
    assert!(staking::total_rewards_for_testing(&pool) == 7_000_000_000 - total, 2);

    let g = staking::unstake(&mut pool, &mut pos, 100_000_000_000, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&g) == 100_000_000_000, 3);
    coin::burn_for_testing(r1); coin::burn_for_testing(r2); coin::burn_for_testing(g);
    staking::close_position(pos);
    clock::destroy_for_testing(clk);
    ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// Staking right before fees arrive and leaving right after earns almost nothing.
#[test]
fun test_jit_staking_earns_nothing() {
    let mut sc = ts::begin(ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    staking::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);

    let mut honest = staking::new_position(ts::ctx(&mut sc));
    staking::stake(&mut pool, &mut honest, coin::mint_for_testing<GTS>(10_000_000_000, ts::ctx(&mut sc)), &clk, ts::ctx(&mut sc));
    clock::increment_for_testing(&mut clk, DAY);

    let mut jit = staking::new_position(ts::ctx(&mut sc));
    staking::stake(&mut pool, &mut jit, coin::mint_for_testing<GTS>(1_000_000_000_000, ts::ctx(&mut sc)), &clk, ts::ctx(&mut sc));
    staking::add_rewards_for_testing(&mut pool, balance::create_for_testing<GTS>(7_000_000_000), &clk);
    clock::increment_for_testing(&mut clk, 1_000);
    let g = staking::unstake(&mut pool, &mut jit, 1_000_000_000_000, &clk, ts::ctx(&mut sc));
    let r = staking::claim_rewards(&mut pool, &mut jit, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&r) < 12_000, 0);

    coin::burn_for_testing(g); coin::burn_for_testing(r);
    transfer::public_transfer(honest, ADMIN); staking::close_position(jit);
    clock::destroy_for_testing(clk);
    ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// Fees that arrive while nobody is staked are paused, not lost.
#[test]
fun test_stream_pauses_when_empty() {
    let mut sc = ts::begin(ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    staking::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);

    staking::add_rewards_for_testing(&mut pool, balance::create_for_testing<GTS>(7_000_000_000), &clk);
    clock::increment_for_testing(&mut clk, 30 * DAY);
    let mut pos = staking::new_position(ts::ctx(&mut sc));
    staking::stake(&mut pool, &mut pos, coin::mint_for_testing<GTS>(5_000_000_000, ts::ctx(&mut sc)), &clk, ts::ctx(&mut sc));
    clock::increment_for_testing(&mut clk, 8 * DAY);
    let r = staking::claim_rewards(&mut pool, &mut pos, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&r) >= 6_999_000_000 && coin::value(&r) <= 7_000_000_000, 0);

    coin::burn_for_testing(r);
    transfer::public_transfer(pos, ADMIN);
    clock::destroy_for_testing(clk);
    ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// Two stakers split the stream by stake size.
#[test]
fun test_two_stakers_split() {
    let mut sc = ts::begin(ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    staking::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut a = staking::new_position(ts::ctx(&mut sc));
    let mut b = staking::new_position(ts::ctx(&mut sc));
    staking::stake(&mut pool, &mut a, coin::mint_for_testing<GTS>(30_000_000_000, ts::ctx(&mut sc)), &clk, ts::ctx(&mut sc));
    staking::stake(&mut pool, &mut b, coin::mint_for_testing<GTS>(10_000_000_000, ts::ctx(&mut sc)), &clk, ts::ctx(&mut sc));
    staking::add_rewards_for_testing(&mut pool, balance::create_for_testing<GTS>(4_000_000_000), &clk);
    clock::increment_for_testing(&mut clk, 7 * DAY);
    let ra = staking::claim_rewards(&mut pool, &mut a, &clk, ts::ctx(&mut sc));
    let rb = staking::claim_rewards(&mut pool, &mut b, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&ra) >= 2_999_000_000 && coin::value(&ra) <= 3_000_000_000, 0);
    assert!(coin::value(&rb) >= 999_000_000 && coin::value(&rb) <= 1_000_000_000, 1);
    coin::burn_for_testing(ra); coin::burn_for_testing(rb);
    transfer::public_transfer(a, ADMIN); transfer::public_transfer(b, ADMIN);
    clock::destroy_for_testing(clk);
    ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// Cannot withdraw more than staked.
#[test, expected_failure(abort_code = gtstar::staking::EInsufficientStake)]
fun test_overdraw_rejected() {
    let mut sc = ts::begin(ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    staking::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut pos = staking::new_position(ts::ctx(&mut sc));
    staking::stake(&mut pool, &mut pos, coin::mint_for_testing<GTS>(1_000_000_000, ts::ctx(&mut sc)), &clk, ts::ctx(&mut sc));
    let g = staking::unstake(&mut pool, &mut pos, 2_000_000_000, &clk, ts::ctx(&mut sc));
    coin::burn_for_testing(g);
    abort 0
}

/// Emission halves every 262,000 rounds, for 7 periods, whatever the calendar says.
#[test]
fun test_emission_schedule() {
    let h = 262_000;
    assert!(game::reward_for_round_for_testing(0) == 0, 0);
    assert!(game::reward_for_round_for_testing(1) == 1_000_000_000, 1);
    assert!(game::reward_for_round_for_testing(h) == 1_000_000_000, 2);
    assert!(game::reward_for_round_for_testing(h + 1) == 500_000_000, 3);
    assert!(game::reward_for_round_for_testing(6 * h + 1) == 1_000_000_000 >> 6, 4);
    assert!(game::reward_for_round_for_testing(7 * h) == 1_000_000_000 >> 6, 5);
    assert!(game::reward_for_round_for_testing(7 * h + 1) == 0, 6);
    // Every round played: miners + 10% stakers stays below the token's final ceiling (572,003.2 GTS).
    let mut total: u128 = 0;
    let mut e = 0;
    while (e < 7) {
        let r = (game::reward_for_round_for_testing(e * h + 1) as u128);
        total = total + (r + r / 10) * (h as u128);
        e = e + 1;
    };
    assert!(total == 571_896_875_000_000, 7);
    assert!(total <= 572_003_236_678_098, 8);
}

/// Rounds last at least a minute, so round-based emission never outruns the token's time ceiling.
#[test]
fun test_emission_within_token_ceiling() {
    let mut sc = ts::begin(ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_790_000_000_000);
    let cap = gts::minter_for_testing(ts::ctx(&mut sc));
    gts::start(&mut treasury, &cap, &clk);
    let g = 1_790_000_000_000;
    // At every point, n rounds need >= n minutes: compare cumulative round emission with allowance.
    let mut n = 0;
    let mut cum: u128 = 0;
    while (n < 7 * 262_000) {
        let step = 1_000;
        let r = (game::reward_for_round_for_testing(n + 1) as u128);
        cum = cum + (r + r / 10) * (step as u128);
        n = n + step;
        assert!(cum <= (gts::allowance(&treasury, g + n * 60_000) as u128), n);
    };
    transfer::public_transfer(cap, ADMIN);
    clock::destroy_for_testing(clk);
    ts::return_shared(treasury);
    ts::end(sc);
}

/// The game cannot run before it is installed with the minting right.
#[test, expected_failure(abort_code = gtstar::game::ENotInstalled)]
fun test_deploy_requires_install() {
    let mut sc = ts::begin(ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    game::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// Install happens exactly once.
#[test, expected_failure(abort_code = gtstar::game::EAlreadyInstalled)]
fun test_install_once() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, ADMIN);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let fake = gts::minter_for_testing(ts::ctx(&mut sc));
    game::install(&mut board, fake, &mut treasury, &clk);
    abort 0
}

// ===== Motherlode =====

const HOUSE: address = @0x4a6e7d021beb465ce1a68ffe45d6e18cd30f6aea45560364a8c59bcdd497458a;

#[test_only]
fun all_tiles(amt: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0;
    while (k < 25) { vector::push_back(&mut v, amt); k = k + 1; };
    v
}

/// Play single-tile rounds (never a hit) until one loses, so the Motherlode holds SUI.
/// Returns the next free clock time.
#[test_only]
fun fill_motherlode(
    board: &mut Board, treasury: &mut Treasury, pool: &mut StakePool, rs: &Random,
    clk: &mut clock::Clock, amt: u64, sc: &mut ts::Scenario,
): u64 {
    let mut t = 1_000;
    let mut guard = 0;
    while (game::motherlode_value(board) == 0 && guard < 60) {
        clock::set_for_testing(clk, t);
        let mut m = game::new_miner(ts::ctx(sc));
        game::deploy(board, &mut m, coin::mint_for_testing<SUI>(amt, ts::ctx(sc)), one_tile(0, amt), clk, ts::ctx(sc));
        clock::set_for_testing(clk, t + 60_000);
        let vault_before = gts::vault_value(treasury);
        game::settle_with_odds_for_testing(board, treasury, pool, rs, clk, 1_000_000_000, ts::ctx(sc));
        let (g, s) = game::claim(board, &mut m, treasury, clk, ts::ctx(sc));
        if (coin::value(&s) == 0) {
            // Lost: 19.5% of the pot rolled into the Motherlode, 1% to the creator, the rest to the reserve.
            let ml_add = amt * 1_950 / 10_000;
            assert!(game::motherlode_value(board) == ml_add, 100);
            assert!(gts::vault_value(treasury) - vault_before == amt - amt / 100 - ml_add, 101);
        };
        coin::burn_for_testing(g); coin::burn_for_testing(s);
        transfer::public_transfer(m, BOB);
        t = t + 100_000; guard = guard + 1;
    };
    assert!(game::motherlode_value(board) > 0, 102);
    t
}

/// No one on the winning tile: the pot rolls into the Motherlode. A round with a winner and a
/// sure hit pays the whole Motherlode on top of the normal pot; every mist is accounted for.
#[test]
fun test_motherlode_rollover_and_payout() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let t = fill_motherlode(&mut board, &mut treasury, &mut pool, &rs, &mut clk, 100_000_000, &mut sc);
    let ml = game::motherlode_value(&board);

    clock::set_for_testing(&mut clk, t);
    let mut b = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut b, coin::mint_for_testing<SUI>(20_000_000 * 25, ts::ctx(&mut sc)), all_tiles(20_000_000), &clk, ts::ctx(&mut sc));
    let id = game::current_round(&board);
    let vault_before = gts::vault_value(&treasury);
    let dev_before = game::dev_fees_value(&board);
    clock::set_for_testing(&mut clk, t + 60_000);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, 1, ts::ctx(&mut sc));
    assert!(game::motherlode_value(&board) == 0, 0);
    assert!(game::motherlode_paid(&board, id) == ml, 1);
    let (g, s) = game::claim(&mut board, &mut b, &mut treasury, &clk, ts::ctx(&mut sc));
    let fees = gts::vault_value(&treasury) - vault_before + game::dev_fees_value(&board) - dev_before;
    assert!(coin::value(&s) + fees + game::motherlode_value(&board) == 20_000_000 * 25 + ml, 2);
    assert!(game::pot_value(&board) == 0, 3);
    // Spread over all 25 tiles: keeps 1/25 of the pot share and of the jackpot, the rest of the
    // jackpot goes back into the fund.
    let losing = 20_000_000 * 24;
    let lf = losing - losing * 4 / 100 - losing / 100;
    assert!(coin::value(&s) == 20_000_000 + lf / 25 + ml / 25, 5);
    assert!(game::motherlode_value(&board) == ml - ml / 25, 6);

    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(b, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// With a winner but no hit, the Motherlode stays untouched and the round pays as before.
#[test]
fun test_motherlode_no_hit_keeps_balance() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let t = fill_motherlode(&mut board, &mut treasury, &mut pool, &rs, &mut clk, 10_000_000, &mut sc);
    let ml = game::motherlode_value(&board);

    clock::set_for_testing(&mut clk, t);
    let mut b = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut b, coin::mint_for_testing<SUI>(10_000_000 * 25, ts::ctx(&mut sc)), all_tiles(10_000_000), &clk, ts::ctx(&mut sc));
    let id = game::current_round(&board);
    clock::set_for_testing(&mut clk, t + 60_000);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, 1_000_000_000_000, ts::ctx(&mut sc));
    assert!(game::motherlode_paid(&board, id) == 0, 0);
    assert!(game::motherlode_value(&board) == ml, 1);
    let (g, s) = game::claim(&mut board, &mut b, &mut treasury, &clk, ts::ctx(&mut sc));
    let losing = 10_000_000 * 24;
    assert!(coin::value(&s) == 10_000_000 + (losing - losing * 4 / 100 - losing / 100) / 25, 2);
    assert!(game::pot_value(&board) == 0, 3);

    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(b, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// The House wallet never keeps Motherlode SUI: its share goes back, a player keeps theirs.
#[test]
fun test_house_returns_motherlode_share() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let t = fill_motherlode(&mut board, &mut treasury, &mut pool, &rs, &mut clk, 100_000_000, &mut sc);
    let ml = game::motherlode_value(&board);

    // House and a player both cover every tile with equal stakes; sure hit.
    clock::set_for_testing(&mut clk, t);
    ts::next_tx(&mut sc, HOUSE);
    let mut h = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut h, coin::mint_for_testing<SUI>(10_000_000 * 25, ts::ctx(&mut sc)), all_tiles(10_000_000), &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, BOB);
    let mut p = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut p, coin::mint_for_testing<SUI>(10_000_000 * 25, ts::ctx(&mut sc)), all_tiles(10_000_000), &clk, ts::ctx(&mut sc));
    let id = game::current_round(&board);
    clock::set_for_testing(&mut clk, t + 60_000);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, 1, ts::ctx(&mut sc));
    assert!(game::motherlode_paid(&board, id) == ml, 0);
    assert!(game::motherlode_value(&board) == 0, 1);

    let (gp, sp) = game::claim(&mut board, &mut p, &mut treasury, &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, HOUSE);
    let (gh, sh) = game::claim(&mut board, &mut h, &mut treasury, &clk, ts::ctx(&mut sc));
    // Each holds half the winning tile: jackpot part j = ml / 2. Both spread over all 25 tiles, so the
    // player keeps j / 25 and returns the rest; the House returns all of j.
    let j = ml / 2;
    assert!(game::motherlode_value(&board) == j + (j - j / 25), 2);
    assert!(coin::value(&sp) == coin::value(&sh) + j / 25, 3);
    assert!(game::pot_value(&board) <= 1, 4);

    coin::burn_for_testing(gp); coin::burn_for_testing(sp);
    coin::burn_for_testing(gh); coin::burn_for_testing(sh);
    transfer::public_transfer(p, BOB); transfer::public_transfer(h, HOUSE);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// The other House bots (here Bot 1) never keep Motherlode SUI either: all of it goes back.
#[test]
fun test_bot_returns_motherlode_share() {
    let bot1 = @0xab4deb30e34487f75bf5632038e46d419c6238b4ea52d35f3ad3421a5bb268fa;
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let t = fill_motherlode(&mut board, &mut treasury, &mut pool, &rs, &mut clk, 100_000_000, &mut sc);
    let ml = game::motherlode_value(&board);

    // Only Bot 1 plays, on every tile; sure hit.
    clock::set_for_testing(&mut clk, t);
    ts::next_tx(&mut sc, bot1);
    let mut b = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut b, coin::mint_for_testing<SUI>(10_000_000 * 25, ts::ctx(&mut sc)), all_tiles(10_000_000), &clk, ts::ctx(&mut sc));
    let id = game::current_round(&board);
    clock::set_for_testing(&mut clk, t + 60_000);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, 1, ts::ctx(&mut sc));
    assert!(game::motherlode_paid(&board, id) == ml, 0);
    assert!(game::motherlode_value(&board) == 0, 1);

    let (g, s) = game::claim(&mut board, &mut b, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(game::motherlode_value(&board) == ml, 2);

    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(b, bot1);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

// ===== Version guard =====

/// A board installed the pre-v5 way: the first v5 call moves the MinterCap off `board.minter`
/// (so versions 1-4 can no longer mint, deploy, settle or claim) and records version 5.
#[test]
fun test_v5_migrates_legacy_board() {
    let mut sc = ts::begin(@0x0);
    random::create_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, @0x0);
    let mut rs = ts::take_shared<Random>(&sc);
    random::update_randomness_state_for_testing(&mut rs, 0, x"0A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20212223242526272829", ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    gts::init_for_testing(ts::ctx(&mut sc));
    staking::init_for_testing(ts::ctx(&mut sc));
    game::init_for_testing(ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ADMIN);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let cap = ts::take_from_sender<MinterCap>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1);
    game::install_legacy_for_testing(&mut board, cap, &mut treasury, &clk);
    assert!(game::legacy_minter_for_testing(&board), 0);
    assert!(game::version_for_testing(&board) == 0, 1);

    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    assert!(!game::legacy_minter_for_testing(&board), 2);
    assert!(game::version_for_testing(&board) == 8, 3);
    assert!(game::installed(&board), 4);

    // The game still mints after the move: settle and claim pay the GTS reward (0.01 SUI -> 0.01 GTS).
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(mined(&board, &g) == 10_000_000, 5);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool); ts::return_shared(rs);
    ts::end(sc);
}

/// Once a newer version has used the Board, this version refuses to change it.
#[test, expected_failure(abort_code = gtstar::game::EWrongVersion)]
fun test_older_version_blocked() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, ADMIN);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_version_for_testing(&mut board, 9);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

// ===== Volume-scaled reward (v6) =====

#[test]
fun test_scaled_reward_math() {
    let full = 1_000_000_000;
    assert!(game::scaled_reward_for_testing(full, 0) == 0, 0);
    assert!(game::scaled_reward_for_testing(full, 10_000_000) == 10_000_000, 1);     // 0.01 SUI -> 0.01 GTS
    assert!(game::scaled_reward_for_testing(full, 250_000_000) == 250_000_000, 2);   // 0.25 SUI -> 0.25 GTS
    assert!(game::scaled_reward_for_testing(full, 1_000_000_000) == full, 3);
    assert!(game::scaled_reward_for_testing(full, 50_000_000_000) == full, 4);       // capped
    assert!(game::scaled_reward_for_testing(full >> 1, 500_000_000) == 250_000_000, 5); // halving still applies
}

/// A bot covering all 25 tiles with the minimum gets 0.25 GTS, not 1, and every new GTS
/// arrives with at least the reserve's floor price behind it.
#[test]
fun test_cheap_round_cannot_dilute_reserve() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);

    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000 * 25, ts::ctx(&mut sc)), all_tiles(10_000_000), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(mined(&board, &g) == 250_000_000, 0);
    assert!(staking::total_rewards_for_testing(&pool) == 25_000_000, 1);
    // Reserve got 4% of the 0.24 losing SUI = 0.0096 SUI for 0.275 GTS -> ~0.035 SUI per GTS.
    let floor = gts::floor_price_scaled(&treasury);
    assert!(floor >= 33_000_000, 2);

    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

// ===== v7: winnings scale with the stake on the winning tile, Wealth Fund =====

/// The reported case: 0.01 SUI on each of the 25 tiles (0.25 total) next to another player's
/// 0.1 SUI. The spread player keeps only 1/25 of their pot share, never a profit, and every
/// mist is accounted for. A single-tile player keeps their whole share.
#[test]
fun test_spread_keeps_proportional_share() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);

    // BOB covers every tile in two deposits with the same Miner (allowed).
    let mut b = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut b, coin::mint_for_testing<SUI>(10_000_000 * 25, ts::ctx(&mut sc)), all_tiles(10_000_000), &clk, ts::ctx(&mut sc));
    game::deploy(&mut board, &mut b, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(7, 10_000_000), &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ALICE);
    let mut a = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut a, coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut sc)), one_tile(0, 100_000_000), &clk, ts::ctx(&mut sc));
    let id = game::current_round(&board);
    let deposits = 260_000_000 + 100_000_000;
    assert!(game::seat_exists_for_testing(&board, id, BOB), 0);

    clock::set_for_testing(&mut clk, 61_000);
    let vault_before = gts::vault_value(&treasury);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, 1_000_000_000_000, ts::ctx(&mut sc));
    let w = game::winning_square_for_testing(&board, id);
    let (ga, sa) = game::claim(&mut board, &mut a, &mut treasury, &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, BOB);
    let (gb, sb) = game::claim(&mut board, &mut b, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(!game::seat_exists_for_testing(&board, id, BOB), 1);

    let bob_w = if (w == 7) { 20_000_000 } else { 10_000_000 };
    let alice_w = if (w == 0) { 100_000_000 } else { 0 };
    let winners = bob_w + alice_w;
    let losing = deposits - winners;
    let lf = losing - losing * 4 / 100 - losing / 100;
    let bob_share = (((lf as u128) * (bob_w as u128) / (winners as u128)) as u64);
    let bob_kept = (((bob_share as u128) * (bob_w as u128) / 260_000_000u128) as u64);
    assert!(coin::value(&sb) == bob_w + bob_kept, 2);
    assert!(coin::value(&sb) < 260_000_000, 3);                 // spreading never profits here
    if (w == 7) { assert!(coin::value(&sb) == 20_000_000 + bob_share * 2 / 26, 4); }
    else if (w != 0) { assert!(coin::value(&sb) == 10_000_000 + lf / 26, 5); };
    // ALICE had everything on one tile: her whole share, as before.
    let alice_share = if (alice_w > 0) { (((lf as u128) * (alice_w as u128) / (winners as u128)) as u64) } else { 0 };
    assert!(coin::value(&sa) == (if (alice_w > 0) { alice_w + alice_share } else { 0 }), 6);
    // Exact conservation: what BOB did not keep went to the reserve.
    let out = coin::value(&sa) + coin::value(&sb) + (gts::vault_value(&treasury) - vault_before) + game::dev_fees_value(&board);
    assert!(out + game::pot_value(&board) == deposits, 7);
    assert!(game::pot_value(&board) <= 1, 8);

    coin::burn_for_testing(ga); coin::burn_for_testing(sa); coin::burn_for_testing(gb); coin::burn_for_testing(sb);
    transfer::public_transfer(a, ALICE); transfer::public_transfer(b, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// A second Miner from the same address in the same round is rejected, so the split cannot be
/// dodged by putting one tile per Miner.
#[test, expected_failure(abort_code = gtstar::game::EOneMinerPerRound)]
fun test_one_miner_per_address_per_round() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m1 = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m1, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    let mut m2 = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m2, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(1, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// After claiming, the same address can play the next round with a new Miner.
#[test]
fun test_new_miner_next_round() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m1 = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m1, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 70_000);
    let mut m2 = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m2, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(1, 10_000_000), &clk, ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut m1, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(!game::seat_exists_for_testing(&board, 1, BOB), 0);
    assert!(game::seat_exists_for_testing(&board, 2, BOB), 1);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m1, BOB); transfer::public_transfer(m2, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// Rounds that took deposits before v7 ran keep the old split.
#[test]
fun test_rounds_before_v7_keep_old_split() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    assert!(game::fair_from_round(&board) == 1, 0);
    game::set_fair_from_for_testing(&mut board, 2);
    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000 * 25, ts::ctx(&mut sc)), all_tiles(10_000_000), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_with_odds_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, 1_000_000_000_000, ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    let losing = 10_000_000 * 24;
    assert!(coin::value(&s) == 10_000_000 * 25 - losing * 4 / 100 - losing / 100, 1);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, BOB);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

#[test]
fun test_wealth_fund_odds() {
    assert!(game::motherlode_odds_for_testing() == 500, 0);
}

// ===== Settings (AdminCap) =====

const OWNER: address = @0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e;

#[test_only]
fun take_admin(sc: &mut ts::Scenario): game::AdminCap {
    ts::next_tx(sc, OWNER);
    let mut board = ts::take_shared<Board>(sc);
    game::take_admin_for_testing(&mut board, ts::ctx(sc));
    ts::return_shared(board);
    ts::next_tx(sc, OWNER);
    ts::take_from_sender<game::AdminCap>(sc)
}

/// The owner changes the odds and the fund share at once; the next no-winner round uses the new share.
#[test]
fun test_admin_changes_settings() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    let cap = take_admin(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let (o, sh, p) = game::current_params(&board);
    assert!(o == 500 && sh == 1_950 && !p, 0);
    game::set_params(&cap, &mut board, 1_000, 3_000, 400, 100, 10_000_000, 60_000, 5_000, false);
    let (o2, sh2, _) = game::current_params(&board);
    assert!(o2 == 1_000 && sh2 == 3_000, 1);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let t = fill_motherlode_share(&mut board, &mut treasury, &mut pool, &rs, &mut clk, 100_000_000, 3_000, &mut sc);
    assert!(t > 0, 2);
    clock::destroy_for_testing(clk);
    transfer::public_transfer(cap, OWNER);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// Like fill_motherlode, for a given fund share.
#[test_only]
fun fill_motherlode_share(
    board: &mut Board, treasury: &mut Treasury, pool: &mut StakePool, rs: &Random,
    clk: &mut clock::Clock, amt: u64, share_bps: u64, sc: &mut ts::Scenario,
): u64 {
    let mut t = 1_000;
    let mut guard = 0u64;
    while (game::motherlode_value(board) == 0 && guard < 60) {
        clock::set_for_testing(clk, t);
        let mut m = game::new_miner(ts::ctx(sc));
        game::deploy(board, &mut m, coin::mint_for_testing<SUI>(amt, ts::ctx(sc)), one_tile(0, amt), clk, ts::ctx(sc));
        clock::set_for_testing(clk, t + 60_000);
        game::settle_with_odds_for_testing(board, treasury, pool, rs, clk, 1_000_000_000, ts::ctx(sc));
        let (g, s) = game::claim(board, &mut m, treasury, clk, ts::ctx(sc));
        if (coin::value(&s) == 0) { assert!(game::motherlode_value(board) == amt * share_bps / 10_000, 100); };
        coin::burn_for_testing(g); coin::burn_for_testing(s);
        transfer::public_transfer(m, OWNER);
        t = t + 100_000; guard = guard + 1;
    };
    assert!(game::motherlode_value(board) > 0, 102);
    t
}

/// The creator fee can never go above 1%.
#[test, expected_failure(abort_code = gtstar::game::EBadParams)]
fun test_admin_cannot_raise_creator_fee() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    let cap = take_admin(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&cap, &mut board, 500, 1_950, 400, 200, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// The Motherlode odds can never be set better than 1 in 500, so it cannot be forced to pay out.
#[test, expected_failure(abort_code = gtstar::game::EBadParams)]
fun test_admin_odds_floor() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    let cap = take_admin(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&cap, &mut board, 499, 1_950, 400, 100, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// Fund share plus fees can never exceed the pot.
#[test, expected_failure(abort_code = gtstar::game::EBadParams)]
fun test_admin_share_bounded() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    let cap = take_admin(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&cap, &mut board, 500, 9_600, 400, 100, 10_000_000, 60_000, 5_000, false);
    abort 0
}

/// Only the owner can take the AdminCap.
#[test, expected_failure(abort_code = gtstar::game::ENotOwner)]
fun test_admin_owner_only() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    game::take_admin_for_testing(&mut board, ts::ctx(&mut sc));
    abort 0
}

/// The AdminCap can be taken only once.
#[test, expected_failure(abort_code = gtstar::game::EAdminTaken)]
fun test_admin_once() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    let cap = take_admin(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::take_admin_for_testing(&mut board, ts::ctx(&mut sc));
    transfer::public_transfer(cap, OWNER);
    abort 0
}

/// A pause stops new deposits but the open round still settles and pays.
#[test]
fun test_pause_blocks_deposits_only() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    let cap = take_admin(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    game::set_params(&cap, &mut board, 500, 1_950, 400, 100, 10_000_000, 60_000, 5_000, true);
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(mined(&board, &g) == 10_000_000, 0); // the round settled and paid its GTS
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, OWNER); transfer::public_transfer(cap, OWNER);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

#[test, expected_failure(abort_code = gtstar::game::EPaused)]
fun test_paused_deploy_rejected() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    let cap = take_admin(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    game::set_params(&cap, &mut board, 500, 1_950, 400, 100, 10_000_000, 60_000, 5_000, true);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}

/// GTS a claim mined: the coin it returned plus everything waiting in the unrefined balances (v8).
#[test_only]
fun mined(board: &Board, g: &coin::Coin<GTS>): u64 { coin::value(g) + game::unrefined_total(board) }

// ===== Unrefined GTS and the 10% withdrawal fee (v8) =====

/// One round where BOB and ALICE each put `amt` on tile 0; both claim with claim_sui.
#[test_only]
fun two_miners_round(sc: &mut ts::Scenario, board: &mut Board, treasury: &mut Treasury, pool: &mut StakePool, rs: &Random, amt: u64) {
    let mut clk = clock::create_for_testing(ts::ctx(sc));
    clock::set_for_testing(&mut clk, 1_000);
    ts::next_tx(sc, BOB);
    let mut mb = game::new_miner(ts::ctx(sc));
    game::deploy(board, &mut mb, coin::mint_for_testing<SUI>(amt, ts::ctx(sc)), one_tile(0, amt), &clk, ts::ctx(sc));
    ts::next_tx(sc, ALICE);
    let mut ma = game::new_miner(ts::ctx(sc));
    game::deploy(board, &mut ma, coin::mint_for_testing<SUI>(amt, ts::ctx(sc)), one_tile(0, amt), &clk, ts::ctx(sc));
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(board, treasury, pool, rs, &clk, ts::ctx(sc));
    ts::next_tx(sc, BOB);
    coin::burn_for_testing(game::claim_sui(board, &mut mb, treasury, &clk, ts::ctx(sc)));
    ts::next_tx(sc, ALICE);
    coin::burn_for_testing(game::claim_sui(board, &mut ma, treasury, &clk, ts::ctx(sc)));
    transfer::public_transfer(mb, BOB); transfer::public_transfer(ma, ALICE);
    clock::destroy_for_testing(clk);
}

/// Mined GTS waits unrefined. The first to withdraw pays 10%, which goes to the one still waiting;
/// the last one's fee is burned for the reserve (supply down, reserve unchanged).
#[test]
fun test_withdraw_fee_goes_to_holders_then_burns() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    two_miners_round(&mut sc, &mut board, &mut treasury, &mut pool, &rs, 500_000_000);

    // 1 SUI in the round -> 1 GTS, half each, all unrefined.
    let (ub, bb) = game::unrefined_of(&board, BOB);
    assert!(ub == 500_000_000 && bb == 0, 0);
    assert!(game::unrefined_total(&board) == 1_000_000_000, 1);

    ts::next_tx(&mut sc, BOB);
    let g = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc));
    assert!(coin::value(&g) == 450_000_000, 2);            // 0.5 - 10%
    let (ua, ba) = game::unrefined_of(&board, ALICE);
    assert!(ua == 500_000_000 && ba == 50_000_000, 3);     // ALICE earned BOB's fee
    assert!(held(&board, BOB, 0, 0), 4);
    coin::burn_for_testing(g);

    let supply = gts::total_supply(&treasury);
    let vault = gts::vault_value(&treasury);
    ts::next_tx(&mut sc, ALICE);
    let g = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc));
    assert!(coin::value(&g) == 450_000_000 + 50_000_000, 5); // own 0.45 + bonus 0.05
    assert!(gts::total_supply(&treasury) == supply - 50_000_000, 6); // her fee burned
    assert!(gts::vault_value(&treasury) == vault, 7);                 // reserve kept all its SUI
    assert!(game::unrefined_total(&board) == 0, 8);
    coin::burn_for_testing(g);

    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// A bonus earned before a new claim is kept, and a later claim does not earn from older fees.
#[test]
fun test_bonus_kept_across_claims() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    two_miners_round(&mut sc, &mut board, &mut treasury, &mut pool, &rs, 500_000_000);
    ts::next_tx(&mut sc, BOB);
    coin::burn_for_testing(game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc)));

    // Round 2: both mine 0.5 GTS again. ALICE keeps her 0.05 bonus; BOB starts fresh.
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 100_000);
    ts::next_tx(&mut sc, BOB);
    let mut mb = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut mb, coin::mint_for_testing<SUI>(500_000_000, ts::ctx(&mut sc)), one_tile(0, 500_000_000), &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ALICE);
    let mut ma = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut ma, coin::mint_for_testing<SUI>(500_000_000, ts::ctx(&mut sc)), one_tile(0, 500_000_000), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 200_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, BOB);
    coin::burn_for_testing(game::claim_sui(&mut board, &mut mb, &mut treasury, &clk, ts::ctx(&mut sc)));
    ts::next_tx(&mut sc, ALICE);
    coin::burn_for_testing(game::claim_sui(&mut board, &mut ma, &mut treasury, &clk, ts::ctx(&mut sc)));
    assert!(held(&board, ALICE, 1_000_000_000, 50_000_000), 0);
    assert!(held(&board, BOB, 500_000_000, 0), 1);

    // ALICE withdraws 1 GTS: 0.1 fee all to BOB (the only other holder).
    ts::next_tx(&mut sc, ALICE);
    let g = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc));
    assert!(coin::value(&g) == 900_000_000 + 50_000_000, 2);
    assert!(held(&board, BOB, 500_000_000, 100_000_000), 3);
    coin::burn_for_testing(g);

    transfer::public_transfer(mb, BOB); transfer::public_transfer(ma, ALICE);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

/// The House bots get their GTS at claim, as before, and never hold unrefined GTS.
#[test]
fun test_house_bot_paid_at_claim() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, HOUSE);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let mut pool = ts::take_shared<StakePool>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&g) == 10_000_000, 0);
    assert!(game::unrefined_total(&board) == 0, 1);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    transfer::public_transfer(m, HOUSE);
    clock::destroy_for_testing(clk);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury); ts::return_shared(pool);
    ts::end(sc);
}

#[test, expected_failure(abort_code = gtstar::game::ENothingToWithdraw)]
fun test_withdraw_nothing() {
    let mut sc = ts::begin(@0x0);
    setup_round(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<Treasury>(&sc);
    let g = game::withdraw_gts(&mut board, &mut treasury, ts::ctx(&mut sc));
    coin::burn_for_testing(g);
    abort 0
}

#[test_only]
fun held(board: &Board, p: address, amount: u64, bonus: u64): bool {
    let (a, b) = game::unrefined_of(board, p);
    a == amount && b == bonus
}
