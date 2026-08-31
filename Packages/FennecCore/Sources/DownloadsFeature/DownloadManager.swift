import CoreContracts
import Foundation
import LocalData

public actor DownloadManager {
  private let store: LocalDataStore
  private let transport: any DownloadTransporting
  private let fileStore: LocalMediaFileStore
  private let timeMilliseconds: @Sendable () -> Int64
  private let downloadDidComplete: @Sendable (EpisodeKey) async -> Void

  private var isConnected = false
  private var episodeByTaskIdentifier: [Int: EpisodeKey] = [:]

  public init(
    store: LocalDataStore,
    transport: any DownloadTransporting,
    storageRoot: URL,
    downloadDidComplete: @escaping @Sendable (EpisodeKey) async -> Void = { _ in },
    timeMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) {
    self.store = store
    self.transport = transport
    self.fileStore = LocalMediaFileStore(storageRoot: storageRoot)
    self.downloadDidComplete = downloadDidComplete
    self.timeMilliseconds = timeMilliseconds
  }

  public func startDownload(_ episodeKey: EpisodeKey) async throws {
    await connectIfNeeded()
    let current = try await store.localMediaRecord(for: episodeKey)
    guard current == nil || current?.state == .notRequested else {
      throw DownloadManagerError.alreadyRequested
    }
    try await beginDownload(episodeKey, previous: current, resumeData: nil)
  }

  public func suspendDownload(_ episodeKey: EpisodeKey) async throws {
    await connectIfNeeded()
    let record = try await requiredRecord(for: episodeKey)
    guard
      record.state == .queued || record.state == .running,
      let taskIdentifier = record.taskIdentifier
    else {
      throw DownloadManagerError.invalidState
    }
    let resumeData = try await transport.suspendTask(taskIdentifier: taskIdentifier)
    guard let resumeData, !resumeData.isEmpty else {
      try await saveFailed(record, error: .unknown, resumeData: nil)
      episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
      throw DownloadManagerError.missingResumeData
    }
    try await store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: episodeKey,
        state: .suspended,
        resumeData: resumeData,
        downloadedBytes: record.downloadedBytes,
        contentLength: record.contentLength,
        eTag: record.eTag,
        lastModified: record.lastModified,
        updatedAtMilliseconds: timeMilliseconds()
      )
    )
    episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
  }

  public func resumeDownload(_ episodeKey: EpisodeKey) async throws {
    await connectIfNeeded()
    let record = try await requiredRecord(for: episodeKey)
    guard record.state == .suspended, let resumeData = record.resumeData else {
      throw DownloadManagerError.invalidState
    }
    try await beginDownload(episodeKey, previous: record, resumeData: resumeData)
  }

  public func retryDownload(_ episodeKey: EpisodeKey) async throws {
    await connectIfNeeded()
    let record = try await requiredRecord(for: episodeKey)
    guard record.state == .failed else {
      throw DownloadManagerError.invalidState
    }
    try await beginDownload(episodeKey, previous: record, resumeData: record.resumeData)
  }

  public func cancelDownload(_ episodeKey: EpisodeKey) async throws {
    await connectIfNeeded()
    let record = try await requiredRecord(for: episodeKey)
    switch record.state {
    case .queued, .running, .cancelling:
      guard let taskIdentifier = record.taskIdentifier else {
        throw DownloadManagerError.invalidState
      }
      if record.state != .cancelling {
        try await store.saveLocalMediaRecord(
          LocalMediaRecord(
            episodeKey: episodeKey,
            state: .cancelling,
            taskIdentifier: taskIdentifier,
            downloadedBytes: record.downloadedBytes,
            contentLength: record.contentLength,
            eTag: record.eTag,
            lastModified: record.lastModified,
            updatedAtMilliseconds: timeMilliseconds()
          )
        )
      }
      await transport.cancelTask(taskIdentifier: taskIdentifier)
      episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
      try await resetRecord(episodeKey)
    case .suspended, .failed:
      try await resetRecord(episodeKey)
    case .notRequested:
      return
    case .completed:
      throw DownloadManagerError.invalidState
    }
  }

  public func removeDownload(_ episodeKey: EpisodeKey) async throws {
    let record = try await requiredRecord(for: episodeKey)
    guard record.state == .completed, let relativePath = record.localRelativePath else {
      throw DownloadManagerError.invalidState
    }
    do {
      try fileStore.remove(relativePath: relativePath)
    } catch {
      throw DownloadManagerError.transport
    }
    try await resetRecord(episodeKey)
  }

  public func connectAndReconcile() async throws {
    await connectIfNeeded()
    let tasks = await transport.currentTasks()
    var restoredTaskIdentifiers = Set<Int>()
    var restoredEpisodeKeys = Set<EpisodeKey>()

    for task in tasks {
      let storedEpisode = try await store.libraryEpisode(for: task.episodeKey)
      guard
        !restoredEpisodeKeys.contains(task.episodeKey),
        let storedEpisode,
        let sourceURL = task.originalURL ?? storedEpisode.metadata.enclosureURL,
        Self.isNetworkURL(sourceURL),
        storedEpisode.metadata.enclosureURL.map(Self.isNetworkURL) ?? false
      else {
        await transport.cancelTask(taskIdentifier: task.taskIdentifier)
        continue
      }
      let current = try await store.localMediaRecord(for: task.episodeKey)
      guard
        current == nil || current?.state == .notRequested
          || ((current?.state == .queued || current?.state == .running)
            && current?.taskIdentifier == task.taskIdentifier)
      else {
        await transport.cancelTask(taskIdentifier: task.taskIdentifier)
        continue
      }

      if current == nil || current?.state == .notRequested {
        try await store.saveLocalMediaRecord(
          LocalMediaRecord(
            episodeKey: task.episodeKey,
            state: .queued,
            taskIdentifier: task.taskIdentifier,
            updatedAtMilliseconds: timeMilliseconds()
          )
        )
      }
      if task.state == .running, current?.state != .running {
        let queued = try await requiredRecord(for: task.episodeKey)
        try await store.saveLocalMediaRecord(
          activeRecord(
            from: queued,
            episodeKey: task.episodeKey,
            state: .running,
            taskIdentifier: task.taskIdentifier
          )
        )
      }
      if task.state == .cancelling {
        await transport.cancelTask(taskIdentifier: task.taskIdentifier)
        try await resetRecord(task.episodeKey)
        continue
      }
      restoredTaskIdentifiers.insert(task.taskIdentifier)
      restoredEpisodeKeys.insert(task.episodeKey)
      episodeByTaskIdentifier[task.taskIdentifier] = task.episodeKey
    }

    let activeRecords = try await store.localMediaRecords(
      states: [.queued, .running, .cancelling]
    )
    for record in activeRecords {
      guard
        let taskIdentifier = record.taskIdentifier,
        !restoredTaskIdentifiers.contains(taskIdentifier)
      else { continue }
      try await saveFailed(record, error: .unknown, resumeData: nil)
      episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
    }

    let completedRecords = try await store.localMediaRecords(states: [.completed])
    for record in completedRecords where (try? fileStore.verifiedURL(for: record)) == nil {
      try await resetRecord(record.episodeKey)
    }
  }

  public func handleTransportEvent(_ event: DownloadTransportEvent) async {
    switch event {
    case .progress(let taskIdentifier, let downloadedBytes, let contentLength):
      await handleProgress(
        taskIdentifier: taskIdentifier,
        downloadedBytes: downloadedBytes,
        contentLength: contentLength
      )
    case .completed(let taskIdentifier, let stagedFileURL, let response):
      await handleCompletion(
        taskIdentifier: taskIdentifier,
        stagedFileURL: stagedFileURL,
        response: response
      )
    case .failed(let taskIdentifier, let resumeData, let error):
      await handleFailure(
        taskIdentifier: taskIdentifier,
        resumeData: resumeData,
        error: error
      )
    }
  }

  private func connectIfNeeded() async {
    guard !isConnected else { return }
    isConnected = true
    await transport.setEventHandler { [weak self] event in
      await self?.handleTransportEvent(event)
    }
  }

  private func beginDownload(
    _ episodeKey: EpisodeKey,
    previous: LocalMediaRecord?,
    resumeData: Data?
  ) async throws {
    guard let episode = try await store.libraryEpisode(for: episodeKey) else {
      throw LocalDataError.episodeNotFound
    }
    guard let sourceURL = episode.metadata.enclosureURL else {
      throw DownloadManagerError.missingMediaSource
    }
    guard Self.isNetworkURL(sourceURL) else {
      throw DownloadManagerError.unsupportedMediaSource
    }
    let taskIdentifier: Int
    do {
      taskIdentifier = try await transport.makeTask(
        episodeKey: episodeKey,
        url: sourceURL,
        resumeData: resumeData
      )
    } catch {
      throw DownloadManagerError.transport
    }
    episodeByTaskIdentifier[taskIdentifier] = episodeKey
    let queued = activeRecord(
      from: previous,
      episodeKey: episodeKey,
      state: .queued,
      taskIdentifier: taskIdentifier
    )
    do {
      try await store.saveLocalMediaRecord(queued)
      try await store.saveLocalMediaRecord(
        activeRecord(
          from: queued,
          episodeKey: episodeKey,
          state: .running,
          taskIdentifier: taskIdentifier
        )
      )
      try await transport.startTask(taskIdentifier: taskIdentifier)
    } catch {
      await transport.cancelTask(taskIdentifier: taskIdentifier)
      episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
      if let current = try? await store.localMediaRecord(for: episodeKey) {
        try? await saveFailed(current, error: .unknown, resumeData: resumeData)
      }
      throw DownloadManagerError.transport
    }
  }

  private func handleProgress(
    taskIdentifier: Int,
    downloadedBytes: Int64,
    contentLength: Int64?
  ) async {
    guard
      downloadedBytes >= 0,
      contentLength.map({ $0 >= downloadedBytes }) ?? true,
      let episodeKey = episodeByTaskIdentifier[taskIdentifier],
      let record = try? await store.localMediaRecord(for: episodeKey),
      record.taskIdentifier == taskIdentifier,
      record.state == .queued || record.state == .running
    else { return }
    let safeDownloadedBytes = max(record.downloadedBytes, downloadedBytes)
    let safeContentLength = contentLength ?? record.contentLength
    guard safeContentLength.map({ $0 >= safeDownloadedBytes }) ?? true else { return }
    try? await store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: episodeKey,
        state: .running,
        taskIdentifier: taskIdentifier,
        downloadedBytes: safeDownloadedBytes,
        contentLength: safeContentLength,
        eTag: record.eTag,
        lastModified: record.lastModified,
        updatedAtMilliseconds: timeMilliseconds()
      )
    )
  }

  private func handleCompletion(
    taskIdentifier: Int,
    stagedFileURL: URL,
    response: DownloadResponseMetadata
  ) async {
    guard
      let episodeKey = episodeByTaskIdentifier[taskIdentifier],
      let record = try? await store.localMediaRecord(for: episodeKey),
      record.taskIdentifier == taskIdentifier,
      record.state == .queued || record.state == .running
    else {
      fileStore.removeStagedFileIfOwned(stagedFileURL)
      return
    }
    guard
      (200..<300).contains(response.statusCode),
      let finalURL = response.finalURL,
      Self.isNetworkURL(finalURL),
      response.contentLength.map({ $0 > 0 }) ?? true
    else {
      fileStore.removeStagedFileIfOwned(stagedFileURL)
      try? await saveFailed(record, error: .invalidResponse, resumeData: nil)
      episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
      return
    }
    do {
      let placed = try fileStore.place(
        stagedFileURL: stagedFileURL,
        episodeKey: episodeKey,
        sourceURL: finalURL,
        mimeType: response.mimeType,
        expectedContentLength: response.contentLength ?? record.contentLength
      )
      try await store.saveLocalMediaRecord(
        LocalMediaRecord(
          episodeKey: episodeKey,
          state: .completed,
          localRelativePath: placed.relativePath,
          downloadedBytes: placed.byteCount,
          contentLength: response.contentLength ?? placed.byteCount,
          eTag: response.eTag,
          lastModified: response.lastModified,
          checksumSHA256: placed.checksumSHA256,
          updatedAtMilliseconds: timeMilliseconds()
        )
      )
      episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
      Task { await downloadDidComplete(episodeKey) }
    } catch let error as LocalMediaFileError {
      fileStore.removeStagedFileIfOwned(stagedFileURL)
      let code: DownloadErrorCode = error == .invalidFile ? .invalidResponse : .fileSystem
      try? await saveFailed(record, error: code, resumeData: nil)
      episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
    } catch {
      fileStore.removeStagedFileIfOwned(stagedFileURL)
      try? await saveFailed(record, error: .fileSystem, resumeData: nil)
      episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
    }
  }

  private func handleFailure(
    taskIdentifier: Int,
    resumeData: Data?,
    error: DownloadErrorCode
  ) async {
    guard
      let episodeKey = episodeByTaskIdentifier[taskIdentifier],
      let record = try? await store.localMediaRecord(for: episodeKey),
      record.taskIdentifier == taskIdentifier
    else { return }
    if record.state == .cancelling || error == .cancelled {
      try? await resetRecord(episodeKey)
    } else if record.state == .queued || record.state == .running {
      try? await saveFailed(record, error: error, resumeData: resumeData)
    }
    episodeByTaskIdentifier.removeValue(forKey: taskIdentifier)
  }

  private func requiredRecord(for episodeKey: EpisodeKey) async throws -> LocalMediaRecord {
    guard let record = try await store.localMediaRecord(for: episodeKey) else {
      throw DownloadManagerError.invalidState
    }
    return record
  }

  private func activeRecord(
    from record: LocalMediaRecord?,
    episodeKey: EpisodeKey,
    state: DownloadState,
    taskIdentifier: Int
  ) -> LocalMediaRecord {
    LocalMediaRecord(
      episodeKey: episodeKey,
      state: state,
      taskIdentifier: taskIdentifier,
      downloadedBytes: record?.downloadedBytes ?? 0,
      contentLength: record?.contentLength,
      eTag: record?.eTag,
      lastModified: record?.lastModified,
      updatedAtMilliseconds: timeMilliseconds()
    )
  }

  private func saveFailed(
    _ record: LocalMediaRecord,
    error: DownloadErrorCode,
    resumeData: Data?
  ) async throws {
    try await store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: record.episodeKey,
        state: .failed,
        resumeData: resumeData?.isEmpty == false ? resumeData : nil,
        downloadedBytes: record.downloadedBytes,
        contentLength: record.contentLength,
        eTag: record.eTag,
        lastModified: record.lastModified,
        lastError: error,
        updatedAtMilliseconds: timeMilliseconds()
      )
    )
  }

  private func resetRecord(_ episodeKey: EpisodeKey) async throws {
    try await store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: episodeKey,
        state: .notRequested,
        updatedAtMilliseconds: timeMilliseconds()
      )
    )
  }

  private static func isNetworkURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }
}
