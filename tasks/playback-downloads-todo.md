# Task List: playback and downloads

## Playback policies and persistence

- [x] Add deterministic rate, completion, sleep and chapter fixtures; observe RED.
- [x] Add playback snapshot and command models.
- [x] Add local playback writer/query helpers without bypassing Outbox.

## Playback engine and native adapter

- [x] Add driver-backed engine tests; observe RED.
- [x] Implement load/resume, play/pause, seek/skip/rate and periodic checkpoints.
- [x] Implement completion, queue advance and sleep timers.
- [x] Implement AVPlayer/audio-session adapter and stale-event isolation.
- [x] Implement Now Playing and remote-command integration.

## Download persistence and service

- [x] Add v3 media-local migration and repository tests; observe RED.
- [x] Implement typed local download states and queries.
- [x] Add transport-backed service tests; observe RED.
- [x] Implement start/progress/suspend/resume/retry/cancel/remove/reconcile.

## Background transport and closeout

- [x] Implement fixed-identifier background URLSession and delegate file handling.
- [x] Add UIApplicationDelegate completion-handler bridge.
- [x] Link playback/download services to AppEnvironment.
- [x] Run package, format, iOS build, Info.plist, build-for-testing and audit gates.
