# Specification: playback

**Status:** Complete  
**Sources:** FennecCast whitepaper v1.1, AntennaPod 3.12.0 behavior and Apple AVFoundation, AVKit, and MediaPlayer documentation

## 1. Purpose

Provide one local-first playback state source for streamed or downloaded podcast audio. UI and system controls send intents to the same actor; persisted playback mutations remain compatible with StateSync Lite v1.

## 2. Official Patterns

- Use `AVPlayer` for media loading, play/pause, seek, rate and periodic progress observation.
- Configure `AVAudioSession` as `.playback`, activate it only when playback begins and declare the `audio` background mode.
- Publish current title, podcast, position, duration and rate through `MPNowPlayingInfoCenter`.
- Register play, pause, toggle, skip, seek, next and rate handlers through the shared `MPRemoteCommandCenter`.
- Sources:
  - `https://developer.apple.com/documentation/avfoundation/avplayer`
  - `https://developer.apple.com/documentation/avfoundation/monitoring-playback-progress-in-your-app`
  - `https://developer.apple.com/documentation/avfaudio/avaudiosession`
  - `https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter`
  - `https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter`

## 3. In Scope

- Load a library episode from its local file when available, otherwise stream its HTTP(S) enclosure.
- Play, pause, exact seek, configurable forward/back skips and rates from 0.5x through 3.0x.
- Restore persisted position and keep the chosen rate across pause, buffering and item changes.
- Persist `checkpoint`, `playback_pause`, `seek`, `mark_played` and `mark_unplayed` intents through the existing atomic state plus Outbox boundary.
- Emit checkpoints at a bounded interval and flush on pause, item change, backgrounding and completion.
- Smart completion when playback ends or leaves an episode with at most 30 seconds remaining, matching AntennaPod's default behavior.
- Queue auto-advance, end-of-episode and episode-count sleep timers based on a monotonic clock/event source.
- Deterministic chapter normalization and source-priority merging.
- Audio interruptions, route changes, lock-screen, headset and Control Center commands.
- Per-podcast playback-rate, skip-intro, and skip-ending rules, without leaking a rate
  override into another podcast.
- Native AVKit video presentation and Picture in Picture over the same AVPlayer session.

## 4. Out of Scope

- Skip Silence, volume normalization, DRM, and AirPlay-specific UI.
- CarPlay template presentation, which is specified separately in `SPEC-carplay.md`.
- Playback-history analytics and media-file synchronization.

## 5. Safety and State Rules

- Only `http`, `https` and app-owned file URLs are playable.
- Invalid times, rates and episode metadata fail with typed errors; raw URLs or media payloads are not logged.
- UI never owns or directly mutates `AVPlayer`.
- Driver callbacks are serialized through `PlaybackEngine`; stale events from a replaced item cannot update the new item.
- Playback completion writes state before queue advancement.

## 6. Success Criteria

- Deterministic tests cover load/resume, play/pause, rate, seek/skip, checkpoints, smart completion, sleep timer and queue advancement.
- Chapter tests cover invalid entries, stable ordering, duplicate timestamps and source priority.
- The native AVPlayer driver, AVKit video surface, and system media controls compile for
  generic iOS and the simulator test target.
- Background audio mode is present in the built app `Info.plist`.
- Full package tests, strict formatting, generic iOS build and build-for-testing pass.

## 7. Verification Evidence

Verified on 2026-08-29 with Xcode 27 beta and Swift 6.4:

- Playback policy, persistence, engine and supplemental-content suites: 20 tests passed.
- Full `FennecCore` package: 136 tests passed.
- Strict Swift format lint passed for the application and package sources/tests.
- Generic iOS Release build and simulator `build-for-testing` passed with `PlaybackFeature`
  linked to the app.
- The built app `Info.plist` contains `UIBackgroundModes = [audio, fetch]`.
- Lock-screen hardware interaction and background continuation still require physical-device validation.
