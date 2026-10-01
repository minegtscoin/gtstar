/// The market inside the draw (v18): buyback and burn, liquidity add and fee compounding, run against
/// the real Cetus CLMM code (a GTS/SUI pool made in the test, sized like the mainnet pool).
#[test_only]
module gtstar::market_tests;

use std::string;
use sui::balance;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::random::{Self, Random};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};
use cetus_clmm::config::{Self as cetus_config, GlobalConfig, AdminCap as CetusAdmin};
use cetus_clmm::pool::{Self as cetus_pool, Pool};
use cetus_clmm::position;
use cetus_clmm::tick_math;
use gtstar::game::{Self, Board, AdminCap};
use gtstar::gts::{Self, Treasury, GTS};
use supply_lock::capped::{Self, CappedTreasury};

const OWNER: address = @0x51417aedc9cd847adc087d75a7d5a647fc1ea63744ac607c518b6c458c30bd4e;
const BOB: address = @0xB0B;
const ALICE: address = @0xA11CE;
const GTS1: u64 = 1_000_000_000;
const SUI1: u64 = 1_000_000_000;

/// The mainnet pool when this was written: 0.2403 SUI per GTS, 1% fee (tick spacing 200), full range.
const PRICE: u128 = 9043328645733481228;
const TICK_LO: u32 = 4294523696; // -443600
const TICK_HI: u32 = 443600;
/// The limit of a draw's buys: 2% in price, 1.009950 in square-root price.
fun cap(p: u128): u128 { p * 1_009_950 / 1_000_000 }

/// The game as on mainnet (supply lock, daily mint limit, Wealth Fund 3%).
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
    let admin = ts::take_from_sender<AdminCap>(sc);
    let mut board = ts::take_shared<Board>(sc);
    let treasury = ts::take_shared<Treasury>(sc);
    game::set_fund_bps(&admin, &mut board, 300);
    game::lock_supply(&admin, &mut board, treasury, ts::ctx(sc));
    game::limit_mint_rate(&admin, &mut board, ts::ctx(sc));
    ts::return_to_sender(sc, admin);
    ts::return_shared(board);
    ts::next_tx(sc, OWNER);
}

/// A Cetus GTS/SUI pool at the mainnet price with `positions` full-range positions of 5 GTS (and its
/// 1.2 SUI) each, all locked in the game, and made the game's market pool.
fun market(sc: &mut Scenario, board: &mut Board, treasury: &mut CappedTreasury<GTS>, clk: &Clock, positions: u64): (GlobalConfig, CetusAdmin, Pool<GTS, SUI>) {
    let (cetus_admin, config) = cetus_config::new_global_config_for_test(ts::ctx(sc), 2_000);
    let mut pool = cetus_pool::new_for_test<GTS, SUI>(200, PRICE, 10_000, string::utf8(b""), 0, clk, ts::ctx(sc));
    let mut i = 0u64;
    while (i < positions) {
        let mut p = cetus_pool::open_position(&config, &mut pool, TICK_LO, TICK_HI, ts::ctx(sc));
        let receipt = cetus_pool::add_liquidity_fix_coin(&config, &mut pool, &mut p, 5 * GTS1, true, clk);
        let (a, b) = cetus_pool::add_liquidity_pay_amount(&receipt);
        // Real GTS (minted through the game), so burning what the buyback buys never passes the supply.
        let g = game::mint_for_testing(board, treasury, a, clk, ts::ctx(sc));
        cetus_pool::repay_add_liquidity(&config, &mut pool, coin::into_balance(g), balance::create_for_testing<SUI>(b), receipt);
        game::lock_position_for_testing(board, p);
        i = i + 1;
    };
    game::set_market_pool_for_testing(board, object::id_address(&pool));
    (config, cetus_admin, pool)
}

