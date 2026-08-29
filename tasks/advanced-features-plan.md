# Implementation Plan: advanced features and CarPlay

## Architecture decisions

- Extend `LocalData` with typed device-local feed preferences and derived statistics.
- Keep automation orchestration in `DownloadsFeature`; persistence and file deletion remain
  behind their existing owners.
- Keep feed Basic credentials in a dedicated Keychain store owned by `FeedLibrary`.
- Share one AVPlayer between the playback driver and AVKit video presentation.
- Stage validated restore files and apply them before `LocalDataStore` opens.
- Build CarPlay exclusively from system templates over the existing app services.

## Tasks

- [x] Task 1: Add v6 preferences/statistics schema and tested repositories.
- [x] Task 2: Add tested automatic download and cleanup policies and wire refresh triggers.
- [x] Task 3: Apply per-podcast playback rules and add video presentation.
- [x] Task 4: Add Keychain-backed authenticated-feed workflows and settings UI.
- [x] Task 5: Add bounded database restore validation and next-launch activation.
- [x] Task 6: Add tag, preferences, statistics, automation, and restore UI/localization.
- [x] Task 7: Add the CarPlay scene, templates, entitlement, and project configuration.
- [x] Task 8: Run focused/full tests, formatting, security review, iOS builds, and scope audit.

## Verification checkpoints

- [x] Every behavior slice records RED before production implementation.
- [x] StateSync protocol models and payload whitelist are unchanged.
- [x] Credentials and imported files pass their security boundaries.
- [x] Automatic cleanup cannot remove favorites or queued episodes.
- [x] Existing database migration fixtures still pass.
- [x] Adjacent AntennaPod checkout remains unchanged.
