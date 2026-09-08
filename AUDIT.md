# Security Audit — `partyos`

**Revision:** working tree (source snapshot — no `.git` in repo) ·
**Date:** 2026-08-23 · **Toolchain:** sui 1.77.2-51d177ad7d65 ·
**Framework:** pinned rev `2a0becb2fcc6989e492981104af67f62f2c9511a`
(`Move.lock`); no other dependencies.

Audit of `party.move` (566 LOC): the identity object every `party-*`
extension hangs off of. Verdict: **safe to publish — no
Critical/High/Medium findings.**

## What it does

A `Party` is a shared, `key`-only object (individual or group) with a
human-readable name. All mutation is gated by a `PartyAdminCap` that carries
`party_id` and is checked by object ID (`authorize`, `party.move:501-503`).
Group membership is a two-sided dynamic-field protocol:

- `invite_party` (group cap) writes matching pending markers on **both**
  parties (`party.move:285-307`);
- `accept_invite` (**member's own** cap) consumes both markers, inserts into
  the group's `VecSet<ID>`, and writes a `Membership` record on the member
  (`party.move:313-341`) — no party can be made a member without consent;
- `decline_invite` (member cap) / `revoke_invite` (group cap) clear both
  sides together;
- `leave` (member cap, unconditional exit) and `remove_member` (group cap,
  eviction) both run `remove_membership`, scrubbing the group's set and the
  member's record (`party.move:409-424`).

`uid()` is public read; `uid_mut(cap)` (`party.move:519-522`) is the sole
authority-bearing accessor — the extension surface for `party_profile`,
`party_wallet`, etc.

Threat model: forged membership (an extension or third party writing group
affiliation without consent), cap confusion across parties, unauthorized
extension writes, eviction/exit asymmetries, object bloat DoS.

## Findings

- **F1 (Informational): `invite_party` writes to the invited party's UID
  without its cap.** `df::add(&mut member.id, PendingMembershipKey(group_id),
  true)` (`party.move:304`) uses the module's own struct-field privilege over
  `Party`. Benign by construction: the value is a unit marker, the member can
  always `decline_invite` to remove it, and the write is bounded only by the
  inviter's gas (each invite is one field on each side, paid by the inviter).
  Corollary dust economics: the storage rebate on removal goes to the
  *remover's* transaction, so a declining member receives a rebate the
  inviter paid. Sub-dust amounts; not actionable.
  **Disposition (2026-08-24):** accepted-by-design — the marker write is
  removable by the member at will and bounded by inviter gas; the rebate
  asymmetry is sub-dust.
- **F2 (Informational): pending invites are unbounded.** `MAX_GROUP_MEMBERS`
  (200) caps *members* (checked at invite, `party.move:299`, and again at
  accept, `party.move:332`) but not pending invitations. A group admin can
  invite arbitrarily many parties, growing both objects' dynamic-field stores
  at the inviter's expense. No funds are locked, no victim pays storage, and
  invites are individually removable. Accepted-as-designed spam surface.
  **Disposition (2026-08-24):** accepted-by-design — pending invites cost only
  the inviter, lock no funds, are individually removable, and member capacity
  is enforced again at accept.
- **F3 (Informational): membership keys are unforgeable — verified.**
  `MembershipKey`, `PendingInviteKey`, `PendingMembershipKey` are `public
  struct`s with private fields (`party.move:62-81`), so only this module can
  construct a key value, and `df::add`/`remove`/`borrow` all require the key
  by value. An extension holding `uid_mut` therefore cannot forge, alter, or
  scrub membership/invite state — the load-bearing isolation property for the
  whole extension ecosystem. `is_member` (`party.move:476-478`) reads the
  member-side record and is the extensions' member-gated authorization
  primitive; it cannot be spoofed.
  **Disposition (2026-08-24):** accepted-by-design — verified property, not a
  defect: module-private key construction makes membership and invite state
  unforgeable by any extension, the intended isolation boundary.

No other findings. Specifically checked and cleared:

- **Cap binding.** `PartyAdminCap` carries `party_id`; `authorize` compares
  object IDs (`party.move:502`). `share`, `set_name`, `uid_mut`, and all
  membership endpoints authorize the correct side: group ops check the
  *group's* cap, member ops check the *member's* cap (`party.move:290, 319,
  350, 368, 383, 398`). Wrong-cap aborts `EUnauthorized` (tested).
- **Two-sided consistency.** Both pending markers are always written and
  removed together (`party.move:303-304, 327-328, 355-356, 373-374`); accept
  requires both to exist, so neither side can be orphaned into a stuck state.
  `remove_membership` guards the member-side remove with `df::exists`
  (`party.move:421`) — defensive, unreachable under the write-together
  invariant.
- **Kind confusion.** Members must be `Individual` at invite
  (`party.move:297`); `PartyKind` is immutable after `new`, so a member can
  never become a group. Self-membership rejected (`party.move:296`).
  Duplicate membership impossible (`VecSet::insert` aborts;
  `EDuplicateParty` pre-checked).
- **Group admin reach is scoped.** `remove_member` scrubs the member's record
  *for this group only* (`party.move:392-405`); nothing else on the member is
  touchable without its cap.
- **Object lifecycle.** `Party` is `key`-only, no `drop`, and the only
  consumer is cap-gated `share` (`party.move:261-264`) — a party cannot be
  transferred, wrapped, or discarded; creation is atomic with sharing.
- **Bounds.** Name 1–200 bytes, members ≤ 200 (`O(n)` `VecSet` ops are
  tx-cheap at that size), no unbounded loops anywhere.

## Edge cases (verified)

- Invite → revoke → re-invite works; invite → decline → re-invite works
  (markers fully cleared on both paths).
- Invite at 199 members + 1000 pending invites: accepts beyond 200 abort
  `EMaxGroupMembersExceeded` at `party.move:332` — capacity enforced at
  accept, so over-inviting degrades to harmless aborts.
- `accept_invite` on an individual "group" argument aborts
  (`assert_is_group_kind`, `party.move:320`); `leave`/`remove_member` on a
  non-member abort `ENotGroupMember`.

## Verification

- **34/34 unit tests** (`sui move test`, sui 1.77.2), including the
  AGENTS.md-mandated wrong-cap negatives and full invite/accept/decline/
  revoke/leave/remove lifecycle coverage.
- Cross-read of consumers: `partyos-extensions/party_wallet` (this audit set),
  `party_profile`, and the `partyos-extensions/AGENTS.md` contract ("gate every
  write with the cap … through `party::uid_mut(cap)`") — all consistent with
  what this module enforces.

## Load-bearing assumptions

- Framework dynamic-field semantics (key-value construction privacy,
  `df::exists_*` honesty) and `derived_object::claim` uniqueness (the cap is
  a derived object of the party, `party.move:245`).
- The `created_at_ms` clock read is informational only; no logic depends on
  it.
