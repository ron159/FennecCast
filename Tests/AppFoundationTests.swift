import Foundation
import XCTest

@testable import FennecCast

@MainActor
final class AppFoundationTests: XCTestCase {
  func testDefaultEnvironmentUsesFennecCastName() {
    let environment = AppEnvironment()

    XCTAssertEqual(environment.appName, "FennecCast")
    XCTAssertEqual(environment.stateSyncProtocolVersion, 1)
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