fun done(config: GlobalConfig, cetus_admin: CetusAdmin, pool: Pool<GTS, SUI>, clk: Clock) {
    transfer::public_transfer(config, OWNER);
    transfer::public_transfer(pool, OWNER);
    transfer::public_transfer(cetus_admin, OWNER);
    clock::destroy_for_testing(clk);
}

fun fund(sc: &mut Scenario, board: &mut Board, buyback: u64, liquidity: u64) {
    game::fund_market_for_testing(board, coin::mint_for_testing<SUI>(buyback, ts::ctx(sc)), coin::mint_for_testing<SUI>(liquidity, ts::ctx(sc)), coin::zero<GTS>(ts::ctx(sc)));
}

fun step(sc: &mut Scenario, board: &mut Board, config: &GlobalConfig, pool: &mut Pool<GTS, SUI>, treasury: &mut CappedTreasury<GTS>, clk: &Clock) {
    game::market_step_for_testing(board, config, pool, treasury, clk, ts::ctx(sc));
}

fun reference(board: &Board): u128 { let (_, r, _, _) = game::market(board); r }

fun liquidity_of(board: &Board, pool: &Pool<GTS, SUI>, i: u64): u128 {
    position::info_liquidity(cetus_pool::borrow_position_info(pool, game::lp_position_id(board, i)))
}

/// Someone else buys GTS with `sui`, with no price limit.
fun outsider_buys(config: &GlobalConfig, pool: &mut Pool<GTS, SUI>, sui: u64, clk: &Clock, ctx: &mut TxContext): Coin<GTS> {
    let (g, none, receipt) = cetus_pool::flash_swap<GTS, SUI>(config, pool, false, true, sui, tick_math::max_sqrt_price(), clk);
    balance::destroy_zero(none);
    let pay = cetus_pool::swap_pay_amount(&receipt);
    cetus_pool::repay_flash_swap<GTS, SUI>(config, pool, balance::zero<GTS>(), balance::create_for_testing<SUI>(pay), receipt);
    coin::from_balance(g, ctx)
}

/// Someone else sells `gts`, with no price limit.
fun outsider_sells(config: &GlobalConfig, pool: &mut Pool<GTS, SUI>, gts: Coin<GTS>, clk: &Clock) {
    let (none, s, receipt) = cetus_pool::flash_swap<GTS, SUI>(config, pool, true, true, coin::value(&gts), tick_math::min_sqrt_price(), clk);
    balance::destroy_zero(none);
    assert!(cetus_pool::swap_pay_amount(&receipt) == coin::value(&gts), 100);
    cetus_pool::repay_flash_swap<GTS, SUI>(config, pool, coin::into_balance(gts), balance::zero<SUI>(), receipt);
    balance::destroy_for_testing(s);
}

