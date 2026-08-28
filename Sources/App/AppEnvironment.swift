import Observation

@MainActor
@Observable
final class AppEnvironment {
  let appName: String

  init(appName: String = "FennecCast") {
    self.appName = appName
  }
}
