# Implementation Plan: StateSync Lite iOS client

## Tasks

- [x] Task 1: Share and persist the Hybrid Logical Clock across synchronized features
- [x] Task 2: Add validated server settings and Keychain Bearer-token storage
- [x] Task 3: Implement bounded StateSync HTTP transport and protocol validation
- [x] Task 4: Implement single-flight SyncEngine, retry/debounce and status stream
- [x] Task 5: Wire foreground, mutation, playback, network and BGAppRefresh triggers
- [x] Task 6: Run full package, format, iOS build and build-for-testing verification

## Checkpoints

- [x] Only the three v1 entity types cross the network
- [x] Failed requests preserve the Outbox and cursor
- [x] Token values never enter UserDefaults, logs or typed errors
- [x] Remote HLC values advance later local mutations, including after relaunch
- [x] Background scheduling is opportunistic and honestly documented