/// The first market step only records the reference price: nothing is bought.
#[test]
fun test_first_step_records_price() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    fund(&mut sc, &mut board, 10_000_000, 60_000_000);
    assert!(reference(&board) == 0, 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(reference(&board) == PRICE && cetus_pool::current_sqrt_price(&pool) == PRICE, 2);
    assert!(game::buyback_value(&board) == 10_000_000 && game::liquidity_value(&board) == 60_000_000, 3);
    let (p, _, buy_min, liq_min) = game::market(&board);
    assert!(p == object::id_address(&pool) && buy_min == 5_000_000 && liq_min == 50_000_000, 4);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

/// Buyback: the saved SUI buys GTS on the pool and the GTS is burned in the same step: the supply falls
/// by exactly the GTS that left the pool, and nothing is kept.
#[test]
fun test_buyback_buys_and_burns() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    fund(&mut sc, &mut board, 10_000_000, 0); // 0.01 SUI: less than a 2% move of this pool (about 0.012)
    let supply = capped::total_supply(&treasury);
    let (pool_gts, pool_sui) = { let (a, b) = cetus_pool::balances(&pool); (balance::value(a), balance::value(b)) };
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    let (pool_gts2, pool_sui2) = { let (a, b) = cetus_pool::balances(&pool); (balance::value(a), balance::value(b)) };
    let bought = pool_gts - pool_gts2;
    assert!(game::buyback_value(&board) == 0 && pool_sui2 == pool_sui + 10_000_000, 1);
    assert!(bought > 40_000_000 && bought < 42_000_000, 2); // 0.01 SUI at ~0.2403, less the 1% pool fee: ~0.0411 GTS
    assert!(capped::total_supply(&treasury) == supply - bought && game::bought_value(&board) == 0, 3);
    let p = cetus_pool::current_sqrt_price(&pool);
    assert!(p > PRICE && p < cap(PRICE) && reference(&board) == p, 4);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

/// The 2% limit: with more SUI saved than a 2% move takes, a step buys up to exactly 2% above the
/// reference and keeps the rest; the next step starts from the new price and buys another 2%.
#[test]
fun test_buyback_stops_at_two_percent() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    fund(&mut sc, &mut board, SUI1, 0);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(cetus_pool::current_sqrt_price(&pool) == cap(PRICE) && reference(&board) == cap(PRICE), 1);
    let spent = SUI1 - game::buyback_value(&board);
    assert!(spent > 11_500_000 && spent < 12_500_000, 2); // ~0.012 SUI moves this pool 2%
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(cetus_pool::current_sqrt_price(&pool) == cap(cap(PRICE)), 3);
    assert!(SUI1 - game::buyback_value(&board) > 2 * spent, 4);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

/// Lifting the pool price before a draw does not make the game buy higher: the limit is measured from
/// the reference price, so the step buys nothing and keeps its SUI, and the reference rises only 2%.
/// Once the price is back, the step buys again, from the lower of the two prices.
#[test]
fun test_pumped_price_buys_nothing() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    fund(&mut sc, &mut board, 10_000_000, 60_000_000);
    let supply = capped::total_supply(&treasury);
    let pumped = outsider_buys(&config, &mut pool, 300_000_000, &clk, ts::ctx(&mut sc)); // +25% in SUI
    let high = cetus_pool::current_sqrt_price(&pool);
    assert!(high > cap(cap(cap(PRICE))), 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(game::buyback_value(&board) == 10_000_000 && game::liquidity_value(&board) == 60_000_000, 2);
    assert!(capped::total_supply(&treasury) == supply && cetus_pool::current_sqrt_price(&pool) == high, 3);
    assert!(reference(&board) == cap(PRICE), 4);
    // The price comes back down, below where it started (the outsider paid the pool fee twice).
    outsider_sells(&config, &mut pool, pumped, &clk);
    let low = cetus_pool::current_sqrt_price(&pool);
    assert!(low < cap(PRICE), 5);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(game::buyback_value(&board) < 10_000_000 && capped::total_supply(&treasury) < supply, 6);
    assert!(cetus_pool::current_sqrt_price(&pool) <= cap(low), 7);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

/// Liquidity: 49% of the saved SUI buys GTS (as far as the 2% limit allows), and the GTS with its
/// matching SUI goes into the first locked position. The SUI not used stays saved; no GTS is left.
#[test]
fun test_liquidity_added_to_locked_position() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 2);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    fund(&mut sc, &mut board, 0, 60_000_000);
    let supply = capped::total_supply(&treasury);
    let (l0, l1) = (liquidity_of(&board, &pool, 0), liquidity_of(&board, &pool, 1));
    let (pool_gts, pool_sui) = { let (a, b) = cetus_pool::balances(&pool); (balance::value(a), balance::value(b)) };
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    let (pool_gts2, pool_sui2) = { let (a, b) = cetus_pool::balances(&pool); (balance::value(a), balance::value(b)) };
    let used = 60_000_000 - game::liquidity_value(&board);
    // 0.0294 SUI to swap fits under 2% of this pool (two positions: ~0.024 SUI), so the price stops at the limit.
    assert!(cetus_pool::current_sqrt_price(&pool) == cap(PRICE), 1);
    // All the SUI used went into the pool, and every GTS bought went back in with it.
    assert!(pool_sui2 == pool_sui + used && pool_gts2 == pool_gts, 2);
    assert!(used > 46_000_000 && used < 50_000_000, 3); // ~0.024 swapped + ~0.024 added beside the GTS
    assert!(liquidity_of(&board, &pool, 0) > l0 && liquidity_of(&board, &pool, 1) == l1, 4);
    assert!(game::bought_value(&board) == 0 && capped::total_supply(&treasury) == supply, 5);
    assert!(game::lp_positions(&board) == 2, 6);
    // The rest is below the 0.05 SUI minimum: it waits.
    let left = game::liquidity_value(&board);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(game::liquidity_value(&board) == left, 7);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

/// Below the minimums (0.005 SUI buyback, 0.05 SUI liquidity) the SUI waits; GTS left from liquidity
/// is still burned.
#[test]
fun test_small_amounts_wait() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    fund(&mut sc, &mut board, 4_999_999, 49_999_999);
    let left = game::mint_for_testing(&mut board, &mut treasury, 500, &clk, ts::ctx(&mut sc));
    game::fund_market_for_testing(&mut board, coin::zero<SUI>(ts::ctx(&mut sc)), coin::zero<SUI>(ts::ctx(&mut sc)), left);
    let supply = capped::total_supply(&treasury);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(game::buyback_value(&board) == 4_999_999 && game::liquidity_value(&board) == 49_999_999, 1);
    assert!(cetus_pool::current_sqrt_price(&pool) == PRICE, 2);
    assert!(game::bought_value(&board) == 0 && capped::total_supply(&treasury) == supply - 500, 3);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

/// When the limit is tight the buyback and the liquidity add take turns going first: liquidity in even
/// rounds, the buyback in odd ones.
#[test]
fun test_buyback_and_liquidity_take_turns() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    fund(&mut sc, &mut board, SUI1, SUI1);
    // Round 1 (odd): the buyback takes the whole 2%.
    assert!(game::current_round(&board) == 1, 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(game::buyback_value(&board) < SUI1 && game::liquidity_value(&board) == SUI1, 2);
    // Play round 1 so the next step runs in round 2 (even): liquidity goes first.
    let mut m = game::new_miner(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(10_000_000, ts::ctx(&mut sc)), one_tile(0, 10_000_000), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 62_000);
    game::settle_plain_for_testing(&mut board, &rs, &clk, ts::ctx(&mut sc));
    assert!(game::current_round(&board) == 2, 3);
    let (bb, lq) = (game::buyback_value(&board), game::liquidity_value(&board));
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(game::liquidity_value(&board) < lq && game::buyback_value(&board) == bb, 4);
    transfer::public_transfer(m, BOB);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

fun one_tile(i: u64, amt: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0u64;
    while (k < 25) { vector::push_back(&mut v, if (k == i) { amt } else { 0 }); k = k + 1; };
    v
}

/// A paused pool does not stop the step: it buys and adds nothing, and the SUI waits.
#[test]
fun test_paused_pool_is_skipped() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    fund(&mut sc, &mut board, 10_000_000, 60_000_000);
    cetus_pool::pause_pool(&mut pool);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(game::buyback_value(&board) == 10_000_000 && game::liquidity_value(&board) == 60_000_000, 1);
    cetus_pool::unpause_pool(&mut pool);
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    assert!(game::buyback_value(&board) < 10_000_000, 2);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

/// Only the game's own market pool is accepted: any other GTS/SUI pool aborts.
#[test, expected_failure(abort_code = game::EWrongPool)]
fun test_other_pool_refused() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, _ca, _pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    let mut other = cetus_pool::new_for_test<GTS, SUI>(200, PRICE, 10_000, string::utf8(b""), 1, &clk, ts::ctx(&mut sc));
    step(&mut sc, &mut board, &config, &mut other, &mut treasury, &clk);
    abort 0
}

/// Without the test pool set, the pool must be the mainnet one: a pool made here is refused.
#[test, expected_failure(abort_code = game::EWrongPool)]
fun test_mainnet_pool_is_fixed() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (_ca, config) = cetus_config::new_global_config_for_test(ts::ctx(&mut sc), 2_000);
    let mut pool = cetus_pool::new_for_test<GTS, SUI>(200, PRICE, 10_000, string::utf8(b""), 0, &clk, ts::ctx(&mut sc));
    step(&mut sc, &mut board, &config, &mut pool, &mut treasury, &clk);
    abort 0
}

