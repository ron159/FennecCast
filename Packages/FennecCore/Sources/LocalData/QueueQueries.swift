import CoreContracts
import GRDB

extension LocalDataStore {
  public func currentQueue() async throws -> [StoredQueueItem] {
    try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT
            q.episode_key AS queue_episode_key,
            q.order_token,
            q.queue_hlc_wall_ms AS hlc_wall_ms,
            q.queue_hlc_counter AS hlc_counter,
            q.queue_device_id AS device_id,
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
          FROM queue_entries q
          LEFT JOIN episodes e ON e.episode_key = q.episode_key
          LEFT JOIN feeds f ON f.feed_key = e.feed_key
          LEFT JOIN episode_state s ON s.episode_key = e.episode_key
          WHERE q.present = 1
          ORDER BY q.order_token ASC, q.episode_key ASC
          """
      ).map { row in
        let episodeKey = EpisodeKey(rawValue: row["queue_episode_key"])
        let tokenValue: String = row["order_token"]
        let storedEpisodeKey: String? = row["episode_key"]
        let episode = try storedEpisodeKey == nil ? nil : Self.storedEpisode(row)
        return StoredQueueItem(
          state: VersionedState(
            value: QueueEntryState(
              episodeKey: episodeKey,
              orderToken: try FractionalIndex(rawValue: tokenValue),
              present: true
            ),
            version: try Self.version(from: row)
          ),
          episode: episode
        )
      }
    }
  }
}
