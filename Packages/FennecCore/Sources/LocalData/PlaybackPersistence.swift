import CoreContracts
import Foundation
import GRDB

extension LocalDataStore {
  public func recordPlaybackMutation(
    episodeKey: EpisodeKey,
    intent: PlaybackIntent,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64?,
    played: Bool,
    hlc: HLCTimestamp,
    createdAtMilliseconds: Int64
  ) async throws -> SyncMutation {
    let deviceID = self.deviceID
    return try await writer.write { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT e.guid, f.canonical_url
            FROM episodes e
            JOIN feeds f ON f.feed_key = e.feed_key
            WHERE e.episode_key = ?
            """,
          arguments: [episodeKey.rawValue]
        )
      else {
        throw LocalDataError.episodeNotFound
      }
      let feedURLValue: String = row["canonical_url"]
      guard let feedURL = URL(string: feedURLValue) else {
        throw LocalDataError.corruptRecord("invalid playback feed url")
      }
      let playback = try EpisodePlayback(
        episodeKey: episodeKey,
        intent: intent,
        positionMilliseconds: positionMilliseconds,
        durationMilliseconds: durationMilliseconds,
        played: played,
        feedURL: feedURL,
        guid: row["guid"]
      )
      let previousPosition =
        try Int64.fetchOne(
          db,
          sql: "SELECT position_ms FROM episode_state WHERE episode_key = ?",
          arguments: [episodeKey.rawValue]
        ) ?? 0
      let listenedDelta: Int64
      switch intent {
      case .checkpoint, .playbackPause:
        listenedDelta = min(300_000, max(0, positionMilliseconds - previousPosition))
      case .seek, .markPlayed, .markUnplayed:
        listenedDelta = 0
      }
      let mutation = try Self.recordLocalMutation(
        .episodePlayback(playback),
        hlc: hlc,
        deviceID: deviceID,
        createdAtMilliseconds: createdAtMilliseconds,
        db: db
      )
      if listenedDelta > 0 {
        try db.execute(
          sql: """
            UPDATE episode_state
            SET played_duration_ms = played_duration_ms + ?
            WHERE episode_key = ?
            """,
          arguments: [listenedDelta, episodeKey.rawValue]
        )
      }
      return mutation
    }
  }
}
