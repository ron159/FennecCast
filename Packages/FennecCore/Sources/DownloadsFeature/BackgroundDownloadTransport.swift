import CoreContracts
import Foundation
import LocalData

public final class BackgroundDownloadTransport: NSObject, @unchecked Sendable,
  DownloadTransporting, URLSessionDownloadDelegate, URLSessionTaskDelegate
{
  public static let sessionIdentifier = "com.ron159.FennecCast.background-downloads"

  private enum TransportError: Error {
    case taskNotFound
  }

  private struct State {
    var handler: (@Sendable (DownloadTransportEvent) async -> Void)?
    var bufferedEvents: [DownloadTransportEvent] = []
    var eventsInFlight = 0
    var sessionEventsFinished = false
    var backgroundCompletion: (@Sendable () -> Void)?
    var intentionalStops = Set<Int>()
  }

  private let stagingDirectory: URL
  private let lock = NSLock()
  private var state = State()

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.background(
      withIdentifier: Self.sessionIdentifier
    )
    #if os(iOS)
      configuration.sessionSendsLaunchEvents = true
    #endif
    configuration.isDiscretionary = false
    configuration.waitsForConnectivity = true
    configuration.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  public init(storageRoot: URL) {
    self.stagingDirectory = storageRoot.appendingPathComponent(
      "Staging",
      isDirectory: true
    )
    super.init()
  }

  public func setEventHandler(
    _ handler: @escaping @Sendable (DownloadTransportEvent) async -> Void
  ) async {
    let bufferedEvents = withState { state in
      state.handler = handler
      let events = state.bufferedEvents
      state.bufferedEvents.removeAll(keepingCapacity: true)
      state.eventsInFlight += events.count
      return events
    }
    for event in bufferedEvents {
      dispatch(event, to: handler)
    }
  }

  public func makeTask(
    episodeKey: EpisodeKey,
    url: URL,
    resumeData: Data?
  ) async throws -> Int {
    let task: URLSessionDownloadTask
    if let resumeData, !resumeData.isEmpty {
      task = session.downloadTask(withResumeData: resumeData)
    } else {
      task = session.downloadTask(with: url)
    }
    task.taskDescription = episodeKey.rawValue
    return task.taskIdentifier
  }

  public func startTask(taskIdentifier: Int) async throws {
    guard let task = await downloadTask(identifier: taskIdentifier) else {
      throw TransportError.taskNotFound
    }
    task.resume()
  }

  public func suspendTask(taskIdentifier: Int) async throws -> Data? {
    guard let task = await downloadTask(identifier: taskIdentifier) else {
      throw TransportError.taskNotFound
    }
    _ = withState { state in
      state.intentionalStops.insert(taskIdentifier)
    }
    return await withCheckedContinuation { continuation in
      task.cancel { resumeData in
        continuation.resume(returning: resumeData)
      }
    }
  }

  public func cancelTask(taskIdentifier: Int) async {
    guard let task = await downloadTask(identifier: taskIdentifier) else { return }
    _ = withState { state in
      state.intentionalStops.insert(taskIdentifier)
    }
    task.cancel()
  }

  public func currentTasks() async -> [DownloadTransportTask] {
    await allDownloadTasks().compactMap { task in
      guard
        let description = task.taskDescription,
        !description.isEmpty,
        let state = Self.transportState(task.state)
      else { return nil }
      return DownloadTransportTask(
        taskIdentifier: task.taskIdentifier,
        episodeKey: EpisodeKey(rawValue: description),
        originalURL: task.originalRequest?.url,
        state: state
      )
    }
  }

  public func setBackgroundEventsCompletionHandler(
    _ handler: @escaping @Sendable () -> Void
  ) {
    let completion = withState { state in
      state.backgroundCompletion = handler
      return Self.takeBackgroundCompletionIfReady(state: &state)
    }
    runOnMain(completion)
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    emit(
      .progress(
        taskIdentifier: downloadTask.taskIdentifier,
        downloadedBytes: totalBytesWritten,
        contentLength: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
      )
    )
  }

  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let stagedFileURL = stagingDirectory.appendingPathComponent(
      "\(downloadTask.taskIdentifier)-\(UUID().uuidString).download",
      isDirectory: false
    )
    do {
      try FileManager.default.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: true
      )
      try FileManager.default.moveItem(at: location, to: stagedFileURL)
    } catch {
      emit(
        .failed(
          taskIdentifier: downloadTask.taskIdentifier,
          resumeData: nil,
          error: .fileSystem
        )
      )
      return
    }

    let response = downloadTask.response as? HTTPURLResponse
    let expectedContentLength = response?.expectedContentLength ?? 0
    emit(
      .completed(
        taskIdentifier: downloadTask.taskIdentifier,
        stagedFileURL: stagedFileURL,
        response: DownloadResponseMetadata(
          statusCode: response?.statusCode ?? 0,
          finalURL: response?.url,
          contentLength: expectedContentLength > 0 ? expectedContentLength : nil,
          mimeType: response?.mimeType,
          eTag: response?.value(forHTTPHeaderField: "ETag"),
          lastModified: response?.value(forHTTPHeaderField: "Last-Modified")
        )
      )
    )
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    let intentional = withState { state in
      state.intentionalStops.remove(task.taskIdentifier) != nil
    }
    guard !intentional, let error else { return }
    let errorValue = error as NSError
    emit(
      .failed(
        taskIdentifier: task.taskIdentifier,
        resumeData: errorValue.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
        error: Self.errorCode(for: errorValue)
      )
    )
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, Self.isNetworkURL(url) else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let completion = withState { state in
      state.sessionEventsFinished = true
      return Self.takeBackgroundCompletionIfReady(state: &state)
    }
    runOnMain(completion)
  }

  private func emit(_ event: DownloadTransportEvent) {
    let handler: (@Sendable (DownloadTransportEvent) async -> Void)? = withState { state in
      state.sessionEventsFinished = false
      guard let handler = state.handler else {
        state.bufferedEvents.append(event)
        return nil
      }
      state.eventsInFlight += 1
      return handler
    }
    if let handler {
      dispatch(event, to: handler)
    }
  }

  private func dispatch(
    _ event: DownloadTransportEvent,
    to handler: @escaping @Sendable (DownloadTransportEvent) async -> Void
  ) {
    Task {
      await handler(event)
      let completion = self.withState { state in
        state.eventsInFlight -= 1
        return Self.takeBackgroundCompletionIfReady(state: &state)
      }
      self.runOnMain(completion)
    }
  }

  private func downloadTask(identifier: Int) async -> URLSessionDownloadTask? {
    await allDownloadTasks().first { $0.taskIdentifier == identifier }
  }

  private func allDownloadTasks() async -> [URLSessionDownloadTask] {
    await withCheckedContinuation { continuation in
      session.getAllTasks { tasks in
        continuation.resume(returning: tasks.compactMap { $0 as? URLSessionDownloadTask })
      }
    }
  }

  private func withState<Result>(_ body: (inout State) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }

  private static func takeBackgroundCompletionIfReady(
    state: inout State
  ) -> (@Sendable () -> Void)? {
    guard
      state.sessionEventsFinished,
      state.eventsInFlight == 0,
      state.bufferedEvents.isEmpty
    else { return nil }
    defer { state.backgroundCompletion = nil }
    return state.backgroundCompletion
  }

  private func runOnMain(_ completion: (@Sendable () -> Void)?) {
    guard let completion else { return }
    DispatchQueue.main.async(execute: completion)
  }

  private static func transportState(
    _ state: URLSessionTask.State
  ) -> DownloadTransportTaskState? {
    switch state {
    case .running:
      return .running
    case .suspended:
      return .suspended
    case .canceling:
      return .cancelling
    case .completed:
      return nil
    @unknown default:
      return nil
    }
  }

  private static func errorCode(for error: NSError) -> DownloadErrorCode {
    guard error.domain == NSURLErrorDomain else { return .unknown }
    switch error.code {
    case NSURLErrorCancelled:
      return .cancelled
    case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
      return .invalidURL
    case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile:
      return .fileSystem
    case NSURLErrorDataLengthExceedsMaximum, NSURLErrorBadServerResponse:
      return .invalidResponse
    case NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
      NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
      NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
      return .network
    default:
      return .unknown
    }
  }

  private static func isNetworkURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }
}
