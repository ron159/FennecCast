import CoreContracts
import Foundation
import LocalData
import Testing

struct DownloadPersistenceTests {
  @Test
  func persistsRecoverableLifecycleWithoutCreatingSyncMutations() async throws {
    let fixture = try await Fixture.make()
    let key = fixture.episodeKey

    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: key,
        state: .queued,
        taskIdentifier: 7,
        downloadedBytes: 0,
        contentLength: 100,
        updatedAtMilliseconds: 2
      )
    )
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: key,
        state: .running,
        taskIdentifier: 7,
        downloadedBytes: 40,
        contentLength: 100,
        eTag: "v1",
        updatedAtMilliseconds: 3
      )
    )
    let resumeData = Data([1, 2, 3])
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: key,
        state: .suspended,
        resumeData: resumeData,
        downloadedBytes: 40,
        contentLength: 100,
        eTag: "v1",
        updatedAtMilliseconds: 4
      )
    )
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: key,
        state: .queued,
        taskIdentifier: 8,
        downloadedBytes: 40,
        contentLength: 100,
        eTag: "v1",
        updatedAtMilliseconds: 5
      )
    )
    let relativePath = "Media/\(key.rawValue).mp3"
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: key,
        state: .completed,
        localRelativePath: relativePath,
        downloadedBytes: 100,
        contentLength: 100,
        eTag: "v1",
        checksumSHA256: String(repeating: "a", count: 64),
        updatedAtMilliseconds: 6
      )
    )

    let record = try #require(await fixture.store.localMediaRecord(for: key))
    #expect(record.state == .completed)
    #expect(record.localRelativePath == relativePath)
    #expect(record.taskIdentifier == nil)
    #expect(record.resumeData == nil)
    #expect(record.downloadedBytes == 100)
    #expect(try await fixture.store.pendingMutationCount() == 1)
  }

  @Test
  func rejectsInvalidTransitionsMetadataPathsAndMissingEpisodes() async throws {
    let fixture = try await Fixture.make()
    let key = fixture.episodeKey

    await #expect(
      throws: LocalDataError.invalidDownloadTransition(
        from: .notRequested,
        to: .completed
      )
    ) {
      try await fixture.store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: key,
          state: .completed,
          localRelativePath: "Media/file.mp3",
          downloadedBytes: 1,
          contentLength: 1,
          updatedAtMilliseconds: 2
        )
      )
    }
    await #expect(throws: LocalDataError.invalidDownloadMetadata) {
      try await fixture.store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: key,
          state: .queued,
          updatedAtMilliseconds: 2
        )
      )
    }
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: key,
        state: .queued,
        taskIdentifier: 7,
        updatedAtMilliseconds: 2
      )
    )
    await #expect(throws: LocalDataError.invalidLocalMediaPath) {
      try await fixture.store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: key,
          state: .completed,
          localRelativePath: "../outside.mp3",
          downloadedBytes: 1,
          contentLength: 1,
          updatedAtMilliseconds: 3
        )
      )
    }
    await #expect(throws: LocalDataError.invalidDownloadMetadata) {
      try await fixture.store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: key,
          state: .running,
          taskIdentifier: 7,
          downloadedBytes: -1,
          updatedAtMilliseconds: 3
        )
      )
    }
    await #expect(throws: LocalDataError.episodeNotFound) {
      try await fixture.store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: EpisodeKey(rawValue: "missing"),
          state: .queued,
          taskIdentifier: 9,
          updatedAtMilliseconds: 3
        )
      )
    }
  }

  @Test
  func listsRecordsByNewestUpdateThenEpisodeKey() async throws {
    let fixture = try await Fixture.make(episodeCount: 3)
    for (index, key) in fixture.episodeKeys.enumerated() {
      try await fixture.store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: key,
          state: .queued,
          taskIdentifier: index + 1,
          updatedAtMilliseconds: index == 0 ? 2 : 3
        )
      )
    }

    let records = try await fixture.store.localMediaRecords(states: [.queued])
    let equallyRecentKeys = fixture.episodeKeys[1...2].sorted {
      $0.rawValue < $1.rawValue
    }
    #expect(records.map(\.episodeKey) == equallyRecentKeys + [fixture.episodeKeys[0]])
  }
}

private struct Fixture {
  let store: LocalDataStore
  let episodeKeys: [EpisodeKey]

  var episodeKey: EpisodeKey { episodeKeys[0] }

  static func make(episodeCount: Int = 1) async throws -> Fixture {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let feedURL = try #require(URL(string: "https://example.com/feed.xml"))
    let feedKey = try FeedKey(canonicalURL: feedURL)
    let episodeKeys = try (1...episodeCount).map { index in
      try EpisodeKey(input: EpisodeIdentityInput(feedKey: feedKey, guid: "episode-\(index)"))
    }
    let episodes = zip(episodeKeys, 1...episodeCount).map { key, index in
      EpisodeMetadata(
        episodeKey: key,
        feedKey: feedKey,
        guid: "episode-\(index)",
        enclosureURL: URL(string: "https://cdn.example.com/episode-\(index).mp3"),
        linkURL: nil,
        title: "Episode \(index)",
        publicationDateMilliseconds: Int64(index * 1_000),
        durationMilliseconds: 120_000,
        summaryHTML: nil,
        mimeType: "audio/mpeg"
      )
    }
    _ = try await store.saveInitialSubscription(
      feed: FeedMetadata(
        feedKey: feedKey,
        canonicalURL: feedURL,
        title: "Download Cast",
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
    return Fixture(store: store, episodeKeys: episodeKeys)
  }
}
