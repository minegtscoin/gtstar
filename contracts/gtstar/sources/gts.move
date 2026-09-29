/// GTS token (relaunch).
///
///  - Hard cap of 1,000,000 GTS. No premine: GTS is only minted by the game in this package
///    (`mint` is package-only), and never past the cap. Burned GTS is never re-minted.
///  - No reserve from v9: GTS cannot be redeemed for SUI (`redeem` and `vault_add` abort), and the SUI
///    that was in the reserve moved to the game's Wealth Fund (`game::reserve_to_fund`). GTS trades
///    only on the market. `vault` stays in the object (fields cannot be removed) and is empty.
module gtstar::gts;

use std::ascii;
use std::string;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, CoinMetadata, TreasuryCap};
use sui::sui::SUI;
use sui::url;

/// One-time witness.
public struct GTS has drop {}

const DECIMALS: u8 = 9;
const MAX_SUPPLY: u64 = 1_000_000 * 1_000_000_000;

const ENoReserve: u64 = 3;

/// Shared: mint authority, reserve and total minted.
public struct Treasury has key {
    id: UID,
    cap: TreasuryCap<GTS>,
    vault: Balance<SUI>,
    minted: u64, // total ever minted (burns do not free up room)
}

/// Emitted by `redeem` before v9 (closed now).
public struct Redeemed has copy, drop { player: address, gts_burned: u64, sui_out: u64 }

#[allow(deprecated_usage)]
fun init(witness: GTS, ctx: &mut TxContext) {
    let (cap, metadata) = coin::create_currency(
        witness,
        DECIMALS,
        b"GTS",
        b"GTStar",
        // Text at publish; the live description was changed with `update_description` (no reserve from v9).
        b"Fair-launch mining token on Sui, backed by a SUI reserve. 1,000,000 max supply.",
        option::some(url::new_unsafe_from_bytes(b"https://minegts.fun/icon.png")),
        ctx,
    );
    // Kept by the publisher so the icon and description can still change; freeze it later.
    transfer::public_transfer(metadata, tx_context::sender(ctx));
    transfer::share_object(Treasury { id: object::new(ctx), cap, vault: balance::zero<SUI>(), minted: 0 });
}

/// Mint up to `amount`, clamped to the hard cap. May return less (or zero). Game only.
public(package) fun mint(t: &mut Treasury, amount: u64, ctx: &mut TxContext): Coin<GTS> {
    let room = MAX_SUPPLY - t.minted;
    let a = if (amount > room) { room } else { amount };
    t.minted = t.minted + a;
    if (a == 0) { coin::zero<GTS>(ctx) } else { coin::mint(&mut t.cap, a, ctx) }
}

/// Burn GTS without touching the reserve (the floor rises). Game only.
public(package) fun burn(t: &mut Treasury, gts: Coin<GTS>) {
    coin::burn(&mut t.cap, gts);
}

/// Closed from v9: there is no reserve, so SUI cannot be added to one.
public fun vault_add(_t: &mut Treasury, _b: Balance<SUI>) {
    abort ENoReserve
}

/// Closed from v9: GTS cannot be redeemed for SUI.
public fun redeem(_t: &mut Treasury, _gts: Coin<GTS>, _ctx: &mut TxContext): Coin<SUI> {
    abort ENoReserve
}

/// All SUI still in the old reserve, for the one-time move to the Wealth Fund. Game only.
public(package) fun vault_take_all(t: &mut Treasury): Balance<SUI> {
    balance::withdraw_all(&mut t.vault)
}

// ===== Metadata (authorized by owning the CoinMetadata object) =====

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
public fun max_supply(): u64 { MAX_SUPPLY }

/// Old reserve over supply, SUI per 1 GTS scaled by 1e9 (0 from v9: the reserve is empty).
public fun floor_price_scaled(t: &Treasury): u64 {
    let supply = coin::total_supply(&t.cap);
    if (supply == 0) { 0 }
    else { ((balance::value(&t.vault) as u128) * 1_000_000_000 / (supply as u128)) as u64 }
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(GTS {}, ctx) }

#[test_only]
public fun vault_fill_for_testing(t: &mut Treasury, amount: u64, ctx: &mut TxContext) {
    balance::join(&mut t.vault, coin::into_balance(coin::mint_for_testing<SUI>(amount, ctx)));
}
