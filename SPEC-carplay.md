# Specification: FennecCast CarPlay audio app

## Scope

FennecCast adds a native CarPlay audio scene using the CarPlay template APIs. It reuses the
existing local library, queue, AVPlayer-backed playback engine, Now Playing metadata, and
remote commands.

## Interface

- The root tab bar contains Continue Listening, Queue, Podcasts, and Now Playing.
- Lists are bounded to the limits reported by `CPListTemplate` and use short driving-safe
  labels.
- Selecting an episode starts playback through `PlaybackEngine`.
- Selecting a podcast opens its newest unplayed episodes.
- Now Playing uses `CPNowPlayingTemplate.shared` and the existing
  `MPNowPlayingInfoCenter` state.
- Empty and failed library loads show a usable list state rather than a blank template.

## Lifecycle and safety

- `CPTemplateApplicationSceneDelegate` owns only the CarPlay interface controller and
  cancellable observation tasks; app services remain owned by `AppEnvironment`.
- Disconnect cancels observers and releases the interface controller without stopping
  audio.
- All template mutations run on the main actor.
- No arbitrary SwiftUI or custom vehicle-screen drawing is used.

## Provisioning boundary

The project declares `com.apple.developer.carplay-audio` and the CarPlay scene manifest.
Apple must approve this managed entitlement before a signed physical-device build can use
CarPlay. Unsigned simulator compilation verifies source integration but cannot prove the
entitlement is provisioned.

## Acceptance criteria

- The CarPlay scene manifest names the scene and delegate correctly.
- The audio entitlement is connected to both app build configurations.
- Root and child templates stay within runtime item/section limits.
- Episode selection calls the same tested playback engine used by the iPhone UI.
- The generic iOS build and build-for-testing compile the CarPlay integration.

## Verification evidence

Verified on 2026-08-29 with Xcode 27 beta and Swift 6.4:

- The generic iOS Debug and Release builds passed without code signing.
- The generic iOS Simulator `build-for-testing` target passed compilation.
- The built app manifest expands the delegate to `FennecCast.CarPlaySceneDelegate`.
- The project connects `FennecCast.entitlements` to Debug and Release configurations.
- Physical CarPlay connection still requires Apple's audio-app entitlement approval,
  provisioning, and a signed device build.
