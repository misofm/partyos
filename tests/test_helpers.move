#[test_only]
module partyos::test_helpers;

use partyos::party::{Self, Party, PartyAdminCap};
use std::string::String;
use sui::clock;

/// Creates an individual party with a default name for testing.
public fun individual(ctx: &mut TxContext): (Party, PartyAdminCap) {
    let clock = clock::create_for_testing(ctx);
    let (party, cap) = party::new(party::new_individual_kind(), b"Test Artist".to_string(), &clock, ctx);
    clock.destroy_for_testing();
    (party, cap)
}

/// Creates an individual party with a custom name for testing.
public fun individual_named(name: String, ctx: &mut TxContext): (Party, PartyAdminCap) {
    let clock = clock::create_for_testing(ctx);
    let (party, cap) = party::new(party::new_individual_kind(), name, &clock, ctx);
    clock.destroy_for_testing();
    (party, cap)
}

/// Creates a group party with a default name for testing.
public fun group(ctx: &mut TxContext): (Party, PartyAdminCap) {
    let clock = clock::create_for_testing(ctx);
    let (party, cap) = party::new(party::new_group_kind(), b"Test Group".to_string(), &clock, ctx);
    clock.destroy_for_testing();
    (party, cap)
}

/// Creates a string of the given length filled with 'A' characters.
public fun long_string(len: u64): String {
    let mut s = vector<u8>[];
    len.do!(|_| s.push_back(65));
    s.to_string()
}

/// Creates a fake ID for testing by creating and immediately deleting a UID.
public fun fake_id(ctx: &mut TxContext): ID {
    let uid = object::new(ctx);
    let id = uid.to_inner();
    uid.delete();
    id
}