/// The market draw: the market step with the SUI saved by earlier rounds, then the draw, with the draw
/// reward for whoever called it. The round's own shares are saved for the next draw.
#[test]
fun test_market_draw() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    // Round 1: 25 SUI on every tile. Its draw is the first market step: it only records the price.
    clock::set_for_testing(&mut clk, 1_000);
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(25 * SUI1, ts::ctx(&mut sc)), all_tiles(SUI1), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 62_000);
    ts::next_tx(&mut sc, ALICE);
    game::settle_market_for_testing(&mut board, &config, &mut pool, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
    ts::next_tx(&mut sc, ALICE);
    let paid = ts::take_from_sender<Coin<SUI>>(&sc);
    assert!(coin::value(&paid) == 5_000_000, 1);
    coin::burn_for_testing(paid);
    assert!(game::current_round(&board) == 2 && reference(&board) == PRICE, 2);
    assert!(game::buyback_value(&board) == 720_000_000 && game::liquidity_value(&board) == 480_000_000, 3);
    ts::next_tx(&mut sc, BOB);
    let (g, s) = game::claim_v3(&mut board, &mut m, &mut treasury, &clk, ts::ctx(&mut sc));
    assert!(coin::value(&s) == SUI1 + 24 * SUI1 * 91 / 100, 4);
    coin::burn_for_testing(g); coin::burn_for_testing(s);
    // Round 2: its draw spends what round 1 saved, up to the 2% limit, before drawing.
    let supply = capped::total_supply(&treasury);
    let l0 = liquidity_of(&board, &pool, 0);
    clock::set_for_testing(&mut clk, 100_000);
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(25 * SUI1, ts::ctx(&mut sc)), all_tiles(SUI1), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 161_000);
    ts::next_tx(&mut sc, ALICE);
    game::settle_market_for_testing(&mut board, &config, &mut pool, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
    assert!(game::current_round(&board) == 3 && cetus_pool::current_sqrt_price(&pool) == cap(PRICE), 5);
    // Round 2 is even: liquidity went first and used the whole 2%; the buyback waits with round 2's share on top.
    assert!(liquidity_of(&board, &pool, 0) > l0 && capped::total_supply(&treasury) == supply, 6);
    assert!(game::buyback_value(&board) == 2 * 720_000_000, 7);
    assert!(game::liquidity_value(&board) < 2 * 480_000_000 - 5_000_000, 8);
    transfer::public_transfer(m, BOB);
    ts::return_shared(rs); ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

fun all_tiles(per: u64): vector<u64> {
    let mut v = vector[];
    let mut k = 0u64;
    while (k < 25) { vector::push_back(&mut v, per); k = k + 1; };
    v
}

/// The market draw cannot run before the round has ended (so the market step cannot be run at will).
#[test, expected_failure(abort_code = game::ERoundNotEnded)]
fun test_market_draw_needs_ended_round() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    ts::next_tx(&mut sc, BOB);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let rs = ts::take_shared<Random>(&sc);
    let mut clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, _ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    let mut m = game::new_miner(ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 1_000);
    game::deploy(&mut board, &mut m, coin::mint_for_testing<SUI>(SUI1, ts::ctx(&mut sc)), one_tile(0, SUI1), &clk, ts::ctx(&mut sc));
    clock::set_for_testing(&mut clk, 30_000);
    game::settle_market_for_testing(&mut board, &config, &mut pool, &mut treasury, &rs, &clk, ts::ctx(&mut sc));
    abort 0
}

