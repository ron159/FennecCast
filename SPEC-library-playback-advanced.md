# Specification: advanced library operations and sleep timer

## Objective

Bring FennecCast's day-to-day library management closer to AntennaPod while using native
iOS interaction patterns. Users can combine useful episode filters, select many episodes,
apply one action to the selection, reorder or sort the queue, and configure a sleep timer
with their own duration or episode count.

## Capability map

| Module | Responsibility | Depends on |
|---|---|---|
| `advanced-library` | Query, select, batch-update, sort, and reorder episodes | `LocalData`, `QueueFeature`, `DownloadsFeature` |
| `custom-sleep-timer` | Custom time/episode timer, remaining status, and extension | `PlaybackFeature` |

Build order: `advanced-library` -> `custom-sleep-timer` -> shared app UI verification.

## Research basis

- AntennaPod batch actions: add/remove queue, mark played/unplayed, add/remove favorite,
  remove from Inbox, download/delete download, reset position, and move queue items.
- AntennaPod filters: played state, progress, queue, download, media, favorite, and Inbox.
- AntennaPod sorting: date, episode title, podcast title, duration, random, and smart shuffle.
- AntennaPod sleep timer: custom minutes or episode count, plus timer extension.
- SwiftUI `List(selection:)` and `EditMode` are the native multiple-selection pattern;
  `onMove` is the native list-reordering pattern.

Sources:

- `../AntennaPod/app/src/main/java/de/danoeh/antennapod/ui/episodeslist/EpisodeMultiSelectActionHandler.java`
- `../AntennaPod/model/src/main/java/de/danoeh/antennapod/model/feed/FeedItemFilter.java`
- `../AntennaPod/storage/database/src/main/java/de/danoeh/antennapod/storage/database/FeedItemPermutors.java`
- `../AntennaPod/app/src/main/java/de/danoeh/antennapod/ui/screen/playback/SleepTimerDialog.java`
- `https://developer.apple.com/documentation/swiftui/list`
- `https://developer.apple.com/documentation/swiftui/editmode`
- `https://developer.apple.com/documentation/swiftui/making-a-view-into-a-drag-source`

## Tech stack and structure

- Swift 6 language mode, iOS 17 deployment target, SwiftUI application UI.
- GRDB-backed `LocalData` query and state APIs.
- StateSync-compatible `QueueFeature` and playback mutations.
- Swift Testing package tests under `Packages/FennecCore/Tests`.
- App integration in `Sources/App/RootView.swift`; localized strings in
  `Sources/Resources/Localizable.xcstrings`.

## User-visible behavior

### Advanced library

- A library screen is reachable from Home and supports multiple selection and Select All.
- Filters can be combined across playback state, Inbox, favorite, archive, queue, download,
  and media availability.
- Episodes can be sorted by publication date, episode title, podcast title, or duration in
  either direction.
- A selection can be marked played/unplayed, added to or removed from Inbox, favorites,
  archive, queue, or downloads.
- Destructive removal deletes only downloaded media and requires confirmation; it does not
  delete feed episode metadata.
- Queue rows support native drag reordering. The complete queue can also be sorted by date,
  title, podcast, duration, or deterministic smart shuffle.
- Queue reorders are persisted through normal StateSync queue mutations.

### Custom sleep timer

- Presets remain available for quick use.
- Users can enter a custom value in minutes or episodes.
- Minutes are limited to 1...1,440; episode counts are limited to 1...100.
- The player displays the current remaining duration or episode count.
- An active clock timer can be extended by 5, 10, or 30 minutes; an episode timer can be
  extended by 1, 2, or 3 episodes.
- Cancelling the timer clears its status immediately.

## Testing strategy

- Query tests prove combined filters, bound arguments, and every supported sort.
- Queue tests prove exact-set validation, atomic reordering, and deterministic smart shuffle.
- Playback policy/engine tests prove validation, status countdown, episode decrement,
  extension, expiry, and snapshot publication.
- App UI is compile-verified for generic iOS and the simulator test target.

## Commands

- Package tests: `swift test --package-path Packages/FennecCore`
- Format lint: `swift format lint --strict --recursive Sources Tests Packages/FennecCore/Sources Packages/FennecCore/Tests`
- Debug build: `xcodebuild -project FennecCast.xcodeproj -scheme FennecCast -configuration Debug -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build`
- Test build: `xcodebuild -project FennecCast.xcodeproj -scheme FennecCast -destination generic/platform=iOS\ Simulator CODE_SIGNING_ALLOWED=NO build-for-testing`

## Boundaries

- Always preserve StateSync outbox semantics for played state and queue changes.
- Always keep batch download removal recoverable by downloading the episode again.
- Do not add dependencies or a database migration for view-only filter preferences.
- Do not delete episode metadata, feeds, credentials, or media outside the selected episodes.
- Do not add shake-to-reset, vibration, or scheduled automatic sleep activation in this
  increment.

## Success criteria

- All advanced library operations above are available through native, localized UI.
- Combined filters and queue sorting operate on tested core logic rather than view-only
  ad-hoc predicates.
- Custom time and episode sleep timers expose accurate remaining status and can be extended.
- Full package tests, strict formatting, generic iOS build, and build-for-testing pass.

## Verification evidence

Verified on 2026-08-29 with Xcode 27 beta:

- `FennecCore` full package suite: 146 tests passed.
- Strict `swift-format` lint: passed for app and package sources/tests.
- Generic iOS Debug build without code signing: passed.
- Generic iOS Simulator `build-for-testing` without code signing: passed.
- Localization catalog JSON, whitespace, secret-pattern, scope, and adjacent-checkout audits:
  passed.
