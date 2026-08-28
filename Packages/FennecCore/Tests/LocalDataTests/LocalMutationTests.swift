import CoreContracts
import Foundation
import GRDB
import Testing

@testable import LocalData

struct LocalMutationTests {
  @Test
  func recordsSubscriptionPlaybackAndQueueWithMonotonicSequences() async throws {
    let deviceID = try DeviceID("ios-phone")
    let store = try LocalDataStore.inMemory(deviceID: deviceID)
    let feedURL = try url("https://example.com/feed.xml")
    let subscription = SubscriptionState(
      feedKey: FeedKey(rawValue: "feed_1"),
      feedURL: feedURL,
      subscribed: true
    )
    let playback = try EpisodePlayback(
      episodeKey: EpisodeKey(rawValue: "episode_1"),
      intent: .playbackPause,
      positionMilliseconds: 1_264_000,
      durationMilliseconds: 3_600_000,
      played: false,
      feedURL: feedURL,
      guid: "guid-1"
    )
    let queue = QueueEntryState(
      episodeKey: EpisodeKey(rawValue: "episode_1"),
      orderToken: try FractionalIndex(rawValue: "3000000000000000"),
      present: true
    )

    let first = try await store.recordLocalMutation(
      .subscription(subscription),
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      createdAtMilliseconds: 100
    )
    let second = try await store.recordLocalMutation(
      .episodePlayback(playback),
      hlc: HLCTimestamp(wallMilliseconds: 101, counter: 0),
      createdAtMilliseconds: 101
    )
    let third = try await store.recordLocalMutation(
      .queueEntry(queue),
      hlc: HLCTimestamp(wallMilliseconds: 102, counter: 0),
      createdAtMilliseconds: 102
    )

    #expect([first.localSequence, second.localSequence, third.localSequence] == [1, 2, 3])
    #expect(first.entityType == .subscription)
    #expect(second.entityType == .episodePlayback)
    #expect(third.entityType == .queueEntry)
    #expect((try await store.syncCursor()).lastLocalSequence == 3)
    #expect(try await store.pendingMutationCount() == 3)

    let subscriptionState = try #require(
      try await store.subscriptionState(for: FeedKey(rawValue: "feed_1"))
    )
    let playbackState = try #require(
      try await store.playbackState(for: EpisodeKey(rawValue: "episode_1"))
    )
    let queueState = try #require(
      try await store.queueState(for: EpisodeKey(rawValue: "episode_1"))
    )
    #expect(subscriptionState.value == subscription)
    #expect(subscriptionState.version.deviceID == deviceID)
    #expect(playbackState.value == playback)
    #expect(playbackState.version.timestamp.wallMilliseconds == 101)
    #expect(queueState.value == queue)
    #expect(queueState.version.timestamp.wallMilliseconds == 102)
  }

  @Test
  func outboxFailureRollsBackBusinessStateAndSequence() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fenneccast.sqlite").path
    let store = try LocalDataStore(path: path, deviceID: DeviceID("ios-phone"))
    let external = try DatabaseQueue(path: path)
    try await external.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER force_outbox_failure
          BEFORE INSERT ON sync_outbox
          BEGIN
            SELECT RAISE(ABORT, 'forced outbox failure');
          END
          """
      )
    }
    let subscription = SubscriptionState(
      feedKey: FeedKey(rawValue: "feed_rollback"),
      feedURL: try url("https://example.com/rollback.xml"),
      subscribed: true
    )

    await #expect(throws: (any Error).self) {
      try await store.recordLocalMutation(
        .subscription(subscription),
        hlc: HLCTimestamp(wallMilliseconds: 200, counter: 0),
        createdAtMilliseconds: 200
      )
    }

    #expect(try await store.subscriptionState(for: subscription.feedKey) == nil)
    #expect((try await store.syncCursor()).lastLocalSequence == 0)
    #expect(try await store.pendingMutationCount() == 0)
    let feedCount = try await external.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feeds")
    }
    #expect(feedCount == 0)
    try await store.close()
  }

  @Test
  func rejectsNegativeCreationTimeWithoutWriting() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let state = SubscriptionState(
      feedKey: FeedKey(rawValue: "feed"),
      feedURL: try url("https://example.com/feed"),
      subscribed: true
    )

    await #expect(throws: LocalDataError.negativeTimestamp) {
      try await store.recordLocalMutation(
        .subscription(state),
        hlc: HLCTimestamp(wallMilliseconds: 1, counter: 0),
        createdAtMilliseconds: -1
      )
    }
    #expect(try await store.pendingMutationCount() == 0)
  }

  private func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("FennecCast-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
