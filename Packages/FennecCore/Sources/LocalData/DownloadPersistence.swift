import CoreContracts
import Foundation
import GRDB

public enum DownloadState: String, Codable, CaseIterable, Sendable {
  case notRequested = "not_requested"
  case queued
  case running
  case suspended
  case completed
  case cancelling
  case failed
}

public enum DownloadErrorCode: String, Codable, CaseIterable, Sendable {
  case invalidURL = "invalid_url"
  case invalidResponse = "invalid_response"
  case network
  case fileSystem = "file_system"
  case checksumMismatch = "checksum_mismatch"
  case insufficientSpace = "insufficient_space"
  case cancelled
  case unknown
}

public struct LocalMediaRecord: Equatable, Sendable {
  public let episodeKey: EpisodeKey
  public let state: DownloadState
  public let taskIdentifier: Int?
  public let localRelativePath: String?
  public let resumeData: Data?
  public let downloadedBytes: Int64
  public let contentLength: Int64?
  public let eTag: String?
  public let lastModified: String?
  public let checksumSHA256: String?
  public let lastError: DownloadErrorCode?
  public let updatedAtMilliseconds: Int64

  public init(
    episodeKey: EpisodeKey,
    state: DownloadState,
    taskIdentifier: Int? = nil,
    localRelativePath: String? = nil,
    resumeData: Data? = nil,
    downloadedBytes: Int64 = 0,
    contentLength: Int64? = nil,
    eTag: String? = nil,
    lastModified: String? = nil,
    checksumSHA256: String? = nil,
    lastError: DownloadErrorCode? = nil,
    updatedAtMilliseconds: Int64
  ) {
    self.episodeKey = episodeKey
    self.state = state
    self.taskIdentifier = taskIdentifier
    self.localRelativePath = localRelativePath
    self.resumeData = resumeData
    self.downloadedBytes = downloadedBytes
    self.contentLength = contentLength
    self.eTag = eTag
    self.lastModified = lastModified
    self.checksumSHA256 = checksumSHA256
    self.lastError = lastError
    self.updatedAtMilliseconds = updatedAtMilliseconds
  }
}

extension LocalDataStore {
  public func saveLocalMediaRecord(_ record: LocalMediaRecord) async throws {
    try await writer.write { db in
      guard
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM episodes WHERE episode_key = ?)",
          arguments: [record.episodeKey.rawValue]
        ) == true
      else {
        throw LocalDataError.episodeNotFound
      }

      let storedStateValue = try String.fetchOne(
        db,
        sql: "SELECT download_state FROM media_local WHERE episode_key = ?",
        arguments: [record.episodeKey.rawValue]
      )
      let storedState: DownloadState
      if let storedStateValue {
        guard let decoded = DownloadState(rawValue: storedStateValue) else {
          throw LocalDataError.corruptRecord("invalid download state")
        }
        storedState = decoded
      } else {
        storedState = .notRequested
      }
      guard Self.canTransitionDownload(from: storedState, to: record.state) else {
        throw LocalDataError.invalidDownloadTransition(from: storedState, to: record.state)
      }
      try Self.validateLocalMediaRecord(record)

