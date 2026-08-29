import BackgroundTasks
import DownloadsFeature
import FeedLibrary
import LocalData
import Network
import StateSyncFeature
import SwiftUI
import UIKit

final class StateSyncNetworkMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.ron159.FennecCast.network-monitor")
  private let lock = NSLock()
  private var hasStarted = false
  private var wasUnavailable = false

  func start(engine: StateSyncEngine?) {
    guard let engine else { return }
    let shouldStart = lock.withLock {
      guard !hasStarted else { return false }
      hasStarted = true
      return true
    }
    guard shouldStart else { return }

    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let shouldSchedule = lock.withLock {
        if path.status != .satisfied {
          wasUnavailable = true
          return false
        }
        guard wasUnavailable else { return false }
        wasUnavailable = false
        return true
      }
      guard shouldSchedule else { return }
      Task {
        await engine.scheduleDebounced(.networkRecovery)
      }
    }
    monitor.start(queue: queue)
  }

  deinit {
    monitor.cancel()
  }
}

@MainActor
final class FennecCastAppDelegate: NSObject, UIApplicationDelegate {
  static let appRefreshIdentifier = "com.ron159.FennecCast.app-refresh"

  private final class CompletionBox: @unchecked Sendable {
    let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
      self.completion = completion
    }
  }

  private final class BackgroundTaskCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private let task: BGTask
    private var completed = false

    init(task: BGTask) {
      self.task = task
    }

    func finish(success: Bool) {
      let shouldFinish = lock.withLock {
        guard !completed else { return false }
        completed = true
        return true
      }
      if shouldFinish {
        task.setTaskCompleted(success: success)
      }
    }
  }

  private var transport: BackgroundDownloadTransport?
  private var pendingCompletion: CompletionBox?
  private var stateSyncEngine: StateSyncEngine?
  private var localDataStore: LocalDataStore?
  private var feedLibraryService: FeedLibraryService?
  private var podcastAutomationService: PodcastAutomationService?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let environment = AppEnvironment.shared
    attachBackgroundDownloadTransport(environment.backgroundDownloadTransport)
    attachStateSyncEngine(environment.stateSyncEngine)
    attachFeedRefresh(
      store: environment.localDataStore,
      service: environment.feedLibraryService,
      automationService: environment.podcastAutomationService
    )
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.appRefreshIdentifier,
      using: .main
    ) { [weak self] task in
      self?.handleStateSyncRefresh(task)
    }
    return true
  }

  func attachBackgroundDownloadTransport(_ transport: BackgroundDownloadTransport?) {
    self.transport = transport
    guard let pendingCompletion, let transport else { return }
    self.pendingCompletion = nil
    transport.setBackgroundEventsCompletionHandler {
      pendingCompletion.completion()
    }
  }

  func attachStateSyncEngine(_ engine: StateSyncEngine?) {
    stateSyncEngine = engine
  }

  func attachFeedRefresh(
    store: LocalDataStore?,
    service: FeedLibraryService?,
    automationService: PodcastAutomationService?
  ) {
    localDataStore = store
    feedLibraryService = service
    podcastAutomationService = automationService
  }

  func scheduleStateSyncRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: Self.appRefreshIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Scheduling is opportunistic. Foreground and mutation triggers remain active.
    }
  }

  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == BackgroundDownloadTransport.sessionIdentifier else {
      completionHandler()
      return
    }
    let completion = CompletionBox(completionHandler)
    guard let transport else {
      pendingCompletion = completion
      return
    }
    transport.setBackgroundEventsCompletionHandler {
      completion.completion()
    }
  }

  private func handleStateSyncRefresh(_ task: BGTask) {
    guard
      let refreshTask = task as? BGAppRefreshTask,
      let stateSyncEngine
    else {
      task.setTaskCompleted(success: false)
      return
    }

    let completion = BackgroundTaskCompletionBox(task: refreshTask)
    let operation = Task {
      let succeeded: Bool
      do {
        _ = try await stateSyncEngine.synchronize(trigger: .background)
        succeeded = true
      } catch StateSyncEngineError.notConfigured {
        succeeded = true
      } catch {
        succeeded = false
      }
      let feedsSucceeded = await self.refreshStaleFeeds()
      guard !Task.isCancelled else { return }
      completion.finish(success: succeeded && feedsSucceeded)
      await MainActor.run {
        self.scheduleStateSyncRefresh()
      }
    }
    refreshTask.expirationHandler = {
      operation.cancel()
      completion.finish(success: false)
    }
  }

  private func refreshStaleFeeds() async -> Bool {
    guard let localDataStore, let feedLibraryService else { return true }
    let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    let staleBefore = now - 6 * 60 * 60 * 1_000
    guard let feeds = try? await localDataStore.subscribedFeeds() else { return false }
    let staleFeeds =
      feeds
      .filter { ($0.lastRefreshAtMilliseconds ?? 0) <= staleBefore }
      .prefix(20)
    var succeeded = true
    for feed in staleFeeds {
      do {
        let outcome = try await feedLibraryService.refresh(feedKey: feed.feedKey)
        if case .updated(let result) = outcome {
          _ = await podcastAutomationService?.handleRefresh(
            feedKey: feed.feedKey,
            insertedEpisodeKeys: result.insertedEpisodeKeys
          )
        }
      } catch {
        succeeded = false
      }
      if Task.isCancelled { return false }
    }
    _ = await podcastAutomationService?.runMaintenance()
    return succeeded
  }
}

@main
struct FennecCastApp: App {
  @UIApplicationDelegateAdaptor(FennecCastAppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase
  @State private var environment = AppEnvironment.shared
  private let stateSyncNetworkMonitor = StateSyncNetworkMonitor()

  var body: some Scene {
    WindowGroup {
      RootView(environment: environment)
        .task {
          appDelegate.scheduleStateSyncRefresh()
          stateSyncNetworkMonitor.start(engine: environment.stateSyncEngine)
          try? await environment.downloadManager?.connectAndReconcile()
          try? await environment.stateSyncEngine?.bootstrapClock()
          _ = try? await environment.stateSyncEngine?.synchronize(trigger: .foreground)
        }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        Task {
          await environment.stateSyncEngine?.scheduleDebounced(.foreground)
        }
      case .background:
        appDelegate.scheduleStateSyncRefresh()
        Task {
          _ = try? await environment.stateSyncEngine?.synchronize(trigger: .background)
        }
      case .inactive:
        break
      @unknown default:
        break
      }
    }
  }
}
