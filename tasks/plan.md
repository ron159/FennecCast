# Implementation Plan: local-data

## Overview

Add GRDB 7.11.1 to `FennecCore`, migrate the complete local schema, implement atomic StateSync state persistence, then link `LocalData` into the iOS target and verify both macOS tests and iOS compilation.

## Architecture Decisions

- One `LocalDataStore` actor owns a type-erased GRDB writer.
- Production files use `DatabasePool`; tests use `DatabaseQueue` in memory or at a temporary path.
- Raw SQL defines the schema and focused persistence statements; `CoreContracts` remains storage-independent.
- The singleton cursor row also persists the device ID and last allocated local sequence.
- Remote merge reuses `ConflictResolver`; transport remains a later module.

## Tasks

- [ ] Task 1: Pin GRDB and create the initial nine-table migration from failing schema tests
- [ ] Task 2: Implement local state plus Outbox atomic transactions from failing tests
- [ ] Task 3: Implement pending reads and remote response/cursor transactions from failing tests
- [ ] Task 4: Implement forward-only aliases from failing tests
- [ ] Task 5: Link `LocalData` to the app and complete module verification

## Checkpoints

- [ ] Every behavior slice records RED before production implementation.
- [ ] Database failure injection proves rollback rather than partial state.
- [ ] Full package tests and format lint pass.
- [ ] Generic iOS build and build-for-testing pass.
- [ ] Adjacent Android checkout remains unchanged.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Business state commits without Outbox | High | One documented GRDB `write` transaction plus forced-failure test |
| Cursor advances before all changes apply | High | Validate and merge the entire response in the same transaction as cursor update |
| Local sequence repeats after cleanup | High | Persist allocator in singleton cursor row, independent of Outbox contents |
| Remote episode arrives before metadata | Medium | Permit synchronized semantic rows without episode foreign-key parent |
| Alias redirect forms a loop | Medium | Traverse candidate chain before insert and reject cycles/conflicting remaps |
| GRDB API drift | Medium | Pin 7.11.1 and follow current official source documentation |

## Open Questions

None blocking. Feed metadata repositories are intentionally deferred to `feed-library`.
