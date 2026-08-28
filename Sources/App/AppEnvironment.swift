import CoreContracts
import FeedLibrary
import Foundation
import LocalData
import Observation
import QueueFeature

enum AppStartupFailure: Equatable {
  case localDatabase
}

@MainActor
@Observable
final class AppEnvironment {
  let appName: String
  let stateSyncProtocolVersion: Int
  let localDataStore: LocalDataStore?
  let feedLibraryService: FeedLibraryService?
  let queueService: QueueService?
  let startupFailure: AppStartupFailure?

  init(
    appName: String = "FennecCast",
    stateSyncProtocolVersion: Int = StateSyncProtocol.version,
    localDataStore: LocalDataStore? = nil,
    feedLibraryService: FeedLibraryService? = nil,
    queueService: QueueService? = nil,
    startupFailure: AppStartupFailure? = nil
  ) {
    self.appName = appName
    self.stateSyncProtocolVersion = stateSyncProtocolVersion
    self.localDataStore = localDataStore
    self.feedLibraryService = feedLibraryService
    self.queueService = queueService
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
      return live(
        applicationSupportDirectory: applicationSupport,
        fileManager: fileManager
      )
    } catch {
      return AppEnvironment(startupFailure: .localDatabase)
    }
  }

  static func live(
    applicationSupportDirectory: URL,
    fileManager: FileManager = .default
  ) -> AppEnvironment {
    do {
      let databaseURL = databaseURL(in: applicationSupportDirectory)
      try fileManager.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let store = try LocalDataStore.openOrCreate(path: databaseURL.path)
      return AppEnvironment(
        localDataStore: store,
        feedLibraryService: FeedLibraryService(store: store),
        queueService: QueueService(store: store)
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
