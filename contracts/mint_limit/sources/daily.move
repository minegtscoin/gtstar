/// A daily mint limit that nobody can lift, not even the coin's creator.
///
/// `wrap` takes the `supply_lock::capped::MinterCap` (the only right to mint) and seals it inside a
/// `DailyLimiter` with a fixed `per_day`. From then on the only way to mint is `mint`, which never lets
/// the coins minted in one UTC day (00:00 to 24:00 UTC, by the on-chain clock) pass `per_day`. A mint
/// that would pass it aborts, so nothing is lost: it can be retried the next UTC day. The total cap of
/// the CappedTreasury still applies on top.
///
/// No function returns the MinterCap, lends it (even immutably), or changes `per_day`. The limiter has
/// no `drop` and no destroy function, so it exists for good. Whoever holds it can mint, but only within
/// the limit. This package is made immutable right after it is published, so these rules never change.
module mint_limit::daily;

use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use supply_lock::capped::{Self, CappedTreasury, MinterCap};

const DAY_MS: u64 = 86_400_000;

const EDailyLimit: u64 = 1;
const EZeroLimit: u64 = 2;

/// Holds the MinterCap for good. `key` so it has its own ID and can be inspected on-chain.
public struct DailyLimiter<phantom T> has key, store {
    id: UID,
    minter: MinterCap<T>,
    per_day: u64,      // most coins minted in one UTC day, fixed
    day: u64,          // UTC day of the last mint (ms since epoch / DAY_MS)
    minted_today: u64, // minted so far in `day`
    minted_total: u64, // minted through this limiter since it was created
}

public struct Wrapped has copy, drop { limiter: ID, treasury: ID, per_day: u64 }
public struct DailyMinted has copy, drop { limiter: ID, day: u64, amount: u64, minted_today: u64 }

/// Seal `minter` for good under a limit of `per_day` coins per UTC day.
public fun wrap<T>(minter: MinterCap<T>, per_day: u64, ctx: &mut TxContext): DailyLimiter<T> {
    assert!(per_day > 0, EZeroLimit);
    let l = DailyLimiter<T> { id: object::new(ctx), minter, per_day, day: 0, minted_today: 0, minted_total: 0 };
    event::emit(Wrapped { limiter: object::id(&l), treasury: capped::treasury_of(&l.minter), per_day });
    l
}

/// Mint `amount` (clamped only by the total cap of the CappedTreasury). Aborts if today's minting
/// would pass `per_day`.
public fun mint<T>(l: &mut DailyLimiter<T>, t: &mut CappedTreasury<T>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<T> {
    let day = clock::timestamp_ms(clock) / DAY_MS;
    if (day != l.day) { l.day = day; l.minted_today = 0; };
    assert!(amount <= l.per_day - l.minted_today, EDailyLimit);
    let c = capped::mint(t, &l.minter, amount, ctx);
    let got = coin::value(&c);
    if (got > 0) {
        l.minted_today = l.minted_today + got;
        l.minted_total = l.minted_total + got;
        event::emit(DailyMinted { limiter: object::id(l), day, amount: got, minted_today: l.minted_today });
    };
    c
}

// ===== Views =====

public fun per_day<T>(l: &DailyLimiter<T>): u64 { l.per_day }
public fun minted_total<T>(l: &DailyLimiter<T>): u64 { l.minted_total }
/// Coins that can still be minted today.
public fun room_today<T>(l: &DailyLimiter<T>, clock: &Clock): u64 {
    if (clock::timestamp_ms(clock) / DAY_MS != l.day) { l.per_day } else { l.per_day - l.minted_today }
}
public fun treasury_of<T>(l: &DailyLimiter<T>): ID { capped::treasury_of(&l.minter) }
