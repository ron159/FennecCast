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
- [ ] Task 4: Add media-local migration, repository and download state tests
- [ ] Task 5: Implement download service and background URLSession transport/recovery
- [ ] Task 6: Link both services to the app and complete verification

## Checkpoints

- [ ] Each behavior slice records RED before production implementation.
- [ ] Playback and download operations use typed, bounded failures.
- [ ] Playback mutations are atomic with Outbox; downloads never create Outbox entries.
- [ ] Full package tests and strict format lint pass.
- [ ] Generic iOS build, built Info.plist audit and build-for-testing pass.
- [ ] Adjacent Android checkout remains unchanged.
