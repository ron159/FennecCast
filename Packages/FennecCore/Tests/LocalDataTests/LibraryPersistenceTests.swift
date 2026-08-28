import CoreContracts
import Foundation
import GRDB
import Testing

@testable import LocalData

struct LibraryPersistenceTests {
  @Test
  func firstSubscriptionPersistsMetadataInboxAndOutboxAtomically() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let fixture = try fixture()

    let result = try await store.saveInitialSubscription(
      feed: fixture.feed,
      episodes: fixture.episodes,
      markNewEpisodesInbox: true,
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      timestampMilliseconds: 100
    )

    #expect(result.insertedEpisodeKeys == fixture.episodes.map(\.episodeKey))
    #expect(result.subscriptionMutation.localSequence == 1)
    let feeds = try await store.subscribedFeeds()
    #expect(feeds.count == 1)
    #expect(feeds[0].title == "Example Cast")
    #expect(feeds[0].subscribed)
    let episodes = try await store.libraryEpisodes(filter: .inbox, sort: .newestFirst)
    #expect(episodes.map(\.title) == ["Episode Two", "Episode One"])
    #expect(episodes.allSatisfy { $0.inbox })
    #expect(
      episodes[1].metadata.transcriptURL
        == (try url("https://cdn.example.com/transcript.vtt"))
    )
    #expect(episodes[1].metadata.transcriptType == "text/vtt")
    #expect(episodes[1].metadata.chaptersURL == (try url("https://cdn.example.com/chapters.json")))
    #expect(episodes[1].metadata.chaptersType == "application/json+chapters")
    #expect(try await store.pendingMutations().map(\.entityType) == [.subscription])
  }

  @Test
  func refreshUpdatesMetadataAndAddsInboxWithoutOverwritingUserState() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let fixture = try fixture()
    _ = try await store.saveInitialSubscription(
      feed: fixture.feed,
      episodes: [fixture.episodes[0]],
      markNewEpisodesInbox: true,
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      timestampMilliseconds: 100
    )
    try await store.setInbox(false, for: fixture.episodes[0].episodeKey)
    try await store.setFavorite(true, for: fixture.episodes[0].episodeKey)
    _ = try await store.recordLocalMutation(
      .episodePlayback(
        try EpisodePlayback(
          episodeKey: fixture.episodes[0].episodeKey,
          intent: .playbackPause,
          positionMilliseconds: 42_000,
          durationMilliseconds: 120_000,
          played: false
        )
      ),
      hlc: HLCTimestamp(wallMilliseconds: 101, counter: 0),
      createdAtMilliseconds: 101
    )

    let updatedFirst = EpisodeMetadata(
      episodeKey: fixture.episodes[0].episodeKey,
      feedKey: fixture.feed.feedKey,
      guid: "episode-1",
      enclosureURL: try url("https://cdn.example.com/one.mp3"),
      linkURL: try url("https://example.com/one"),
      title: "Episode One Updated",
      publicationDateMilliseconds: 1_000,
      durationMilliseconds: 120_000,
      summaryHTML: "Updated notes",
      mimeType: "audio/mpeg"
    )
    let result = try await store.saveFeedRefresh(
      feed: FeedMetadata(
        feedKey: fixture.feed.feedKey,
        canonicalURL: fixture.feed.canonicalURL,
        title: "Example Cast Updated",
        author: "New Author",
        summaryHTML: "New summary",
        imageURL: nil,
        eTag: "v2",
        lastModified: "Fri, 01 Jan 2027 00:00:00 GMT"
      ),
      episodes: [updatedFirst, fixture.episodes[1]],
      markNewEpisodesInbox: true,
      refreshedAtMilliseconds: 200
    )

    #expect(result.insertedEpisodeKeys == [fixture.episodes[1].episodeKey])
    #expect(try await store.pendingMutationCount() == 2)
    let all = try await store.libraryEpisodes(filter: .all, sort: .oldestFirst)
    #expect(all.map(\.title) == ["Episode One Updated", "Episode Two"])
    #expect(!all[0].inbox)
    #expect(all[0].favorite)
    #expect(all[0].positionMilliseconds == 42_000)
    #expect(all[1].inbox)
    #expect((try await store.subscribedFeeds())[0].title == "Example Cast Updated")
  }

  @Test
  func filtersAndLocalStateActionsAreDeterministic() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let fixture = try fixture()
    _ = try await store.saveInitialSubscription(
      feed: fixture.feed,
      episodes: fixture.episodes,
      markNewEpisodesInbox: false,
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      timestampMilliseconds: 100
    )
    try await store.setFavorite(true, for: fixture.episodes[1].episodeKey)
    try await store.setInbox(true, for: fixture.episodes[0].episodeKey)
    try await store.setEpisodeArchived(true, for: fixture.episodes[0].episodeKey)
    _ = try await store.recordLocalMutation(
      .episodePlayback(
        try EpisodePlayback(
          episodeKey: fixture.episodes[1].episodeKey,
          intent: .markPlayed,
          positionMilliseconds: 180_000,
          durationMilliseconds: 180_000,
          played: true
        )
      ),
      hlc: HLCTimestamp(wallMilliseconds: 101, counter: 0),
      createdAtMilliseconds: 101
    )

    #expect(
      try await store.libraryEpisodes(filter: .inbox, sort: .newestFirst).map(\.episodeKey)
        == [fixture.episodes[0].episodeKey]
    )
    #expect(
      try await store.libraryEpisodes(filter: .favorites, sort: .newestFirst).map(\.episodeKey)
        == [fixture.episodes[1].episodeKey]
    )
    #expect(
      try await store.libraryEpisodes(filter: .unplayed, sort: .newestFirst).map(\.episodeKey)
        == [fixture.episodes[0].episodeKey]
    )
    #expect(
      try await store.libraryEpisodes(filter: .archived, sort: .newestFirst).map(\.episodeKey)
        == [fixture.episodes[0].episodeKey]
    )
  }

  @Test
  func outboxFailureRollsBackInitialFeedAndEpisodes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fenneccast.sqlite").path
    let store = try LocalDataStore(path: path, deviceID: DeviceID("ios-phone"))
    let external = try DatabaseQueue(path: path)
    try await external.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER force_feed_outbox_failure
          BEFORE INSERT ON sync_outbox
          BEGIN
            SELECT RAISE(ABORT, 'forced feed outbox failure');
          END
          """
      )
    }
    let fixture = try fixture()

    await #expect(throws: (any Error).self) {
      try await store.saveInitialSubscription(
        feed: fixture.feed,
        episodes: fixture.episodes,
        markNewEpisodesInbox: true,
        hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
        timestampMilliseconds: 100
      )
    }

    #expect(try await store.subscribedFeeds().isEmpty)
    #expect(try await store.libraryEpisodes(filter: .all, sort: .newestFirst).isEmpty)
    #expect((try await store.syncCursor()).lastLocalSequence == 0)
    try await store.close()
  }

  private func fixture() throws -> (feed: FeedMetadata, episodes: [EpisodeMetadata]) {
    let feedURL = try url("https://example.com/feed.xml")
    let feedKey = try FeedKey(canonicalURL: feedURL)
    let first = try episode(
      feedKey: feedKey,
      guid: "episode-1",
      title: "Episode One",
      publication: 1_000,
      duration: 120_000
    )
    let second = try episode(
      feedKey: feedKey,
      guid: "episode-2",
      title: "Episode Two",
      publication: 2_000,
      duration: 180_000
    )
    return (
      FeedMetadata(
        feedKey: feedKey,
        canonicalURL: feedURL,
        title: "Example Cast",
        author: "Author",
        summaryHTML: "Summary",
        imageURL: try url("https://example.com/cover.jpg"),
        eTag: "v1",
        lastModified: nil
      ),
      [first, second]
    )
  }

  private func episode(
    feedKey: FeedKey,
    guid: String,
    title: String,
    publication: Int64,
    duration: Int64
  ) throws -> EpisodeMetadata {
    let enclosure = try url("https://cdn.example.com/\(guid).mp3")
    let key = try EpisodeKey(
      input: EpisodeIdentityInput(feedKey: feedKey, guid: guid, enclosureURL: enclosure)
    )
    return EpisodeMetadata(
      episodeKey: key,
      feedKey: feedKey,
      guid: guid,
      enclosureURL: enclosure,
      linkURL: try url("https://example.com/\(guid)"),
      title: title,
      publicationDateMilliseconds: publication,
      durationMilliseconds: duration,
      summaryHTML: "Notes for \(title)",
      mimeType: "audio/mpeg",
      transcriptURL: try url("https://cdn.example.com/transcript.vtt"),
      transcriptType: "text/vtt",
      chaptersURL: try url("https://cdn.example.com/chapters.json"),
      chaptersType: "application/json+chapters"
    )
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
