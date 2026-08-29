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
- [ ] Task 2: Add tested automatic download and cleanup policies and wire refresh triggers.
- [ ] Task 3: Apply per-podcast playback rules and add video presentation.
- [ ] Task 4: Add Keychain-backed authenticated-feed workflows and settings UI.
- [ ] Task 5: Add bounded database restore validation and next-launch activation.
- [ ] Task 6: Add tag, preferences, statistics, automation, and restore UI/localization.
- [ ] Task 7: Add the CarPlay scene, templates, entitlement, and project configuration.
- [ ] Task 8: Run focused/full tests, formatting, security review, iOS builds, and scope audit.

## Verification checkpoints

- [ ] Every behavior slice records RED before production implementation.
- [ ] StateSync protocol models and payload whitelist are unchanged.
- [ ] Credentials and imported files pass their security boundaries.
- [ ] Automatic cleanup cannot remove favorites or queued episodes.
- [ ] Existing database migration fixtures still pass.
- [ ] Adjacent AntennaPod checkout remains unchanged.
