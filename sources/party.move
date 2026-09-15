// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Represents parties (individuals or groups) that participate in on-chain
/// activities. A party is a named entity with capability-based authorization.
///
/// ### Key Features:
///
/// - Individual and group party types
/// - Extensible metadata via dynamic fields
/// - Capability-based authorization for modifications
/// - Groups can contain multiple individual parties
module partyos::party;

use std::option::{Self, Option};
use std::string::String;
use sui::clock::Clock;
use sui::derived_object::claim;
use sui::dynamic_field as df;
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

public use fun party_admin_cap_party_id as PartyAdminCap.party_id;
public use fun party_kind_name as PartyKind.name;

// === Structs ===

/// A party in the ecosystem. Can represent an individual or a group of parties.
public struct Party has key {
    /// Unique identifier for this party.
    id: UID,
    /// Whether this is an individual or group party.
    kind: PartyKind,
    /// Human-readable name of the party.
    /// Note this name is not "official" or "verified" in any way.
    /// Verification should be performed by the application layer.
    name: String,
    /// Unix ms when the party was created. Set once at `new`; immutable.
    created_at_ms: u64,
}

/// Capability that authorizes modifications to a specific party.
/// Created when a party is registered and transferred to the owner.
public struct PartyAdminCap has key, store {
    /// Unique identifier for this capability.
    id: UID,
    /// ID of the party this capability controls.
    party_id: ID,
}

// === Derivation Keys ===

/// Key for deriving the admin capability's deterministic address.
public struct PartyAdminCapKey(
    /// ID of the party.
    ID,
) has copy, drop, store;

// === Membership Records (dynamic fields) ===

/// Key for a group's pending invite to an individual party, stored on the
/// GROUP's UID. Its presence means "invited, awaiting the member's accept".
public struct PendingInviteKey(
    /// ID of the invited member party.
    ID,
) has copy, drop, store;

/// Key for a group's pending invitation, stored on the invited MEMBER party's
/// UID. Its presence is the member-facing inbox index: it lets a party discover
/// every group that is awaiting its response without scanning all groups.
public struct PendingMembershipKey(
    /// ID of the inviting group party.
    ID,
) has copy, drop, store;

/// Key for a membership record, stored on the MEMBER party's UID — one per
/// group the party belongs to. Only this module can construct it, so a
/// membership record can never be forged by an extension holding `uid_mut`.
public struct MembershipKey(
    /// ID of the group party.
    ID,
) has copy, drop, store;

/// A member party's record of belonging to a group, held as the value of a
/// `MembershipKey` dynamic field on the member. Mirrors the group's member set;
/// the two are always written together so they can't diverge.
public struct Membership has store, drop {
    /// Epoch in which the party joined the group.
    since_epoch: u64,
}

// === Enums ===

/// The type of self: individual person or group.
public enum PartyKind has copy, drop, store {
    /// A single person (artist, producer, etc.).
    Individual,
    /// A group containing multiple individual parties.
    Group(
        /// Set of individual party IDs in this group.
        VecSet<ID>,
    ),
}

// === Events ===

/// Emitted once when the newly created party is shared. The payload contains
/// its final same-transaction state and the original creation provenance.
public struct PartyCreatedEvent has copy, drop {
    party_id: ID,
    admin_cap_id: ID,
    name: String,
    /// Kind discriminant: 0 for an individual and 1 for a group.
    kind: u8,
    /// Group member IDs in `VecSet` insertion order, or an empty vector for an
    /// individual.
    member_ids: vector<ID>,
    creator: address,
    created_at_ms: u64,
    /// Epoch in which the party was created.
    created_epoch: u64,
}

/// Emitted after the party name is changed.
public struct PartyNameSetEvent has copy, drop {
    party_id: ID,
    admin_cap_id: ID,
    old_name: String,
    name: String,
}

/// Emitted after a group creates a pending invitation.
public struct PartyGroupInviteCreatedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
    group_admin_cap_id: ID,
    group_member_count: u64,
    pending_invite: bool,
    pending_membership: bool,
}

/// Emitted after an invited party accepts and joins a group.
public struct PartyGroupMembershipAcceptedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
    member_admin_cap_id: ID,
    group_member_count: u64,
    pending_invite: bool,
    pending_membership: bool,
    group_contains_member: bool,
    membership_present: bool,
    since_epoch: u64,
    accepted_by: address,
}

