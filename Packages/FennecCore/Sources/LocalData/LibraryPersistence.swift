import CoreContracts
import Foundation
import GRDB

extension LocalDataStore {
  public func saveInitialSubscription(
    feed: FeedMetadata,
    episodes: [EpisodeMetadata],
    markNewEpisodesInbox: Bool,
    hlc: HLCTimestamp,
    timestampMilliseconds: Int64,
    redirectedFromFeedKey: FeedKey? = nil
  ) async throws -> InitialSubscriptionResult {
    try Self.validateLibraryWrite(
      feed: feed,
      episodes: episodes,
      timestampMilliseconds: timestampMilliseconds
    )
    let deviceID = self.deviceID

    return try await writer.write { db in
      if let redirectedFromFeedKey, redirectedFromFeedKey != feed.feedKey {
        try Self.recordAlias(
          from: redirectedFromFeedKey.rawValue,
          to: feed.feedKey.rawValue,
          kind: .feed,
          updatedAtMilliseconds: timestampMilliseconds,
          db: db
        )
      }
      try Self.upsertFeed(feed, refreshedAtMilliseconds: timestampMilliseconds, db: db)
      let insertedEpisodeKeys = try Self.upsertEpisodes(
        episodes,
        markNewEpisodesInbox: markNewEpisodesInbox,
        refreshedAtMilliseconds: timestampMilliseconds,
        db: db
      )
      let mutation = try Self.recordLocalMutation(
        .subscription(
          SubscriptionState(
            feedKey: feed.feedKey,
            feedURL: feed.canonicalURL,
            subscribed: true
          )
        ),
        hlc: hlc,
        deviceID: deviceID,
        createdAtMilliseconds: timestampMilliseconds,
        db: db
      )
      return InitialSubscriptionResult(
        insertedEpisodeKeys: insertedEpisodeKeys,
        subscriptionMutation: mutation
      )
    }
  }

