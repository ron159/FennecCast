import DownloadsFeature
import SwiftUI
import UIKit

@MainActor
final class FennecCastAppDelegate: NSObject, UIApplicationDelegate {
  private final class CompletionBox: @unchecked Sendable {
    let completion: () -> Void

    init(_ completion: @escaping () -> Void) {
      self.completion = completion
    }
  }

  private var transport: BackgroundDownloadTransport?
  private var pendingCompletion: CompletionBox?

  func attachBackgroundDownloadTransport(_ transport: BackgroundDownloadTransport?) {
    self.transport = transport
    guard let pendingCompletion, let transport else { return }
    self.pendingCompletion = nil
    transport.setBackgroundEventsCompletionHandler {
      pendingCompletion.completion()
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
}

@main
struct FennecCastApp: App {
  @UIApplicationDelegateAdaptor(FennecCastAppDelegate.self) private var appDelegate
  @State private var environment = AppEnvironment.live()

  var body: some Scene {
    WindowGroup {
      RootView(environment: environment)
        .task {
          appDelegate.attachBackgroundDownloadTransport(
            environment.backgroundDownloadTransport
          )
          try? await environment.downloadManager?.connectAndReconcile()
        }
    }
  }
}
