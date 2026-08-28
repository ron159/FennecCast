# FennecCast

FennecCast is a personal native iOS podcast client based on the behavioral workflows of AntennaPod. Its first release target is the P0/MVP defined by the StateSync Lite whitepaper: local-first subscriptions, playback, downloads and queues, with only subscriptions, playback state and queue state eligible for cross-device synchronization.

The P0 native iOS client is implemented. It includes the local-first library, queue,
playback, downloads, StateSync Lite, bilingual SwiftUI experience, Podcasting 2.0
Transcript/chapters, OPML migration and local SQLite backup export. Specifications and
validation boundaries are documented in `SPEC-*.md`.

## Requirements

- macOS with Xcode 27.0 or a compatible newer Xcode
- iOS 17 or later deployment target
- An installed iOS Simulator Runtime to execute XCTest locally
- An Apple Developer signing identity only when installing on a physical device

No signing identity is required for the generic Simulator build gates.

## Build

Run from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project FennecCast.xcodeproj \
  -scheme FennecCast \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Compile the application and XCTest bundle:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project FennecCast.xcodeproj \
  -scheme FennecCast \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

Format validation:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift-format \
  lint --strict --recursive Sources Tests
```

## Scope Boundaries

- The iOS database remains independent from AntennaPod's Android database.
- StateSync Lite v1 synchronizes only subscriptions, playback state and queue state.
- Media files, downloads, Inbox, favorites, tags, settings and cache remain local to each device.
- NAS server and Android adapter implementations live outside this iOS repository.

## License

FennecCast is licensed under the GNU General Public License, version 3. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
