import CoreContracts
import Foundation
import GRDB

extension LocalDataStore {
  public func feedPreferences(for feedKey: FeedKey) async throws -> FeedPreferences {
    try await writer.read { db in
      let feedExists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM feeds WHERE feed_key = ?)",
          arguments: [feedKey.rawValue]
        ) ?? false
      guard feedExists else { throw LocalDataError.feedNotFound }
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM feed_settings WHERE feed_key = ?",
          arguments: [feedKey.rawValue]
        )
      else {
        return .default
      }
      return try Self.decodeFeedPreferences(row)
    }
  }

  public func allFeedPreferences() async throws -> [FeedKey: FeedPreferences] {
    try await writer.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT
            f.feed_key,
            s.auto_download,
            s.auto_delete_played,
            s.download_retention_limit,
            s.playback_speed,
            s.skip_intro_ms,
            s.skip_ending_ms,
            s.tags_json
          FROM feeds f
          LEFT JOIN feed_settings s ON s.feed_key = f.feed_key
          WHERE f.subscribed = 1
          ORDER BY f.feed_key
          """
      )
      return try Dictionary(
        uniqueKeysWithValues: rows.map { row in
          let feedKey = FeedKey(rawValue: row["feed_key"])
          let hasSettings: Bool = row["auto_download"] != nil
          return (
            feedKey,
            hasSettings ? try Self.decodeFeedPreferences(row) : FeedPreferences.default
          )
        }
      )
    }
  }

  public func saveFeedPreferences(
    _ preferences: FeedPreferences,
    for feedKey: FeedKey
  ) async throws {
    let normalized = try Self.normalizedFeedPreferences(preferences)
    let tagsJSON = try JSONEncoder().encode(normalized.tags)
    try await writer.write { db in
      let feedExists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM feeds WHERE feed_key = ?)",
          arguments: [feedKey.rawValue]
        ) ?? false
      guard feedExists else { throw LocalDataError.feedNotFound }
      try db.execute(
        sql: """
          INSERT INTO feed_settings(
            feed_key,
            auto_download,
            auto_delete_played,
            download_retention_limit,
            playback_speed,
            skip_intro_ms,
            skip_ending_ms,
            tags_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(feed_key) DO UPDATE SET
            auto_download = excluded.auto_download,
            auto_delete_played = excluded.auto_delete_played,
            download_retention_limit = excluded.download_retention_limit,
            playback_speed = excluded.playback_speed,
            skip_intro_ms = excluded.skip_intro_ms,
            skip_ending_ms = excluded.skip_ending_ms,
            tags_json = excluded.tags_json
          """,
        arguments: [
          feedKey.rawValue,
          normalized.autoDownload,
          normalized.autoDeletePlayed,
          normalized.downloadRetentionLimit,
          normalized.playbackRate,
          normalized.skipIntroMilliseconds,
          normalized.skipEndingMilliseconds,
          tagsJSON,
        ]
      )
    }
  }

  public func libraryStatistics() async throws -> LibraryStatistics {
    try await writer.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT
            f.feed_key,
            f.title,
            COALESCE(SUM(s.played_duration_ms), 0) AS listening_ms,
            COUNT(DISTINCT CASE WHEN s.played = 1 THEN e.episode_key END) AS completed_count,
            COALESCE(SUM(
              CASE WHEN m.download_state = 'completed' THEN m.downloaded_bytes ELSE 0 END
            ), 0) AS downloaded_bytes
          FROM feeds f
          LEFT JOIN episodes e ON e.feed_key = f.feed_key
          LEFT JOIN episode_state s ON s.episode_key = e.episode_key
          LEFT JOIN media_local m ON m.episode_key = e.episode_key
          WHERE f.subscribed = 1
          GROUP BY f.feed_key, f.title
          ORDER BY listening_ms DESC, f.title COLLATE NOCASE, f.feed_key
          """
      )
      let feeds = rows.map { row in
        FeedStatistics(
          feedKey: FeedKey(rawValue: row["feed_key"]),
          feedTitle: row["title"],
          listeningMilliseconds: row["listening_ms"],
          completedEpisodeCount: row["completed_count"],
          downloadedBytes: row["downloaded_bytes"]
        )
      }
      return LibraryStatistics(
        listeningMilliseconds: feeds.reduce(0) { $0 + $1.listeningMilliseconds },
        completedEpisodeCount: feeds.reduce(0) { $0 + $1.completedEpisodeCount },
        downloadedBytes: feeds.reduce(0) { $0 + $1.downloadedBytes },
        feeds: feeds
      )
    }
  }

  private static func normalizedFeedPreferences(
    _ preferences: FeedPreferences
  ) throws -> FeedPreferences {
    guard
      preferences.downloadRetentionLimit.map({ (1...100).contains($0) }) ?? true,
      preferences.playbackRate.map({ $0.isFinite && (0.5...3).contains($0) }) ?? true,
      (0...21_600_000).contains(preferences.skipIntroMilliseconds),
      (0...21_600_000).contains(preferences.skipEndingMilliseconds)
    else {
      throw LocalDataError.invalidFeedPreferences
    }

    var seen = Set<String>()
    var tags: [String] = []
    for rawTag in preferences.tags {
      let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
      guard tag.count <= 40 else { throw LocalDataError.invalidFeedPreferences }
      guard !tag.isEmpty else { continue }
      if seen.insert(tag.lowercased()).inserted {
        tags.append(tag)
      }
    }
    guard tags.count <= 20 else { throw LocalDataError.invalidFeedPreferences }
    tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    return FeedPreferences(
      autoDownload: preferences.autoDownload,
      autoDeletePlayed: preferences.autoDeletePlayed,
      downloadRetentionLimit: preferences.downloadRetentionLimit,
      playbackRate: preferences.playbackRate,
      skipIntroMilliseconds: preferences.skipIntroMilliseconds,
      skipEndingMilliseconds: preferences.skipEndingMilliseconds,
      tags: tags
    )
  }

  private static func decodeFeedPreferences(_ row: Row) throws -> FeedPreferences {
    let tagsData: Data? = row["tags_json"]
    let tags: [String]
    if let tagsData {
      do {
        tags = try JSONDecoder().decode([String].self, from: tagsData)
      } catch {
        throw LocalDataError.corruptRecord("invalid feed tags")
      }
    } else {
      tags = []
    }
    let preferences = FeedPreferences(
      autoDownload: row["auto_download"],
      autoDeletePlayed: row["auto_delete_played"],
      downloadRetentionLimit: row["download_retention_limit"],
      playbackRate: row["playback_speed"],
      skipIntroMilliseconds: row["skip_intro_ms"],
      skipEndingMilliseconds: row["skip_ending_ms"],
      tags: tags
    )
    return try normalizedFeedPreferences(preferences)
  }
}
