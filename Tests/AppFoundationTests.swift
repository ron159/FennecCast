import Foundation
import XCTest

@testable import FennecCast

@MainActor
final class AppFoundationTests: XCTestCase {
  func testDefaultEnvironmentUsesFennecCastName() {
    let environment = AppEnvironment()

    XCTAssertEqual(environment.appName, "FennecCast")
  }

  func testEnvironmentPreservesInjectedAppName() {
    let environment = AppEnvironment(appName: "Preview Cast")

    XCTAssertEqual(environment.appName, "Preview Cast")
  }

  func testAppBundleContainsSupportedLocalizations() {
    let localizations = Set(Bundle.main.localizations)

    XCTAssertTrue(localizations.contains("en"))
    XCTAssertTrue(localizations.contains("zh-Hans"))
  }
}
