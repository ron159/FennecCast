# Implementation Plan: core-contracts

## Overview

Build the pure Swift contract layer described in `SPEC-core-contracts.md`, verify it with executable macOS Swift Package tests, then link the package into the iOS app and run the generic Simulator build.

## Architecture Decisions

- Keep contracts in `Packages/FennecCore` as a local Swift Package product named `CoreContracts`.
- Use Foundation and CryptoKit only.
- Keep persistence, HTTP and UI adapters outside the package.
- Encode polymorphic payloads explicitly so an entity/payload mismatch cannot enter persistence.
- Use fixed-width hexadecimal fractional tokens; do not add a general CRDT dependency.

## Dependency Graph

```text
canonical identity ─┐
HLC + version stamp ├─> sync wire models ─> conflict resolution
fractional index ───┘
                all contracts ─> local Xcode package link
```

## Task List

- [ ] Task 1: Scaffold the local package and implement canonical identity from failing tests
- [ ] Task 2: Implement HLC and version ordering from failing tests
- [ ] Task 3: Implement fractional queue tokens from failing tests
- [ ] Task 4: Implement StateSync v1 models and golden JSON coding from failing tests
- [ ] Task 5: Implement subscription, playback and queue conflict resolution from failing tests
- [ ] Task 6: Link `CoreContracts` into the iOS target and close verification

## Checkpoints

- [ ] Each behavior slice has observed RED then passing focused tests.
- [ ] Full package tests and format lint pass.
- [ ] Generic iOS Simulator build succeeds with the package linked.
- [ ] Changes remain inside `FennecCast/`; the adjacent Android checkout is unchanged.
- [ ] Commits are small, descriptive and independently revertible.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| URL normalization differs across platforms | High | Specify components precisely and cover case, default port, fragment and query ordering fixtures |
| HLC edge cases produce divergent ordering | High | Inject physical time and test local, remote and concurrent branches |
| Polymorphic JSON accepts invalid payloads | High | Use an enum payload with custom entity-driven Codable validation |
| Fractional token space is exhausted | Medium | Return a typed error and provide deterministic rebase |
| Local package is not actually linked by Xcode | Medium | Add an explicit package product dependency and run a full generic Simulator build |

## Open Questions

None blocking. The user has authorized uninterrupted implementation and self-review.
