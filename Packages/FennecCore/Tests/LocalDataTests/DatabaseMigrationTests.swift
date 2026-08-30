import CoreContracts
import Foundation
import GRDB
import Testing

@testable import LocalData

struct DatabaseMigrationTests {
  @Test
  func initialMigrationCreatesExpectedTablesAndCursor() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))

    let tables = try await store.applicationTableNames()
    let cursor = try await store.syncCursor()

    #expect(
      tables == [
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
    )
    #expect(try await store.foreignKeysEnabled())
    #expect(
      try await store.applicationIndexNames() == [
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
    )
    #expect(cursor.serverSequence == 0)
    #expect(cursor.lastLocalSequence == 0)
    #expect(cursor.deviceID == DeviceID(rawValue: "ios-phone"))
  }

  @Test
  func currentMigrationAddsEpisodeArtworkColumn() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fenneccast.sqlite").path
    let store = try LocalDataStore(path: path, deviceID: DeviceID("ios-phone"))
    try await store.close()

    let database = try DatabaseQueue(path: path)
    let columns = try await database.read { db in
      try Row.fetchAll(db, sql: "PRAGMA table_info(episodes)")
        .map { $0["name"] as String }
    }

    #expect(columns.contains("image_url"))
  }

  @Test
  func migrationIsIdempotentForTheSameDevice() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fenneccast.sqlite").path

    let first = try LocalDataStore(path: path, deviceID: DeviceID("ios-phone"))
    try await first.close()
    let reopened = try LocalDataStore(path: path, deviceID: DeviceID("ios-phone"))

    #expect((try await reopened.syncCursor()).deviceID == DeviceID(rawValue: "ios-phone"))
    try await reopened.close()
  }

  @Test
  func databaseRejectsDifferentDeviceIdentity() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fenneccast.sqlite").path

    let first = try LocalDataStore(path: path, deviceID: DeviceID("ios-phone"))
    try await first.close()

    #expect(
      throws: LocalDataError.deviceIDMismatch(
        stored: DeviceID(rawValue: "ios-phone")!,
        requested: DeviceID(rawValue: "android-phone")!
      )
    ) {
      try LocalDataStore(path: path, deviceID: DeviceID("android-phone"))
    }
  }

  @Test
  func openOrCreateGeneratesAndReusesTheDatabaseDeviceIdentity() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("fenneccast.sqlite").path

    let first = try LocalDataStore.openOrCreate(path: path)
    let firstIdentity = try await first.syncCursor().deviceID
    #expect(!firstIdentity.rawValue.isEmpty)
    try await first.close()

    let reopened = try LocalDataStore.openOrCreate(path: path)
    #expect(try await reopened.syncCursor().deviceID == firstIdentity)
    try await reopened.close()
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("FennecCast-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
