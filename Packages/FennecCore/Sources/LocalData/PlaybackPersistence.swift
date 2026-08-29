import CoreContracts
import Foundation
import GRDB

public struct PlaybackMutationInput: Equatable, Sendable {
  public let episodeKey: EpisodeKey
  public let intent: PlaybackIntent
  public let positionMilliseconds: Int64
  public let durationMilliseconds: Int64?
  public let played: Bool

  public init(
    episodeKey: EpisodeKey,
    intent: PlaybackIntent,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64?,
    played: Bool
  ) {
    self.episodeKey = episodeKey
    self.intent = intent
    self.positionMilliseconds = positionMilliseconds
    self.durationMilliseconds = durationMilliseconds
    self.played = played
  }
}

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
    let mutations = try await recordPlaybackMutations(
      [
        PlaybackMutationInput(
          episodeKey: episodeKey,
          intent: intent,
          positionMilliseconds: positionMilliseconds,
          durationMilliseconds: durationMilliseconds,
          played: played
        )
      ],
      hlc: hlc,
      createdAtMilliseconds: createdAtMilliseconds
    )
    return mutations[0]
  }

  public func recordPlaybackMutations(
    _ inputs: [PlaybackMutationInput],
    hlc: HLCTimestamp,
    createdAtMilliseconds: Int64
  ) async throws -> [SyncMutation] {
    guard !inputs.isEmpty else { return [] }
    let deviceID = self.deviceID
    return try await writer.write { db in
      try inputs.map { input in
        try Self.recordPlaybackMutation(
          input,
          hlc: hlc,
          createdAtMilliseconds: createdAtMilliseconds,
          deviceID: deviceID,
          db: db
        )
      }
    }
  }

  private static func recordPlaybackMutation(
    _ input: PlaybackMutationInput,
    hlc: HLCTimestamp,
    createdAtMilliseconds: Int64,
    deviceID: DeviceID,
    db: Database
  ) throws -> SyncMutation {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT e.guid, f.canonical_url
          FROM episodes e
          JOIN feeds f ON f.feed_key = e.feed_key
          WHERE e.episode_key = ?
          """,
        arguments: [input.episodeKey.rawValue]
      )
    else {
      throw LocalDataError.episodeNotFound
    }
    let feedURLValue: String = row["canonical_url"]
    guard let feedURL = URL(string: feedURLValue) else {
      throw LocalDataError.corruptRecord("invalid playback feed url")
    }
    let playback = try EpisodePlayback(
      episodeKey: input.episodeKey,
      intent: input.intent,
      positionMilliseconds: input.positionMilliseconds,
      durationMilliseconds: input.durationMilliseconds,
      played: input.played,
      feedURL: feedURL,
      guid: row["guid"]
    )
    let previousPosition =
      try Int64.fetchOne(
        db,
        sql: "SELECT position_ms FROM episode_state WHERE episode_key = ?",
        arguments: [input.episodeKey.rawValue]
      ) ?? 0
    let listenedDelta: Int64
    switch input.intent {
    case .checkpoint, .playbackPause:
      listenedDelta = min(300_000, max(0, input.positionMilliseconds - previousPosition))
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
        arguments: [listenedDelta, input.episodeKey.rawValue]
      )
    }
    return mutation
  }
}
