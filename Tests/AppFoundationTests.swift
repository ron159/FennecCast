import Foundation
import XCTest

@testable import FennecCast

@MainActor
final class AppFoundationTests: XCTestCase {
  func testDefaultEnvironmentUsesFennecCastName() {
    let environment = AppEnvironment()

    XCTAssertEqual(environment.appName, "FennecCast")
    XCTAssertEqual(environment.stateSyncProtocolVersion, 1)
    XCTAssertNil(environment.stateSyncClock)
    XCTAssertNil(environment.stateSyncSettingsStore)
    XCTAssertNil(environment.stateSyncEngine)
    XCTAssertNil(environment.localDataStore)
    XCTAssertNil(environment.feedLibraryService)
    XCTAssertNil(environment.queueService)
    XCTAssertNil(environment.playbackEngine)
    XCTAssertNil(environment.mediaPlayer)
    XCTAssertNil(environment.systemPlaybackController)
    XCTAssertNil(environment.downloadManager)
    XCTAssertNil(environment.backgroundDownloadTransport)
    XCTAssertNil(environment.databaseURL)
    XCTAssertNil(environment.databaseRestoreStartupResult)
    XCTAssertNil(environment.startupFailure)
  }

  func testLiveEnvironmentProvidesLibraryAndQueueServices() throws {
    let applicationSupport = FileManager.default.temporaryDirectory
      .appendingPathComponent("FennecCast-AppEnvironment-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: applicationSupport) }

    let environment = AppEnvironment.live(
      applicationSupportDirectory: applicationSupport
    )

    XCTAssertNil(environment.startupFailure)
    XCTAssertNotNil(environment.localDataStore)
    XCTAssertNotNil(environment.stateSyncClock)
    XCTAssertNotNil(environment.stateSyncSettingsStore)
    XCTAssertNotNil(environment.stateSyncEngine)
    XCTAssertNotNil(environment.feedLibraryService)
    XCTAssertNotNil(environment.queueService)
    XCTAssertNotNil(environment.playbackEngine)
    XCTAssertNotNil(environment.mediaPlayer)
    XCTAssertNotNil(environment.systemPlaybackController)
    XCTAssertNotNil(environment.downloadManager)
    XCTAssertNotNil(environment.backgroundDownloadTransport)
    XCTAssertEqual(
      environment.databaseURL,
      AppEnvironment.databaseURL(in: applicationSupport)
    )
    XCTAssertNil(environment.databaseRestoreStartupResult)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: AppEnvironment.databaseURL(in: applicationSupport).path
      )
    )
  }

  func testDatabaseUsesAnApplicationSupportSubdirectory() {
    let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support")

    XCTAssertEqual(
      AppEnvironment.databaseURL(in: applicationSupport).path,
      "/tmp/Application Support/FennecCast/FennecCast.sqlite"
    )
  }

  func testRestoreStagingUsesTheDatabaseDirectory() {
    let applicationSupport = URL(fileURLWithPath: "/tmp/Application Support")

    XCTAssertEqual(
      AppEnvironment.restoreStagingURL(in: applicationSupport).path,
      "/tmp/Application Support/FennecCast/FennecCast.restore.pending.sqlite"
    )
  }

  func testEnvironmentPreservesInjectedAppName() {
    let environment = AppEnvironment(
      appName: "Preview Cast",
      stateSyncProtocolVersion: 2
    )

    XCTAssertEqual(environment.appName, "Preview Cast")
    XCTAssertEqual(environment.stateSyncProtocolVersion, 2)
  }

  func testAppBundleContainsSupportedLocalizations() {
    let localizations = Set(Bundle.main.localizations)

    XCTAssertTrue(localizations.contains("en"))
    XCTAssertTrue(localizations.contains("zh-Hans"))
  }
}
