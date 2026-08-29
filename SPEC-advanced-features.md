# Specification: Android-aligned advanced podcast features

## Scope

This increment implements the whitepaper v1.1 P1 features that are still missing from
FennecCast: per-podcast preferences, tags, automatic downloads and cleanup, local
statistics, authenticated feeds, video playback, and local database restore.

StateSync Lite v1 remains unchanged. These settings, credentials, statistics, download
decisions, and media files stay on the iOS device.

## User-visible behavior

- Each subscribed podcast can enable automatic download of newly discovered episodes.
- Each podcast can delete played downloads automatically and retain a bounded number of
  its newest completed downloads.
- Each podcast can override playback speed, skip-intro time, skip-ending time, and tags.
- Subscription lists can be filtered by tag.
- A statistics screen shows aggregate and per-podcast listening time, completed episodes,
  and downloaded storage derived from local data.
- A feed can be added or refreshed with HTTP Basic credentials. Credentials are accepted
  only for HTTPS feeds and are stored only in Keychain.
- Video episodes use the same playback engine and AVPlayer instance as audio playback and
  can be presented with the native AVKit player.
- A local SQLite export can be selected for restore. FennecCast validates and stages it,
  then replaces the database atomically before services open on the next launch. Keychain
  data is never imported.

## Limits and safety rules

- A refresh starts at most three automatic downloads for a podcast.
- Maintenance evaluates at most 1,000 episodes and never deletes favorites or queued
  episodes.
- Tags are trimmed, deduplicated case-insensitively, limited to 20 per podcast and 40
  characters each.
- Feed usernames are limited to 256 characters and passwords to 1,024 characters.
- Database imports are regular SQLite files no larger than 256 MiB, must pass
  `quick_check` and foreign-key checks, and may contain only the schema owned by the app.
- Restore is restricted to a backup with the same StateSync device identifier, preventing
  a copied database from making two devices share one identity.
- Feed credentials and StateSync tokens never enter SQLite, UserDefaults, logs, errors, or
  exported documents.

## Acceptance criteria

- Database migrations preserve existing P0 libraries and expose typed preference and
  statistics APIs.
- New-episode automation is deterministic, bounded, idempotent, and covered by tests.
- Per-podcast playback overrides apply when loading an episode.
- Credential request headers and validation are covered by tests; cross-origin redirects
  cannot forward an Authorization header.
- Video episodes render through AVKit without creating a second playback session.
- Valid same-device backups stage successfully; malformed, oversized, schema-mismatched,
  and foreign-device backups fail without changing the live database.
- English and Simplified Chinese strings cover every new control and status.
- Package tests, strict formatting, generic iOS build, and build-for-testing pass.

## Verification evidence

Verified on 2026-08-29 with Xcode 27 beta and Swift 6.4:

- All 136 `FennecCore` tests passed, including preferences, automation, playback rules,
  credential redirects/rollback, and database restore.
- Strict Swift format lint, plist validation, string-catalog JSON validation, and diff
  whitespace checks passed.
- Generic iOS Debug and Release builds and simulator `build-for-testing` passed.
- No StateSync protocol/model files changed in this increment; the advanced state remains
  device-local.
