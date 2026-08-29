import CoreContracts
import Foundation
import LocalData
import Testing

@testable import DownloadsFeature

struct PodcastAutomationServiceTests {
  @Test
  func refreshStartsAtMostThreeNewDownloadsAndReportsFailures() async throws {
    let fixture = try await AutomationFixture.make(episodeCount: 5)
    try await fixture.store.saveFeedPreferences(
      FeedPreferences(autoDownload: true),
      for: fixture.feedKey
    )
    await fixture.manager.fail(episodeKey: fixture.episodeKeys[3])
    let service = PodcastAutomationService(
      store: fixture.store,
      downloadManager: fixture.manager
    )

    let result = await service.handleRefresh(
      feedKey: fixture.feedKey,
      insertedEpisodeKeys: fixture.episodeKeys
    )

    #expect(result.startedEpisodeKeys == [fixture.episodeKeys[4], fixture.episodeKeys[2]])
    #expect(result.failedEpisodeKeys == [fixture.episodeKeys[3]])
    #expect(await fixture.manager.started() == Array(fixture.episodeKeys[2...4].reversed()))
  }

  @Test
  func refreshDoesNothingWhenPodcastAutomationIsDisabled() async throws {
    let fixture = try await AutomationFixture.make(episodeCount: 2)
    let service = PodcastAutomationService(
      store: fixture.store,
      downloadManager: fixture.manager
    )

    let result = await service.handleRefresh(
      feedKey: fixture.feedKey,
      insertedEpisodeKeys: fixture.episodeKeys
    )

    #expect(result == .empty)
    #expect(await fixture.manager.started().isEmpty)
  }
}

private enum MockAutomationError: Error {
  case forced
}

private actor MockAutomationDownloadManager: PodcastAutomationDownloadManaging {
  private var startedKeys: [EpisodeKey] = []
  private var failedKey: EpisodeKey?

  func fail(episodeKey: EpisodeKey) {
    failedKey = episodeKey
  }

  func startDownload(_ episodeKey: EpisodeKey) async throws {
    startedKeys.append(episodeKey)
    if episodeKey == failedKey { throw MockAutomationError.forced }
  }

  func removeDownload(_ episodeKey: EpisodeKey) async throws {}

  func started() -> [EpisodeKey] {
    startedKeys
  }
}

private struct AutomationFixture {
  let store: LocalDataStore
  let feedKey: FeedKey
  let episodeKeys: [EpisodeKey]
  let manager: MockAutomationDownloadManager

  static func make(episodeCount: Int) async throws -> AutomationFixture {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let feedURL = try #require(URL(string: "https://example.com/feed.xml"))
    let feedKey = try FeedKey(canonicalURL: feedURL)
    let episodeKeys = try (1...episodeCount).map { index in
      let enclosure = try url("https://cdn.example.com/\(index).mp3")
      return try EpisodeKey(
        input: EpisodeIdentityInput(
          feedKey: feedKey,
          guid: "episode-\(index)",
          enclosureURL: enclosure
        )
      )
    }
    let episodes = try episodeKeys.enumerated().map { index, episodeKey in
      EpisodeMetadata(
        episodeKey: episodeKey,
        feedKey: feedKey,
        guid: "episode-\(index + 1)",
        enclosureURL: try url("https://cdn.example.com/\(index + 1).mp3"),
        linkURL: nil,
        title: "Episode \(index + 1)",
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
    return AutomationFixture(
      store: store,
      feedKey: feedKey,
      episodeKeys: episodeKeys,
      manager: MockAutomationDownloadManager()
    )
  }

  private static func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }
}
