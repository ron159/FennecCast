# Specification: StateSync Lite iOS client

**Status:** Complete
**Source:** FennecCast whitepaper v1.1, sections 8-10

## 1. Purpose

Synchronize only subscription tombstones, episode playback state and queue entries with one personal StateSync Lite v1 server. Local podcast metadata, Inbox, favorites, settings, downloads, media files and credentials never enter the protocol payload.

## 2. In Scope

- One `POST /v1/sync` push/pull request using the existing typed v1 request and response contracts.
- Ordered Outbox batches of at most 500 mutations and at most 1 MiB encoded JSON.
- Atomic remote merge, cursor advance and acknowledged-Outbox deletion through `LocalDataStore`.
- Shared HLC across subscription, queue, playback and sync, restored from SQLite after relaunch.
- HTTPS server configuration, with insecure HTTP allowed only for loopback development.
- Bearer token validation and storage in Keychain with background-readable, device-only protection.
- Single-flight synchronization, bounded retry scheduling, foreground/manual/user-mutation/playback/background triggers and observable status.
- BGAppRefreshTask integration and network-recovery hints; both remain opportunistic.

## 3. Safety Boundaries

- Never log, persist in UserDefaults or include the Bearer token in an error value.
- Reject URLs with credentials, query, fragment, non-network schemes or insecure non-loopback HTTP.
- Reject cross-origin redirects, non-JSON responses, non-2xx statuses, oversized request/response bodies and malformed protocol envelopes.
- Reject an acknowledgement above the highest local sequence actually uploaded in the current batch.
- Keep generic typed error categories; never surface raw response bodies.
- Delete Outbox entries only after a valid response has been atomically applied.
- Persist the maximum local or observed remote HLC in the same database transaction as its associated state change.

## 4. Success Criteria

- Tests cover shared/restart-safe HLC behavior, request authentication and bounds, settings persistence, successful sync, invalid responses, retries, single-flight behavior and Outbox retention on failure.
- Generic iOS Simulator build and build-for-testing pass with Keychain, Network and BackgroundTasks adapters linked.
- Strict Swift format lint and all FennecCore tests pass.
- Physical-device background execution is explicitly left for later device validation.

## 5. Verification Evidence

Verified on 2026-08-29 with Xcode 27 beta and Swift 6.4:

- All 118 `FennecCore` tests passed, including 12 StateSync tests.
- Strict Swift format lint passed across application and package sources/tests.
- Generic iOS Simulator build and `build-for-testing` passed.
- App XCTest execution remains unavailable because this Mac has no installed Simulator Runtime.
- BGAppRefreshTask scheduling remains opportunistic and requires later physical-device validation.
