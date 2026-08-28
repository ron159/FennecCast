# Task List: feed-library and queue

## Task 1: Feed parser

- [ ] Add `FeedLibrary` target and golden RSS/Atom fixtures.
- [ ] Observe parser tests fail before implementation.
- [ ] Implement namespace-aware XML parsing, dates and durations.
- [ ] Verify malformed XML and unsupported roots fail safely.

## Task 2: Library persistence

- [ ] Add metadata/user-state preservation tests, then observe RED.
- [ ] Implement atomic first subscription and metadata-only refresh.
- [ ] Implement feed and episode queries plus Inbox/favorite/archive actions.
- [ ] Verify invalid episodes are skipped and existing state is preserved.

## Task 3: Fetch and workflows

- [ ] Add stubbed HTTP request/response tests, then observe RED.
- [ ] Implement conditional headers, bounds and HTTP status handling.
- [ ] Implement add, refresh and unsubscribe workflows with redirect aliases.
- [ ] Verify `304` and failures do not write local state.

## Task 4: Queue

- [ ] Add queue operation and rebase tests, then observe RED.
- [ ] Implement current queue query and fractional placement.
- [ ] Implement tombstone removal, re-add, move and auto-advance.
- [ ] Prove atomic rebase and ordered Outbox mutations.

## Task 5: Integration and closeout

- [ ] Link `FeedLibrary` and queue services to the app environment.
- [ ] Run all package tests and strict format lint.
- [ ] Run generic iOS build and build-for-testing.
- [ ] Run diff, secret and adjacent-checkout audits; record evidence.