/// Emitted after an invited party declines a pending invitation.
public struct PartyGroupInviteDeclinedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
    member_admin_cap_id: ID,
    pending_invite: bool,
    pending_membership: bool,
}

/// Emitted after a group's admin revokes a pending invitation.
public struct PartyGroupInviteRevokedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
    group_admin_cap_id: ID,
    pending_invite: bool,
    pending_membership: bool,
}

/// Emitted after a party leaves a group using its own admin capability.
public struct PartyGroupMembershipLeftEvent has copy, drop {
    group_id: ID,
    member_id: ID,
    member_admin_cap_id: ID,
    group_member_count: u64,
    group_contains_member: bool,
    membership_present: bool,
    removed_since_epoch: Option<u64>,
}

/// Emitted after a group's admin removes a party from the group.
public struct PartyGroupMembershipRemovedEvent has copy, drop {
    group_id: ID,
    member_id: ID,
    group_admin_cap_id: ID,
    group_member_count: u64,
    group_contains_member: bool,
    membership_present: bool,
    removed_since_epoch: Option<u64>,
}

// === Constants ===

/// Maximum number of members allowed in a group.
const MAX_GROUP_MEMBERS: u64 = 200;
/// Maximum length of a party name in bytes.
const MAX_NAME_LENGTH: u64 = 200;

// === Errors ===

// Authorization errors (0-9)
/// The provided admin capability does not match this party.
const EUnauthorized: u64 = 0;

// State errors (10-19)
/// Operation requires an individual party, but a group was provided.
const ENotIndividualKind: u64 = 10;
/// Operation requires a group party, but an individual was provided.
const ENotGroupKind: u64 = 11;

// Constraint errors (30-39)
/// Group has too many members.
const EMaxGroupMembersExceeded: u64 = 30;
/// Name exceeds maximum length.
const EMaxNameLengthExceeded: u64 = 31;
/// String must not be empty.
const EEmptyString: u64 = 32;

// Conflict errors (40-49)
/// Attempted to invite a party that is already a member of the group.
const EDuplicateParty: u64 = 40;
/// Attempted to add a group as a member of itself.
const ECantAddSelfAsMember: u64 = 41;
/// The party already has a pending invite to this group.
const EAlreadyInvited: u64 = 42;

// Reference errors (50-59)
/// The party is not a member of the group.
const ENotGroupMember: u64 = 50;
/// No pending invite exists for the party in this group.
const ENoPendingInvite: u64 = 51;

// Returns the compact kind discriminant and a copy of the group's member IDs
// in their VecSet insertion order. This helper only reads party state so it can
// be used for the creation snapshot emitted when a party is shared.
fun kind_and_member_ids(kind: &PartyKind): (u8, vector<ID>) {
    match (kind) {
        PartyKind::Individual => (0, vector[]),
        PartyKind::Group(members) => (1, vec_set::into_keys(*members)),
    }
}

// === Public Functions ===

/// Creates a new party with the specified kind and name.
/// Returns the admin capability for managing the party.
/// The returned key-only party must be shared before the transaction completes.
public fun new(
    kind: PartyKind,
    name: String,
    clock: &Clock,
    ctx: &mut TxContext,
): (Party, PartyAdminCap) {
    assert!(!name.is_empty(), EEmptyString);
    assert!(name.length() <= MAX_NAME_LENGTH, EMaxNameLengthExceeded);

    let created_at_ms = clock.timestamp_ms();
    let mut party = Party {
        id: object::new(ctx),
        kind,
        name,
        created_at_ms,
    };

    let party_id = object::id(&party);

    let party_admin_cap = PartyAdminCap {
        id: claim(&mut party.id, PartyAdminCapKey(party_id)),
        party_id,
    };

    (party, party_admin_cap)
}

/// Shares the party object, making it publicly accessible.
/// Requires the admin capability. The creation snapshot is emitted from the
/// final pre-share state. Creation and sharing must finish in one transaction,
/// so `ctx` retains the original creator and creation epoch.
public fun share(self: Party, cap: &PartyAdminCap, ctx: &TxContext) {
    self.authorize(cap);
    let party_id = object::id(&self);
    let admin_cap_id = object::id(cap);
    let name = self.name;
    let (kind, member_ids) = kind_and_member_ids(&self.kind);
    let created_at_ms = self.created_at_ms;
    transfer::share_object(self);
    emit(PartyCreatedEvent {
        party_id,
        admin_cap_id,
        name,
        kind,
        member_ids,
        creator: ctx.sender(),
        created_at_ms,
        created_epoch: ctx.epoch(),
    });
}

