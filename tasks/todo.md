# Task List: core-contracts

## Task 1: Canonical identity

- [x] Add the local Swift Package skeleton and canonical identity tests.
- [x] Observe the tests fail before production implementation exists.
- [x] Implement deterministic URL normalization, `FeedKey` and `EpisodeKey`.
- [x] Pass focused identity tests and format lint.

## Task 2: Hybrid Logical Clock

- [x] Add deterministic clock and ordering tests.
- [x] Observe RED before implementation.
- [x] Implement validated timestamps, version stamps, local tick and remote observe.
- [x] Pass focused HLC tests and format lint.

## Task 3: Fractional queue tokens

- [x] Add prepend, append, insertion, ordering, exhaustion and rebase tests.
- [x] Observe RED before implementation.
- [x] Implement fixed-width hexadecimal tokens and rebase.
- [x] Pass focused fractional-index tests and format lint.

## Task 4: StateSync v1 models

- [x] Add JSON golden tests and validation tests.
- [x] Observe RED before implementation.
- [x] Implement the entity whitelist, payloads and request/response envelopes.
- [x] Pass focused coding tests and format lint.

## Task 5: Conflict resolution

- [x] Add LWW tombstone, backward-seek and intent-priority tests.
- [x] Observe RED before implementation.
- [x] Implement deterministic subscription, playback and queue resolution.
- [x] Pass focused merge tests and the complete package suite.

## Task 6: iOS integration and closeout

- [x] Link the local `CoreContracts` product to the app target.
- [x] Build the generic iOS Simulator destination without signing.
- [x] Run full package tests, format lint, diff checks and focused secret scan.
- [x] Record verification evidence and leave the working tree clean.