/// Trading fees of the locked positions are collected and added back to the pool by anyone: the first
/// position's liquidity grows, nothing leaves the game, and what cannot be paired is kept (SUI for the
/// next liquidity add, GTS to be burned).
#[test]
fun test_compound_fees() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 3);
    // Trades both ways: fees in SUI (buys) and in GTS (sells).
    let g = outsider_buys(&config, &mut pool, 500_000_000, &clk, ts::ctx(&mut sc));
    outsider_sells(&config, &mut pool, g, &clk);
    let (l0, l1, l2) = (liquidity_of(&board, &pool, 0), liquidity_of(&board, &pool, 1), liquidity_of(&board, &pool, 2));
    let (pool_gts, pool_sui) = { let (a, b) = cetus_pool::balances(&pool); (balance::value(a), balance::value(b)) };
    ts::next_tx(&mut sc, ALICE);
    game::compound_fees(&mut board, &config, &mut pool, 0, 20, &clk);
    let (pool_gts2, pool_sui2) = { let (a, b) = cetus_pool::balances(&pool); (balance::value(a), balance::value(b)) };
    let (kept_sui, kept_gts) = (game::liquidity_value(&board), game::bought_value(&board));
    // 0.5 SUI in at 1%: 0.005 SUI of fees, 80% of it to the positions (20% is Cetus's protocol fee).
    assert!(liquidity_of(&board, &pool, 0) > l0 && liquidity_of(&board, &pool, 1) == l1 && liquidity_of(&board, &pool, 2) == l2, 1);
    // What left the pool as fees and did not go back in is exactly what the game kept.
    assert!(pool_sui - pool_sui2 == kept_sui && pool_gts - pool_gts2 == kept_gts, 2);
    assert!(kept_sui == 0 || kept_gts == 0, 3); // one side is always used up
    assert!(kept_sui < 4_000_000 && kept_gts < 16_000_000, 4);
    // A second call right after has nothing to collect.
    let l0b = liquidity_of(&board, &pool, 0);
    game::compound_fees(&mut board, &config, &mut pool, 0, 20, &clk);
    assert!(liquidity_of(&board, &pool, 0) == l0b, 5);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}

