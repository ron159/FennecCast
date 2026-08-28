# Specification: local-data

**Status:** Complete  
**Sources:** FennecCast whitepaper v1.1 and GRDB 7.11.1 official documentation

## 1. Purpose

Provide FennecCast's migrated local SQLite database and the atomic persistence boundary required by StateSync Lite. Local podcast behavior remains available without a server; synchronized user actions write business state and Outbox entries in one transaction.

## 2. Dependencies and Official Patterns

- Pin GRDB 7.11.1 from `https://github.com/groue/GRDB.swift.git`.
- Use `DatabasePool` for file databases and `DatabaseQueue` for isolated in-memory tests.
- Register ordered migrations with `DatabaseMigrator`; never erase a distributed user's database when schema changes.
- Use `DatabaseWriter.write` for atomic business-state plus Outbox updates and remote-state plus cursor updates.
- Sources:
  - `https://github.com/groue/GRDB.swift/releases/tag/v7.11.1`
  - `https://github.com/groue/GRDB.swift/blob/master/README.md#database-connections`
  - `https://github.com/groue/GRDB.swift/blob/master/GRDB/Migration/DatabaseMigrator.swift`
  - `https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/DatabaseWriter.swift`

## 3. In Scope

- A local Swift Package target and product named `LocalData`.
- Ordered migrations for the base tables, feed/library state, download metadata, persistent HLC and Podcasting 2.0 supplemental URLs.
- Stable string primary keys; Android integer IDs never enter the schema.
- File-backed and in-memory database creation with persistent device identity validation.
- Atomic local subscription, playback and queue mutations with monotonically increasing `local_seq` and encoded Outbox envelopes.
- Ordered pending mutation reads with a hard maximum batch size of 500.
- Atomic remote change merge, cursor advancement and acknowledged Outbox deletion.
- Forward-only alias insertion and cycle-safe canonical key resolution.
- Read APIs for the three versioned synchronized business states and sync cursor.
- Metadata/user-state repositories, playback persistence, local download persistence and consistent SQLite backup export.

## 4. Out of Scope

- Feed parsing and HTTP refresh transport.
- StateSync HTTP transport, Bearer token and Keychain.
- UI rendering, media files and AVPlayer ownership.
- NAS database or Android persistence changes.
- Snapshot compaction and tombstone garbage collection.

## 5. Data Rules

- `sync_cursor` is a singleton row containing `server_seq`, persistent `last_local_seq` and the database's device ID.
- `sync_outbox` primary key is `(device_id, local_seq)` and stores only the three v1 entity types.
- Local mutation sequence allocation, business-state write and Outbox insert occur in one GRDB `write` transaction.
- Applying a response validates increasing `server_seq`, rejects cursor regression, merges changes in order, advances the cursor and deletes acknowledged local Outbox rows in one transaction.
- A failed transaction leaves business state, sequence allocator, Outbox and cursor unchanged.
- Remote application never generates a new Outbox operation.
- Synchronized episode and queue state may exist before feed metadata is refreshed, so those semantic tables do not require an `episodes` foreign-key parent.
- Alias mappings are idempotent when repeated, reject remapping to another canonical key and reject cycles.

## 6. Concurrency and Safety

- `LocalDataStore` is an actor and never exposes a live GRDB `Database` connection.
- SQL values use bound arguments; entity names are fixed in source.
- Stored JSON is decoded through validated `CoreContracts` models.
- Errors identify invalid batches, device mismatch, corrupt records, cursor/order violations and alias conflicts without logging secrets or payload bodies.
- Backup export refuses non-file destinations and existing files; Keychain credentials are outside the database snapshot.

## 7. Success Criteria

- A temporary database migrates through every registered schema version with foreign-key checking enabled.
- Tests prove local state and Outbox atomicity, including a forced SQLite failure rollback.
- Tests prove local sequences remain monotonic after Outbox acknowledgement.
- Tests prove remote changes and cursor are atomic and remote apply does not create Outbox rows.
- Tests prove playback and queue conflict rules are used during remote apply.
- Tests prove alias idempotency, conflict rejection and cycle detection.
- Tests prove an exported SQLite snapshot reopens with state, Outbox and cursor intact.
- Full `LocalData` and `CoreContracts` package tests pass on macOS.
- Swift format lint, generic iOS Simulator build and build-for-testing pass.

## 8. Compatibility Boundary

The initial schema migration is append-only after release. Later schema changes require a new migration identifier. App schema and StateSync protocol version remain independent.

## 9. Verification Evidence

Verified on 2026-08-29 with Xcode 27 beta, Swift 6.4 and GRDB 7.11.1:

- `xcrun swift test --package-path Packages/FennecCore`: 118 tests passed, including 28 LocalData tests and 37 CoreContracts tests.
- `xcrun swift-format lint --strict --recursive Sources Tests Packages/FennecCore/Sources Packages/FennecCore/Tests`: passed.
- Generic iOS Simulator `build`: passed with `CoreContracts`, `LocalData` and GRDB in the application dependency graph.
- Generic iOS Simulator `build-for-testing`: app and XCTest bundle compiled successfully.
- Forced SQLite failures prove local Outbox writes and remote response application roll back atomically.
- JSON catalog validation, `git diff --check`, focused secret scan and adjacent Android checkout audit passed.
