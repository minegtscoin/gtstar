/// Timelock for the GTStar game's UpgradeCap.
///
/// Once the UpgradeCap is locked here it can never be taken out again. Every upgrade must be
/// announced on-chain (with the exact digest of the new code) at least DELAY_MS before it can
/// run, so anyone can see and check a new version two days before it goes live. The only other
/// things the owner can do are cancel an announcement or make the game immutable for good.
/// This package itself is made immutable right after it is published.
module gtstar_timelock::timelock;

use sui::clock::{Self, Clock};
use sui::event;
use sui::package::{Self, UpgradeCap, UpgradeTicket, UpgradeReceipt};

/// 48 hours between the announcement and the upgrade.
const DELAY_MS: u64 = 172_800_000;

const ENothingAnnounced: u64 = 1;
const ETooEarly: u64 = 2;
const EAlreadyAnnounced: u64 = 3;

/// Holds the UpgradeCap. Owned by the deployer; it has no `store`, so it cannot be sent elsewhere.
public struct Timelock has key {
    id: UID,
    cap: UpgradeCap,
    pending: Option<Pending>,
}

public struct Pending has store, drop, copy {
    policy: u8,
    digest: vector<u8>,
    ready_ms: u64,
}

public struct Locked has copy, drop { timelock: ID, package: ID, delay_ms: u64 }
public struct Announced has copy, drop { package: ID, policy: u8, digest: vector<u8>, ready_ms: u64 }
public struct Cancelled has copy, drop { package: ID, digest: vector<u8> }
public struct Upgraded has copy, drop { package: ID, version: u64 }
public struct MadeImmutable has copy, drop { package: ID }

/// Lock an UpgradeCap. There is no function that gives it back.
entry fun lock(cap: UpgradeCap, ctx: &mut TxContext) {
    let tl = Timelock { id: object::new(ctx), cap, pending: option::none() };
    event::emit(Locked { timelock: object::id(&tl), package: package::upgrade_package(&tl.cap), delay_ms: DELAY_MS });
    transfer::transfer(tl, tx_context::sender(ctx));
}

/// Announce an upgrade: `digest` is the digest of the new package, which can run from `ready_ms`.
entry fun announce(tl: &mut Timelock, policy: u8, digest: vector<u8>, clock: &Clock) {
    assert!(option::is_none(&tl.pending), EAlreadyAnnounced);
    let ready_ms = clock::timestamp_ms(clock) + DELAY_MS;
    tl.pending = option::some(Pending { policy, digest, ready_ms });
    event::emit(Announced { package: package::upgrade_package(&tl.cap), policy, digest, ready_ms });
}

/// Drop the pending announcement.
entry fun cancel(tl: &mut Timelock) {
    assert!(option::is_some(&tl.pending), ENothingAnnounced);
    let p = option::extract(&mut tl.pending);
    event::emit(Cancelled { package: package::upgrade_package(&tl.cap), digest: p.digest });
}

/// After the delay: authorize exactly the announced upgrade (the chain checks the digest).
public fun authorize(tl: &mut Timelock, clock: &Clock): UpgradeTicket {
    assert!(option::is_some(&tl.pending), ENothingAnnounced);
    let p = option::extract(&mut tl.pending);
    assert!(clock::timestamp_ms(clock) >= p.ready_ms, ETooEarly);
    package::authorize_upgrade(&mut tl.cap, p.policy, p.digest)
}

/// Finish the upgrade in the same transaction.
public fun commit(tl: &mut Timelock, receipt: UpgradeReceipt) {
    package::commit_upgrade(&mut tl.cap, receipt);
    event::emit(Upgraded { package: package::upgrade_package(&tl.cap), version: package::version(&tl.cap) });
}

/// Make the game immutable for good (no delay: it only removes power).
entry fun make_immutable(tl: Timelock) {
    let Timelock { id, cap, pending: _ } = tl;
    event::emit(MadeImmutable { package: package::upgrade_package(&cap) });
    object::delete(id);
    package::make_immutable(cap);
}

// ===== Views =====
public fun delay_ms(): u64 { DELAY_MS }
public fun ready_ms(tl: &Timelock): u64 {
    if (option::is_some(&tl.pending)) { option::borrow(&tl.pending).ready_ms } else { 0 }
}

#[test_only]
public fun lock_for_testing(cap: UpgradeCap, ctx: &mut TxContext): Timelock {
    Timelock { id: object::new(ctx), cap, pending: option::none() }
}

#[test_only]
public fun destroy_for_testing(tl: Timelock) { make_immutable(tl) }
