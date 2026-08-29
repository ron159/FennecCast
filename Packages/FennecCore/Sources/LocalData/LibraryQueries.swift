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
    try await libraryEpisodes(
      criteria: Self.criteria(for: filter),
      sort: sort,
      feedKey: feedKey,
      limit: limit
    )
  }

  public func libraryEpisodes(
    criteria: EpisodeListCriteria,
    sort: EpisodeListSort,
    feedKey: FeedKey? = nil,
    limit: Int = 500
  ) async throws -> [StoredEpisode] {
    guard (1...1_000).contains(limit) else {
      throw LocalDataError.invalidQueryLimit
    }
    let filterSQL = Self.filterSQL(criteria)
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
          e.transcript_url,
          e.transcript_type,
          e.chapters_url,
          e.chapters_type,
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

  public func libraryEpisode(for episodeKey: EpisodeKey) async throws -> StoredEpisode? {
    try await writer.read { db in
      try Row.fetchOne(
        db,
        sql: """
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
            e.transcript_url,
            e.transcript_type,
            e.chapters_url,
            e.chapters_type,
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
          WHERE e.episode_key = ?
          """,
        arguments: [episodeKey.rawValue]
      ).map(Self.storedEpisode)
    }
  }

  public func libraryContainsEpisodes(_ episodeKeys: [EpisodeKey]) async throws -> Bool {
    let uniqueKeys = Array(Set(episodeKeys)).sorted { $0.rawValue < $1.rawValue }
    guard !uniqueKeys.isEmpty else { return true }
    return try await writer.read { db in
      for start in stride(from: 0, to: uniqueKeys.count, by: 500) {
        let end = min(start + 500, uniqueKeys.count)
        let keys = uniqueKeys[start..<end]
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let count =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM episodes WHERE episode_key IN (\(placeholders))",
            arguments: StatementArguments(keys.map(\.rawValue))
          ) ?? 0
        guard count == keys.count else { return false }
      }
      return true
    }
  }

  public func setInbox(_ isInbox: Bool, for episodeKey: EpisodeKey) async throws {
    try await setInbox(isInbox, for: [episodeKey])
  }

  public func setInbox(_ isInbox: Bool, for episodeKeys: [EpisodeKey]) async throws {
    try await updateLocalEpisodeFlag("inbox", value: isInbox, episodeKeys: episodeKeys)
  }

  public func setFavorite(_ isFavorite: Bool, for episodeKey: EpisodeKey) async throws {
    try await setFavorite(isFavorite, for: [episodeKey])
  }

  public func setFavorite(_ isFavorite: Bool, for episodeKeys: [EpisodeKey]) async throws {
    try await updateLocalEpisodeFlag("favorite", value: isFavorite, episodeKeys: episodeKeys)
  }

  public func setEpisodeArchived(
    _ isArchived: Bool,
    for episodeKey: EpisodeKey
  ) async throws {
    try await setEpisodeArchived(isArchived, for: [episodeKey])
  }

  public func setEpisodeArchived(
    _ isArchived: Bool,
    for episodeKeys: [EpisodeKey]
  ) async throws {
    try await updateLocalEpisodeFlag("archived", value: isArchived, episodeKeys: episodeKeys)
  }

  private func updateLocalEpisodeFlag(
    _ column: String,
    value: Bool,
    episodeKeys: [EpisodeKey]
  ) async throws {
    let uniqueKeys = Array(Set(episodeKeys)).sorted { $0.rawValue < $1.rawValue }
    guard !uniqueKeys.isEmpty else { return }
    try await writer.write { db in
      let placeholders = Array(repeating: "?", count: uniqueKeys.count).joined(separator: ", ")
      let arguments = StatementArguments(uniqueKeys.map(\.rawValue))
      let existingCount =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM episodes WHERE episode_key IN (\(placeholders))",
          arguments: arguments
        ) ?? 0
      guard existingCount == uniqueKeys.count else {
        throw LocalDataError.episodeNotFound
      }
      for episodeKey in uniqueKeys {
        try db.execute(
          sql: "INSERT INTO episode_state(episode_key) VALUES (?) ON CONFLICT DO NOTHING",
          arguments: [episodeKey.rawValue]
        )
      }
      switch column {
      case "inbox":
        try db.execute(
          sql: "UPDATE episode_state SET inbox = ? WHERE episode_key IN (\(placeholders))",
          arguments: StatementArguments([value] + uniqueKeys.map(\.rawValue))
        )
      case "favorite":
        try db.execute(
          sql: "UPDATE episode_state SET favorite = ? WHERE episode_key IN (\(placeholders))",
          arguments: StatementArguments([value] + uniqueKeys.map(\.rawValue))
        )
      case "archived":
        try db.execute(
          sql: "UPDATE episode_state SET archived = ? WHERE episode_key IN (\(placeholders))",
          arguments: StatementArguments([value] + uniqueKeys.map(\.rawValue))
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

  static func storedEpisode(_ row: Row) throws -> StoredEpisode {
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
        mimeType: row["mime_type"],
        transcriptURL: try optionalURL(row["transcript_url"], field: "episode transcript url"),
        transcriptType: row["transcript_type"],
        chaptersURL: try optionalURL(row["chapters_url"], field: "episode chapters url"),
        chaptersType: row["chapters_type"]
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

  private static func criteria(for filter: EpisodeListFilter) -> EpisodeListCriteria {
    switch filter {
    case .all:
      .all
    case .inbox:
      EpisodeListCriteria(inbox: true)
    case .favorites:
      EpisodeListCriteria(favorite: true)
    case .unplayed:
      EpisodeListCriteria(playback: .unplayed)
    case .archived:
      EpisodeListCriteria(archived: true)
    }
  }

  private static func filterSQL(_ criteria: EpisodeListCriteria) -> String {
    var conditions = ["1 = 1"]
    if let inbox = criteria.inbox {
      conditions.append("COALESCE(s.inbox, 0) = \(inbox ? 1 : 0)")
    }
    if let favorite = criteria.favorite {
      conditions.append("COALESCE(s.favorite, 0) = \(favorite ? 1 : 0)")
    }
    if let archived = criteria.archived {
      conditions.append("COALESCE(s.archived, 0) = \(archived ? 1 : 0)")
    }
    switch criteria.playback {
    case .any:
      break
    case .played:
      conditions.append("COALESCE(s.played, 0) = 1")
    case .unplayed:
      conditions.append("COALESCE(s.played, 0) = 0")
    case .inProgress:
      conditions.append("COALESCE(s.played, 0) = 0 AND COALESCE(s.position_ms, 0) > 0")
    case .notInProgress:
      conditions.append("COALESCE(s.position_ms, 0) = 0")
    }
    switch criteria.queue {
    case .any:
      break
    case .queued:
      conditions.append(
        "EXISTS (SELECT 1 FROM queue_entries q WHERE q.episode_key = e.episode_key AND q.present = 1)"
      )
    case .notQueued:
      conditions.append(
        "NOT EXISTS (SELECT 1 FROM queue_entries q WHERE q.episode_key = e.episode_key AND q.present = 1)"
      )
    }
    switch criteria.download {
    case .any:
      break
    case .downloaded:
      conditions.append(
        "EXISTS (SELECT 1 FROM media_local m WHERE m.episode_key = e.episode_key AND m.download_state = 'completed')"
      )
    case .notDownloaded:
      conditions.append(
        "NOT EXISTS (SELECT 1 FROM media_local m WHERE m.episode_key = e.episode_key AND m.download_state = 'completed')"
      )
    }
    switch criteria.media {
    case .any:
      break
    case .hasMedia:
      conditions.append("e.enclosure_url IS NOT NULL")
    case .noMedia:
      conditions.append("e.enclosure_url IS NULL")
    }
    return conditions.joined(separator: " AND ")
  }

  private static func sortSQL(_ sort: EpisodeListSort) -> String {
    switch sort {
    case .newestFirst:
      "e.publication_date_ms IS NULL ASC, e.publication_date_ms DESC, e.episode_key ASC"
    case .oldestFirst:
      "e.publication_date_ms IS NULL ASC, e.publication_date_ms ASC, e.episode_key ASC"
    case .episodeTitleAscending:
      "e.title COLLATE NOCASE ASC, e.episode_key ASC"
    case .episodeTitleDescending:
      "e.title COLLATE NOCASE DESC, e.episode_key ASC"
    case .podcastTitleAscending:
      "f.title COLLATE NOCASE ASC, e.publication_date_ms IS NULL ASC, e.publication_date_ms ASC, e.episode_key ASC"
    case .podcastTitleDescending:
      "f.title COLLATE NOCASE DESC, e.publication_date_ms IS NULL ASC, e.publication_date_ms ASC, e.episode_key ASC"
    case .durationShortestFirst:
      "e.duration_ms IS NULL ASC, e.duration_ms ASC, e.episode_key ASC"
    case .durationLongestFirst:
      "e.duration_ms IS NULL ASC, e.duration_ms DESC, e.episode_key ASC"
    }
  }
}
