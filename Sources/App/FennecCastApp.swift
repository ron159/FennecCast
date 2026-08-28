import SwiftUI

@main
struct FennecCastApp: App {
  @State private var environment = AppEnvironment()

  var body: some Scene {
    WindowGroup {
      RootView(environment: environment)
    }
  }
}