      try db.execute(
        sql: """
          INSERT INTO media_local(
            episode_key, download_state, task_identifier, local_relative_path,
            resume_data, downloaded_bytes, etag, last_modified, content_length,
            checksum_sha256, last_error, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(episode_key) DO UPDATE SET
            download_state = excluded.download_state,
            task_identifier = excluded.task_identifier,
            local_relative_path = excluded.local_relative_path,
            resume_data = excluded.resume_data,
            downloaded_bytes = excluded.downloaded_bytes,
            etag = excluded.etag,
            last_modified = excluded.last_modified,
            content_length = excluded.content_length,
            checksum_sha256 = excluded.checksum_sha256,
            last_error = excluded.last_error,
            updated_at_ms = excluded.updated_at_ms
          """,
        arguments: [
          record.episodeKey.rawValue,
          record.state.rawValue,
          record.taskIdentifier,
          record.localRelativePath,
          record.resumeData,
          record.downloadedBytes,
          record.eTag,
          record.lastModified,
          record.contentLength,
          record.checksumSHA256,
          record.lastError?.rawValue,
          record.updatedAtMilliseconds,
        ]
      )
    }
  }

  public func localMediaRecord(for episodeKey: EpisodeKey) async throws -> LocalMediaRecord? {
    try await writer.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT * FROM media_local WHERE episode_key = ?",
        arguments: [episodeKey.rawValue]
      ).map(Self.decodeLocalMediaRecord)
    }
  }

  public func localMediaRecords(states: Set<DownloadState>) async throws -> [LocalMediaRecord] {
    guard !states.isEmpty else { return [] }
    let rawStates = states.map(\.rawValue).sorted()
    let placeholders = Array(repeating: "?", count: rawStates.count).joined(separator: ", ")
    return try await writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM media_local
          WHERE download_state IN (\(placeholders))
          ORDER BY updated_at_ms DESC, episode_key ASC
          """,
        arguments: StatementArguments(rawStates)
      ).map(Self.decodeLocalMediaRecord)
    }
  }

  private static func canTransitionDownload(
    from oldState: DownloadState,
    to newState: DownloadState
  ) -> Bool {
    guard oldState != newState else { return true }
    switch oldState {
    case .notRequested:
      return newState == .queued
    case .queued:
      return [.running, .suspended, .completed, .cancelling, .failed].contains(newState)
    case .running:
      return [.suspended, .completed, .cancelling, .failed].contains(newState)
    case .suspended:
      return [.notRequested, .queued, .running, .cancelling, .failed].contains(newState)
    case .completed:
      return newState == .notRequested
    case .cancelling:
      return [.notRequested, .failed].contains(newState)
    case .failed:
      return [.notRequested, .queued].contains(newState)
    }
  }

  private static func validateLocalMediaRecord(_ record: LocalMediaRecord) throws {
    guard
      record.updatedAtMilliseconds >= 0,
      record.downloadedBytes >= 0,
      record.contentLength.map({ $0 >= record.downloadedBytes }) ?? true,
      record.taskIdentifier.map({ $0 >= 0 }) ?? true,
      record.checksumSHA256.map(isValidSHA256) ?? true
    else {
      throw LocalDataError.invalidDownloadMetadata
    }

    if let path = record.localRelativePath {
      try validateLocalMediaPath(path)
    }

    let metadataIsValid: Bool
    switch record.state {
    case .notRequested:
      metadataIsValid =
        record.taskIdentifier == nil && record.localRelativePath == nil
        && record.resumeData == nil && record.downloadedBytes == 0 && record.lastError == nil
    case .queued, .running:
      metadataIsValid =
        record.taskIdentifier != nil && record.localRelativePath == nil
        && record.resumeData == nil && record.lastError == nil
    case .suspended:
      metadataIsValid =
        record.taskIdentifier == nil && record.localRelativePath == nil
        && record.resumeData?.isEmpty == false && record.lastError == nil
    case .completed:
      metadataIsValid =
        record.taskIdentifier == nil && record.localRelativePath != nil
        && record.resumeData == nil && record.downloadedBytes > 0 && record.lastError == nil
    case .cancelling:
      metadataIsValid =
        record.taskIdentifier != nil && record.localRelativePath == nil
        && record.resumeData == nil && record.lastError == nil
    case .failed:
      metadataIsValid =
        record.taskIdentifier == nil && record.localRelativePath == nil && record.lastError != nil
    }
    guard metadataIsValid else {
      throw LocalDataError.invalidDownloadMetadata
    }
  }

  private static func validateLocalMediaPath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !path.hasPrefix("/"),
      URL(string: path)?.scheme == nil,
      !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw LocalDataError.invalidLocalMediaPath
    }
  }

  private static func isValidSHA256(_ value: String) -> Bool {
    guard value.count == 64 else { return false }
    return value.allSatisfy { character in
      character.isNumber || ("a"..."f").contains(String(character))
    }
  }

  private static func decodeLocalMediaRecord(_ row: Row) throws -> LocalMediaRecord {
    let episodeKeyValue: String = row["episode_key"]
    let stateValue: String = row["download_state"]
    guard let state = DownloadState(rawValue: stateValue) else {
      throw LocalDataError.corruptRecord("invalid local media identity or state")
    }
    let episodeKey = EpisodeKey(rawValue: episodeKeyValue)
    let errorValue: String? = row["last_error"]
    let lastError: DownloadErrorCode?
    if let errorValue {
      guard let decoded = DownloadErrorCode(rawValue: errorValue) else {
        throw LocalDataError.corruptRecord("invalid download error")
      }
      lastError = decoded
    } else {
      lastError = nil
    }
    return LocalMediaRecord(
      episodeKey: episodeKey,
      state: state,
      taskIdentifier: row["task_identifier"],
      localRelativePath: row["local_relative_path"],
      resumeData: row["resume_data"],
      downloadedBytes: row["downloaded_bytes"],
      contentLength: row["content_length"],
      eTag: row["etag"],
      lastModified: row["last_modified"],
      checksumSHA256: row["checksum_sha256"],
      lastError: lastError,
      updatedAtMilliseconds: row["updated_at_ms"]
    )
  }
}
