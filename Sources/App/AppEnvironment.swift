import AVFoundation
import CoreContracts
import DownloadsFeature
import FeedLibrary
import Foundation
import LocalData
import Observation
import PlaybackFeature
import QueueFeature
import StateSyncFeature
import TranscriptionFeature

enum AppStartupFailure: Equatable {
  case localDatabase
}

enum DatabaseRestoreStartupResult: Equatable {
  case applied
  case rejected
}

@MainActor
@Observable
final class AppEnvironment {
  static let shared = AppEnvironment.live()

  let appName: String
  let stateSyncProtocolVersion: Int
  let stateSyncClock: StateSyncClock?
  let stateSyncSettingsStore: StateSyncSettingsStore?
  let stateSyncEngine: StateSyncEngine?
  let localDataStore: LocalDataStore?
  let feedLibraryService: FeedLibraryService?
  let queueService: QueueService?
  let playbackEngine: PlaybackEngine?
  let mediaPlayer: AVPlayer?
  let systemPlaybackController: SystemPlaybackController?
  let downloadManager: DownloadManager?
  let podcastAutomationService: PodcastAutomationService?
  let backgroundDownloadTransport: BackgroundDownloadTransport?
  let transcriptionCoordinator: TranscriptionCoordinator?
  let databaseURL: URL?
  let databaseRestoreStartupResult: DatabaseRestoreStartupResult?
  let startupFailure: AppStartupFailure?

  init(
    appName: String = "FennecCast",
    stateSyncProtocolVersion: Int = StateSyncProtocol.version,
    stateSyncClock: StateSyncClock? = nil,
    stateSyncSettingsStore: StateSyncSettingsStore? = nil,
    stateSyncEngine: StateSyncEngine? = nil,
    localDataStore: LocalDataStore? = nil,
    feedLibraryService: FeedLibraryService? = nil,
    queueService: QueueService? = nil,
    playbackEngine: PlaybackEngine? = nil,
    mediaPlayer: AVPlayer? = nil,
    systemPlaybackController: SystemPlaybackController? = nil,
    downloadManager: DownloadManager? = nil,
    podcastAutomationService: PodcastAutomationService? = nil,
    backgroundDownloadTransport: BackgroundDownloadTransport? = nil,
    transcriptionCoordinator: TranscriptionCoordinator? = nil,
    databaseURL: URL? = nil,
    databaseRestoreStartupResult: DatabaseRestoreStartupResult? = nil,
    startupFailure: AppStartupFailure? = nil
  ) {
    self.appName = appName
    self.stateSyncProtocolVersion = stateSyncProtocolVersion
    self.stateSyncClock = stateSyncClock
    self.stateSyncSettingsStore = stateSyncSettingsStore
    self.stateSyncEngine = stateSyncEngine
    self.localDataStore = localDataStore
    self.feedLibraryService = feedLibraryService
    self.queueService = queueService
    self.playbackEngine = playbackEngine
    self.mediaPlayer = mediaPlayer
    self.systemPlaybackController = systemPlaybackController
    self.downloadManager = downloadManager
    self.podcastAutomationService = podcastAutomationService
    self.backgroundDownloadTransport = backgroundDownloadTransport
    self.transcriptionCoordinator = transcriptionCoordinator
    self.databaseURL = databaseURL
    self.databaseRestoreStartupResult = databaseRestoreStartupResult
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
      let databaseURL = Self.databaseURL(in: applicationSupportDirectory)
      let stagedRestoreURL = Self.restoreStagingURL(in: applicationSupportDirectory)
      try fileManager.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let restoreCoordinator = DatabaseRestoreCoordinator()
      let databaseRestoreStartupResult: DatabaseRestoreStartupResult?
      do {
        databaseRestoreStartupResult =
          try restoreCoordinator.applyStagedBackup(
            liveDatabaseURL: databaseURL,
            stagingURL: stagedRestoreURL
          ) ? .applied : nil
      } catch {
        try? restoreCoordinator.discardStagedBackup(at: stagedRestoreURL)
        databaseRestoreStartupResult = .rejected
      }
      let store = try LocalDataStore.openOrCreate(path: databaseURL.path)
      let clock = StateSyncClock()
      let stateSyncSettingsStore = StateSyncSettingsStore()
      let stateSyncEngine = StateSyncEngine(
        store: store,
        settingsStore: stateSyncSettingsStore,
        clock: clock
      )
      let scheduleSync: @Sendable () async -> Void = {
        await stateSyncEngine.scheduleDebounced(.userMutation)
      }
      let schedulePlaybackSync: @Sendable () async -> Void = {
        await stateSyncEngine.scheduleDebounced(.playback)
      }
      let queueService = QueueService(
        store: store,
        clock: clock,
        mutationDidCommit: scheduleSync
      )
      let storageRoot = databaseURL.deletingLastPathComponent()
      let backgroundDownloadTransport = BackgroundDownloadTransport(
        storageRoot: storageRoot
      )
      let transcriptionCoordinator = TranscriptionCoordinator(
        store: store,
        storageRoot: storageRoot
      )
      let downloadManager = DownloadManager(
        store: store,
        transport: backgroundDownloadTransport,
        storageRoot: storageRoot,
        downloadDidComplete: { episodeKey in
          await transcriptionCoordinator.handleDownloadCompleted(episodeKey)
        }
      )
      let podcastAutomationService = PodcastAutomationService(
        store: store,
        downloadManager: downloadManager
      )
      let mediaPlayer = AVPlayer()
      let playbackEngine = PlaybackEngine(
        store: store,
        queueService: queueService,
        driver: AVPlayerPlaybackDriver(player: mediaPlayer),
        sourceResolver: LocalFirstPlaybackSourceResolver(
          store: store,
          storageRoot: storageRoot
        ),
        clock: clock,
        mutationDidCommit: schedulePlaybackSync
      )
      return AppEnvironment(
        stateSyncClock: clock,
        stateSyncSettingsStore: stateSyncSettingsStore,
        stateSyncEngine: stateSyncEngine,
        localDataStore: store,
        feedLibraryService: FeedLibraryService(
          store: store,
          clock: clock,
          mutationDidCommit: scheduleSync
        ),
        queueService: queueService,
        playbackEngine: playbackEngine,
        mediaPlayer: mediaPlayer,
        systemPlaybackController: SystemPlaybackController(engine: playbackEngine),
        downloadManager: downloadManager,
        podcastAutomationService: podcastAutomationService,
        backgroundDownloadTransport: backgroundDownloadTransport,
        transcriptionCoordinator: transcriptionCoordinator,
        databaseURL: databaseURL,
        databaseRestoreStartupResult: databaseRestoreStartupResult
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

  static func restoreStagingURL(in applicationSupportDirectory: URL) -> URL {
    databaseURL(in: applicationSupportDirectory)
      .deletingLastPathComponent()
      .appendingPathComponent("FennecCast.restore.pending.sqlite", isDirectory: false)
  }
}
