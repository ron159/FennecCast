import CoreContracts
import Foundation
import GRDB
import LocalData
import QueueFeature
import Testing

struct QueueServiceTests {
  @Test
  func supportsHeadTailBeforeAfterMoveRemoveAndReadd() async throws {
    let fixture = try await Fixture.make()
    let service = QueueService(store: fixture.store, timeMilliseconds: { 1_000 })

    _ = try await service.enqueue(fixture.keys[0], at: .tail)
    _ = try await service.enqueue(fixture.keys[1], at: .tail)
    _ = try await service.enqueue(fixture.keys[2], at: .head)
    _ = try await service.enqueue(fixture.keys[3], at: .before(fixture.keys[1]))
    #expect(
      try await service.currentQueue().map(\.episodeKey) == [
        fixture.keys[2], fixture.keys[0], fixture.keys[3], fixture.keys[1],
      ])

    _ = try await service.move(fixture.keys[1], to: .after(fixture.keys[2]))
    #expect(
      try await service.currentQueue().map(\.episodeKey) == [
        fixture.keys[2], fixture.keys[1], fixture.keys[0], fixture.keys[3],
      ])

    let removal = try await service.remove(fixture.keys[0])
    #expect(removal.payload.entityKey == fixture.keys[0].rawValue)
    #expect((try await fixture.store.queueState(for: fixture.keys[0]))?.value.present == false)
    _ = try await service.enqueue(fixture.keys[0], at: .after(fixture.keys[3]))
    let queue = try await service.currentQueue()
    #expect(
      queue.map(\.episodeKey) == [
        fixture.keys[2], fixture.keys[1], fixture.keys[3], fixture.keys[0],
      ])
    #expect(queue.allSatisfy { $0.episode != nil })
  }

  @Test
  func autoAdvanceOnlyRemovesCurrentAndReturnsNext() async throws {
    let fixture = try await Fixture.make()
    let service = QueueService(store: fixture.store, timeMilliseconds: { 2_000 })
    for key in fixture.keys.prefix(3) {
      _ = try await service.enqueue(key, at: .tail)
    }

    await #expect(throws: QueueServiceError.notCurrentEpisode) {
      try await service.autoAdvance(completedEpisodeKey: fixture.keys[1])
    }
    #expect(try await service.autoAdvance(completedEpisodeKey: fixture.keys[0]) == fixture.keys[1])
    #expect(
      try await service.currentQueue().map(\.episodeKey) == [
        fixture.keys[1], fixture.keys[2],
      ])
  }

  @Test
  func rejectsDuplicateMissingEntryTargetAndNoOpMove() async throws {
    let fixture = try await Fixture.make()
    let service = QueueService(store: fixture.store, timeMilliseconds: { 3_000 })
    _ = try await service.enqueue(fixture.keys[0], at: .tail)
    _ = try await service.enqueue(fixture.keys[1], at: .tail)

    await #expect(throws: QueueServiceError.alreadyQueued) {
      try await service.enqueue(fixture.keys[0], at: .tail)
    }
    await #expect(throws: QueueServiceError.entryNotQueued) {
      try await service.move(fixture.keys[2], to: .head)
    }
    await #expect(throws: QueueServiceError.targetNotQueued) {
      try await service.move(fixture.keys[0], to: .before(fixture.keys[3]))
    }
    #expect(try await service.move(fixture.keys[0], to: .head).isEmpty)
    await #expect(throws: LocalDataError.episodeNotFound) {
      try await service.enqueue(EpisodeKey(rawValue: "missing"), at: .tail)
    }
  }

  @Test
  func exhaustedGapRebasesVisibleOrderInOneBatch() async throws {
    let fixture = try await Fixture.make()
    let one = try FractionalIndex(rawValue: "0000000000000001")
    let two = try FractionalIndex(rawValue: "0000000000000002")
    _ = try await fixture.store.recordLocalMutation(
      .queueEntry(QueueEntryState(episodeKey: fixture.keys[0], orderToken: one, present: true)),
      hlc: HLCTimestamp(wallMilliseconds: 10, counter: 0),
      createdAtMilliseconds: 10
    )
    _ = try await fixture.store.recordLocalMutation(
      .queueEntry(QueueEntryState(episodeKey: fixture.keys[1], orderToken: two, present: true)),
      hlc: HLCTimestamp(wallMilliseconds: 11, counter: 0),
      createdAtMilliseconds: 11
    )
    let service = QueueService(store: fixture.store, timeMilliseconds: { 4_000 })

    let mutations = try await service.enqueue(
      fixture.keys[2],
      at: .before(fixture.keys[1])
    )

    #expect(mutations.count == 3)
    #expect(mutations.map(\.localSequence) == [4, 5, 6])
    let queue = try await service.currentQueue()
    #expect(queue.map(\.episodeKey) == [fixture.keys[0], fixture.keys[2], fixture.keys[1]])
    #expect(queue.map(\.orderToken) == (try FractionalIndex.rebase(count: 3)))
  }

  @Test
  func failedRebaseRollsBackEveryQueueEntryAndSequence() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fenneccast.sqlite").path
    let store = try LocalDataStore(path: path, deviceID: DeviceID("ios-phone"))
    let fixture = try await Fixture.populate(store: store)
    let one = try FractionalIndex(rawValue: "0000000000000001")
    let two = try FractionalIndex(rawValue: "0000000000000002")
    _ = try await store.recordLocalMutation(
      .queueEntry(QueueEntryState(episodeKey: fixture.keys[0], orderToken: one, present: true)),
      hlc: HLCTimestamp(wallMilliseconds: 10, counter: 0),
      createdAtMilliseconds: 10
    )
    _ = try await store.recordLocalMutation(
      .queueEntry(QueueEntryState(episodeKey: fixture.keys[1], orderToken: two, present: true)),
      hlc: HLCTimestamp(wallMilliseconds: 11, counter: 0),
      createdAtMilliseconds: 11
    )
    let external = try DatabaseQueue(path: path)
    try await external.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER fail_second_rebase_mutation
          BEFORE INSERT ON sync_outbox
          WHEN NEW.local_seq = 5
          BEGIN
            SELECT RAISE(ABORT, 'forced queue rebase failure');
          END
          """
      )
    }
    let service = QueueService(store: store, timeMilliseconds: { 5_000 })

    await #expect(throws: (any Error).self) {
      try await service.enqueue(fixture.keys[2], at: .before(fixture.keys[1]))
    }

    let queue = try await service.currentQueue()
    #expect(queue.map(\.episodeKey) == [fixture.keys[0], fixture.keys[1]])
    #expect(queue.map(\.orderToken) == [one, two])
    #expect((try await store.syncCursor()).lastLocalSequence == 3)
    #expect(try await store.pendingMutationCount() == 3)
    try await store.close()
  }

  @Test
  func exactReorderPersistsTheRequestedOrderAndRejectsInvalidKeySets() async throws {
    let fixture = try await Fixture.make()
    let service = QueueService(store: fixture.store, timeMilliseconds: { 6_000 })
    for key in fixture.keys.prefix(3) {
      _ = try await service.enqueue(key, at: .tail)
    }
    let desired = [fixture.keys[2], fixture.keys[0], fixture.keys[1]]

    let mutations = try await service.reorder(desired)

    #expect(!mutations.isEmpty)
    #expect(try await service.currentQueue().map(\.episodeKey) == desired)
    #expect(try await service.reorder(desired).isEmpty)
    await #expect(throws: QueueServiceError.invalidReorder) {
      try await service.reorder([fixture.keys[0], fixture.keys[0], fixture.keys[1]])
    }
    await #expect(throws: QueueServiceError.invalidReorder) {
      try await service.reorder([fixture.keys[0], fixture.keys[1]])
    }
    await #expect(throws: QueueServiceError.invalidReorder) {
      try await service.reorder([fixture.keys[0], fixture.keys[1], fixture.keys[3]])
    }
    #expect(try await service.currentQueue().map(\.episodeKey) == desired)
  }

  @Test
  func batchRemoveIsAtomicAndDeduplicatesSelectedKeys() async throws {
    let fixture = try await Fixture.make()
    let service = QueueService(store: fixture.store, timeMilliseconds: { 7_000 })
    for key in fixture.keys.prefix(3) {
      _ = try await service.enqueue(key, at: .tail)
    }

    let removals = try await service.remove([
      fixture.keys[0], fixture.keys[0], fixture.keys[2],
    ])

    #expect(removals.count == 2)
    #expect(try await service.currentQueue().map(\.episodeKey) == [fixture.keys[1]])
    await #expect(throws: QueueServiceError.entryNotQueued) {
      try await service.remove([fixture.keys[1], fixture.keys[3]])
    }
    #expect(try await service.currentQueue().map(\.episodeKey) == [fixture.keys[1]])
  }

  @Test
  func batchEnqueueIsAtomicAndDeduplicatesSelectedKeys() async throws {
    let fixture = try await Fixture.make()
    let service = QueueService(store: fixture.store, timeMilliseconds: { 8_000 })

    let additions = try await service.enqueue([
      fixture.keys[0], fixture.keys[0], fixture.keys[2],
    ])

    #expect(additions.count == 2)
    #expect(
      try await service.currentQueue().map(\.episodeKey)
        == [fixture.keys[0], fixture.keys[2]]
    )
    await #expect(throws: LocalDataError.episodeNotFound) {
      try await service.enqueue([fixture.keys[1], EpisodeKey(rawValue: "missing")])
    }
    #expect(
      try await service.currentQueue().map(\.episodeKey)
        == [fixture.keys[0], fixture.keys[2]]
    )
  }

  @Test
  func queueSorterSupportsMetadataOrdersAndDeterministicSmartShuffle() throws {
    let items = try [
      queueItem(feed: "a", episode: "a1", publication: 1, duration: 30),
      queueItem(feed: "a", episode: "a2", publication: 2, duration: 20),
      queueItem(feed: "a", episode: "a3", publication: 3, duration: 10),
      queueItem(feed: "b", episode: "b1", publication: 4, duration: 40),
      queueItem(feed: "b", episode: "b2", publication: 5, duration: 50),
      queueItem(feed: "c", episode: "c1", publication: 6, duration: 60),
    ]

    #expect(
      QueueSorter.sortedEpisodeKeys(items, by: .durationShortestFirst).map(\.rawValue)
        == ["a3", "a2", "a1", "b1", "b2", "c1"]
    )
    #expect(
      QueueSorter.sortedEpisodeKeys(items, by: .episodeTitleDescending).map(\.rawValue)
        == ["c1", "b2", "b1", "a3", "a2", "a1"]
    )
    let shuffled = QueueSorter.sortedEpisodeKeys(items, by: .smartShuffleOldestFirst)
    #expect(shuffled == QueueSorter.sortedEpisodeKeys(items, by: .smartShuffleOldestFirst))
    #expect(Set(shuffled) == Set(items.map(\.episodeKey)))
    #expect(shuffled.map(\.rawValue) == ["b1", "a1", "a2", "b2", "a3", "c1"])

    let missing = try queueItemWithoutMetadata(episode: "missing")
    let itemsWithMissingMetadata = items + [missing]
    #expect(
      QueueSorter.sortedEpisodeKeys(itemsWithMissingMetadata, by: .oldestFirst).last
        == missing.episodeKey
    )
    #expect(
      QueueSorter.sortedEpisodeKeys(itemsWithMissingMetadata, by: .durationShortestFirst).last
        == missing.episodeKey
    )
    #expect(
      QueueSorter.sortedEpisodeKeys(itemsWithMissingMetadata, by: .episodeTitleDescending).last
        == missing.episodeKey
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("FennecCast-Queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private func queueItem(
  feed: String,
  episode: String,
  publication: Int64,
  duration: Int64
) throws -> StoredQueueItem {
  let feedKey = FeedKey(rawValue: feed)
  let episodeKey = EpisodeKey(rawValue: episode)
  return StoredQueueItem(
    state: VersionedState(
      value: QueueEntryState(
        episodeKey: episodeKey,
        orderToken: try FractionalIndex(rawValue: String(format: "%016llx", publication)),
        present: true
      ),
      version: VersionStamp(timestamp: .zero, deviceID: try DeviceID("ios-phone"))
    ),
    episode: StoredEpisode(
      metadata: EpisodeMetadata(
        episodeKey: episodeKey,
        feedKey: feedKey,
        guid: episode,
        enclosureURL: nil,
        linkURL: nil,
        title: episode,
        publicationDateMilliseconds: publication,
        durationMilliseconds: duration,
        summaryHTML: nil,
        mimeType: "audio/mpeg"
      ),
      feedTitle: feed,
      inbox: false,
      favorite: false,
      archived: false,
      played: false,
      positionMilliseconds: 0,
      playedDurationMilliseconds: 0
    )
  )
}

private func queueItemWithoutMetadata(episode: String) throws -> StoredQueueItem {
  let episodeKey = EpisodeKey(rawValue: episode)
  return StoredQueueItem(
    state: VersionedState(
      value: QueueEntryState(
        episodeKey: episodeKey,
        orderToken: try FractionalIndex(rawValue: "fffffffffffffffe"),
        present: true
      ),
      version: VersionStamp(timestamp: .zero, deviceID: try DeviceID("ios-phone"))
    ),
    episode: nil
  )
}

private struct Fixture {
  let store: LocalDataStore
  let keys: [EpisodeKey]

  static func make() async throws -> Fixture {
    try await populate(store: LocalDataStore.inMemory(deviceID: DeviceID("ios-phone")))
  }

  static func populate(store: LocalDataStore) async throws -> Fixture {
    let feedURL = try #require(URL(string: "https://example.com/feed.xml"))
    let feedKey = try FeedKey(canonicalURL: feedURL)
    let keys = try (1...4).map { index in
      try EpisodeKey(
        input: EpisodeIdentityInput(feedKey: feedKey, guid: "episode-\(index)")
      )
    }
    let episodes = zip(keys, 1...4).map { key, index in
      EpisodeMetadata(
        episodeKey: key,
        feedKey: feedKey,
        guid: "episode-\(index)",
        enclosureURL: nil,
        linkURL: nil,
        title: "Episode \(index)",
        publicationDateMilliseconds: Int64(index * 1_000),
        durationMilliseconds: 60_000,
        summaryHTML: nil,
        mimeType: "audio/mpeg"
      )
    }
    _ = try await store.saveInitialSubscription(
      feed: FeedMetadata(
        feedKey: feedKey,
        canonicalURL: feedURL,
        title: "Queue Cast",
        author: nil,
        summaryHTML: nil,
        imageURL: nil,
        eTag: nil,
        lastModified: nil
      ),
      episodes: episodes,
      markNewEpisodesInbox: false,
      hlc: HLCTimestamp(wallMilliseconds: 1, counter: 0),
      timestampMilliseconds: 1
    )
    return Fixture(store: store, keys: keys)
  }
}
