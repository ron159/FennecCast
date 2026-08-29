import CoreContracts
import Foundation
import Testing

@testable import LocalData

struct AdvancedLibraryTests {
  @Test
  func feedPreferencesDefaultNormalizeAndRemainDeviceLocal() async throws {
    let fixture = try await Fixture.make()

    #expect(try await fixture.store.feedPreferences(for: fixture.feedKey) == .default)

    try await fixture.store.saveFeedPreferences(
      FeedPreferences(
        autoDownload: true,
        autoDeletePlayed: true,
        downloadRetentionLimit: 5,
        playbackRate: 1.5,
        skipIntroMilliseconds: 30_000,
        skipEndingMilliseconds: 45_000,
        tags: [" Tech ", "News", "tech", ""]
      ),
      for: fixture.feedKey
    )

    let stored = try await fixture.store.feedPreferences(for: fixture.feedKey)
    #expect(stored.autoDownload)
    #expect(stored.autoDeletePlayed)
    #expect(stored.downloadRetentionLimit == 5)
    #expect(stored.playbackRate == 1.5)
    #expect(stored.skipIntroMilliseconds == 30_000)
    #expect(stored.skipEndingMilliseconds == 45_000)
    #expect(stored.tags == ["News", "Tech"])
    #expect(try await fixture.store.allFeedPreferences()[fixture.feedKey] == stored)
    #expect(try await fixture.store.pendingMutationCount() == 1)
  }

  @Test
  func feedPreferencesRejectInvalidValuesWithoutOverwritingStoredRules() async throws {
    let fixture = try await Fixture.make()
    let valid = FeedPreferences(autoDownload: true, tags: ["Daily"])
    try await fixture.store.saveFeedPreferences(valid, for: fixture.feedKey)

    await #expect(throws: LocalDataError.invalidFeedPreferences) {
      try await fixture.store.saveFeedPreferences(
        FeedPreferences(downloadRetentionLimit: 0),
        for: fixture.feedKey
      )
    }
    await #expect(throws: LocalDataError.invalidFeedPreferences) {
      try await fixture.store.saveFeedPreferences(
        FeedPreferences(playbackRate: 4),
        for: fixture.feedKey
      )
    }
    await #expect(throws: LocalDataError.invalidFeedPreferences) {
      try await fixture.store.saveFeedPreferences(
        FeedPreferences(tags: [String(repeating: "x", count: 41)]),
        for: fixture.feedKey
      )
    }

    #expect(try await fixture.store.feedPreferences(for: fixture.feedKey) == valid)
  }

  @Test
  func statisticsDeriveListeningCompletionAndDownloadTotals() async throws {
    let fixture = try await Fixture.make()
    let first = fixture.episodeKeys[0]
    let second = fixture.episodeKeys[1]

    _ = try await fixture.store.recordPlaybackMutation(
      episodeKey: first,
      intent: .checkpoint,
      positionMilliseconds: 10_000,
      durationMilliseconds: 60_000,
      played: false,
      hlc: HLCTimestamp(wallMilliseconds: 10, counter: 0),
      createdAtMilliseconds: 10
    )
    _ = try await fixture.store.recordPlaybackMutation(
      episodeKey: first,
      intent: .playbackPause,
      positionMilliseconds: 40_000,
      durationMilliseconds: 60_000,
      played: false,
      hlc: HLCTimestamp(wallMilliseconds: 20, counter: 0),
      createdAtMilliseconds: 20
    )
    _ = try await fixture.store.recordPlaybackMutation(
      episodeKey: first,
      intent: .markPlayed,
      positionMilliseconds: 60_000,
      durationMilliseconds: 60_000,
      played: true,
      hlc: HLCTimestamp(wallMilliseconds: 30, counter: 0),
      createdAtMilliseconds: 30
    )

    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: second,
        state: .queued,
        taskIdentifier: 7,
        updatedAtMilliseconds: 40
      )
    )
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: second,
        state: .completed,
        localRelativePath: "Media/second.mp3",
        downloadedBytes: 2_048,
        contentLength: 2_048,
        checksumSHA256: String(repeating: "a", count: 64),
        updatedAtMilliseconds: 50
      )
    )

    let statistics = try await fixture.store.libraryStatistics()

    #expect(statistics.listeningMilliseconds == 40_000)
    #expect(statistics.completedEpisodeCount == 1)
    #expect(statistics.downloadedBytes == 2_048)
    #expect(statistics.feeds.count == 1)
    #expect(statistics.feeds[0].feedKey == fixture.feedKey)
    #expect(statistics.feeds[0].listeningMilliseconds == 40_000)
    #expect(statistics.feeds[0].completedEpisodeCount == 1)
    #expect(statistics.feeds[0].downloadedBytes == 2_048)
  }

  @Test
  func automaticDownloadCandidatesExcludeExistingPlayedAndArchivedEpisodes() async throws {
    let fixture = try await Fixture.make(episodeCount: 6)
    try await fixture.store.setEpisodeArchived(true, for: fixture.episodeKeys[0])
    _ = try await fixture.store.recordPlaybackMutation(
      episodeKey: fixture.episodeKeys[1],
      intent: .markPlayed,
      positionMilliseconds: 60_000,
      durationMilliseconds: 60_000,
      played: true,
      hlc: HLCTimestamp(wallMilliseconds: 10, counter: 0),
      createdAtMilliseconds: 10
    )
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: fixture.episodeKeys[2],
        state: .queued,
        taskIdentifier: 7,
        updatedAtMilliseconds: 11
      )
    )

    let candidates = try await fixture.store.automaticDownloadCandidates(
      feedKey: fixture.feedKey,
      episodeKeys: fixture.episodeKeys,
      limit: 3
    )

    #expect(candidates == Array(fixture.episodeKeys[3...5].reversed()))
  }

  @Test
  func cleanupCandidatesProtectFavoritesAndQueueEntries() async throws {
    let fixture = try await Fixture.make(episodeCount: 5)
    for (index, episodeKey) in fixture.episodeKeys.enumerated() {
      try await fixture.store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: episodeKey,
          state: .queued,
          taskIdentifier: index + 1,
          updatedAtMilliseconds: Int64(index + 10)
        )
      )
      try await fixture.store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: episodeKey,
          state: .completed,
          localRelativePath: "Media/\(index).mp3",
          downloadedBytes: 100,
          contentLength: 100,
          checksumSHA256: String(repeating: "a", count: 64),
          updatedAtMilliseconds: Int64(index + 20)
        )
      )
    }
    try await fixture.store.setFavorite(true, for: fixture.episodeKeys[0])
    _ = try await fixture.store.recordLocalMutation(
      .queueEntry(
        QueueEntryState(
          episodeKey: fixture.episodeKeys[1],
          orderToken: try FractionalIndex(rawValue: "0000000000000001"),
          present: true
        )
      ),
      hlc: HLCTimestamp(wallMilliseconds: 30, counter: 0),
      createdAtMilliseconds: 30
    )
    _ = try await fixture.store.recordPlaybackMutation(
      episodeKey: fixture.episodeKeys[2],
      intent: .markPlayed,
      positionMilliseconds: 60_000,
      durationMilliseconds: 60_000,
      played: true,
      hlc: HLCTimestamp(wallMilliseconds: 31, counter: 0),
      createdAtMilliseconds: 31
    )

    let candidates = try await fixture.store.downloadCleanupCandidates(
      feedKey: fixture.feedKey,
      autoDeletePlayed: true,
      retentionLimit: 2,
      limit: 100
    )

    #expect(candidates == [fixture.episodeKeys[2]])
  }
}

