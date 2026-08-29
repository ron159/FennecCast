import Foundation
import GRDB

public enum DatabaseRestoreError: Error, Equatable, Sendable {
  case invalidSource
  case backupTooLarge
  case corruptBackup
  case schemaMismatch
  case foreignDevice
  case stagingFailed
}

public struct DatabaseRestoreCoordinator: Sendable {
  public static let defaultMaximumBytes = 256 * 1_024 * 1_024

  private static let expectedTables: Set<String> = [
    "episode_state",
    "episodes",
    "feed_settings",
    "feeds",
    "media_local",
    "queue_entries",
    "sync_aliases",
    "sync_cursor",
    "sync_outbox",
  ]
  private static let expectedIndexes: Set<String> = [
    "episode_state_archived",
    "episode_state_favorite",
    "episode_state_inbox",
    "episode_state_played",
    "episodes_feed_date",
    "episodes_publication_date",
    "feed_settings_auto_download",
    "feeds_subscription_title",
    "media_local_state",
    "queue_present_order",
  ]
  private static let expectedMigrations: Set<String> = [
    "v1.initial",
    "v2.libraryIndexes",
    "v3.downloadRecovery",
    "v4.syncClock",
    "v5.episodeSupplementalContent",
    "v6.advancedFeedPreferences",
  ]

  private let maximumBytes: Int

  public init(maximumBytes: Int = Self.defaultMaximumBytes) {
    self.maximumBytes = max(1, maximumBytes)
  }