/// Sets the human-readable name of the party.
/// Requires the admin capability. Equal-value writes retain their validation,
/// authorization, and state assignment but do not emit a change event.
public fun set_name(self: &mut Party, cap: &PartyAdminCap, name: String) {
    self.authorize(cap);
    assert!(!name.is_empty(), EEmptyString);
    assert!(name.length() <= MAX_NAME_LENGTH, EMaxNameLengthExceeded);
    let name_changed = self.name != name;
    let old_name = self.name;
    let party_id = object::id(self);
    let admin_cap_id = object::id(cap);
    self.name = name;

    if (name_changed) {
        emit(PartyNameSetEvent {
            party_id,
            admin_cap_id,
            old_name,
            name,
        });
    }
}

/// Invites an individual party to join a group. Requires the group's admin
/// capability. Records matching pending-invite indexes on both parties; the
/// invited party joins only by calling `accept_invite` with its own admin cap —
/// so no party can be made a member without its consent. The party being
/// invited must be an individual (not another group).
public fun invite_party(
    group: &mut Party,
    member: &mut Party,
    group_cap: &PartyAdminCap,
) {
    group.authorize(group_cap);
    group.assert_is_group_kind();

    let group_id = object::id(group);
    let member_id = object::id(member);

    assert!(member_id != group_id, ECantAddSelfAsMember);
    member.assert_is_individual_kind();
    assert!(!group.group_members().contains(&member_id), EDuplicateParty);
    assert!(group.group_members().length() < MAX_GROUP_MEMBERS, EMaxGroupMembersExceeded);
    assert!(!df::exists(&group.id, PendingInviteKey(member_id)), EAlreadyInvited);
    assert!(!df::exists(&member.id, PendingMembershipKey(group_id)), EAlreadyInvited);

    df::add(&mut group.id, PendingInviteKey(member_id), true);
    df::add(&mut member.id, PendingMembershipKey(group_id), true);

    emit(PartyGroupInviteCreatedEvent {
        group_id,
        member_id,
        group_admin_cap_id: object::id(group_cap),
        group_member_count: group.group_members().length(),
        pending_invite: df::exists(&group.id, PendingInviteKey(member_id)),
        pending_membership: df::exists(&member.id, PendingMembershipKey(group_id)),
    });
}

/// Accepts a pending invite, joining `member` to `group`. Requires the
/// *member's* own admin cap (consent). Consumes the pending invite, inserts the
/// member into the group's set, and writes a `Membership` record onto the
/// member party — both sides in one transaction, so they can't diverge.
public fun accept_invite(
    group: &mut Party,
    member: &mut Party,
    member_cap: &PartyAdminCap,
    ctx: &TxContext,
) {
    member.authorize(member_cap);
    group.assert_is_group_kind();

    let group_id = object::id(group);
    let member_id = object::id(member);

    assert!(df::exists(&group.id, PendingInviteKey(member_id)), ENoPendingInvite);
    assert!(df::exists(&member.id, PendingMembershipKey(group_id)), ENoPendingInvite);
    let _: bool = df::remove(&mut group.id, PendingInviteKey(member_id));
    let _: bool = df::remove(&mut member.id, PendingMembershipKey(group_id));

    match (&mut group.kind) {
        PartyKind::Group(members) => {
            assert!(members.length() < MAX_GROUP_MEMBERS, EMaxGroupMembersExceeded);
            members.insert(member_id);
        },
        _ => abort ENotGroupKind,
    };

    let since_epoch = ctx.epoch();
    df::add(&mut member.id, MembershipKey(group_id), Membership { since_epoch });

    emit(PartyGroupMembershipAcceptedEvent {
        group_id,
        member_id,
        member_admin_cap_id: object::id(member_cap),
        group_member_count: group.group_members().length(),
        pending_invite: df::exists(&group.id, PendingInviteKey(member_id)),
        pending_membership: df::exists(&member.id, PendingMembershipKey(group_id)),
        group_contains_member: group.group_members().contains(&member_id),
        membership_present: df::exists(&member.id, MembershipKey(group_id)),
        since_epoch,
        accepted_by: ctx.sender(),
    });
}