  public func saveFeedRefresh(
    feed: FeedMetadata,
    episodes: [EpisodeMetadata],
    markNewEpisodesInbox: Bool,
    refreshedAtMilliseconds: Int64
  ) async throws -> FeedRefreshResult {
    try Self.validateLibraryWrite(
      feed: feed,
      episodes: episodes,
      timestampMilliseconds: refreshedAtMilliseconds
    )

    return try await writer.write { db in
      let exists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM feeds WHERE feed_key = ?)",
          arguments: [feed.feedKey.rawValue]
        ) ?? false
      guard exists else {
        throw LocalDataError.feedNotFound
      }
      try Self.upsertFeed(feed, refreshedAtMilliseconds: refreshedAtMilliseconds, db: db)
      return FeedRefreshResult(
        insertedEpisodeKeys: try Self.upsertEpisodes(
          episodes,
          markNewEpisodesInbox: markNewEpisodesInbox,
          refreshedAtMilliseconds: refreshedAtMilliseconds,
          db: db
        )
      )
    }
  }

  private static func validateLibraryWrite(
    feed: FeedMetadata,
    episodes: [EpisodeMetadata],
    timestampMilliseconds: Int64
  ) throws {
    guard timestampMilliseconds >= 0 else {
      throw LocalDataError.negativeTimestamp
    }
    guard
      !feed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      try FeedKey(canonicalURL: feed.canonicalURL) == feed.feedKey,
      isNetworkURL(feed.canonicalURL),
      feed.imageURL.map(isNetworkURL) ?? true
    else {
      throw LocalDataError.invalidMetadata
    }

    var seenEpisodeKeys = Set<EpisodeKey>()
    for episode in episodes {
      guard
        episode.feedKey == feed.feedKey,
        seenEpisodeKeys.insert(episode.episodeKey).inserted,
        !episode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        episode.durationMilliseconds.map({ $0 >= 0 }) ?? true,
        episode.enclosureURL.map(isNetworkURL) ?? true,
        episode.linkURL.map(isNetworkURL) ?? true,
        episode.transcriptURL.map(isNetworkURL) ?? true,
        episode.chaptersURL.map(isNetworkURL) ?? true
      else {
        throw LocalDataError.invalidMetadata
      }
      let publicationDate = episode.publicationDateMilliseconds.map {
        Date(timeIntervalSince1970: Double($0) / 1_000)
      }
      let expectedKey = try EpisodeKey(
        input: EpisodeIdentityInput(
          feedKey: episode.feedKey,
          guid: episode.guid,
          enclosureURL: episode.enclosureURL,
          linkURL: episode.linkURL,
          publicationDate: publicationDate,
          title: episode.title,
          durationMilliseconds: episode.durationMilliseconds
        )
      )
      guard expectedKey == episode.episodeKey else {
        throw LocalDataError.invalidMetadata
      }
    }
  }

  private static func isNetworkURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }

  private static func upsertFeed(
    _ feed: FeedMetadata,
    refreshedAtMilliseconds: Int64,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO feeds(
          feed_key,
          canonical_url,
          title,
          author,
          description_html,
          image_url,
          subscribed,
          etag,
          last_modified,
          last_refresh_at_ms,
          created_at_ms,
          updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
        ON CONFLICT(feed_key) DO UPDATE SET
          canonical_url = excluded.canonical_url,
          title = excluded.title,
          author = excluded.author,
          description_html = excluded.description_html,
          image_url = excluded.image_url,
          etag = excluded.etag,
          last_modified = excluded.last_modified,
          last_refresh_at_ms = excluded.last_refresh_at_ms,
          updated_at_ms = excluded.updated_at_ms
        """,
      arguments: [
        feed.feedKey.rawValue,
        feed.canonicalURL.absoluteString,
        feed.title,
        feed.author,
        feed.summaryHTML,
        feed.imageURL?.absoluteString,
        feed.eTag,
        feed.lastModified,
        refreshedAtMilliseconds,
        refreshedAtMilliseconds,
        refreshedAtMilliseconds,
      ]
    )
  }

  private static func upsertEpisodes(
    _ episodes: [EpisodeMetadata],
    markNewEpisodesInbox: Bool,
    refreshedAtMilliseconds: Int64,
    db: Database
  ) throws -> [EpisodeKey] {
    var insertedEpisodeKeys: [EpisodeKey] = []
    for episode in episodes {
      let existingFeedKey = try String.fetchOne(
        db,
        sql: "SELECT feed_key FROM episodes WHERE episode_key = ?",
        arguments: [episode.episodeKey.rawValue]
      )
      if let existingFeedKey {
        guard existingFeedKey == episode.feedKey.rawValue else {
          throw LocalDataError.invalidMetadata
        }
        try updateEpisode(
          episode,
          refreshedAtMilliseconds: refreshedAtMilliseconds,
          db: db
        )
      } else {
        try insertEpisode(
          episode,
          discoveredAtMilliseconds: refreshedAtMilliseconds,
          db: db
        )
        try db.execute(
          sql: """
            INSERT INTO episode_state(episode_key, inbox)
            VALUES (?, ?)
            ON CONFLICT(episode_key) DO UPDATE SET
              inbox = CASE WHEN excluded.inbox = 1 THEN 1 ELSE inbox END
            """,
          arguments: [episode.episodeKey.rawValue, markNewEpisodesInbox]
        )
        insertedEpisodeKeys.append(episode.episodeKey)
      }
    }
    return insertedEpisodeKeys
  }

  private static func insertEpisode(
    _ episode: EpisodeMetadata,
    discoveredAtMilliseconds: Int64,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO episodes(
          episode_key,
          feed_key,
          guid,
          enclosure_url,
          link_url,
          title,
          publication_date_ms,
          duration_ms,
          description_html,
          mime_type,
          transcript_url,
          transcript_type,
          chapters_url,
          chapters_type,
          discovered_at_ms,
          updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        episode.episodeKey.rawValue,
        episode.feedKey.rawValue,
        episode.guid,
        episode.enclosureURL?.absoluteString,
        episode.linkURL?.absoluteString,
        episode.title,
        episode.publicationDateMilliseconds,
        episode.durationMilliseconds,
        episode.summaryHTML,
        episode.mimeType,
        episode.transcriptURL?.absoluteString,
        episode.transcriptType,
        episode.chaptersURL?.absoluteString,
        episode.chaptersType,
        discoveredAtMilliseconds,
        discoveredAtMilliseconds,
      ]
    )
  }

  private static func updateEpisode(
    _ episode: EpisodeMetadata,
    refreshedAtMilliseconds: Int64,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        UPDATE episodes SET
          guid = ?,
          enclosure_url = ?,
          link_url = ?,
          title = ?,
          publication_date_ms = ?,
          duration_ms = ?,
          description_html = ?,
          mime_type = ?,
          transcript_url = ?,
          transcript_type = ?,
          chapters_url = ?,
          chapters_type = ?,
          updated_at_ms = ?
        WHERE episode_key = ?
        """,
      arguments: [
        episode.guid,
        episode.enclosureURL?.absoluteString,
        episode.linkURL?.absoluteString,
        episode.title,
        episode.publicationDateMilliseconds,
        episode.durationMilliseconds,
        episode.summaryHTML,
        episode.mimeType,
        episode.transcriptURL?.absoluteString,
        episode.transcriptType,
        episode.chaptersURL?.absoluteString,
        episode.chaptersType,
        refreshedAtMilliseconds,
        episode.episodeKey.rawValue,
      ]
    )
  }

}
