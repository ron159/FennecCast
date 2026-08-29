# Implementation Plan: advanced library and custom sleep timer

## Architecture decisions

- Add a typed, composable episode query beside the existing compatibility query API.
- Keep local-only Inbox/favorite/archive batch writes in one GRDB transaction.
- Keep played state and queue changes on their existing StateSync mutation paths.
- Put deterministic queue ordering in `QueueFeature`, not in SwiftUI.
- Expose typed sleep-timer status from `PlaybackFeature`; the app only renders and sends
  intents.
- Follow SwiftUI's standard `List(selection:)`, `EditButton`, confirmation dialog, and
  `onMove` patterns.

## Implementation order

1. Specify typed filters, sorts, batch local flags, and their tests.
2. Add exact queue reorder and smart-sort policies with tests.
3. Integrate the advanced library selection/actions and queue UI.
4. Add sleep-timer status and extension policies with tests.
5. Integrate the custom timer sheet and localization.
6. Run full tests, format checks, iOS builds, and a final diff review.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Partial batch mutation | Mixed episode state | Local flags use one transaction; sync mutations use one bounded operation and reload once |
| Invalid queue reorder | Lost or duplicated queue rows | Require the reordered keys to exactly equal the current queue set |
| Timer overflow or unreasonable input | Incorrect pause behavior | Validate bounded UI input and overflow in the core policy |
| Edit-mode navigation conflict | Wrong row opens while selecting | Use native list selection tags and disable row actions while editing where needed |

## Checkpoints

- Core checkpoint: focused LocalData, QueueFeature, and PlaybackFeature tests pass.
- UI checkpoint: localized app compiles for generic iOS and simulator test products.
- Completion checkpoint: full package tests, strict formatting, and diff checks pass.