/// GTS fees with no SUI fees beside them are paired with SUI saved for liquidity.
#[test]
fun test_compound_pairs_gts_fees_with_saved_sui() {
    let mut sc = ts::begin(@0x0);
    setup(&mut sc);
    let mut board = ts::take_shared<Board>(&sc);
    let mut treasury = ts::take_shared<CappedTreasury<GTS>>(&sc);
    let clk = clock::create_for_testing(ts::ctx(&mut sc));
    let (config, ca, mut pool) = market(&mut sc, &mut board, &mut treasury, &clk, 1);
    // Only a sell: fees in GTS only.
    let g = game::mint_for_testing(&mut board, &mut treasury, GTS1, &clk, ts::ctx(&mut sc));
    outsider_sells(&config, &mut pool, g, &clk);
    fund(&mut sc, &mut board, 0, 40_000_000);
    let l0 = liquidity_of(&board, &pool, 0);
    game::compound_fees(&mut board, &config, &mut pool, 0, 1, &clk);
    assert!(liquidity_of(&board, &pool, 0) > l0, 1);
    assert!(game::bought_value(&board) == 0 && game::liquidity_value(&board) < 40_000_000, 2);
    ts::return_shared(board); ts::return_shared(treasury);
    done(config, ca, pool, clk);
    ts::end(sc);
}