private struct Fixture {
  let store: LocalDataStore
  let feedKey: FeedKey
  let episodeKeys: [EpisodeKey]

  static func make(episodeCount: Int = 2) async throws -> Fixture {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let feedURL = try #require(URL(string: "https://example.com/feed.xml"))
    let feedKey = try FeedKey(canonicalURL: feedURL)
    let guids = (1...episodeCount).map { "episode-\($0)" }
    let episodeKeys = try guids.map { guid in
      let enclosureURL = try url("https://cdn.example.com/\(guid).mp3")
      return try EpisodeKey(
        input: EpisodeIdentityInput(
          feedKey: feedKey,
          guid: guid,
          enclosureURL: enclosureURL
        )
      )
    }
    let episodes = try zip(episodeKeys, guids).enumerated().map {
      index, value in
      EpisodeMetadata(
        episodeKey: value.0,
        feedKey: feedKey,
        guid: value.1,
        enclosureURL: try url("https://cdn.example.com/\(value.1).mp3"),
        linkURL: nil,
        title: value.1.capitalized,
        publicationDateMilliseconds: Int64(index + 1),
        durationMilliseconds: 60_000,
        summaryHTML: nil,
        mimeType: "audio/mpeg"
      )
    }
    _ = try await store.saveInitialSubscription(
      feed: FeedMetadata(
        feedKey: feedKey,
        canonicalURL: feedURL,
        title: "Example Cast",
        author: nil,
        summaryHTML: nil,
        imageURL: nil,
        eTag: nil,
        lastModified: nil
      ),
      episodes: episodes,
      markNewEpisodesInbox: true,
      hlc: HLCTimestamp(wallMilliseconds: 1, counter: 0),
      timestampMilliseconds: 1
    )
    return Fixture(store: store, feedKey: feedKey, episodeKeys: episodeKeys)
  }

  private static func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }
}
