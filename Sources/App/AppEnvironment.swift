import CoreContracts
import DownloadsFeature
import FeedLibrary
import Foundation
import LocalData
import Observation
import PlaybackFeature
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
  let playbackEngine: PlaybackEngine?
  let systemPlaybackController: SystemPlaybackController?
  let downloadManager: DownloadManager?
  let backgroundDownloadTransport: BackgroundDownloadTransport?
  let startupFailure: AppStartupFailure?

  init(
    appName: String = "FennecCast",
    stateSyncProtocolVersion: Int = StateSyncProtocol.version,
    localDataStore: LocalDataStore? = nil,
    feedLibraryService: FeedLibraryService? = nil,
    queueService: QueueService? = nil,
    playbackEngine: PlaybackEngine? = nil,
    systemPlaybackController: SystemPlaybackController? = nil,
    downloadManager: DownloadManager? = nil,
    backgroundDownloadTransport: BackgroundDownloadTransport? = nil,
    startupFailure: AppStartupFailure? = nil
  ) {
    self.appName = appName
    self.stateSyncProtocolVersion = stateSyncProtocolVersion
    self.localDataStore = localDataStore
    self.feedLibraryService = feedLibraryService
    self.queueService = queueService
    self.playbackEngine = playbackEngine
    self.systemPlaybackController = systemPlaybackController
    self.downloadManager = downloadManager
    self.backgroundDownloadTransport = backgroundDownloadTransport
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
      let queueService = QueueService(store: store)
      let storageRoot = databaseURL.deletingLastPathComponent()
      let backgroundDownloadTransport = BackgroundDownloadTransport(
        storageRoot: storageRoot
      )
      let downloadManager = DownloadManager(
        store: store,
        transport: backgroundDownloadTransport,
        storageRoot: storageRoot
      )
      let playbackEngine = PlaybackEngine(
        store: store,
        queueService: queueService,
        driver: AVPlayerPlaybackDriver(),
        sourceResolver: LocalFirstPlaybackSourceResolver(
          store: store,
          storageRoot: storageRoot
        )
      )
      return AppEnvironment(
        localDataStore: store,
        feedLibraryService: FeedLibraryService(store: store),
        queueService: queueService,
        playbackEngine: playbackEngine,
        systemPlaybackController: SystemPlaybackController(engine: playbackEngine),
        downloadManager: downloadManager,
        backgroundDownloadTransport: backgroundDownloadTransport
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
