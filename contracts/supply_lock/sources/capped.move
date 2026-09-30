/// A hard supply cap that nobody can lift, not even the coin's creator.
///
/// `lock` takes a coin's `TreasuryCap` and seals it inside a shared `CappedTreasury` with a fixed `max`.
/// From then on the only way to mint is `mint`, which never lets the total ever minted pass `max`
/// (burned coins do not free up room). No function returns the TreasuryCap, lends it mutably, or
/// changes `max` or `minted` other than by minting. This package is made immutable right after it is
/// published, so these rules can never change.
///
/// Minting also needs the `MinterCap` returned by `lock`; whoever holds it decides who receives new
/// coins, but only up to `max`. Anyone may burn their own coins.
module supply_lock::capped;

use std::ascii;
use std::string;
use sui::coin::{Self, Coin, CoinMetadata, TreasuryCap};
use sui::event;

const EOverMax: u64 = 1;
const EWrongMinter: u64 = 2;

/// Shared. `cap` and `minted` keep the names of the GTS Treasury fields they replace.
public struct CappedTreasury<phantom T> has key {
    id: UID,
    cap: TreasuryCap<T>,
    minted: u64, // total ever minted, including before the lock; never above `max`
    max: u64,
}

/// Right to mint from one CappedTreasury, up to its `max`.
public struct MinterCap<phantom T> has key, store {
    id: UID,
    treasury: ID,
}

public struct Locked has copy, drop { treasury: ID, minted: u64, max: u64, supply: u64 }
public struct Minted has copy, drop { treasury: ID, amount: u64, minted: u64 }
public struct Burned has copy, drop { treasury: ID, amount: u64 }

/// Seal `cap` for good. `minted` is everything minted so far (at least the current supply), `max` the cap.
public fun lock<T>(cap: TreasuryCap<T>, minted: u64, max: u64, ctx: &mut TxContext): MinterCap<T> {
    let supply = coin::total_supply(&cap);
    assert!(minted >= supply && minted <= max, EOverMax);
    let t = CappedTreasury<T> { id: object::new(ctx), cap, minted, max };
    let treasury = object::id(&t);
    event::emit(Locked { treasury, minted, max, supply });
    transfer::share_object(t);
    MinterCap<T> { id: object::new(ctx), treasury }
}

/// Mint up to `amount`, clamped to the room left under `max`. May return less (or zero).
public fun mint<T>(t: &mut CappedTreasury<T>, m: &MinterCap<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    assert!(m.treasury == object::id(t), EWrongMinter);
    let room = t.max - t.minted;
    let a = if (amount > room) { room } else { amount };
    if (a == 0) { return coin::zero<T>(ctx) };
    t.minted = t.minted + a;
    event::emit(Minted { treasury: object::id(t), amount: a, minted: t.minted });
    coin::mint(&mut t.cap, a, ctx)
}

/// Burn coins for good. Anyone may burn their own.
public fun burn<T>(t: &mut CappedTreasury<T>, c: Coin<T>) {
    let amount = coin::value(&c);
    if (amount == 0) { coin::destroy_zero(c); return };
    coin::burn(&mut t.cap, c);
    event::emit(Burned { treasury: object::id(t), amount });
}

// ===== Metadata (authorized by owning the CoinMetadata object) =====

public fun update_icon_url<T>(t: &CappedTreasury<T>, metadata: &mut CoinMetadata<T>, url: ascii::String) {
    coin::update_icon_url(&t.cap, metadata, url);
}

public fun update_description<T>(t: &CappedTreasury<T>, metadata: &mut CoinMetadata<T>, description: string::String) {
    coin::update_description(&t.cap, metadata, description);
}

// ===== Views =====

/// Read-only access to the TreasuryCap (a shared reference cannot mint or burn).
public fun treasury_cap<T>(t: &CappedTreasury<T>): &TreasuryCap<T> { &t.cap }
public fun total_supply<T>(t: &CappedTreasury<T>): u64 { coin::total_supply(&t.cap) }
public fun minted<T>(t: &CappedTreasury<T>): u64 { t.minted }
public fun max<T>(t: &CappedTreasury<T>): u64 { t.max }
public fun room<T>(t: &CappedTreasury<T>): u64 { t.max - t.minted }
public fun treasury_of<T>(m: &MinterCap<T>): ID { m.treasury }
