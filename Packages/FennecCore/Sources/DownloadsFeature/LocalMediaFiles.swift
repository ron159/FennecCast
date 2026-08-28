import CoreContracts
import CryptoKit
import Foundation
import LocalData
import PlaybackFeature

enum LocalMediaFileError: Error {
  case invalidPath
  case invalidFile
  case fileSystem
}

struct PlacedMediaFile {
  let relativePath: String
  let byteCount: Int64
  let checksumSHA256: String
}

struct LocalMediaFileStore: Sendable {
  let storageRoot: URL

  private var mediaDirectory: URL {
    storageRoot.appendingPathComponent("Media", isDirectory: true)
  }

  private var stagingDirectory: URL {
    storageRoot.appendingPathComponent("Staging", isDirectory: true)
  }

  func place(
    stagedFileURL: URL,
    episodeKey: EpisodeKey,
    sourceURL: URL,
    mimeType: String?,
    expectedContentLength: Int64?
  ) throws -> PlacedMediaFile {
    guard isDescendant(stagedFileURL, of: stagingDirectory) else {
      throw LocalMediaFileError.invalidPath
    }
    let byteCount = try regularFileSize(at: stagedFileURL)
    guard
      byteCount > 0,
      expectedContentLength.map({ $0 == byteCount }) ?? true
    else {
      throw LocalMediaFileError.invalidFile
    }
    let checksum = try sha256(at: stagedFileURL)
    let fileExtension = allowedExtension(sourceURL: sourceURL, mimeType: mimeType)
    let filename = "\(episodeKey.rawValue).\(fileExtension)"
    let destination = mediaDirectory.appendingPathComponent(filename, isDirectory: false)
    guard isDescendant(destination, of: mediaDirectory) else {
      throw LocalMediaFileError.invalidPath
    }

    do {
      try FileManager.default.createDirectory(
        at: mediaDirectory,
        withIntermediateDirectories: true
      )
      guard isDescendant(destination, of: mediaDirectory) else {
        throw LocalMediaFileError.invalidPath
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(
          destination,
          withItemAt: stagedFileURL,
          backupItemName: nil,
          options: .usingNewMetadataOnly
        )
      } else {
        try FileManager.default.moveItem(at: stagedFileURL, to: destination)
      }
    } catch let error as LocalMediaFileError {
      throw error
    } catch {
      throw LocalMediaFileError.fileSystem
    }
    return PlacedMediaFile(
      relativePath: "Media/\(filename)",
      byteCount: byteCount,
      checksumSHA256: checksum
    )
  }

  func verifiedURL(for record: LocalMediaRecord) throws -> URL {
    guard
      record.state == .completed,
      let relativePath = record.localRelativePath
    else {
      throw LocalMediaFileError.invalidFile
    }
    let url = try resolve(relativePath: relativePath)
    let byteCount = try regularFileSize(at: url)
    guard
      byteCount > 0,
      record.downloadedBytes == byteCount,
      record.contentLength.map({ $0 == byteCount }) ?? true
    else {
      throw LocalMediaFileError.invalidFile
    }
    if let expectedChecksum = record.checksumSHA256 {
      guard try sha256(at: url) == expectedChecksum else {
        throw LocalMediaFileError.invalidFile
      }
    }
    return url
  }

  func remove(relativePath: String) throws {
    let url = try resolve(relativePath: relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw LocalMediaFileError.fileSystem
    }
  }

  func removeStagedFileIfOwned(_ url: URL) {
    guard isDescendant(url, of: stagingDirectory) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  private func resolve(relativePath: String) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !relativePath.hasPrefix("/"),
      URL(string: relativePath)?.scheme == nil,
      !components.isEmpty,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw LocalMediaFileError.invalidPath
    }
    let url = storageRoot.appendingPathComponent(relativePath, isDirectory: false)
    guard isDescendant(url, of: storageRoot) else {
      throw LocalMediaFileError.invalidPath
    }
    return url
  }

  private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
    let parentPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    return candidatePath.hasPrefix(parentPath + "/")
  }

  private func regularFileSize(at url: URL) throws -> Int64 {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, let size = values.fileSize else {
        throw LocalMediaFileError.invalidFile
      }
      return Int64(size)
    } catch let error as LocalMediaFileError {
      throw error
    } catch {
      throw LocalMediaFileError.fileSystem
    }
  }

  private func sha256(at url: URL) throws -> String {
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hasher = SHA256()
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    } catch {
      throw LocalMediaFileError.fileSystem
    }
  }

  private func allowedExtension(sourceURL: URL, mimeType: String?) -> String {
    let extensions = Set(["aac", "flac", "m4a", "mp3", "mp4", "ogg", "opus", "wav"])
    let sourceExtension = sourceURL.pathExtension.lowercased()
    if extensions.contains(sourceExtension) {
      return sourceExtension
    }
    switch mimeType?.lowercased() {
    case "audio/aac":
      return "aac"
    case "audio/flac":
      return "flac"
    case "audio/m4a", "audio/mp4", "audio/x-m4a":
      return "m4a"
    case "audio/mpeg":
      return "mp3"
    case "audio/ogg":
      return "ogg"
    case "audio/opus":
      return "opus"
    case "audio/wav", "audio/x-wav":
      return "wav"
    case "video/mp4":
      return "mp4"
    default:
      return "media"
    }
  }
}

public struct LocalFirstPlaybackSourceResolver: PlaybackSourceResolving {
  private let store: LocalDataStore
  private let fileStore: LocalMediaFileStore
  private let streamingResolver = StreamingPlaybackSourceResolver()

  public init(store: LocalDataStore, storageRoot: URL) {
    self.store = store
    self.fileStore = LocalMediaFileStore(storageRoot: storageRoot)
  }

  public func sourceURL(for episode: StoredEpisode) async throws -> URL {
    if let record = try await store.localMediaRecord(for: episode.episodeKey),
      let localURL = try? fileStore.verifiedURL(for: record)
    {
      return localURL
    }
    return try await streamingResolver.sourceURL(for: episode)
  }
}
