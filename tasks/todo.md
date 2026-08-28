# Task List: feed-library and queue

## Task 1: Feed parser

- [x] Add `FeedLibrary` target and golden RSS/Atom fixtures.
- [x] Observe parser tests fail before implementation.
- [x] Implement namespace-aware XML parsing, dates and durations.
- [x] Verify malformed XML and unsupported roots fail safely.

## Task 2: Library persistence

- [x] Add metadata/user-state preservation tests, then observe RED.
- [x] Implement atomic first subscription and metadata-only refresh.
- [x] Implement feed and episode queries plus Inbox/favorite/archive actions.
- [x] Verify invalid episodes are skipped and existing state is preserved.

## Task 3: Fetch and workflows

- [x] Add stubbed HTTP request/response tests, then observe RED.
- [x] Implement conditional headers, bounds and HTTP status handling.
- [x] Implement add, refresh and unsubscribe workflows with redirect aliases.
- [x] Verify `304` and failures do not write local state.

## Task 4: Queue

- [x] Add queue operation and rebase tests, then observe RED.
- [x] Implement current queue query and fractional placement.
- [x] Implement tombstone removal, re-add, move and auto-advance.
- [x] Prove atomic rebase and ordered Outbox mutations.

## Task 5: Integration and closeout

- [x] Link `FeedLibrary` and queue services to the app environment.
- [x] Run all package tests and strict format lint.
- [x] Run generic iOS build and build-for-testing.
- [x] Run diff, secret and adjacent-checkout audits; record evidence.
