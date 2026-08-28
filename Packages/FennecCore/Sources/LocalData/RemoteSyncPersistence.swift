import CoreContracts
import Foundation
import GRDB

extension LocalDataStore {
  public func pendingMutations(limit: Int = 500) async throws -> [SyncMutation] {
    guard (1...500).contains(limit) else {
      throw LocalDataError.invalidBatchLimit
    }
    let deviceID = self.deviceID

    return try await writer.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT local_seq, entity_type, entity_key, envelope_json
          FROM sync_outbox
          WHERE device_id = ?
          ORDER BY local_seq ASC
          LIMIT ?
          """,
        arguments: [deviceID.rawValue, limit]
      )
      return try rows.map { row in
        let data: Data = row["envelope_json"]
        let mutation = try JSONDecoder().decode(SyncMutation.self, from: data)
        let localSequence: Int64 = row["local_seq"]
        let entityType: String = row["entity_type"]
        let entityKey: String = row["entity_key"]
        guard
          mutation.localSequence == localSequence,
          mutation.entityType.rawValue == entityType,
          mutation.entityKey == entityKey
        else {
          throw LocalDataError.corruptRecord("outbox envelope metadata mismatch")
        }
        return mutation
      }
    }
  }

  public func applySyncResponse(_ response: SyncResponse) async throws {
    try Self.validateChangeOrdering(response.changes)
    let deviceID = self.deviceID

    // One transaction covers remote merges, cursor advancement, and Outbox acknowledgement.
    // Source: https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/DatabaseWriter.swift
    try await writer.write { db in
      let cursor = try Self.fetchCursor(db)
      guard response.nextCursor >= cursor.serverSequence else {
        throw LocalDataError.cursorRegression(
          current: cursor.serverSequence,
          proposed: response.nextCursor
        )
      }
      guard response.acceptedLocalSequence <= cursor.lastLocalSequence else {
        throw LocalDataError.invalidAcknowledgement
      }

      for change in response.changes {
        guard change.serverSequence > cursor.serverSequence else {
          throw LocalDataError.staleServerChange(
            sequence: change.serverSequence,
            currentCursor: cursor.serverSequence
          )
        }
        guard change.serverSequence <= response.nextCursor else {
          throw LocalDataError.serverChangeOutsideCursor(
            sequence: change.serverSequence,
            nextCursor: response.nextCursor
          )
        }
        try Self.apply(change, db: db)
      }
      if let maximumRemoteClock = response.changes.map(\.hlc).max() {
        try Self.persistSyncClock(maximumRemoteClock, db: db)
      }

      try db.execute(
        sql: "UPDATE sync_cursor SET server_seq = ? WHERE singleton_id = 1",
        arguments: [response.nextCursor]
      )
      try db.execute(
        sql: "DELETE FROM sync_outbox WHERE device_id = ? AND local_seq <= ?",
        arguments: [deviceID.rawValue, response.acceptedLocalSequence]
      )
    }
  }

  private static func validateChangeOrdering(_ changes: [SyncChange]) throws {
    var previous: Int64?
    for change in changes {
      if let previous, change.serverSequence <= previous {
        throw LocalDataError.unorderedServerChanges
      }
      previous = change.serverSequence
    }
  }

  private static func apply(_ change: SyncChange, db: Database) throws {
    let version = VersionStamp(timestamp: change.hlc, deviceID: change.deviceID)

    switch change.payload {
    case .subscription(let state):
      let incoming = VersionedState(value: state, version: version)
      let resolved: VersionedState<SubscriptionState>
      if let current = try fetchSubscriptionState(db, feedKey: state.feedKey) {
        resolved = try ConflictResolver.resolveSubscription(
          current: current,
          incoming: incoming
        )
      } else {
        resolved = incoming
      }
      if resolved == incoming {
        try persist(
          .subscription(resolved.value),
          version: resolved.version,
          updatedAtMilliseconds: resolved.version.timestamp.wallMilliseconds,
          db: db
        )
      }

    case .episodePlayback(let state):
      let incoming = VersionedState(value: state, version: version)
      let resolved: VersionedState<EpisodePlayback>
      if let current = try fetchPlaybackState(db, episodeKey: state.episodeKey) {
        resolved = try ConflictResolver.resolvePlayback(current: current, incoming: incoming)
      } else {
        resolved = incoming
      }
      if resolved == incoming {
        try persist(
          .episodePlayback(resolved.value),
          version: resolved.version,
          updatedAtMilliseconds: resolved.version.timestamp.wallMilliseconds,
          db: db
        )
      }

    case .queueEntry(let state):
      let incoming = VersionedState(value: state, version: version)
      let resolved: VersionedState<QueueEntryState>
      if let current = try fetchQueueState(db, episodeKey: state.episodeKey) {
        resolved = try ConflictResolver.resolveQueueEntry(current: current, incoming: incoming)
      } else {
        resolved = incoming
      }
      if resolved == incoming {
        try persist(
          .queueEntry(resolved.value),
          version: resolved.version,
          updatedAtMilliseconds: resolved.version.timestamp.wallMilliseconds,
          db: db
        )
      }
    }
  }
}
