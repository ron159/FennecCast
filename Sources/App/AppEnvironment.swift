import CoreContracts
import Observation

@MainActor
@Observable
final class AppEnvironment {
  let appName: String
  let stateSyncProtocolVersion: Int

  init(
    appName: String = "FennecCast",
    stateSyncProtocolVersion: Int = StateSyncProtocol.version
  ) {
    self.appName = appName
    self.stateSyncProtocolVersion = stateSyncProtocolVersion
  }
}
