# Specification: migration import and export

**Status:** Complete
**Source:** FennecCast whitepaper v1.1, M2 migration milestone

## Scope and boundaries

- Import nested OPML 1.x/2.0 outlines and add valid HTTP(S) Feed URLs through the normal subscription workflow.
- Deduplicate feeds with the same canonical `FeedKey` and skip already subscribed feeds.
- Export subscribed Feed titles and URLs as deterministic UTF-8 OPML 2.0.
- Export a transactionally consistent SQLite snapshot of local application state, bounded to 256 MiB for safe file-export memory use.
- Limit documents to 5 MiB and 5,000 subscriptions.
- Reject DTDs, malformed XML, non-regular files, invalid export URLs and external entity resolution.
- OPML never contains playback, queue, downloads, database rows, settings or StateSync credentials.
- Database export refuses to overwrite an existing file and never includes the StateSync token stored in Keychain.
- Downloaded media files are not embedded in the SQLite snapshot.
- Database restore follows `SPEC-advanced-features.md`: only a bounded, validated,
  same-device backup can be staged, and replacement happens before services open on the
  next launch.

## Verification

- Four codec tests cover nesting, canonical deduplication, limits, DTD rejection, escaping and round trips.
- Two LocalData tests prove the SQLite snapshot reopens with state, Outbox and cursor intact and that existing files are not overwritten.
- iOS file importer/exporter integration compiles in the complete XCTest bundle.
