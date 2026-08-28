# Specification: queue

**Status:** Approved by the user's standing authorization to continue without repeated confirmation  
**Sources:** FennecCast whitepaper v1.1 and approved CoreContracts conflict/order rules

## 1. Purpose

Provide a persistent, local-first playback queue whose add, remove and move operations emit StateSync Lite queue mutations while preserving deterministic order across iOS and Android.

## 2. In Scope

- Read current present queue joined with episode/feed metadata.
- Add at head, tail, before or after another present entry.
- Move an existing entry, remove by tombstone and remove the completed current item during auto-advance.
- Allocate one fractional token for normal edits and deterministically rebase only when a gap is exhausted.
- Record every changed queue entry and Outbox envelope in one transaction for a rebase.
- Reject missing targets, duplicate no-op positions and invalid timestamps with typed errors.

## 3. Rules

- Queue order is `(order_token, episode_key)` for deterministic ties.
- Removed rows remain tombstones; re-adding the episode reuses the row with a new token and newer version.
- Moving or adding normally updates only one row.
- Rebase preserves visible order and emits versioned mutations for every changed present entry atomically.
- Remote conflict resolution remains owned by `LocalDataStore.applySyncResponse`.

## 4. Success Criteria

- Tests cover head/tail/before/after insertion, move, removal, re-add and auto-advance.
- Tests force an exhausted token gap and prove deterministic atomic rebase.
- Local sequence and pending Outbox order remain monotonic.
- Full Swift package tests, strict formatting, generic iOS build and build-for-testing pass.

