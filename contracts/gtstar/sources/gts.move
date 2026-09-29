/// GTS token (relaunch) and its SUI reserve.
///
///  - Hard cap of 1,000,000 GTS. No premine: GTS is only minted by the game in this package
///    (`mint` is package-only), and never past the cap. Burned GTS is never re-minted.
///  - Reserve: SUI can only leave the reserve through `redeem`, which pays each holder a
///    pro-rata share and burns their GTS.
module gtstar::gts;

use std::ascii;
use std::string;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, CoinMetadata, TreasuryCap};
use sui::event;
use sui::sui::SUI;
use sui::url;

/// One-time witness.
public struct GTS has drop {}

const DECIMALS: u8 = 9;
const MAX_SUPPLY: u64 = 1_000_000 * 1_000_000_000;

const ERedeemZero: u64 = 1;
const EEmptyVault: u64 = 2;

/// Shared: mint authority, reserve and total minted.
public struct Treasury has key {
    id: UID,
    cap: TreasuryCap<GTS>,
    vault: Balance<SUI>,
    minted: u64, // total ever minted (burns do not free up room)
}

public struct Redeemed has copy, drop { player: address, gts_burned: u64, sui_out: u64 }

#[allow(deprecated_usage)]
fun init(witness: GTS, ctx: &mut TxContext) {
    let (cap, metadata) = coin::create_currency(
        witness,
        DECIMALS,
        b"GTS",
        b"GTStar",
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

/// Floor price in SUI per 1 GTS, scaled by 1e9. Returns 0 if no supply.
public fun floor_price_scaled(t: &Treasury): u64 {
    let supply = coin::total_supply(&t.cap);
    if (supply == 0) { 0 }
    else { ((balance::value(&t.vault) as u128) * 1_000_000_000 / (supply as u128)) as u64 }
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(GTS {}, ctx) }
