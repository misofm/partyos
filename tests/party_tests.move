#[test_only]
module partyos::party_tests;

use partyos::party::{Self, Party, PartyAdminCap};
use partyos::test_helpers;
use std::unit_test::{assert_eq, destroy};

// Error codes from party.move
const EUnauthorized: u64 = 0;
const ENotIndividualKind: u64 = 10;
const ENotGroupKind: u64 = 11;
const EMaxGroupMembersExceeded: u64 = 30;
const EMaxNameLengthExceeded: u64 = 31;
const EEmptyString: u64 = 32;
const EDuplicateParty: u64 = 40;
const EAlreadyInvited: u64 = 42;
const ENotGroupMember: u64 = 50;
const ENoPendingInvite: u64 = 51;

// Must match party.move
const MAX_NAME_LENGTH: u64 = 200;
const MAX_GROUP_MEMBERS: u64 = 200;

/// invite + accept in one step (the common path when one operator holds both caps).
fun join(
    group: &mut Party,
    group_cap: &PartyAdminCap,
    member: &mut Party,
    member_cap: &PartyAdminCap,
    ctx: &mut TxContext,
) {
    group.invite_party(member, group_cap);
    group.accept_invite(member, member_cap, ctx);
}

// === Individual Party ===

#[test]
fun test_new_individual() {
    let ctx = &mut tx_context::dummy();
    let (party, cap) = test_helpers::individual(ctx);
    assert_eq!(party.name(), b"Test Artist".to_string());
    assert!(party.is_individual_kind());
    assert!(!party.is_group_kind());
    destroy(party);
    destroy(cap);
}

#[test]
fun test_new_individual_with_max_name() {
    let ctx = &mut tx_context::dummy();
    let name = test_helpers::long_string(MAX_NAME_LENGTH);
    let (party, cap) = test_helpers::individual_named(name, ctx);
    assert_eq!(party.name().length(), MAX_NAME_LENGTH);
    destroy(party);
    destroy(cap);
}

// === Group Party ===

#[test]
fun test_new_group() {
    let ctx = &mut tx_context::dummy();
    let (party, cap) = test_helpers::group(ctx);
    assert!(party.is_group_kind());
    assert!(!party.is_individual_kind());
    assert!(party.group_members().is_empty());
    destroy(party);
    destroy(cap);
}

// === Invite / Accept ===

#[test]
fun test_join_group() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut individual, individual_cap) = test_helpers::individual(ctx);

    let party_id = object::id(&individual);
    join(&mut group, &group_cap, &mut individual, &individual_cap, ctx);

    // Both sides recorded: the group's set and the member's own membership df.
    assert_eq!(group.group_members().length(), 1);
    assert!(group.group_members().contains(&party_id));
    assert!(party::is_member(&individual, object::id(&group)));
    assert!(!group.has_pending_invite(party_id)); // invite consumed
    assert!(!party::has_pending_membership(&individual, object::id(&group))); // inbox entry consumed
    assert_eq!(sui::event::events_by_type<party::PartyJoinedGroupEvent>().length(), 1);

    destroy(group);
    destroy(group_cap);
    destroy(individual);
    destroy(individual_cap);
}

#[test]
fun test_join_multiple() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut ind1, cap1) = test_helpers::individual_named(b"Artist 1".to_string(), ctx);
    let (mut ind2, cap2) = test_helpers::individual_named(b"Artist 2".to_string(), ctx);
    let (mut ind3, cap3) = test_helpers::individual_named(b"Artist 3".to_string(), ctx);

    join(&mut group, &group_cap, &mut ind1, &cap1, ctx);
    join(&mut group, &group_cap, &mut ind2, &cap2, ctx);
    join(&mut group, &group_cap, &mut ind3, &cap3, ctx);

    assert_eq!(group.group_members().length(), 3);

    destroy(group);
    destroy(group_cap);
    destroy(ind1);
    destroy(cap1);
    destroy(ind2);
    destroy(cap2);
    destroy(ind3);
    destroy(cap3);
}

#[test]
fun test_decline_invite() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut member, member_cap) = test_helpers::individual(ctx);

    group.invite_party(&mut member, &group_cap);
    assert!(group.has_pending_invite(object::id(&member)));
    assert!(party::has_pending_membership(&member, object::id(&group)));

    group.decline_invite(&mut member, &member_cap);
    assert!(!group.has_pending_invite(object::id(&member)));
    assert!(!party::has_pending_membership(&member, object::id(&group)));
    assert_eq!(group.group_members().length(), 0);

    destroy(group);
    destroy(group_cap);
    destroy(member);
    destroy(member_cap);
}

