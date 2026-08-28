# Specification: core-contracts

**Status:** Approved by the user's standing authorization to continue without repeated confirmation  
**Source:** `../local_doc/AntennaPod_iOS个人版与Android双端轻量状态同步技术方案白皮书_v1.1.md`

## 1. Purpose

Define the deterministic, storage-independent contracts shared by FennecCast's local database, queue, playback and StateSync Lite client. The module must compile and run tests without an iOS Simulator Runtime.

## 2. In Scope

- Stable `FeedKey` and `EpisodeKey` generation using SHA-256 and canonical locators.
- Hybrid Logical Clock timestamps and deterministic device tie-breaking.
- StateSync Lite v1 entity, payload, mutation, change, request and response models.
- Subscription, playback and queue conflict resolution.
- Lexicographically sortable fractional queue tokens and deterministic rebasing.
- A local Swift Package product named `CoreContracts`, linked by the iOS app target.

## 3. Out of Scope

- GRDB records, migrations, repositories, Outbox persistence and cursor persistence.
- HTTP transport, authentication, Keychain storage and NAS behavior.
- Feed parsing, playback, downloads and user interface.
- Synchronizing Inbox, favorites, tags, settings, download state, media or SQLite files.

## 4. Functional Requirements

### 4.1 Canonical identity

- `FeedKey` is the lowercase SHA-256 hex digest of `feed:v1:<normalized canonical feed URL>`.
- Network URL normalization lowercases scheme and host, removes fragments and default ports, removes a trailing root slash, preserves path case and sorts query items by name then value.
- `EpisodeKey` hashes `episode:v1:<feed key>:<locator>`.
- Locator priority is: nonblank valid GUID, enclosure URL, link plus publication time, then normalized title plus publication time and duration.
- An episode without any complete locator returns a typed error rather than an unstable identifier.

### 4.2 Hybrid Logical Clock

- `HLCTimestamp` compares by `wallMilliseconds`, then `counter`.
- `VersionStamp` compares by timestamp, then lexicographic `deviceID`.
- A local tick uses the greater of physical time and prior wall time, incrementing the counter when physical time has not advanced.
- Observing a remote timestamp follows the standard HLC max-wall algorithm and never moves backward.

### 4.3 StateSync Lite v1 models

- The entity whitelist is exactly `subscription`, `episode_playback` and `queue_entry`.
- Payloads encode only the whitepaper fields needed for these entities.
- `SyncMutation`, `SyncChange`, `SyncRequest` and `SyncResponse` use the wire keys from the whitepaper, including `local_seq`, `server_seq`, `accepted_local_seq` and `next_cursor`.
- Payload decoding is selected by `entity_type`; a mismatched entity and payload is rejected.
- Model constructors reject negative sequences, cursors, positions, durations and HLC components.

### 4.4 Conflict resolution

- Subscription and queue state use last-writer-wins over `(wall_ms, counter, device_id)`; `subscribed=false` and `present=false` remain explicit tombstones.
- Playback uses intent priority first, then the version stamp. `seek`, `mark_played` and `mark_unplayed` are explicit intent; `playback_pause` and `checkpoint` are progress intent.
- Explicit intent replaces progress intent even when the explicit event has an older timestamp; events in the same intent class use the newer version stamp.
- Position is never merged by taking the numeric maximum.

### 4.5 Queue ordering

- A token is a fixed-width lowercase hexadecimal representation of a positive `UInt64`, so string order equals numeric order.
- `between(lower:upper:)` generates a midpoint token for prepend, append and insertion when representable.
- Invalid bounds and exhausted gaps return typed errors.
- Rebase assigns evenly spaced tokens in the caller-provided stable order.

## 5. Non-Functional Requirements

- Swift 6 strict-concurrency compatible and `Sendable` where appropriate.
- Apple SDK only; no runtime dependency is added by this module.
- Public value types are `Equatable`, `Hashable` and `Codable` when meaningful.
- Tests use deterministic clocks and fixed fixtures; no wall-clock or network dependency.
- Implementation stays small and explicit; no generalized CRDT framework.

## 6. Success Criteria

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test --package-path Packages/FennecCore` passes.
- `swift-format lint --strict --recursive Packages/FennecCore/Sources Packages/FennecCore/Tests` passes.
- Generic iOS Simulator build succeeds with `CoreContracts` linked to `FennecCast`.
- Golden JSON tests prove snake-case wire compatibility and reject entity/payload mismatch.
- Boundary tests cover identity priority, clock skew/concurrency, tombstones, backward seek and fractional-index exhaustion.
- `git diff --check` and focused secret scan pass.

## 7. Compatibility Boundary

This module establishes protocol version 1 behavior. Any later change to canonical identity input, entity whitelist, wire keys, intent precedence or token format requires a new protocol decision and migration rather than an in-place semantic change.
