# Specification: FennecCast app experience

**Status:** Complete
**Source:** FennecCast whitepaper v1.1, sections 4 and 6

## Scope

- Native SwiftUI tabs for Home, Inbox, Queue, Subscriptions, Downloads, Search and Settings.
- Podcast and episode detail, direct Feed URL subscription, conditional refresh and unsubscribe.
- Local Inbox, favorite and archive actions; episode filtering and sorting.
- Queue add, remove and deterministic movement.
- Mini player and full player with play/pause, seek, skip, speed, sleep timer, next and chapters.
- Download start, progress, pause, resume, retry, cancel and local-file removal.
- StateSync configuration, redacted Keychain token handling, manual sync and visible status.
- Bounded OPML import/export and a consistent local SQLite backup export that excludes Keychain credentials.
- English and Simplified Chinese localizations.
- Foreground stale-Feed refresh and opportunistic background refresh of at most 20 stale feeds.

## Boundaries

- Search is local-library search plus a direct discovery/add-Feed entry; no third-party directory is required.
- HTML descriptions render as inert SwiftUI text and are never executed.
- Background scheduling time is controlled by iOS and is not promised as periodic.
- Downloads, Inbox, favorites, archives and settings remain device-local.

## Verification

- Generic iOS Simulator build and `build-for-testing` passed on 2026-08-29.
- Strict Swift format lint passed.
- Runtime UI tests and background behavior require an installed Simulator Runtime and physical iPhone respectively.
