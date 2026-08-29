# Task List: advanced features and CarPlay

## Local advanced state

- [x] Write migration and repository tests for preferences, tags, and cleanup settings.
- [x] Observe RED, then implement v6 migration and typed APIs.
- [x] Write statistics query tests, observe RED, then implement bounded aggregates.

## Automation and playback

- [x] Write candidate/cleanup policy tests and observe RED.
- [x] Implement bounded auto-download and protected cleanup.
- [x] Wire foreground and refreshed-feed triggers.
- [x] Write playback override tests and implement speed/intro/ending rules.
- [x] Share AVPlayer with an AVKit video view.

## Auth and restore

- [x] Write authenticated request and credential validation tests and observe RED.
- [x] Implement Keychain feed credentials and safe redirect handling.
- [ ] Add authenticated add/edit feed workflows.
- [ ] Write backup validation/staging tests and observe RED.
- [ ] Implement same-device, next-launch database restore.

## UI and CarPlay

- [ ] Add focused SwiftUI files for podcast settings, statistics, video, and restore.
- [ ] Add English and Simplified Chinese localizations.
- [ ] Add CarPlay template scene, bounded content, entitlement, and scene manifest.

## Closeout

- [ ] Run all package tests and strict Swift format lint.
- [ ] Run generic iOS build and build-for-testing.
- [ ] Review correctness, simplicity, architecture, security, and performance.
- [ ] Audit diff, secrets, StateSync scope, and adjacent Android status.
