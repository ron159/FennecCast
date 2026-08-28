# Specification: downloads

**Status:** Approved by the user's standing authorization to continue without repeated confirmation  
**Sources:** FennecCast whitepaper v1.1 and Apple Foundation background-transfer documentation

## 1. Purpose

Provide device-local, recoverable podcast media downloads backed by one background URLSession and the existing `media_local` table. Download state, task identifiers, files and errors never enter StateSync Lite.

## 2. Official Patterns

- Create one fixed-identifier `URLSessionConfiguration.background` session and recreate it at launch.
- Set `sessionSendsLaunchEvents`, use delegate download tasks and restore existing tasks after relaunch.
- Move the temporary completed file to permanent app-owned storage before the delegate callback returns.
- Store and invoke the application background-session completion handler only after `urlSessionDidFinishEvents`.
- Sources:
  - `https://developer.apple.com/documentation/foundation/downloading-files-in-the-background`
  - `https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)`
  - `https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate`
  - `https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:handleeventsforbackgroundurlsession:completionhandler:)`

## 3. In Scope

- Persistent states: not requested, queued, running, suspended, completed, cancelling and failed.
- Start, progress, suspend with resume data, resume, retry, cancel, remove and launch-time task reconciliation.
- Store task identifier, relative path, bytes, validators, content length, checksum and a bounded generic error code.
- Prefer a verified completed local file for playback and fall back to streaming if it is absent.
- Keep media under the FennecCast Application Support directory with canonical episode-key filenames.

## 4. Safety and State Rules

- Accept only HTTP(S) enclosure URLs; redirects must end on HTTP(S).
- Never trust a response filename for a path component. Derive the destination from `EpisodeKey` plus an allowlisted extension.
- Permanent destinations must remain under the configured media root.
- Validate 2xx response status, non-empty file, expected content length when known and optional SHA-256 before marking completed.
- File replacement is atomic where the filesystem permits; database state changes only after durable placement.
- Persist generic error categories, not raw server bodies, credential-bearing URLs or unrestricted localized descriptions.

## 5. Success Criteria

- Repository tests cover every state transition and prove download writes create no sync Outbox operations.
- Service tests cover duplicate requests, suspend/resume, retry, progress, completion, invalid status/path and relaunch reconciliation.
- Native background URLSession adapter and UIApplicationDelegate bridge compile for generic iOS Simulator.
- Full package tests, strict formatting, generic iOS build and build-for-testing pass.
- Simulator build limitations are reported; background continuation requires later physical-device validation.
