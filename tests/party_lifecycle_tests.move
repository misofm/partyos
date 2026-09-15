// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Multi-transaction tests for the shared-object flows parties actually live
/// in: share, post-share mutation, group editing, and the dynamic-field
/// extension surface.
#[test_only]
module partyos::party_lifecycle_tests;

use partyos::party::{Self, Party};
use partyos::test_helpers;
use std::unit_test::{assert_eq, destroy};
use sui::dynamic_field;
use sui::test_scenario;

const OWNER: address = @0xA1;
const READER: address = @0xB2;

// Error codes from party.move
const EUnauthorized: u64 = 0;
const ENotGroupKind: u64 = 11;

#[test]
fun share_makes_party_publicly_readable() {
    let mut scenario = test_scenario::begin(OWNER);
    let (mut group, group_cap) = test_helpers::group(scenario.ctx());
    let (mut member, member_cap) = test_helpers::individual(scenario.ctx());
    let group_id = object::id(&group);
    let member_id = object::id(&member);
    let group_cap_id = object::id(&group_cap);
    let created_at_ms = group.created_at_ms();
    let created_epoch = scenario.ctx().epoch();

    // Construction is silent; the creation event waits for the final snapshot.
    assert_eq!(sui::event::events_by_type<party::PartyCreatedEvent>().length(), 0);
    group.set_name(&group_cap, b"Final Group".to_string());
    group.invite_party(&mut member, &group_cap);
    group.accept_invite(&mut member, &member_cap, scenario.ctx());
    assert_eq!(group.group_members().length(), 1);
    assert_eq!(sui::event::events_by_type<party::PartyCreatedEvent>().length(), 0);

    group.share(&group_cap, scenario.ctx());
    let mut events = sui::event::events_by_type<party::PartyCreatedEvent>();
    assert_eq!(events.length(), 1);
    let (
        event_party_id,
        event_admin_cap_id,
        event_name,
        event_kind,
        event_member_ids,
        event_creator,
        event_created_at_ms,
        event_created_epoch,
    ) = party::created_event_fields(events.pop_back());
    assert_eq!(event_party_id, group_id);
    assert_eq!(event_admin_cap_id, group_cap_id);
    assert_eq!(event_name, b"Final Group".to_string());
    assert_eq!(event_kind, 1);
    assert_eq!(event_member_ids, vector[member_id]);
    assert_eq!(event_creator, OWNER);
    assert_eq!(event_created_at_ms, created_at_ms);
    assert_eq!(event_created_epoch, created_epoch);

    scenario.next_tx(READER);
    let group = scenario.take_shared<Party>();
    assert_eq!(group.name(), b"Final Group".to_string());
    assert_eq!(group.group_members().length(), 1);
    assert!(group.group_members().contains(&member_id));
    test_scenario::return_shared(group);

    destroy(member);
    destroy(member_cap);
    destroy(group_cap);
    scenario.end();
}

#[test]
fun set_name_works_on_shared_party() {
    let mut scenario = test_scenario::begin(OWNER);
    let (p, cap) = test_helpers::individual(scenario.ctx());
    p.share(&cap, scenario.ctx());
    assert_eq!(sui::event::events_by_type<party::PartyCreatedEvent>().length(), 1);

    scenario.next_tx(OWNER);
    let mut p = scenario.take_shared<Party>();
    p.set_name(&cap, b"New Stage Name".to_string());
    assert_eq!(p.name(), b"New Stage Name".to_string());
    assert_eq!(sui::event::events_by_type<party::PartyNameSetEvent>().length(), 1);
    test_scenario::return_shared(p);

    destroy(cap);
    scenario.end();
}

/// The dynamic-field extension surface works on a shared party (this is where
/// a Profile object would attach).
#[test]
fun uid_mut_attaches_dynamic_fields_on_shared_party() {
    let mut scenario = test_scenario::begin(OWNER);
    let (p, cap) = test_helpers::individual(scenario.ctx());
    p.share(&cap, scenario.ctx());

    scenario.next_tx(OWNER);
    let mut p = scenario.take_shared<Party>();
    dynamic_field::add(p.uid_mut(&cap), b"profile", 42u64);
    assert!(dynamic_field::exists(p.uid(), b"profile"));
    assert_eq!(*dynamic_field::borrow<vector<u8>, u64>(p.uid(), b"profile"), 42);
    // Dynamic-field attachment is a read/write extension operation and emits
    // no Party lifecycle event in this transaction.
    assert_eq!(sui::event::events_by_type<party::PartyCreatedEvent>().length(), 0);
    assert_eq!(sui::event::events_by_type<party::PartyNameSetEvent>().length(), 0);
    test_scenario::return_shared(p);

    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = EUnauthorized, location = party)]
fun share_rejects_wrong_cap() {
    let ctx = &mut tx_context::dummy();
    let (party, cap) = test_helpers::individual(ctx);
    let (other, other_cap) = test_helpers::individual(ctx);

    destroy(cap);
    destroy(other);
    party.share(&other_cap, ctx);
    destroy(other_cap);
}

/// Group membership lifecycle across shared objects: invite + accept, then the
/// member leaves. Exercises both `Party` objects being taken shared and mutated.
#[test]
fun member_joins_and_leaves_shared_group() {
    let mut scenario = test_scenario::begin(OWNER);
    let (group, group_cap) = test_helpers::group(scenario.ctx());
    let (member, member_cap) = test_helpers::individual(scenario.ctx());
    let group_id = object::id(&group);
    let member_id = object::id(&member);
    group.share(&group_cap, scenario.ctx());
    member.share(&member_cap, scenario.ctx());

    // Group admin invites; the member accepts with its own cap (consent).
    scenario.next_tx(OWNER);
    let mut group = scenario.take_shared_by_id<Party>(group_id);
    let mut member = scenario.take_shared_by_id<Party>(member_id);
    group.invite_party(&mut member, &group_cap);
    group.accept_invite(&mut member, &member_cap, scenario.ctx());
    assert_eq!(group.group_members().length(), 1);
    assert!(member.is_member(group_id));
    assert_eq!(sui::event::events_by_type<party::PartyGroupInviteCreatedEvent>().length(), 1);
    assert_eq!(sui::event::events_by_type<party::PartyGroupMembershipAcceptedEvent>().length(), 1);
    test_scenario::return_shared(group);
    test_scenario::return_shared(member);

    // The member exits with their own cap; both sides are cleared.
    scenario.next_tx(READER);
    let mut group = scenario.take_shared_by_id<Party>(group_id);
    let mut member = scenario.take_shared_by_id<Party>(member_id);
    group.leave(&mut member, &member_cap);
    assert!(!group.group_members().contains(&member_id));
    assert!(!member.is_member(group_id));
    assert_eq!(sui::event::events_by_type<party::PartyGroupMembershipLeftEvent>().length(), 1);
    test_scenario::return_shared(group);
    test_scenario::return_shared(member);

    destroy(group_cap);
    destroy(member_cap);
    scenario.end();
}

#[test]
fun assert_is_group_kind_accepts_group() {
    let ctx = &mut tx_context::dummy();
    let (group, cap) = test_helpers::group(ctx);
    group.assert_is_group_kind();
    destroy(group);
    destroy(cap);
}

#[test, expected_failure(abort_code = ENotGroupKind, location = party)]
fun assert_is_group_kind_rejects_individual() {
    let ctx = &mut tx_context::dummy();
    let (individual, cap) = test_helpers::individual(ctx);
    individual.assert_is_group_kind();
    destroy(individual);
    destroy(cap);
}
