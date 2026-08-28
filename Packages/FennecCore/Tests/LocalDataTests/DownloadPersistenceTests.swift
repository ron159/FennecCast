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

  @Test(arguments: DownloadTransition.allowed)
  func acceptsEveryDocumentedStateTransition(_ transition: DownloadTransition) async throws {
    let fixture = try await Fixture.make()
    let key = fixture.episodeKey
    try await prepare(
      transition.from,
      episodeKey: key,
      store: fixture.store
    )

    try await fixture.store.saveLocalMediaRecord(
      record(for: transition.to, episodeKey: key, timestamp: 10)
    )

    #expect(try await fixture.store.localMediaRecord(for: key)?.state == transition.to)
  }

  private func prepare(
    _ state: DownloadState,
    episodeKey: EpisodeKey,
    store: LocalDataStore
  ) async throws {
    if state == .notRequested {
      try await store.saveLocalMediaRecord(
        record(for: .notRequested, episodeKey: episodeKey, timestamp: 2)
      )
      return
    }
    try await store.saveLocalMediaRecord(
      record(for: .queued, episodeKey: episodeKey, timestamp: 2)
    )
    if state != .queued {
      try await store.saveLocalMediaRecord(
        record(for: state, episodeKey: episodeKey, timestamp: 3)
      )
    }
  }

  private func record(
    for state: DownloadState,
    episodeKey: EpisodeKey,
    timestamp: Int64
  ) -> LocalMediaRecord {
    switch state {
    case .notRequested:
      return LocalMediaRecord(
        episodeKey: episodeKey,
        state: state,
        updatedAtMilliseconds: timestamp
      )
    case .queued, .running, .cancelling:
      return LocalMediaRecord(
        episodeKey: episodeKey,
        state: state,
        taskIdentifier: 7,
        updatedAtMilliseconds: timestamp
      )
    case .suspended:
      return LocalMediaRecord(
        episodeKey: episodeKey,
        state: state,
        resumeData: Data([1]),
        updatedAtMilliseconds: timestamp
      )
    case .completed:
      return LocalMediaRecord(
        episodeKey: episodeKey,
        state: state,
        localRelativePath: "Media/\(episodeKey.rawValue).mp3",
        downloadedBytes: 1,
        contentLength: 1,
        updatedAtMilliseconds: timestamp
      )
    case .failed:
      return LocalMediaRecord(
        episodeKey: episodeKey,
        state: state,
        lastError: .network,
        updatedAtMilliseconds: timestamp
      )
    }
  }
}

struct DownloadTransition: Sendable, CustomTestStringConvertible {
  let from: DownloadState
  let to: DownloadState

  var testDescription: String {
    "\(from.rawValue) -> \(to.rawValue)"
  }

  static let allowed = [
    DownloadTransition(from: .notRequested, to: .queued),
    DownloadTransition(from: .queued, to: .running),
    DownloadTransition(from: .queued, to: .suspended),
    DownloadTransition(from: .queued, to: .completed),
    DownloadTransition(from: .queued, to: .cancelling),
    DownloadTransition(from: .queued, to: .failed),
    DownloadTransition(from: .running, to: .suspended),
    DownloadTransition(from: .running, to: .completed),
    DownloadTransition(from: .running, to: .cancelling),
    DownloadTransition(from: .running, to: .failed),
    DownloadTransition(from: .suspended, to: .notRequested),
    DownloadTransition(from: .suspended, to: .queued),
    DownloadTransition(from: .suspended, to: .running),
    DownloadTransition(from: .suspended, to: .cancelling),
    DownloadTransition(from: .suspended, to: .failed),
    DownloadTransition(from: .completed, to: .notRequested),
    DownloadTransition(from: .cancelling, to: .notRequested),
    DownloadTransition(from: .cancelling, to: .failed),
    DownloadTransition(from: .failed, to: .notRequested),
    DownloadTransition(from: .failed, to: .queued),
  ]
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
