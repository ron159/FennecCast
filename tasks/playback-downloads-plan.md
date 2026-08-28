# Implementation Plan: playback and downloads

## Architecture Decisions

- `PlaybackFeature` owns the playback actor and pure policies; `AVPlayerPlaybackDriver` owns Apple media APIs.
- `DownloadsFeature` owns the download actor; `BackgroundDownloadTransport` owns URLSession delegate mechanics.
- `LocalData` remains the only SQLite boundary for playback mutations and device-local download records.
- Native adapters implement small protocols so state behavior runs deterministically in package tests.

## Tasks

- [x] Task 1: Add playback policies, chapter merge and local playback persistence tests
- [x] Task 2: Implement PlaybackEngine state, commands, checkpoints, completion, sleep and queue advance
- [x] Task 3: Implement AVPlayer, AVAudioSession, Now Playing and remote-command adapters
- [x] Task 4: Add media-local migration, repository and download state tests
- [x] Task 5: Implement download service and background URLSession transport/recovery
- [x] Task 6: Link both services to the app and complete verification

## Checkpoints

- [x] Each behavior slice records RED before production implementation.
- [x] Playback and download operations use typed, bounded failures.
- [x] Playback mutations are atomic with Outbox; downloads never create Outbox entries.
- [x] Full package tests and strict format lint pass.
- [x] Generic iOS build, built Info.plist audit and build-for-testing pass.
- [x] Adjacent Android checkout remains unchanged.
