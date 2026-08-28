import BackgroundTasks
import DownloadsFeature
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
  static let stateSyncRefreshIdentifier = "com.ron159.FennecCast.state-sync-refresh"

  private final class CompletionBox: @unchecked Sendable {
    let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
      self.completion = completion
    }
  }

  private var transport: BackgroundDownloadTransport?
  private var pendingCompletion: CompletionBox?
  private var stateSyncEngine: StateSyncEngine?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.stateSyncRefreshIdentifier,
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

  func scheduleStateSyncRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: Self.stateSyncRefreshIdentifier)
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
      guard !Task.isCancelled else { return }
      refreshTask.setTaskCompleted(success: succeeded)
      await MainActor.run {
        self.scheduleStateSyncRefresh()
      }
    }
    refreshTask.expirationHandler = {
      operation.cancel()
      refreshTask.setTaskCompleted(success: false)
    }
  }
}

@main
struct FennecCastApp: App {
  @UIApplicationDelegateAdaptor(FennecCastAppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase
  @State private var environment = AppEnvironment.live()
  private let stateSyncNetworkMonitor = StateSyncNetworkMonitor()

  var body: some Scene {
    WindowGroup {
      RootView(environment: environment)
        .task {
          appDelegate.attachBackgroundDownloadTransport(
            environment.backgroundDownloadTransport
          )
          appDelegate.attachStateSyncEngine(environment.stateSyncEngine)
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
