import CoreContracts
import Foundation
import Testing

@testable import LocalData

struct RemoteSyncPersistenceTests {
  @Test
  func persistsMaximumLocalAndRemoteLogicalClock() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    #expect(try await store.syncClockTimestamp() == .zero)
    let feedKey = FeedKey(rawValue: "clock-feed")
    let feedURL = try url("https://example.com/clock.xml")
    _ = try await store.recordLocalMutation(
      .subscription(
        SubscriptionState(feedKey: feedKey, feedURL: feedURL, subscribed: true)
      ),
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 2),
      createdAtMilliseconds: 100
    )
    #expect(
      try await store.syncClockTimestamp()
        == HLCTimestamp(wallMilliseconds: 100, counter: 2)
    )
    let remote = try SyncChange(
      serverSequence: 1,
      deviceID: DeviceID("android-phone"),
      hlc: HLCTimestamp(wallMilliseconds: 500, counter: 7),
      entityType: .subscription,
      entityKey: feedKey.rawValue,
      payload: .subscription(
        SubscriptionState(feedKey: feedKey, feedURL: feedURL, subscribed: false)
      )
    )

    try await store.applySyncResponse(
      SyncResponse(acceptedLocalSequence: 0, nextCursor: 1, changes: [remote])
    )

    #expect(
      try await store.syncClockTimestamp()
        == HLCTimestamp(wallMilliseconds: 500, counter: 7)
    )
  }

  @Test
  func pendingMutationsAreOrderedLimitedAndRemainMonotonicAfterAcknowledgement() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    for index in 1...3 {
      let state = SubscriptionState(
        feedKey: FeedKey(rawValue: "feed_\(index)"),
        feedURL: try url("https://example.com/feed-\(index).xml"),
        subscribed: true
      )
      _ = try await store.recordLocalMutation(
        .subscription(state),
        hlc: HLCTimestamp(wallMilliseconds: Int64(index), counter: 0),
        createdAtMilliseconds: Int64(index)
      )
    }

    #expect(try await store.pendingMutations(limit: 2).map(\.localSequence) == [1, 2])
    await #expect(throws: LocalDataError.invalidBatchLimit) {
      try await store.pendingMutations(limit: 0)
    }
    await #expect(throws: LocalDataError.invalidBatchLimit) {
      try await store.pendingMutations(limit: 501)
    }

    try await store.applySyncResponse(
      SyncResponse(acceptedLocalSequence: 3, nextCursor: 0, changes: [])
    )
    #expect(try await store.pendingMutationCount() == 0)
    let fourth = try await store.recordLocalMutation(
      .subscription(
        SubscriptionState(
          feedKey: FeedKey(rawValue: "feed_4"),
          feedURL: try url("https://example.com/feed-4.xml"),
          subscribed: true
        )
      ),
      hlc: HLCTimestamp(wallMilliseconds: 4, counter: 0),
      createdAtMilliseconds: 4
    )
    #expect(fourth.localSequence == 4)
  }

  @Test
  func responseAtomicallyMergesAdvancesCursorAndAcknowledgesOutbox() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let feedKey = FeedKey(rawValue: "feed")
    let feedURL = try url("https://example.com/feed.xml")
    _ = try await store.recordLocalMutation(
      .subscription(
        SubscriptionState(feedKey: feedKey, feedURL: feedURL, subscribed: true)
      ),
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      createdAtMilliseconds: 100
    )
    let remoteState = SubscriptionState(
      feedKey: feedKey,
      feedURL: feedURL,
      subscribed: false
    )
    let change = try SyncChange(
      serverSequence: 10,
      deviceID: DeviceID("android-phone"),
      hlc: HLCTimestamp(wallMilliseconds: 101, counter: 0),
      entityType: .subscription,
      entityKey: feedKey.rawValue,
      payload: .subscription(remoteState)
    )

    try await store.applySyncResponse(
      SyncResponse(acceptedLocalSequence: 1, nextCursor: 10, changes: [change])
    )

    let resolved = try #require(try await store.subscriptionState(for: feedKey))
    #expect(resolved.value == remoteState)
    #expect(resolved.version.deviceID == DeviceID(rawValue: "android-phone"))
    #expect((try await store.syncCursor()).serverSequence == 10)
    #expect(try await store.pendingMutationCount() == 0)
  }

  @Test
  func remoteApplyUsesPlaybackIntentAndQueueConflictRulesWithoutCreatingOutbox() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let episodeKey = EpisodeKey(rawValue: "episode")
    let localPlayback = try EpisodePlayback(
      episodeKey: episodeKey,
      intent: .seek,
      positionMilliseconds: 10_000,
      durationMilliseconds: 100_000,
      played: false
    )
    let token = try FractionalIndex(rawValue: "3000000000000000")
    _ = try await store.recordLocalMutation(
      .episodePlayback(localPlayback),
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      createdAtMilliseconds: 100
    )
    _ = try await store.recordLocalMutation(
      .queueEntry(
        QueueEntryState(episodeKey: episodeKey, orderToken: token, present: true)
      ),
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 1),
      createdAtMilliseconds: 100
    )
    let remotePlayback = try EpisodePlayback(
      episodeKey: episodeKey,
      intent: .checkpoint,
      positionMilliseconds: 50_000,
      durationMilliseconds: 100_000,
      played: false
    )
    let playbackChange = try change(
      sequence: 1,
      hlcWall: 200,
      payload: .episodePlayback(remotePlayback)
    )
    let queueChange = try change(
      sequence: 2,
      hlcWall: 201,
      payload: .queueEntry(
        QueueEntryState(episodeKey: episodeKey, orderToken: token, present: false)
      )
    )

    try await store.applySyncResponse(
      SyncResponse(
        acceptedLocalSequence: 0,
        nextCursor: 2,
        changes: [playbackChange, queueChange]
      )
    )

    #expect((try await store.playbackState(for: episodeKey))?.value == localPlayback)
    #expect((try await store.queueState(for: episodeKey))?.value.present == false)
    #expect(try await store.pendingMutationCount() == 2)
  }

  @Test
  func rejectsInvalidResponseOrderingAcknowledgementAndCursorRegression() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let first = try change(
      sequence: 2,
      hlcWall: 2,
      payload: .subscription(try subscription("first"))
    )
    let second = try change(
      sequence: 1,
      hlcWall: 1,
      payload: .subscription(try subscription("second"))
    )

    await #expect(throws: LocalDataError.unorderedServerChanges) {
      try await store.applySyncResponse(
        SyncResponse(
          acceptedLocalSequence: 0,
          nextCursor: 2,
          changes: [first, second]
        )
      )
    }
    await #expect(throws: LocalDataError.invalidAcknowledgement) {
      try await store.applySyncResponse(
        SyncResponse(acceptedLocalSequence: 1, nextCursor: 0, changes: [])
      )
    }

    try await store.applySyncResponse(
      SyncResponse(acceptedLocalSequence: 0, nextCursor: 5, changes: [])
    )
    await #expect(throws: LocalDataError.cursorRegression(current: 5, proposed: 4)) {
      try await store.applySyncResponse(
        SyncResponse(acceptedLocalSequence: 0, nextCursor: 4, changes: [])
      )
    }
    #expect((try await store.syncCursor()).serverSequence == 5)
  }

  @Test
  func failedRemoteChangeRollsBackEarlierChangesAndCursor() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let sharedURL = try url("https://example.com/shared.xml")
    let firstState = SubscriptionState(
      feedKey: FeedKey(rawValue: "feed_a"),
      feedURL: sharedURL,
      subscribed: true
    )
    let conflictingState = SubscriptionState(
      feedKey: FeedKey(rawValue: "feed_b"),
      feedURL: sharedURL,
      subscribed: true
    )
    let changes = [
      try change(sequence: 1, hlcWall: 1, payload: .subscription(firstState)),
      try change(sequence: 2, hlcWall: 2, payload: .subscription(conflictingState)),
    ]

    await #expect(throws: (any Error).self) {
      try await store.applySyncResponse(
        SyncResponse(acceptedLocalSequence: 0, nextCursor: 2, changes: changes)
      )
    }

    #expect(try await store.subscriptionState(for: firstState.feedKey) == nil)
    #expect(try await store.subscriptionState(for: conflictingState.feedKey) == nil)
    #expect((try await store.syncCursor()).serverSequence == 0)
  }

  private func change(
    sequence: Int64,
    hlcWall: Int64,
    payload: SyncPayload
  ) throws -> SyncChange {
    try SyncChange(
      serverSequence: sequence,
      deviceID: DeviceID("android-phone"),
      hlc: HLCTimestamp(wallMilliseconds: hlcWall, counter: 0),
      entityType: payload.entityType,
      entityKey: payload.entityKey,
      payload: payload
    )
  }

  private func subscription(_ suffix: String) throws -> SubscriptionState {
    SubscriptionState(
      feedKey: FeedKey(rawValue: "feed_\(suffix)"),
      feedURL: try url("https://example.com/\(suffix).xml"),
      subscribed: true
    )
  }

  private func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }
}
