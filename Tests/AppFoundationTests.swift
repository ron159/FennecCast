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

  func testCarPlayContentBoundsRespectSystemMaximums() {
    XCTAssertEqual(
      CarPlayContentLimit.boundedCount(requested: 500, systemMaximum: 100),
      100
    )
    XCTAssertEqual(
      CarPlayContentLimit.boundedCount(requested: -1, systemMaximum: 100),
      0
    )
    XCTAssertEqual(
      CarPlayContentLimit.boundedCount(requested: 4, systemMaximum: 0),
      0
    )
  }

  func testCarPlaySceneIsDeclaredInTheApplicationManifest() throws {
    let manifest = try XCTUnwrap(
      Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest")
        as? [String: Any]
    )
    let configurations = try XCTUnwrap(
      manifest["UISceneConfigurations"] as? [String: Any]
    )
    let scenes = try XCTUnwrap(
      configurations["CPTemplateApplicationSceneSessionRoleApplication"]
        as? [[String: Any]]
    )

    XCTAssertEqual(
      scenes.first?["UISceneDelegateClassName"] as? String,
      "FennecCast.CarPlaySceneDelegate"
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

  func testSubscriptionLayoutRestoresSafePersistentValues() {
    XCTAssertEqual(SubscriptionLayout.restored(from: nil), .artworkGrid)
    XCTAssertEqual(SubscriptionLayout.restored(from: "list"), .list)
    XCTAssertEqual(SubscriptionLayout.restored(from: "compactGrid"), .compactGrid)
    XCTAssertEqual(SubscriptionLayout.restored(from: "future-value"), .artworkGrid)
  }

  func testPrimaryNavigationFitsTheNativeIPhoneTabBar() {
    XCTAssertEqual(
      PrimaryTab.allCases,
      [.home, .inbox, .queue, .subscriptions, .downloads]
    )
    XCTAssertLessThanOrEqual(PrimaryTab.allCases.count, 5)
    XCTAssertEqual(
      PrimaryTab.launchSelection(
        from: ["FennecCast", "--fenneccast-tab", "subscriptions"]
      ),
      .subscriptions
    )
    XCTAssertEqual(
      PrimaryTab.launchSelection(from: ["FennecCast", "--fenneccast-tab", "unknown"]),
      .home
    )
  }

  func testFeedMarkupPreservesReadableStructureAndRemovesActiveContent() {
    let html = """
      <p>First line<br>Second &amp; line</p>
      <p><strong>Next paragraph</strong></p>
      <script>alert('hidden')</script>
      <img src="https://tracking.example/pixel.png">
      """

    let text = FeedMarkup.plainText(from: html)

    XCTAssertTrue(text.contains("First line\nSecond & line"))
    XCTAssertTrue(text.contains("Second & line\n\nNext paragraph"))
    XCTAssertFalse(text.contains("hidden"))
    XCTAssertFalse(text.contains("tracking.example"))
  }

  func testFeedMarkupFallsBackForMalformedMarkup() {
    let text = FeedMarkup.plainText(from: "One<br>Two <broken Three")

    XCTAssertTrue(text.contains("One\nTwo"))
    XCTAssertTrue(text.contains("Three"))
  }

  func testFeedMarkupRemovesLinksAndPublisherStyling() {
    let html = """
      <a href="https://example.com" style="font-size: 80px" onclick="alert(1)">Read more</a>
      """

    let attributed = FeedMarkup.attributedString(from: html)

    XCTAssertEqual(String(attributed.characters), "Read more")
    XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
  }
}
