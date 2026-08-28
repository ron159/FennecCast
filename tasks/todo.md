# Task List: core-contracts

## Task 1: Canonical identity

- [ ] Add the local Swift Package skeleton and canonical identity tests.
- [ ] Observe the tests fail before production implementation exists.
- [ ] Implement deterministic URL normalization, `FeedKey` and `EpisodeKey`.
- [ ] Pass focused identity tests and format lint.

## Task 2: Hybrid Logical Clock

- [ ] Add deterministic clock and ordering tests.
- [ ] Observe RED before implementation.
- [ ] Implement validated timestamps, version stamps, local tick and remote observe.
- [ ] Pass focused HLC tests and format lint.

## Task 3: Fractional queue tokens

- [ ] Add prepend, append, insertion, ordering, exhaustion and rebase tests.
- [ ] Observe RED before implementation.
- [ ] Implement fixed-width hexadecimal tokens and rebase.
- [ ] Pass focused fractional-index tests and format lint.

## Task 4: StateSync v1 models

- [ ] Add JSON golden tests and validation tests.
- [ ] Observe RED before implementation.
- [ ] Implement the entity whitelist, payloads and request/response envelopes.
- [ ] Pass focused coding tests and format lint.

## Task 5: Conflict resolution

- [ ] Add LWW tombstone, backward-seek and intent-priority tests.
- [ ] Observe RED before implementation.
- [ ] Implement deterministic subscription, playback and queue resolution.
- [ ] Pass focused merge tests and the complete package suite.

## Task 6: iOS integration and closeout

- [ ] Link the local `CoreContracts` product to the app target.
- [ ] Build the generic iOS Simulator destination without signing.
- [ ] Run full package tests, format lint, diff checks and focused secret scan.
- [ ] Record verification evidence and leave the working tree clean.
