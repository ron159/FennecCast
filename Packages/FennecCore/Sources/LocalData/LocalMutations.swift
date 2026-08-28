import CoreContracts
import Foundation
import GRDB

extension LocalDataStore {
  public func recordLocalMutation(
    _ payload: SyncPayload,
    hlc: HLCTimestamp,
    createdAtMilliseconds: Int64
  ) async throws -> SyncMutation {
    let deviceID = self.deviceID

    // `write` transaction-wraps the business update, sequence allocation, and Outbox insert.
    // Source: https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/DatabaseWriter.swift
    return try await writer.write { db in
      try Self.recordLocalMutation(
        payload,
        hlc: hlc,
        deviceID: deviceID,
        createdAtMilliseconds: createdAtMilliseconds,
        db: db
      )
    }
  }

  public func recordLocalMutations(
    _ payloads: [SyncPayload],
    hlc: HLCTimestamp,
    createdAtMilliseconds: Int64
  ) async throws -> [SyncMutation] {
    guard createdAtMilliseconds >= 0 else {
      throw LocalDataError.negativeTimestamp
    }
    let deviceID = self.deviceID

    return try await writer.write { db in
      try payloads.map { payload in
        try Self.recordLocalMutation(
          payload,
          hlc: hlc,
          deviceID: deviceID,
          createdAtMilliseconds: createdAtMilliseconds,
          db: db
        )
      }
    }
  }

  static func recordLocalMutation(
    _ payload: SyncPayload,
    hlc: HLCTimestamp,
    deviceID: DeviceID,
    createdAtMilliseconds: Int64,
    db: Database
  ) throws -> SyncMutation {
    guard createdAtMilliseconds >= 0 else {
      throw LocalDataError.negativeTimestamp
    }
    let cursor = try fetchCursor(db)
    let (localSequence, overflow) = cursor.lastLocalSequence.addingReportingOverflow(1)
    guard !overflow else {
      throw LocalDataError.localSequenceOverflow
    }
    let version = VersionStamp(timestamp: hlc, deviceID: deviceID)
    try persist(
      payload,
      version: version,
      updatedAtMilliseconds: createdAtMilliseconds,
      db: db
    )

    let mutation = try SyncMutation(
      localSequence: localSequence,
      hlc: hlc,
      entityType: payload.entityType,
      entityKey: payload.entityKey,
      payload: payload
    )
    let envelope = try JSONEncoder().encode(mutation)
    try db.execute(
      sql: """
        UPDATE sync_cursor
        SET last_local_seq = ?
        WHERE singleton_id = 1
        """,
      arguments: [localSequence]
    )
    try persistSyncClock(hlc, db: db)
    try db.execute(
      sql: """
        INSERT INTO sync_outbox(
          device_id,
          local_seq,
          hlc_wall_ms,
          hlc_counter,
          entity_type,
          entity_key,
          envelope_json,
          created_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        deviceID.rawValue,
        localSequence,
        hlc.wallMilliseconds,
        hlc.counter,
        payload.entityType.rawValue,
        payload.entityKey,
        envelope,
        createdAtMilliseconds,
      ]
    )
    return mutation
  }

  public func pendingMutationCount() async throws -> Int {
    try await writer.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM sync_outbox WHERE device_id = ?",
        arguments: [deviceID.rawValue]
      ) ?? 0
    }
  }

  public func subscriptionState(
    for feedKey: FeedKey
  ) async throws -> VersionedState<SubscriptionState>? {
    try await writer.read { db in
      try Self.fetchSubscriptionState(db, feedKey: feedKey)
    }
  }

  public func playbackState(
    for episodeKey: EpisodeKey
  ) async throws -> VersionedState<EpisodePlayback>? {
    try await writer.read { db in
      try Self.fetchPlaybackState(db, episodeKey: episodeKey)
    }
  }

  public func queueState(
    for episodeKey: EpisodeKey
  ) async throws -> VersionedState<QueueEntryState>? {
    try await writer.read { db in
      try Self.fetchQueueState(db, episodeKey: episodeKey)
    }
  }

  static func fetchSubscriptionState(
    _ db: Database,
    feedKey: FeedKey
  ) throws -> VersionedState<SubscriptionState>? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            canonical_url,
            subscribed,
            subscription_hlc_wall_ms AS hlc_wall_ms,
            subscription_hlc_counter AS hlc_counter,
            subscription_device_id AS device_id
          FROM feeds
          WHERE feed_key = ?
          """,
        arguments: [feedKey.rawValue]
      )
    else {
      return nil
    }
    let storedDeviceID: String = row["device_id"]
    guard !storedDeviceID.isEmpty else {
      return nil
    }
    let urlString: String = row["canonical_url"]
    guard let feedURL = URL(string: urlString) else {
      throw LocalDataError.corruptRecord("invalid feed url")
    }
    return VersionedState(
      value: SubscriptionState(
        feedKey: feedKey,
        feedURL: feedURL,
        subscribed: row["subscribed"]
      ),
      version: try version(from: row)
    )
  }

