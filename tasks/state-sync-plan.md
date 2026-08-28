# Implementation Plan: StateSync Lite iOS client

## Tasks

- [x] Task 1: Share and persist the Hybrid Logical Clock across synchronized features
- [ ] Task 2: Add validated server settings and Keychain Bearer-token storage
- [ ] Task 3: Implement bounded StateSync HTTP transport and protocol validation
- [ ] Task 4: Implement single-flight SyncEngine, retry/debounce and status stream
- [ ] Task 5: Wire foreground, mutation, playback, network and BGAppRefresh triggers
- [ ] Task 6: Run full package, format, iOS build and build-for-testing verification

## Checkpoints

- [ ] Only the three v1 entity types cross the network
- [ ] Failed requests preserve the Outbox and cursor
- [ ] Token values never enter UserDefaults, logs or typed errors
- [ ] Remote HLC values advance later local mutations, including after relaunch
- [ ] Background scheduling is opportunistic and honestly documented
