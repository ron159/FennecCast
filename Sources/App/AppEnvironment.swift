import CoreContracts
import Foundation
import LocalData
import Observation

enum AppStartupFailure: Equatable {
  case localDatabase
}

@MainActor
@Observable
final class AppEnvironment {
  let appName: String
  let stateSyncProtocolVersion: Int
  let localDataStore: LocalDataStore?
  let startupFailure: AppStartupFailure?

  init(
    appName: String = "FennecCast",
    stateSyncProtocolVersion: Int = StateSyncProtocol.version,
    localDataStore: LocalDataStore? = nil,
    startupFailure: AppStartupFailure? = nil
  ) {
    self.appName = appName
    self.stateSyncProtocolVersion = stateSyncProtocolVersion
    self.localDataStore = localDataStore
    self.startupFailure = startupFailure
  }

  static func live(fileManager: FileManager = .default) -> AppEnvironment {
    do {
      let applicationSupport = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let databaseURL = databaseURL(in: applicationSupport)
      try fileManager.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      return AppEnvironment(
        localDataStore: try LocalDataStore.openOrCreate(path: databaseURL.path)
      )
    } catch {
      return AppEnvironment(startupFailure: .localDatabase)
    }
  }

  static func databaseURL(in applicationSupportDirectory: URL) -> URL {
    applicationSupportDirectory
      .appendingPathComponent("FennecCast", isDirectory: true)
      .appendingPathComponent("FennecCast.sqlite", isDirectory: false)
  }
}
