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
    assert!(coin::value(&g) == 1_000_000_000, 0); // whole miner reward (only player)
    let losing = per * 24;
    let fees = losing * 4 / 100 + losing / 100;
    assert!(coin::value(&s) == per * 25 - fees, 1);
    assert!(gts::vault_value(&treasury) == losing * 4 / 100, 2);
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
    let minted = coin::value(&ga) + coin::value(&gb);
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
            // Lost: half of the 95% rolled into the Motherlode, the reserve got its 4% + the other half.
            let after_fee = amt - amt * 4 / 100 - amt / 100;
            assert!(game::motherlode_value(board) == after_fee / 2, 100);
            assert!(gts::vault_value(treasury) - vault_before == amt * 4 / 100 + (after_fee - after_fee / 2), 101);
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
    assert!(coin::value(&s) + fees == 20_000_000 * 25 + ml, 2);
    assert!(game::pot_value(&board) == 0, 3);

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
    assert!(coin::value(&s) == 10_000_000 * 25 - losing * 4 / 100 - losing / 100, 2);
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
    let mut h = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut h, coin::mint_for_testing<SUI>(10_000_000 * 25, ts::ctx(&mut sc)), all_tiles(10_000_000), &clk, ts::ctx(&mut sc));
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
    assert!(game::motherlode_value(&board) == ml / 2, 2);
    assert!(coin::value(&sp) == coin::value(&sh) + ml / 2, 3);
    assert!(game::pot_value(&board) <= 1, 4);

    coin::burn_for_testing(gp); coin::burn_for_testing(sp);
    coin::burn_for_testing(gh); coin::burn_for_testing(sh);
    transfer::public_transfer(p, BOB); transfer::public_transfer(h, HOUSE);
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
    assert!(game::version_for_testing(&board) == 5, 3);
    assert!(game::installed(&board), 4);

    // The game still mints after the move: settle and claim pay the GTS reward.
    clock::set_for_testing(&mut clk, 61_000);
    game::settle_for_testing(&mut board, &mut treasury, &mut pool, &rs, &clk, ts::ctx(&mut sc));
    let (g, s) = game::claim(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&g) == 1_000_000_000, 5);
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
    game::set_version_for_testing(&mut board, 6);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let mut m = game::new_miner(ts::ctx(&mut sc));
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    abort 0
}
