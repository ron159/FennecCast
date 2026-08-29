# Task List: advanced library and custom sleep timer

## Task 1: Composable episode queries

- [x] Add failing tests for combined state/queue/download/media filters and richer sorting.
- [x] Implement typed query criteria with bound values and compatibility wrappers.
- [x] Verify focused `LocalDataTests` pass.

## Task 2: Batch local state and queue ordering

- [x] Add failing tests for atomic batch flags and exact-set queue reordering.
- [x] Implement batch Inbox/favorite/archive updates and queue reorder/smart sort.
- [x] Verify rollback, duplicate-key, and missing-key cases.

## Task 3: Advanced library UI

- [x] Add the Home library entry, filter/sort controls, multiple selection, and Select All.
- [x] Add played, Inbox, favorite, archive, queue, download, and media-removal actions.
- [x] Add queue drag reorder, sorting, selected move-to-top/bottom, and confirmation.

## Task 4: Custom sleep timer core

- [x] Add failing tests for timer status, bounds, extension, countdown, and episode decrement.
- [x] Expose typed status through playback snapshots and implement extension.
- [x] Verify focused playback policy and engine tests pass.

## Task 5: Custom sleep timer UI

- [x] Add custom minute/episode input, presets, active status, extension, and cancellation.
- [x] Localize every new user-visible string in English and Simplified Chinese.
- [x] Compile the complete app UI.

## Task 6: Closeout

- [x] Run all package tests and strict Swift format lint.
- [x] Run generic iOS Debug build and simulator build-for-testing.
- [x] Run whitespace, secret, scope, and adjacent-checkout audits.
- [x] Record verification evidence in the spec and mark this task list complete.