  static func fetchPlaybackState(
    _ db: Database,
    episodeKey: EpisodeKey
  ) throws -> VersionedState<EpisodePlayback>? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            played,
            position_ms,
            duration_ms,
            playback_intent,
            feed_url,
            guid,
            playback_hlc_wall_ms AS hlc_wall_ms,
            playback_hlc_counter AS hlc_counter,
            playback_device_id AS device_id
          FROM episode_state
          WHERE episode_key = ?
          """,
        arguments: [episodeKey.rawValue]
      )
    else {
      return nil
    }
    let storedDeviceID: String = row["device_id"]
    guard !storedDeviceID.isEmpty else {
      return nil
    }
    let intentValue: String = row["playback_intent"]
    guard let intent = PlaybackIntent(rawValue: intentValue) else {
      throw LocalDataError.corruptRecord("invalid playback intent")
    }
    let feedURLString: String? = row["feed_url"]
    let feedURL = feedURLString.flatMap(URL.init(string:))
    if feedURLString != nil, feedURL == nil {
      throw LocalDataError.corruptRecord("invalid playback feed url")
    }
    return VersionedState(
      value: try EpisodePlayback(
        episodeKey: episodeKey,
        intent: intent,
        positionMilliseconds: row["position_ms"],
        durationMilliseconds: row["duration_ms"],
        played: row["played"],
        feedURL: feedURL,
        guid: row["guid"]
      ),
      version: try version(from: row)
    )
  }

  static func fetchQueueState(
    _ db: Database,
    episodeKey: EpisodeKey
  ) throws -> VersionedState<QueueEntryState>? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            order_token,
            present,
            queue_hlc_wall_ms AS hlc_wall_ms,
            queue_hlc_counter AS hlc_counter,
            queue_device_id AS device_id
          FROM queue_entries
          WHERE episode_key = ?
          """,
        arguments: [episodeKey.rawValue]
      )
    else {
      return nil
    }
    let storedDeviceID: String = row["device_id"]
    guard !storedDeviceID.isEmpty else {
      return nil
    }
    let tokenValue: String = row["order_token"]
    return VersionedState(
      value: QueueEntryState(
        episodeKey: episodeKey,
        orderToken: try FractionalIndex(rawValue: tokenValue),
        present: row["present"]
      ),
      version: try version(from: row)
    )
  }

  static func persist(
    _ payload: SyncPayload,
    version: VersionStamp,
    updatedAtMilliseconds: Int64,
    db: Database
  ) throws {
    switch payload {
    case .subscription(let state):
      try persist(
        state,
        version: version,
        updatedAtMilliseconds: updatedAtMilliseconds,
        db: db
      )
    case .episodePlayback(let state):
      try persist(state, version: version, db: db)
    case .queueEntry(let state):
      try persist(
        state,
        version: version,
        updatedAtMilliseconds: updatedAtMilliseconds,
        db: db
      )
    }
  }

  private static func persist(
    _ state: SubscriptionState,
    version: VersionStamp,
    updatedAtMilliseconds: Int64,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO feeds(
          feed_key,
          canonical_url,
          subscribed,
          created_at_ms,
          updated_at_ms,
          subscription_hlc_wall_ms,
          subscription_hlc_counter,
          subscription_device_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(feed_key) DO UPDATE SET
          canonical_url = excluded.canonical_url,
          subscribed = excluded.subscribed,
          updated_at_ms = excluded.updated_at_ms,
          subscription_hlc_wall_ms = excluded.subscription_hlc_wall_ms,
          subscription_hlc_counter = excluded.subscription_hlc_counter,
          subscription_device_id = excluded.subscription_device_id
        """,
      arguments: [
        state.feedKey.rawValue,
        state.feedURL.absoluteString,
        state.subscribed,
        updatedAtMilliseconds,
        updatedAtMilliseconds,
        version.timestamp.wallMilliseconds,
        version.timestamp.counter,
        version.deviceID.rawValue,
      ]
    )
  }

  private static func persist(
    _ state: EpisodePlayback,
    version: VersionStamp,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO episode_state(
          episode_key,
          played,
          position_ms,
          duration_ms,
          playback_intent,
          feed_url,
          guid,
          playback_hlc_wall_ms,
          playback_hlc_counter,
          playback_device_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(episode_key) DO UPDATE SET
          played = excluded.played,
          position_ms = excluded.position_ms,
          duration_ms = excluded.duration_ms,
          playback_intent = excluded.playback_intent,
          feed_url = excluded.feed_url,
          guid = excluded.guid,
          playback_hlc_wall_ms = excluded.playback_hlc_wall_ms,
          playback_hlc_counter = excluded.playback_hlc_counter,
          playback_device_id = excluded.playback_device_id
        """,
      arguments: [
        state.episodeKey.rawValue,
        state.played,
        state.positionMilliseconds,
        state.durationMilliseconds,
        state.intent.rawValue,
        state.feedURL?.absoluteString,
        state.guid,
        version.timestamp.wallMilliseconds,
        version.timestamp.counter,
        version.deviceID.rawValue,
      ]
    )
  }

  private static func persist(
    _ state: QueueEntryState,
    version: VersionStamp,
    updatedAtMilliseconds: Int64,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO queue_entries(
          episode_key,
          order_token,
          added_at_ms,
          present,
          queue_hlc_wall_ms,
          queue_hlc_counter,
          queue_device_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(episode_key) DO UPDATE SET
          order_token = excluded.order_token,
          added_at_ms = excluded.added_at_ms,
          present = excluded.present,
          queue_hlc_wall_ms = excluded.queue_hlc_wall_ms,
          queue_hlc_counter = excluded.queue_hlc_counter,
          queue_device_id = excluded.queue_device_id
        """,
      arguments: [
        state.episodeKey.rawValue,
        state.orderToken.rawValue,
        updatedAtMilliseconds,
        state.present,
        version.timestamp.wallMilliseconds,
        version.timestamp.counter,
        version.deviceID.rawValue,
      ]
    )
  }

  static func version(from row: Row) throws -> VersionStamp {
    let deviceValue: String = row["device_id"]
    guard let deviceID = DeviceID(rawValue: deviceValue) else {
      throw LocalDataError.corruptRecord("invalid state device id")
    }
    return VersionStamp(
      timestamp: try HLCTimestamp(
        wallMilliseconds: row["hlc_wall_ms"],
        counter: row["hlc_counter"]
      ),
      deviceID: deviceID
    )
  }
}