#[test]
fun test_revoke_invite() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut member, member_cap) = test_helpers::individual(ctx);

    let member_id = object::id(&member);
    group.invite_party(&mut member, &group_cap);
    assert!(group.has_pending_invite(member_id));
    assert!(party::has_pending_membership(&member, object::id(&group)));

    group.revoke_invite(&mut member, &group_cap);
    assert!(!group.has_pending_invite(member_id));
    assert!(!party::has_pending_membership(&member, object::id(&group)));

    destroy(group);
    destroy(group_cap);
    destroy(member);
    destroy(member_cap);
}

#[test, expected_failure(abort_code = ENoPendingInvite, location = party)]
fun test_accept_without_invite() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut member, member_cap) = test_helpers::individual(ctx);

    group.accept_invite(&mut member, &member_cap, ctx); // no pending invite

    destroy(group);
    destroy(group_cap);
    destroy(member);
    destroy(member_cap);
}

#[test, expected_failure(abort_code = EUnauthorized, location = party)]
fun test_accept_with_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut member, member_cap) = test_helpers::individual(ctx);
    let (other, other_cap) = test_helpers::individual(ctx);

    group.invite_party(&mut member, &group_cap);
    group.accept_invite(&mut member, &other_cap, ctx); // not the member's cap

    destroy(group);
    destroy(group_cap);
    destroy(member);
    destroy(member_cap);
    destroy(other);
    destroy(other_cap);
}

// === Remove / Evict ===

#[test]
fun test_remove_member() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut individual, individual_cap) = test_helpers::individual(ctx);

    join(&mut group, &group_cap, &mut individual, &individual_cap, ctx);
    assert_eq!(group.group_members().length(), 1);

    // Admin evict — scrubs both the set and the member's own record, no member cap.
    group.remove_member(&group_cap, &mut individual);
    assert_eq!(group.group_members().length(), 0);
    assert!(!party::is_member(&individual, object::id(&group)));

    destroy(group);
    destroy(group_cap);
    destroy(individual);
    destroy(individual_cap);
}

// === Set Name ===

#[test]
fun test_set_name() {
    let ctx = &mut tx_context::dummy();
    let (mut party, cap) = test_helpers::individual(ctx);
    party.set_name(&cap, b"New Name".to_string());
    assert_eq!(party.name(), b"New Name".to_string());
    destroy(party);
    destroy(cap);
}

#[test]
fun test_set_name_at_max_length() {
    let ctx = &mut tx_context::dummy();
    let (mut party, cap) = test_helpers::individual(ctx);
    let name = test_helpers::long_string(MAX_NAME_LENGTH);
    party.set_name(&cap, name);
    assert_eq!(party.name().length(), MAX_NAME_LENGTH);
    destroy(party);
    destroy(cap);
}

// === Boundary Tests ===

#[test, expected_failure(abort_code = EMaxGroupMembersExceeded, location = party)]
fun test_invite_exceeds_max_group_members() {
    let ctx = &mut tx_context::dummy();
    // Create a group pre-filled with MAX_GROUP_MEMBERS members.
    let (mut group, group_cap) = party::new_group_with_n_members_for_testing(MAX_GROUP_MEMBERS, ctx);

    // Inviting one more should fail (the group is already full).
    let (mut individual, individual_cap) = test_helpers::individual(ctx);
    group.invite_party(&mut individual, &group_cap);

    destroy(individual);
    destroy(individual_cap);
    destroy(group);
    destroy(group_cap);
}

// === Error Conditions ===

#[test, expected_failure(abort_code = EEmptyString, location = party)]
fun test_new_empty_name() {
    let ctx = &mut tx_context::dummy();
    let clock = sui::clock::create_for_testing(ctx);
    let (party, cap) = party::new(party::new_individual_kind(), b"".to_string(), &clock, ctx);
    destroy(party);
    destroy(cap);
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = EMaxNameLengthExceeded, location = party)]
fun test_new_name_too_long() {
    let ctx = &mut tx_context::dummy();
    let clock = sui::clock::create_for_testing(ctx);
    let (party, cap) = party::new(
        party::new_individual_kind(),
        test_helpers::long_string(MAX_NAME_LENGTH + 1),
        &clock,
        ctx,
    );
    destroy(party);
    destroy(cap);
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = EEmptyString, location = party)]
fun test_set_name_empty() {
    let ctx = &mut tx_context::dummy();
    let (mut party, cap) = test_helpers::individual(ctx);
    party.set_name(&cap, b"".to_string());
    destroy(party);
    destroy(cap);
}

#[test, expected_failure(abort_code = EMaxNameLengthExceeded, location = party)]
fun test_set_name_too_long() {
    let ctx = &mut tx_context::dummy();
    let (mut party, cap) = test_helpers::individual(ctx);
    party.set_name(&cap, test_helpers::long_string(MAX_NAME_LENGTH + 1));
    destroy(party);
    destroy(cap);
}