/// Declines a pending invite, authorized by the invited party's own admin cap.
/// Clears the group-side invitation and the member-facing inbox entry together.
public fun decline_invite(
    group: &mut Party,
    member: &mut Party,
    member_cap: &PartyAdminCap,
) {
    member.authorize(member_cap);
    let group_id = object::id(group);
    let member_id = object::id(member);
    assert!(df::exists(&group.id, PendingInviteKey(member_id)), ENoPendingInvite);
    assert!(df::exists(&member.id, PendingMembershipKey(group_id)), ENoPendingInvite);
    let _: bool = df::remove(&mut group.id, PendingInviteKey(member_id));
    let _: bool = df::remove(&mut member.id, PendingMembershipKey(group_id));

    emit(PartyGroupInviteDeclinedEvent {
        group_id,
        member_id,
        member_admin_cap_id: object::id(member_cap),
        pending_invite: df::exists(&group.id, PendingInviteKey(member_id)),
        pending_membership: df::exists(&member.id, PendingMembershipKey(group_id)),
    });
}

/// Revokes a pending invite, authorized by the group's admin cap. Clears the
/// group-side invitation and the member-facing inbox entry together.
public fun revoke_invite(
    group: &mut Party,
    member: &mut Party,
    group_cap: &PartyAdminCap,
) {
    group.authorize(group_cap);
    let group_id = object::id(group);
    let member_id = object::id(member);
    assert!(df::exists(&group.id, PendingInviteKey(member_id)), ENoPendingInvite);
    assert!(df::exists(&member.id, PendingMembershipKey(group_id)), ENoPendingInvite);
    let _: bool = df::remove(&mut group.id, PendingInviteKey(member_id));
    let _: bool = df::remove(&mut member.id, PendingMembershipKey(group_id));

    emit(PartyGroupInviteRevokedEvent {
        group_id,
        member_id,
        group_admin_cap_id: object::id(group_cap),
        pending_invite: df::exists(&group.id, PendingInviteKey(member_id)),
        pending_membership: df::exists(&member.id, PendingMembershipKey(group_id)),
    });
}

/// Removes the caller's party from a group, authorized by the *member's* own
/// admin capability — the member's unconditional exit. Clears both the group's
/// member set and the member's own membership record.
public fun leave(group: &mut Party, member: &mut Party, member_cap: &PartyAdminCap) {
    member.authorize(member_cap);
    let member_id = object::id(member);
    let group_id = object::id(group);

    let removed_since_epoch = remove_membership(group, member);

    emit(PartyGroupMembershipLeftEvent {
        group_id,
        member_id,
        member_admin_cap_id: object::id(member_cap),
        group_member_count: group.group_members().length(),
        group_contains_member: group.group_members().contains(&member_id),
        membership_present: df::exists(&member.id, MembershipKey(group_id)),
        removed_since_epoch,
    });
}

/// Removes (evicts) a member from a group, authorized by the *group's* admin
/// capability. Because this module owns `Party`, it can scrub the member's own
/// membership record here even without the member's cap — but only the record
/// for *this* group, so the admin's reach into the member is scoped to
/// "cancel my group's membership" and nothing else on the member is touchable.
public fun remove_member(group: &mut Party, group_cap: &PartyAdminCap, member: &mut Party) {
    group.authorize(group_cap);
    let member_id = object::id(member);
    let group_id = object::id(group);

    let removed_since_epoch = remove_membership(group, member);

    emit(PartyGroupMembershipRemovedEvent {
        group_id,
        member_id,
        group_admin_cap_id: object::id(group_cap),
        group_member_count: group.group_members().length(),
        group_contains_member: group.group_members().contains(&member_id),
        membership_present: df::exists(&member.id, MembershipKey(group_id)),
        removed_since_epoch,
    });
}

/// Removes a membership from both sides: the group's member set and the
/// member's `MembershipKey` record. Aborts if the party is not a member.
fun remove_membership(group: &mut Party, member: &mut Party): Option<u64> {
    let group_id = object::id(group);
    let member_id = object::id(member);

    match (&mut group.kind) {
        PartyKind::Group(members) => {
            assert!(members.contains(&member_id), ENotGroupMember);
            members.remove(&member_id);
        },
        _ => abort ENotGroupKind,
    };

    if (df::exists(&member.id, MembershipKey(group_id))) {
        let Membership { since_epoch } = df::remove(&mut member.id, MembershipKey(group_id));
        option::some(since_epoch)
    } else {
        option::none()
    }
}

/// Creates a new individual party kind.
public fun new_individual_kind(): PartyKind {
    PartyKind::Individual
}

