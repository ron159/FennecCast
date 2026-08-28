import CoreContracts
import Foundation
import GRDB

public enum LocalDataError: Error, Equatable, Sendable {
  case deviceIDMismatch(stored: DeviceID, requested: DeviceID)
  case corruptRecord(String)
  case invalidBatchLimit
  case invalidAcknowledgement
  case unorderedServerChanges
  case cursorRegression(current: Int64, proposed: Int64)
  case staleServerChange(sequence: Int64, currentCursor: Int64)
  case serverChangeOutsideCursor(sequence: Int64, nextCursor: Int64)
  case emptyAliasKey
  case aliasKindMismatch
  case aliasConflict(existing: String, requested: String)
  case aliasCycle
  case feedNotFound
  case episodeNotFound
  case invalidMetadata
  case invalidQueryLimit
  case negativeTimestamp
  case localSequenceOverflow
  case invalidDownloadTransition(from: DownloadState, to: DownloadState)
  case invalidDownloadMetadata
  case invalidLocalMediaPath
}

public struct SyncCursorState: Equatable, Sendable {
  public let serverSequence: Int64
  public let lastLocalSequence: Int64
  public let deviceID: DeviceID

  public init(serverSequence: Int64, lastLocalSequence: Int64, deviceID: DeviceID) {
    self.serverSequence = serverSequence
    self.lastLocalSequence = lastLocalSequence
    self.deviceID = deviceID
  }
}

public actor LocalDataStore {
  let writer: AnyDatabaseWriter
  let deviceID: DeviceID

  // DatabasePool enables WAL and concurrent reads for a file database.
  // Source: https://github.com/groue/GRDB.swift/blob/master/README.md#database-connections
  public init(path: String, deviceID: DeviceID) throws {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let writer = AnyDatabaseWriter(
      try DatabasePool(path: path, configuration: configuration)
    )
    _ = try Self.prepare(writer: writer, deviceID: deviceID)
    self.writer = writer
    self.deviceID = deviceID
  }

  public static func openOrCreate(path: String) throws -> LocalDataStore {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let writer = AnyDatabaseWriter(
      try DatabasePool(path: path, configuration: configuration)
    )
    let proposedDeviceID = try DeviceID("ios-\(UUID().uuidString.lowercased())")
    let deviceID = try prepare(
      writer: writer,
      deviceID: proposedDeviceID,
      reuseStoredDeviceID: true
    )
    return LocalDataStore(writer: writer, deviceID: deviceID)
  }

  public static func inMemory(deviceID: DeviceID) throws -> LocalDataStore {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let writer = AnyDatabaseWriter(try DatabaseQueue(configuration: configuration))
    _ = try prepare(writer: writer, deviceID: deviceID)
    return LocalDataStore(writer: writer, deviceID: deviceID)
  }

  public func applicationTableNames() async throws -> [String] {
    try await writer.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT name
          FROM sqlite_master
          WHERE type = 'table'
            AND name NOT LIKE 'sqlite_%'
            AND name <> 'grdb_migrations'
          ORDER BY name
          """
      )
    }
  }

  public func foreignKeysEnabled() async throws -> Bool {
    try await writer.read { db in
      try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1
    }
  }

  public func applicationIndexNames() async throws -> [String] {
    try await writer.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT name
          FROM sqlite_master
          WHERE type = 'index'
            AND name NOT LIKE 'sqlite_autoindex_%'
          ORDER BY name
          """
      )
    }
  }

  public func syncCursor() async throws -> SyncCursorState {
    try await writer.read { db in
      try Self.fetchCursor(db)
    }
  }

  public func close() throws {
    try writer.close()
  }

  private init(writer: AnyDatabaseWriter, deviceID: DeviceID) {
    self.writer = writer
    self.deviceID = deviceID
  }

  private static func prepare(
    writer: AnyDatabaseWriter,
    deviceID: DeviceID,
    reuseStoredDeviceID: Bool = false
  ) throws -> DeviceID {
    try DatabaseSchema.migrator.migrate(writer)
    // GRDB `write` wraps updates in a transaction.
    // Source: https://github.com/groue/GRDB.swift/blob/master/GRDB/Core/DatabaseWriter.swift
    return try writer.write { db in
      let storedValue = try String.fetchOne(
        db,
        sql: "SELECT device_id FROM sync_cursor WHERE singleton_id = 1"
      )
      guard let storedValue else {
        throw LocalDataError.corruptRecord("missing sync_cursor singleton")
      }
      if storedValue.isEmpty {
        try db.execute(
          sql: "UPDATE sync_cursor SET device_id = ? WHERE singleton_id = 1",
          arguments: [deviceID.rawValue]
        )
        return deviceID
      } else {
        guard let storedDeviceID = DeviceID(rawValue: storedValue) else {
          throw LocalDataError.corruptRecord("invalid stored device id")
        }
        if reuseStoredDeviceID {
          return storedDeviceID
        }
        guard storedDeviceID == deviceID else {
          throw LocalDataError.deviceIDMismatch(
            stored: storedDeviceID,
            requested: deviceID
          )
        }
        return storedDeviceID
      }
    }
  }

  static func fetchCursor(_ db: Database) throws -> SyncCursorState {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT server_seq, last_local_seq, device_id
          FROM sync_cursor
          WHERE singleton_id = 1
          """
      )
    else {
      throw LocalDataError.corruptRecord("missing sync_cursor singleton")
    }
    guard let deviceID = DeviceID(rawValue: row["device_id"]) else {
      throw LocalDataError.corruptRecord("invalid stored device id")
    }
    return SyncCursorState(
      serverSequence: row["server_seq"],
      lastLocalSequence: row["last_local_seq"],
      deviceID: deviceID
    )
  }
}
