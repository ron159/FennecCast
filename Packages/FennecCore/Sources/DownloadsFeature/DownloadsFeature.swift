import CoreContracts
import Foundation
import LocalData

public enum DownloadManagerError: Error, Equatable, Sendable {
  case missingMediaSource
  case unsupportedMediaSource
  case alreadyRequested
  case invalidState
  case missingResumeData
  case transport
}

public struct DownloadResponseMetadata: Equatable, Sendable {
  public let statusCode: Int
  public let finalURL: URL?
  public let contentLength: Int64?
  public let mimeType: String?
  public let eTag: String?
  public let lastModified: String?

  public init(
    statusCode: Int,
    finalURL: URL?,
    contentLength: Int64?,
    mimeType: String?,
    eTag: String?,
    lastModified: String?
  ) {
    self.statusCode = statusCode
    self.finalURL = finalURL
    self.contentLength = contentLength
    self.mimeType = mimeType
    self.eTag = eTag
    self.lastModified = lastModified
  }
}

public enum DownloadTransportTaskState: Equatable, Sendable {
  case running
  case suspended
  case cancelling
}

public struct DownloadTransportTask: Equatable, Sendable {
  public let taskIdentifier: Int
  public let episodeKey: EpisodeKey
  public let originalURL: URL?
  public let state: DownloadTransportTaskState

  public init(
    taskIdentifier: Int,
    episodeKey: EpisodeKey,
    originalURL: URL?,
    state: DownloadTransportTaskState
  ) {
    self.taskIdentifier = taskIdentifier
    self.episodeKey = episodeKey
    self.originalURL = originalURL
    self.state = state
  }
}

public enum DownloadTransportEvent: Equatable, Sendable {
  case progress(taskIdentifier: Int, downloadedBytes: Int64, contentLength: Int64?)
  case completed(
    taskIdentifier: Int,
    stagedFileURL: URL,
    response: DownloadResponseMetadata
  )
  case failed(taskIdentifier: Int, resumeData: Data?, error: DownloadErrorCode)
}

public protocol DownloadTransporting: Sendable {
  func setEventHandler(
    _ handler: @escaping @Sendable (DownloadTransportEvent) async -> Void
  ) async
  func makeTask(episodeKey: EpisodeKey, url: URL, resumeData: Data?) async throws -> Int
  func startTask(taskIdentifier: Int) async throws
  func suspendTask(taskIdentifier: Int) async throws -> Data?
  func cancelTask(taskIdentifier: Int) async
  func currentTasks() async -> [DownloadTransportTask]
}