  public func stageBackup(
    at sourceURL: URL,
    liveDatabaseURL: URL,
    stagingURL: URL
  ) throws {
    let sourceURL = sourceURL.standardizedFileURL
    let liveDatabaseURL = liveDatabaseURL.standardizedFileURL
    let stagingURL = stagingURL.standardizedFileURL
    let fileManager = FileManager.default
    guard
      sourceURL.isFileURL,
      liveDatabaseURL.isFileURL,
      stagingURL.isFileURL,
      sourceURL != liveDatabaseURL,
      sourceURL != stagingURL,
      liveDatabaseURL != stagingURL
    else {
      throw DatabaseRestoreError.invalidSource
    }
    try validateRegularFile(at: sourceURL)
    let expectedDeviceID = try readDeviceID(at: liveDatabaseURL)

    let stagingDirectory = stagingURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: true
      )
      let temporaryURL = stagingDirectory.appendingPathComponent(
        ".\(stagingURL.lastPathComponent).\(UUID().uuidString).tmp"
      )
      defer { try? fileManager.removeItem(at: temporaryURL) }
      try fileManager.copyItem(at: sourceURL, to: temporaryURL)
      try validateRegularFile(at: temporaryURL)
      try validateDatabase(at: temporaryURL, expectedDeviceID: expectedDeviceID)
      if fileManager.fileExists(atPath: stagingURL.path) {
        _ = try fileManager.replaceItemAt(
          stagingURL,
          withItemAt: temporaryURL,
          backupItemName: nil
        )
      } else {
        try fileManager.moveItem(at: temporaryURL, to: stagingURL)
      }
    } catch let error as DatabaseRestoreError {
      throw error
    } catch {
      throw DatabaseRestoreError.stagingFailed
    }
  }

  @discardableResult
  public func applyStagedBackup(
    liveDatabaseURL: URL,
    stagingURL: URL
  ) throws -> Bool {
    let liveDatabaseURL = liveDatabaseURL.standardizedFileURL
    let stagingURL = stagingURL.standardizedFileURL
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: stagingURL.path) else { return false }
    guard liveDatabaseURL.isFileURL, stagingURL.isFileURL, liveDatabaseURL != stagingURL else {
      throw DatabaseRestoreError.invalidSource
    }
    try validateRegularFile(at: stagingURL)
    let expectedDeviceID = try readDeviceID(at: liveDatabaseURL)
    try validateDatabase(at: stagingURL, expectedDeviceID: expectedDeviceID)

    let backupName = ".\(liveDatabaseURL.lastPathComponent).pre-restore"
    do {
      _ = try fileManager.replaceItemAt(
        liveDatabaseURL,
        withItemAt: stagingURL,
        backupItemName: backupName
      )
    } catch {
      throw DatabaseRestoreError.stagingFailed
    }
    try? removeIfPresent(URL(fileURLWithPath: liveDatabaseURL.path + "-wal"))
    try? removeIfPresent(URL(fileURLWithPath: liveDatabaseURL.path + "-shm"))
    try? removeIfPresent(
      liveDatabaseURL.deletingLastPathComponent().appendingPathComponent(
        backupName
      ))
    return true
  }

  public func discardStagedBackup(at stagingURL: URL) throws {
    try removeIfPresent(stagingURL.standardizedFileURL)
  }

  private func validateRegularFile(at url: URL) throws {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [
        .fileSizeKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ])
    } catch {
      throw DatabaseRestoreError.invalidSource
    }
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw DatabaseRestoreError.invalidSource
    }
    guard let fileSize = values.fileSize else {
      throw DatabaseRestoreError.invalidSource
    }
    guard fileSize <= maximumBytes else {
      throw DatabaseRestoreError.backupTooLarge
    }
  }

  private func readDeviceID(at url: URL) throws -> String {
    do {
      let database = try openDatabaseForValidation(at: url)
      defer { try? database.close() }
      return try database.read { db in
        guard
          let deviceID = try String.fetchOne(
            db,
            sql: "SELECT device_id FROM sync_cursor WHERE singleton_id = 1"
          ),
          !deviceID.isEmpty
        else {
          throw DatabaseRestoreError.corruptBackup
        }
        return deviceID
      }
    } catch let error as DatabaseRestoreError {
      throw error
    } catch {
      throw DatabaseRestoreError.corruptBackup
    }
  }

  private func validateDatabase(at url: URL, expectedDeviceID: String) throws {
    do {
      let database = try openDatabaseForValidation(at: url)
      defer { try? database.close() }
      try database.read { db in
        let quickCheck = try String.fetchAll(db, sql: "PRAGMA quick_check")
        guard quickCheck == ["ok"] else {
          throw DatabaseRestoreError.corruptBackup
        }
        guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
          throw DatabaseRestoreError.corruptBackup
        }
        let tables = Set(
          try String.fetchAll(
            db,
            sql: """
              SELECT name FROM sqlite_master
              WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%'
                AND name <> 'grdb_migrations'
              """
          )
        )
        let indexes = Set(
          try String.fetchAll(
            db,
            sql: """
              SELECT name FROM sqlite_master
              WHERE type = 'index' AND name NOT LIKE 'sqlite_autoindex_%'
              """
          )
        )
        let migrations = Set(
          try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        )
        let disallowedObjects =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type IN ('view', 'trigger')"
          ) ?? 0
        guard
          tables == Self.expectedTables,
          indexes == Self.expectedIndexes,
          migrations == Self.expectedMigrations,
          disallowedObjects == 0
        else {
          throw DatabaseRestoreError.schemaMismatch
        }
        let cursorRows = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM sync_cursor WHERE singleton_id = 1"
        )
        guard cursorRows == 1 else {
          throw DatabaseRestoreError.corruptBackup
        }
        let deviceID = try String.fetchOne(
          db,
          sql: "SELECT device_id FROM sync_cursor WHERE singleton_id = 1"
        )
        guard deviceID == expectedDeviceID else {
          throw DatabaseRestoreError.foreignDevice
        }
      }
    } catch let error as DatabaseRestoreError {
      throw error
    } catch {
      throw DatabaseRestoreError.corruptBackup
    }
  }

  private func openDatabaseForValidation(at url: URL) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    return try DatabaseQueue(path: url.path, configuration: configuration)
  }

  private func removeIfPresent(_ url: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }
}
