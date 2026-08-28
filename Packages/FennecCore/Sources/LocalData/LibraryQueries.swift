import CoreContracts
import Foundation
import GRDB

extension LocalDataStore {
  public func subscribedFeeds() async throws -> [StoredFeed] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT
            feed_key,
            canonical_url,
            title,
            author,
            description_html,
            image_url,
            etag,
            last_modified,
            subscribed,
            archived,
            last_refresh_at_ms
          FROM feeds
          WHERE subscribed = 1
          ORDER BY title COLLATE NOCASE ASC, feed_key ASC
          """
      ).map(Self.storedFeed)
    }
  }

  public func feed(for feedKey: FeedKey) async throws -> StoredFeed? {
    try await writer.read { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT
            feed_key,
            canonical_url,
            title,
            author,
            description_html,
            image_url,
            etag,
            last_modified,
            subscribed,
            archived,
            last_refresh_at_ms
          FROM feeds
          WHERE feed_key = ?
          """,
        arguments: [feedKey.rawValue]
      ).map(Self.storedFeed)
    }
  }

  public func libraryEpisodes(
    filter: EpisodeListFilter,
    sort: EpisodeListSort,
    feedKey: FeedKey? = nil,
    limit: Int = 500
  ) async throws -> [StoredEpisode] {
    guard (1...1_000).contains(limit) else {
      throw LocalDataError.invalidQueryLimit
    }
    let filterSQL = Self.filterSQL(filter)
    let sortSQL = Self.sortSQL(sort)

    return try await writer.read { db in
      let feedCondition = feedKey == nil ? "" : " AND e.feed_key = ?"
      let sql = """
        SELECT
          e.episode_key,
          e.feed_key,
          e.guid,
          e.enclosure_url,
          e.link_url,
          e.title,
          e.publication_date_ms,
          e.duration_ms,
          e.description_html,
          e.mime_type,
          f.title AS feed_title,
          COALESCE(s.inbox, 0) AS inbox,
          COALESCE(s.favorite, 0) AS favorite,
          COALESCE(s.archived, 0) AS archived,
          COALESCE(s.played, 0) AS played,
          COALESCE(s.position_ms, 0) AS position_ms,
          COALESCE(s.played_duration_ms, 0) AS played_duration_ms
        FROM episodes e
        JOIN feeds f ON f.feed_key = e.feed_key
        LEFT JOIN episode_state s ON s.episode_key = e.episode_key
        WHERE \(filterSQL)\(feedCondition)
        ORDER BY \(sortSQL)
        LIMIT ?
        """
      let rows: [Row]
      if let feedKey {
        rows = try Row.fetchAll(db, sql: sql, arguments: [feedKey.rawValue, limit])
      } else {
        rows = try Row.fetchAll(db, sql: sql, arguments: [limit])
      }
      return try rows.map(Self.storedEpisode)
    }
  }

  public func setInbox(_ isInbox: Bool, for episodeKey: EpisodeKey) async throws {
    try await updateLocalEpisodeFlag("inbox", value: isInbox, episodeKey: episodeKey)
  }

  public func setFavorite(_ isFavorite: Bool, for episodeKey: EpisodeKey) async throws {
    try await updateLocalEpisodeFlag("favorite", value: isFavorite, episodeKey: episodeKey)
  }

  public func setEpisodeArchived(
    _ isArchived: Bool,
    for episodeKey: EpisodeKey
  ) async throws {
    try await updateLocalEpisodeFlag("archived", value: isArchived, episodeKey: episodeKey)
  }

  private func updateLocalEpisodeFlag(
    _ column: String,
    value: Bool,
    episodeKey: EpisodeKey
  ) async throws {
    try await writer.write { db in
      let episodeExists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM episodes WHERE episode_key = ?)",
          arguments: [episodeKey.rawValue]
        ) ?? false
      guard episodeExists else {
        throw LocalDataError.episodeNotFound
      }
      try db.execute(
        sql: "INSERT INTO episode_state(episode_key) VALUES (?) ON CONFLICT DO NOTHING",
        arguments: [episodeKey.rawValue]
      )
      switch column {
      case "inbox":
        try db.execute(
          sql: "UPDATE episode_state SET inbox = ? WHERE episode_key = ?",
          arguments: [value, episodeKey.rawValue]
        )
      case "favorite":
        try db.execute(
          sql: "UPDATE episode_state SET favorite = ? WHERE episode_key = ?",
          arguments: [value, episodeKey.rawValue]
        )
      case "archived":
        try db.execute(
          sql: "UPDATE episode_state SET archived = ? WHERE episode_key = ?",
          arguments: [value, episodeKey.rawValue]
        )
      default:
        throw LocalDataError.corruptRecord("unsupported local episode flag")
      }
    }
  }

  private static func storedFeed(_ row: Row) throws -> StoredFeed {
    let feedKey = FeedKey(rawValue: row["feed_key"])
    let canonicalURL = try requiredURL(row["canonical_url"], field: "feed canonical url")
    return StoredFeed(
      metadata: FeedMetadata(
        feedKey: feedKey,
        canonicalURL: canonicalURL,
        title: row["title"],
        author: row["author"],
        summaryHTML: row["description_html"],
        imageURL: try optionalURL(row["image_url"], field: "feed image url"),
        eTag: row["etag"],
        lastModified: row["last_modified"]
      ),
      subscribed: row["subscribed"],
      archived: row["archived"],
      lastRefreshAtMilliseconds: row["last_refresh_at_ms"]
    )
  }

  private static func storedEpisode(_ row: Row) throws -> StoredEpisode {
    StoredEpisode(
      metadata: EpisodeMetadata(
        episodeKey: EpisodeKey(rawValue: row["episode_key"]),
        feedKey: FeedKey(rawValue: row["feed_key"]),
        guid: row["guid"],
        enclosureURL: try optionalURL(row["enclosure_url"], field: "episode enclosure url"),
        linkURL: try optionalURL(row["link_url"], field: "episode link url"),
        title: row["title"],
        publicationDateMilliseconds: row["publication_date_ms"],
        durationMilliseconds: row["duration_ms"],
        summaryHTML: row["description_html"],
        mimeType: row["mime_type"]
      ),
      feedTitle: row["feed_title"],
      inbox: row["inbox"],
      favorite: row["favorite"],
      archived: row["archived"],
      played: row["played"],
      positionMilliseconds: row["position_ms"],
      playedDurationMilliseconds: row["played_duration_ms"]
    )
  }

  private static func requiredURL(_ value: String, field: String) throws -> URL {
    guard let url = URL(string: value) else {
      throw LocalDataError.corruptRecord("invalid \(field)")
    }
    return url
  }

  private static func optionalURL(_ value: String?, field: String) throws -> URL? {
    guard let value else { return nil }
    return try requiredURL(value, field: field)
  }

  private static func filterSQL(_ filter: EpisodeListFilter) -> String {
    switch filter {
    case .all:
      "1 = 1"
    case .inbox:
      "COALESCE(s.inbox, 0) = 1"
    case .favorites:
      "COALESCE(s.favorite, 0) = 1"
    case .unplayed:
      "COALESCE(s.played, 0) = 0"
    case .archived:
      "COALESCE(s.archived, 0) = 1"
    }
  }

  private static func sortSQL(_ sort: EpisodeListSort) -> String {
    switch sort {
    case .newestFirst:
      "e.publication_date_ms IS NULL ASC, e.publication_date_ms DESC, e.episode_key ASC"
    case .oldestFirst:
      "e.publication_date_ms IS NULL ASC, e.publication_date_ms ASC, e.episode_key ASC"
    }
  }
}
