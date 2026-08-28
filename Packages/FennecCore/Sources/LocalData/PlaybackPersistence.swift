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
      return try Self.recordLocalMutation(
        .episodePlayback(playback),
        hlc: hlc,
        deviceID: deviceID,
        createdAtMilliseconds: createdAtMilliseconds,
        db: db
      )
    }
  }
}
