import CoreContracts
import Foundation
import GRDB
import LocalData
import Testing

struct DatabaseRestoreTests {
  @Test
  func stagesAndAppliesAValidatedSameDeviceBackup() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let deviceID = try DeviceID("ios-restore-device")
    let liveStore = try LocalDataStore(path: fixture.liveURL.path, deviceID: deviceID)
    _ = try await liveStore.recordLocalMutation(
      .subscription(
        SubscriptionState(
          feedKey: FeedKey(rawValue: "feed_backup"),
          feedURL: try #require(URL(string: "https://example.com/backup.xml")),
          subscribed: true
        )
      ),
      hlc: HLCTimestamp(wallMilliseconds: 1, counter: 0),
      createdAtMilliseconds: 1
    )
    try await liveStore.exportDatabase(to: fixture.backupURL)
    _ = try await liveStore.recordLocalMutation(
      .subscription(
        SubscriptionState(
          feedKey: FeedKey(rawValue: "feed_newer"),
          feedURL: try #require(URL(string: "https://example.com/newer.xml")),
          subscribed: true
        )
      ),
      hlc: HLCTimestamp(wallMilliseconds: 2, counter: 0),
      createdAtMilliseconds: 2
    )

    try DatabaseRestoreCoordinator().stageBackup(
      at: fixture.backupURL,
      liveDatabaseURL: fixture.liveURL,
      stagingURL: fixture.stagingURL
    )

    #expect(FileManager.default.fileExists(atPath: fixture.stagingURL.path))
    try await liveStore.close()
    #expect(
      try DatabaseRestoreCoordinator().applyStagedBackup(
        liveDatabaseURL: fixture.liveURL,
        stagingURL: fixture.stagingURL
      )
    )

    let restored = try LocalDataStore(path: fixture.liveURL.path, deviceID: deviceID)
    #expect(try await restored.pendingMutationCount() == 1)
    try await restored.close()
    #expect(!FileManager.default.fileExists(atPath: fixture.stagingURL.path))
  }

  @Test
  func rejectsForeignDeviceAndUnknownSchemaWithoutStaging() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let live = try LocalDataStore(
      path: fixture.liveURL.path,
      deviceID: DeviceID("ios-live-device")
    )
    let foreign = try LocalDataStore(
      path: fixture.foreignURL.path,
      deviceID: DeviceID("ios-foreign-device")
    )
    try await foreign.exportDatabase(to: fixture.backupURL)

    #expect(throws: DatabaseRestoreError.foreignDevice) {
      try DatabaseRestoreCoordinator().stageBackup(
        at: fixture.backupURL,
        liveDatabaseURL: fixture.liveURL,
        stagingURL: fixture.stagingURL
      )
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.stagingURL.path))

    let liveBackup = fixture.directory.appendingPathComponent("live-backup.sqlite")
    try await live.exportDatabase(to: liveBackup)
    let database = try DatabaseQueue(path: liveBackup.path)
    try await database.write { db in
      try db.execute(sql: "CREATE TABLE unexpected_secret(value TEXT)")
    }
    try database.close()
    #expect(throws: DatabaseRestoreError.schemaMismatch) {
      try DatabaseRestoreCoordinator().stageBackup(
        at: liveBackup,
        liveDatabaseURL: fixture.liveURL,
        stagingURL: fixture.stagingURL
      )
    }

    try await foreign.close()
    try await live.close()
  }

  @Test
  func rejectsDamagedAndOversizedBackups() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let live = try LocalDataStore(
      path: fixture.liveURL.path,
      deviceID: DeviceID("ios-live-device")
    )
    try Data("not sqlite".utf8).write(to: fixture.backupURL)

    #expect(throws: DatabaseRestoreError.corruptBackup) {
      try DatabaseRestoreCoordinator().stageBackup(
        at: fixture.backupURL,
        liveDatabaseURL: fixture.liveURL,
        stagingURL: fixture.stagingURL
      )
    }
    #expect(throws: DatabaseRestoreError.backupTooLarge) {
      try DatabaseRestoreCoordinator(maximumBytes: 4).stageBackup(
        at: fixture.backupURL,
        liveDatabaseURL: fixture.liveURL,
        stagingURL: fixture.stagingURL
      )
    }

    try await live.close()
  }
}

private struct Fixture {
  let directory: URL
  let liveURL: URL
  let backupURL: URL
  let stagingURL: URL
  let foreignURL: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FennecCast-Restore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    liveURL = directory.appendingPathComponent("live.sqlite")
    backupURL = directory.appendingPathComponent("backup.sqlite")
    stagingURL = directory.appendingPathComponent("restore.pending.sqlite")
    foreignURL = directory.appendingPathComponent("foreign.sqlite")
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
