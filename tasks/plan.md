# Implementation Plan: feed-library and queue

## Overview

Build the RSS/Atom parser and library persistence first, add bounded conditional fetching and subscription workflows, then implement the synchronized queue repository over the same local transaction boundary.

## Architecture Decisions

- `FeedLibrary` contains parser, HTTP client and user workflow code; it never sees a live database connection.
- `LocalData` owns metadata transactions and user-state queries.
- Foundation `XMLParser` avoids a second feed dependency and keeps identity behavior explicit.
- Queue operations use approved `FractionalIndex` values and atomic batch mutation support.

## Tasks

- [x] Task 1: Add `FeedLibrary` models and RSS/Atom parser from failing golden fixtures
- [x] Task 2: Add feed/episode metadata transactions and library queries from failing database tests
- [x] Task 3: Add bounded conditional HTTP refresh and subscription workflows from stubbed fetch tests
- [x] Task 4: Add atomic batch mutations and queue repository from failing operation/rebase tests
- [x] Task 5: Link services into the app and complete both-module verification

## Checkpoints

- [x] Every completed behavior slice records RED before production implementation.
- [x] Feed parse/fetch failures leave the database unchanged.
- [x] Queue rebase and its Outbox operations are atomic.
- [x] Full package tests and format lint pass for the package implementation.
- [x] Generic iOS build and build-for-testing pass.
- [x] Adjacent Android checkout remains unchanged.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Malformed XML or external entities | High | Event parser, entity resolution disabled, golden failure fixtures |
| Refresh overwrites user state | High | Metadata-only upsert plus persistence regression tests |
| Redirect changes identity | High | Canonical response URL and forward-only feed alias |
| Huge response exhausts memory | Medium | 10 MiB response limit before parsing |
| Queue token gap exhausts | Medium | Atomic deterministic rebase fallback |

## Open Questions

None blocking. JSON Feed and authenticated feeds remain later increments.
