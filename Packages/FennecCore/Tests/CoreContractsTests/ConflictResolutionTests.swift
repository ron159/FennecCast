import Foundation
import Testing

@testable import CoreContracts

struct ConflictResolutionTests {
  @Test
  func newerSubscriptionTombstoneWins() throws {
    let current = VersionedState(
      value: SubscriptionState(
        feedKey: FeedKey(rawValue: "feed"),
        feedURL: try url("https://example.com/feed"),
        subscribed: true
      ),
      version: try version(wall: 100, counter: 0, device: "ios")
    )
    let incoming = VersionedState(
      value: SubscriptionState(
        feedKey: FeedKey(rawValue: "feed"),
        feedURL: try url("https://example.com/feed"),
        subscribed: false
      ),
      version: try version(wall: 101, counter: 0, device: "android")
    )

    let resolved = try ConflictResolver.resolveSubscription(current: current, incoming: incoming)

    #expect(resolved == incoming)
    #expect(!resolved.value.subscribed)
  }

  @Test
  func subscriptionTieUsesDeviceID() throws {
    let current = VersionedState(
      value: SubscriptionState(
        feedKey: FeedKey(rawValue: "feed"),
        feedURL: try url("https://example.com/feed"),
        subscribed: true
      ),
      version: try version(wall: 100, counter: 2, device: "android-phone")
    )
    let incoming = VersionedState(
      value: SubscriptionState(
        feedKey: FeedKey(rawValue: "feed"),
        feedURL: try url("https://example.com/feed"),
        subscribed: false
      ),
      version: try version(wall: 100, counter: 2, device: "ios-phone")
    )

    #expect(
      try ConflictResolver.resolveSubscription(current: current, incoming: incoming) == incoming
    )
  }

  @Test
  func newerQueueRemovalTombstoneWins() throws {
    let token = try FractionalIndex(rawValue: "3000000000000000")
    let current = VersionedState(
      value: QueueEntryState(
        episodeKey: EpisodeKey(rawValue: "ep"),
        orderToken: token,
        present: true
      ),
      version: try version(wall: 10, counter: 0, device: "ios")
    )
    let incoming = VersionedState(
      value: QueueEntryState(
        episodeKey: EpisodeKey(rawValue: "ep"),
        orderToken: token,
        present: false
      ),
      version: try version(wall: 11, counter: 0, device: "android")
    )

    let resolved = try ConflictResolver.resolveQueueEntry(current: current, incoming: incoming)

    #expect(resolved == incoming)
    #expect(!resolved.value.present)
  }

  @Test
  func newerPauseCanMovePlaybackBackward() throws {
    let current = VersionedState(
      value: try playback(intent: .playbackPause, position: 45 * 60_000),
      version: try version(wall: 100, counter: 0, device: "android")
    )
    let incoming = VersionedState(
      value: try playback(intent: .playbackPause, position: 30 * 60_000),
      version: try version(wall: 101, counter: 0, device: "ios")
    )

    let resolved = try ConflictResolver.resolvePlayback(current: current, incoming: incoming)

    #expect(resolved == incoming)
    #expect(resolved.value.positionMilliseconds == 30 * 60_000)
  }

  @Test
  func explicitSeekBeatsNewerCheckpoint() throws {
    let current = VersionedState(
      value: try playback(intent: .seek, position: 10 * 60_000),
      version: try version(wall: 100, counter: 0, device: "ios")
    )
    let incoming = VersionedState(
      value: try playback(intent: .checkpoint, position: 50 * 60_000),
      version: try version(wall: 200, counter: 0, device: "android")
    )

    #expect(try ConflictResolver.resolvePlayback(current: current, incoming: incoming) == current)
  }

  @Test
  func markUnplayedBeatsCheckpointAndPreservesZeroPosition() throws {
    let current = VersionedState(
      value: try EpisodePlayback(
        episodeKey: EpisodeKey(rawValue: "ep"),
        intent: .checkpoint,
        positionMilliseconds: 3_600_000,
        durationMilliseconds: 3_600_000,
        played: true
      ),
      version: try version(wall: 300, counter: 0, device: "android")
    )
    let incoming = VersionedState(
      value: try playback(intent: .markUnplayed, position: 0),
      version: try version(wall: 200, counter: 0, device: "ios")
    )

    let resolved = try ConflictResolver.resolvePlayback(current: current, incoming: incoming)

    #expect(resolved == incoming)
    #expect(!resolved.value.played)
    #expect(resolved.value.positionMilliseconds == 0)
  }

  @Test
  func samePlaybackIntentClassUsesVersion() throws {
    let current = VersionedState(
      value: try playback(intent: .markPlayed, position: 3_600_000, played: true),
      version: try version(wall: 100, counter: 0, device: "ios")
    )
    let incoming = VersionedState(
      value: try playback(intent: .markUnplayed, position: 0),
      version: try version(wall: 101, counter: 0, device: "android")
    )

    #expect(try ConflictResolver.resolvePlayback(current: current, incoming: incoming) == incoming)
  }

  @Test
  func resolverRejectsDifferentLogicalEntities() throws {
    let current = VersionedState(
      value: try playback(intent: .checkpoint, position: 1, episodeKey: "ep_a"),
      version: try version(wall: 1, counter: 0, device: "ios")
    )
    let incoming = VersionedState(
      value: try playback(intent: .checkpoint, position: 2, episodeKey: "ep_b"),
      version: try version(wall: 2, counter: 0, device: "android")
    )

    #expect(throws: ConflictResolutionError.entityKeyMismatch) {
      try ConflictResolver.resolvePlayback(current: current, incoming: incoming)
    }
  }

  private func playback(
    intent: PlaybackIntent,
    position: Int64,
    played: Bool = false,
    episodeKey: String = "ep"
  ) throws -> EpisodePlayback {
    try EpisodePlayback(
      episodeKey: EpisodeKey(rawValue: episodeKey),
      intent: intent,
      positionMilliseconds: position,
      durationMilliseconds: 3_600_000,
      played: played
    )
  }

  private func version(
    wall: Int64,
    counter: Int64,
    device: String
  ) throws -> VersionStamp {
    VersionStamp(
      timestamp: try HLCTimestamp(wallMilliseconds: wall, counter: counter),
      deviceID: try DeviceID(device)
    )
  }

  private func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }
}