#[test, expected_failure(abort_code = EDuplicateParty, location = party)]
fun test_invite_already_member() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut individual, individual_cap) = test_helpers::individual(ctx);

    join(&mut group, &group_cap, &mut individual, &individual_cap, ctx);
    group.invite_party(&mut individual, &group_cap); // already a member

    destroy(group);
    destroy(group_cap);
    destroy(individual);
    destroy(individual_cap);
}

#[test, expected_failure(abort_code = EAlreadyInvited, location = party)]
fun test_invite_duplicate_pending() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut individual, individual_cap) = test_helpers::individual(ctx);

    group.invite_party(&mut individual, &group_cap);
    group.invite_party(&mut individual, &group_cap); // already invited (pending)

    destroy(group);
    destroy(group_cap);
    destroy(individual);
    destroy(individual_cap);
}

#[test, expected_failure(abort_code = ENotGroupKind, location = party)]
fun test_invite_on_individual() {
    let ctx = &mut tx_context::dummy();
    let (mut party1, cap1) = test_helpers::individual(ctx);
    let (mut party2, cap2) = test_helpers::individual(ctx);

    party1.invite_party(&mut party2, &cap1);

    destroy(party1);
    destroy(cap1);
    destroy(party2);
    destroy(cap2);
}

#[test, expected_failure(abort_code = ENotIndividualKind, location = party)]
fun test_invite_group_as_member() {
    let ctx = &mut tx_context::dummy();
    let (mut group1, cap1) = test_helpers::group(ctx);
    let (mut group2, cap2) = test_helpers::group(ctx);

    group1.invite_party(&mut group2, &cap1);

    destroy(group1);
    destroy(cap1);
    destroy(group2);
    destroy(cap2);
}

#[test, expected_failure(abort_code = EUnauthorized, location = party)]
fun test_unauthorized_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut party1, cap1) = test_helpers::individual(ctx);
    let (party2, cap2) = test_helpers::individual(ctx);

    // Try to use party2's cap on party1.
    party1.set_name(&cap2, b"Hacked".to_string());

    destroy(party1);
    destroy(cap1);
    destroy(party2);
    destroy(cap2);
}

#[test, expected_failure(abort_code = ENotGroupKind, location = party)]
fun test_remove_member_on_individual() {
    let ctx = &mut tx_context::dummy();
    let (mut party, cap) = test_helpers::individual(ctx);
    let (mut member, member_cap) = test_helpers::individual(ctx);

    party.remove_member(&cap, &mut member); // `party` is not a group

    destroy(party);
    destroy(cap);
    destroy(member);
    destroy(member_cap);
}

#[test, expected_failure(abort_code = ENotGroupKind, location = party)]
fun test_group_members_on_individual() {
    let ctx = &mut tx_context::dummy();
    let (party, cap) = test_helpers::individual(ctx);

    party.group_members(); // should abort

    destroy(party);
    destroy(cap);
}

// === Leave Group ===

#[test]
fun test_leave_group() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut member, member_cap) = test_helpers::individual(ctx);

    join(&mut group, &group_cap, &mut member, &member_cap, ctx);
    assert_eq!(group.group_members().length(), 1);

    // The member's own cap authorizes the exit — no group admin involved.
    group.leave(&mut member, &member_cap);
    assert_eq!(group.group_members().length(), 0);
    assert!(!party::is_member(&member, object::id(&group)));
    assert_eq!(sui::event::events_by_type<party::PartyLeftGroupEvent>().length(), 1);
    assert_eq!(sui::event::events_by_type<party::PartyRemovedFromGroupEvent>().length(), 0);

    destroy(group);
    destroy(group_cap);
    destroy(member);
    destroy(member_cap);
}

#[test, expected_failure(abort_code = ENotGroupMember, location = party)]
fun test_leave_not_a_member() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut outsider, outsider_cap) = test_helpers::individual(ctx);

    group.leave(&mut outsider, &outsider_cap); // never joined

    destroy(group);
    destroy(group_cap);
    destroy(outsider);
    destroy(outsider_cap);
}

#[test, expected_failure(abort_code = ENotGroupKind, location = party)]
fun test_leave_on_individual() {
    let ctx = &mut tx_context::dummy();
    let (mut individual, individual_cap) = test_helpers::individual(ctx);
    let (mut member, member_cap) = test_helpers::individual(ctx);

    individual.leave(&mut member, &member_cap); // `individual` is not a group

    destroy(individual);
    destroy(individual_cap);
    destroy(member);
    destroy(member_cap);
}

#[test, expected_failure(abort_code = ENotGroupMember, location = party)]
fun test_remove_member_not_a_member() {
    let ctx = &mut tx_context::dummy();
    let (mut group, group_cap) = test_helpers::group(ctx);
    let (mut outsider, outsider_cap) = test_helpers::individual(ctx);

    group.remove_member(&group_cap, &mut outsider); // never joined

    destroy(group);
    destroy(group_cap);
    destroy(outsider);
    destroy(outsider_cap);
}
