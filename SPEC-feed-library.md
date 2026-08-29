# Specification: feed-library

**Status:** Complete  
**Sources:** FennecCast whitepaper v1.1, Apple Foundation documentation, RSS 2.0 specification and RFC 4287

## 1. Purpose

Provide local-first podcast subscription, refresh and library behavior for RSS 2.0 and Atom feeds. Feed metadata is local; only the subscribed tombstone is written to StateSync Lite.

## 2. Official Patterns

- Parse XML with Foundation `XMLParser` as an event-driven delegate parser and disable external entity resolution.
- Fetch feeds with `URLSession.data(for:)`, conditional `If-None-Match` and `If-Modified-Since` headers, explicit HTTP status validation and bounded response size.
- Follow the response URL as the canonical redirect target and record forward-only feed aliases.
- Interpret RSS items according to RSS 2.0 and Atom entries/links according to RFC 4287.
- Sources:
  - `https://developer.apple.com/documentation/foundation/xmlparser`
  - `https://developer.apple.com/documentation/foundation/xmlparserdelegate`
  - `https://developer.apple.com/documentation/foundation/urlsession/data(for:)`
  - `https://www.rssboard.org/rss-specification`
  - `https://www.rfc-editor.org/rfc/rfc4287`

## 3. In Scope

- RSS 2.0 and Atom feed parsing, namespaces, CDATA, common dates and iTunes durations.
- Feed and episode canonical identity through `CoreContracts`.
- Add subscription, unsubscribe and conditional refresh.
- Metadata upsert without overwriting Inbox, favorite, archive or playback user state.
- Newly discovered episode Inbox policy.
- Subscription, episode list and Inbox/favorite/unplayed queries with deterministic sorting.
- Local Inbox, favorite and archive actions.
- English and Simplified Chinese failure states when surfaced by the app.

## 4. Out of Scope

- JSON Feed, paginated feed crawling and authenticated feeds.
- Auto-download policy, tags, statistics and feed-specific settings UI.
- HTML rendering; descriptions remain sanitized storage input and UI-safe plain text later.
- Server-side feed fetching or Android database changes.

## 5. Data and Safety Rules

- A successful first subscription persists feed metadata, episode metadata, new-episode Inbox state, subscribed state and its Outbox envelope atomically.
- A refresh never resets existing user state and never creates a sync mutation unless the subscription state changes.
- Invalid individual episodes without any stable locator are skipped; malformed feed documents fail without partial database writes.
- Only `http` and `https` URLs are accepted. HTTP redirects must also end on a network URL.
- Responses above 10 MiB are rejected before parsing; non-2xx responses are typed failures; `304` performs no database write.
- XML external entities are never resolved.

## 6. Success Criteria

- Golden RSS and Atom fixtures produce stable feed/episode metadata and canonical keys.
- Database tests prove refresh preserves user state and first subscription is atomic with Outbox.
- Fetch tests prove conditional headers, redirect aliases, `304`, status and size handling.
- Full Swift package tests, strict formatting, generic iOS build and build-for-testing pass.

## 7. Verification Evidence

Verified on 2026-08-29 with Xcode 27 beta and Swift 6.4:

- Feed parser, HTTP and workflow suites: 14 tests passed.
- Full `FennecCore` package: 136 tests passed.
- Strict Swift format lint passed for the application and package sources/tests.
- Generic iOS Simulator build and `build-for-testing` passed with `FeedLibrary` linked to the app.
- Runtime XCTest execution remains unavailable because this Mac has no installed Simulator Runtime.