/// Creates a new group party kind with an empty member set.
public fun new_group_kind(): PartyKind {
    PartyKind::Group(vec_set::empty())
}

// === Public View Functions ===

/// Returns the human-readable name of this party.
public fun name(self: &Party): String {
    self.name
}

/// Returns the Unix ms when this party was created.
public fun created_at_ms(self: &Party): u64 {
    self.created_at_ms
}

/// Returns true if this party is an individual.
public fun is_individual_kind(self: &Party): bool {
    match (&self.kind) {
        PartyKind::Individual => true,
        _ => false,
    }
}

/// Returns true if this party is a group.
public fun is_group_kind(self: &Party): bool {
    match (&self.kind) {
        PartyKind::Group(_) => true,
        _ => false,
    }
}

/// Returns a reference to the group members.
/// Aborts if this party is not a group.
public fun group_members(self: &Party): &VecSet<ID> {
    match (&self.kind) {
        PartyKind::Group(members) => members,
        _ => abort ENotGroupKind,
    }
}

/// Whether `member` currently holds a membership record for `group_id`. Reads
/// the member side, so it needs only the member party (no group object) — the
/// primitive extensions use for member-gated authorization.
public fun is_member(member: &Party, group_id: ID): bool {
    df::exists(&member.id, MembershipKey(group_id))
}

/// Whether the group has a pending invite outstanding for `member_id`.
public fun has_pending_invite(group: &Party, member_id: ID): bool {
    df::exists(&group.id, PendingInviteKey(member_id))
}

/// Whether an individual party has a pending membership invitation from a group.
/// Reads the member-facing invitation index, so callers can discover invitations
/// by enumerating only the member party's dynamic fields.
public fun has_pending_membership(member: &Party, group_id: ID): bool {
    df::exists(&member.id, PendingMembershipKey(group_id))
}

/// Returns the human-readable name of the party kind.
public fun party_kind_name(self: &PartyKind): String {
    match (self) {
        PartyKind::Individual => "Individual",
        PartyKind::Group(_) => "Group",
    }
}

/// Verifies that the admin capability matches this party.
public fun authorize(self: &Party, cap: &PartyAdminCap) {
    assert!(cap.party_id == object::id(self), EUnauthorized);
}

/// Returns the ID of the party associated with the admin capability.
public fun party_admin_cap_party_id(cap: &PartyAdminCap): ID {
    cap.party_id
}

// === UID Functions ===

/// Returns a reference to the party's UID for reading dynamic fields.
public fun uid(self: &Party): &UID {
    &self.id
}

/// Returns a mutable reference to the party's UID for dynamic field operations.
/// Requires the admin capability.
public fun uid_mut(self: &mut Party, cap: &PartyAdminCap): &mut UID {
    self.authorize(cap);
    &mut self.id
}

// === Assert Functions ===

/// Aborts if this party is not an individual.
public fun assert_is_individual_kind(self: &Party) {
    assert!(is_individual_kind(self), ENotIndividualKind);
}

/// Aborts if this party is not a group.
public fun assert_is_group_kind(self: &Party) {
    assert!(is_group_kind(self), ENotGroupKind);
}

// === Test Only ===

/// Extracts a creation event for assertions without exposing event fields in
/// the production API.
#[test_only]
public fun created_event_fields(
    event: PartyCreatedEvent,
): (ID, ID, String, u8, vector<ID>, address, u64, u64) {
    let PartyCreatedEvent {
        party_id,
        admin_cap_id,
        name,
        kind,
        member_ids,
        creator,
        created_at_ms,
        created_epoch,
    } = event;
    (party_id, admin_cap_id, name, kind, member_ids, creator, created_at_ms, created_epoch)
}

#[test_only]
public fun new_group_with_n_members_for_testing(
    n: u64,
    ctx: &mut TxContext,
): (Party, PartyAdminCap) {
    let mut members = vec_set::empty();
    n.do!(|_| {
        let uid = object::new(ctx);
        let id = uid.to_inner();
        uid.delete();
        members.insert(id);
    });

    let mut party = Party {
        id: object::new(ctx),
        kind: PartyKind::Group(members),
        name: b"Test Group".to_string(),
        created_at_ms: 0,
    };

    let party_id = object::id(&party);

    let party_admin_cap = PartyAdminCap {
        id: claim(&mut party.id, PartyAdminCapKey(party_id)),
        party_id,
    };

    (party, party_admin_cap)
}
