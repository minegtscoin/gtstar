/// GTS token, supply schedule and SUI reserve.
///
/// This package is made immutable at launch. It is the part that holds the
/// economic guarantees, so they cannot be changed by anyone, ever:
///  - Hard cap of 1,000,000 GTS.
///  - No premine: the only way to mint is `mint`, gated by `MinterCap`
///    (held by the game) and bounded by the published emission ceiling.
///  - Emission ceiling: at most 1.1 GTS per minute (1 to miners + 0.1 to
///    stakers), halving every 6 months from genesis, zero from 2030-01-01.
///    Burned GTS is never re-minted: the ceiling counts everything ever minted.
///  - Reserve: SUI can only leave the reserve through `redeem`, which pays
///    each holder a pro-rata share and burns their GTS.
module gts_token::gts;

use std::ascii;
use std::string;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, CoinMetadata, TreasuryCap};
use sui::event;
use sui::sui::SUI;
use sui::url;

/// One-time witness.
public struct GTS has drop {}

const DECIMALS: u8 = 9;
const MAX_SUPPLY: u64 = 1_000_000 * 1_000_000_000;
/// Ceiling on emission: 1.1 GTS per minute at genesis.
const RATE_PER_MIN: u64 = 1_100_000_000;
const MINUTE_MS: u64 = 60_000;
const HALVING_MS: u64 = 15_778_800_000;          // 182.625 days
const EMISSION_END_MS: u64 = 1_893_456_000_000;  // 2030-01-01T00:00:00Z

const ERedeemZero: u64 = 1;
const EEmptyVault: u64 = 2;
const EAlreadyStarted: u64 = 3;

/// Shared: mint authority, reserve and emission accounting.
public struct Treasury has key {
    id: UID,
    cap: TreasuryCap<GTS>,
    vault: Balance<SUI>,
    genesis_ms: u64,
    minted: u64, // total ever minted (burns do not free up room)
}

/// The right to mint within the emission ceiling. Created once; held by the game.
public struct MinterCap has key, store { id: UID }

public struct Redeemed has copy, drop { player: address, gts_burned: u64, sui_out: u64 }

fun init(witness: GTS, ctx: &mut TxContext) {
    let (cap, metadata) = coin::create_currency(
        witness,
        DECIMALS,
        b"GTS",
        b"GTStar",
        b"Fair-launch mining token on Sui, backed by a SUI reserve.",
        option::some(url::new_unsafe_from_bytes(b"https://gtstar-sui.netlify.app/icon.png")),
        ctx,
    );
    transfer::public_transfer(metadata, tx_context::sender(ctx));
    transfer::share_object(Treasury { id: object::new(ctx), cap, vault: balance::zero<SUI>(), genesis_ms: 0, minted: 0 });
    transfer::public_transfer(MinterCap { id: object::new(ctx) }, tx_context::sender(ctx));
}

// ===== Minting (MinterCap only, bounded by the schedule) =====

/// Start the emission clock. Can only happen once.
public fun start(t: &mut Treasury, _: &MinterCap, clock: &Clock) {
    assert!(t.genesis_ms == 0, EAlreadyStarted);
    t.genesis_ms = clock::timestamp_ms(clock);
}

/// Maximum GTS that may have been minted in total by `now`.
public fun allowance(t: &Treasury, now: u64): u64 {
    let g = t.genesis_ms;
    if (g == 0) { return 0 };
    let end = if (now < EMISSION_END_MS) { now } else { EMISSION_END_MS };
    if (end <= g) { return 0 };
    let mut total: u128 = 0;
    let mut s = g;
    let mut e: u8 = 0;
    while (s < end && e < 64) {
        let next = if (s + HALVING_MS < end) { s + HALVING_MS } else { end };
        total = total + ((RATE_PER_MIN >> e) as u128) * ((next - s) as u128) / (MINUTE_MS as u128);
        s = next;
        e = e + 1;
    };
    if (total > (MAX_SUPPLY as u128)) { MAX_SUPPLY } else { total as u64 }
}

/// Mint up to `amount`, clamped to the emission ceiling. May return less (or zero).
public fun mint(t: &mut Treasury, _: &MinterCap, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<GTS> {
    let cap = allowance(t, clock::timestamp_ms(clock));
    let room = if (cap > t.minted) { cap - t.minted } else { 0 };
    let a = if (amount > room) { room } else { amount };
    t.minted = t.minted + a;
    if (a == 0) { coin::zero<GTS>(ctx) } else { coin::mint(&mut t.cap, a, ctx) }
}

// ===== Reserve =====

/// Add SUI to the reserve. Anyone may add; nobody can withdraw except via `redeem`.
public fun vault_add(t: &mut Treasury, b: Balance<SUI>) {
    balance::join(&mut t.vault, b);
}

/// Burn GTS for a pro-rata share of the reserve.
public fun redeem(t: &mut Treasury, gts: Coin<GTS>, ctx: &mut TxContext): Coin<SUI> {
    let amount = coin::value(&gts);
    assert!(amount > 0, ERedeemZero);
    let supply = coin::total_supply(&t.cap);
    let vault_value = balance::value(&t.vault);
    assert!(vault_value > 0, EEmptyVault);
    let payout = ((vault_value as u128) * (amount as u128) / (supply as u128)) as u64;
    coin::burn(&mut t.cap, gts);
    event::emit(Redeemed { player: tx_context::sender(ctx), gts_burned: amount, sui_out: payout });
    coin::from_balance(balance::split(&mut t.vault, payout), ctx)
}

// ===== Metadata (authorized by owning the CoinMetadata object; frozen at launch) =====

public fun update_icon_url(t: &Treasury, metadata: &mut CoinMetadata<GTS>, url: ascii::String) {
    coin::update_icon_url(&t.cap, metadata, url);
}

public fun update_description(t: &Treasury, metadata: &mut CoinMetadata<GTS>, description: string::String) {
    coin::update_description(&t.cap, metadata, description);
}

// ===== Views =====

public fun total_supply(t: &Treasury): u64 { coin::total_supply(&t.cap) }
public fun vault_value(t: &Treasury): u64 { balance::value(&t.vault) }
public fun minted(t: &Treasury): u64 { t.minted }
public fun genesis_ms(t: &Treasury): u64 { t.genesis_ms }
public fun max_supply(): u64 { MAX_SUPPLY }
public fun emission_end_ms(): u64 { EMISSION_END_MS }
public fun halving_ms(): u64 { HALVING_MS }

/// Floor price in SUI per 1 GTS, scaled by 1e9. Returns 0 if no supply.
public fun floor_price_scaled(t: &Treasury): u64 {
    let supply = coin::total_supply(&t.cap);
    if (supply == 0) { 0 }
    else { ((balance::value(&t.vault) as u128) * 1_000_000_000 / (supply as u128)) as u64 }
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(GTS {}, ctx) }

#[test_only]
public fun minter_for_testing(ctx: &mut TxContext): MinterCap { MinterCap { id: object::new(ctx) } }
