import Foundation

public protocol SupplementalContentDataLoading: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionSupplementalContentLoader: SupplementalContentDataLoading {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }
}

public enum SupplementalContentError: Error, Equatable, Sendable {
  case invalidURL
  case invalidResponse
  case responseTooLarge
  case unsupportedFormat
  case malformedContent
}

public struct TranscriptCue: Equatable, Sendable {
  public let startMilliseconds: Int64
  public let endMilliseconds: Int64?
  public let text: String

  public init(startMilliseconds: Int64, endMilliseconds: Int64?, text: String) throws {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      startMilliseconds >= 0,
      endMilliseconds.map({ $0 >= startMilliseconds }) ?? true,
      !normalized.isEmpty
    else {
      throw SupplementalContentError.malformedContent
    }
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.text = normalized
  }
}

public struct EpisodeTranscript: Equatable, Sendable {
  public let plainText: String
  public let cues: [TranscriptCue]

  public init(plainText: String, cues: [TranscriptCue]) throws {
    let normalized = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw SupplementalContentError.malformedContent
    }
    self.plainText = normalized
    self.cues = cues
  }
}

public struct SupplementalContentClient: Sendable {
  public static let defaultMaximumBodyBytes = 2 * 1_024 * 1_024

  private let loader: any SupplementalContentDataLoading
  private let maximumBodyBytes: Int

  public init(
    loader: any SupplementalContentDataLoading = URLSessionSupplementalContentLoader(),
    maximumBodyBytes: Int = Self.defaultMaximumBodyBytes
  ) {
    self.loader = loader
    self.maximumBodyBytes = max(1, maximumBodyBytes)
  }

  public func transcript(from url: URL, declaredType: String?) async throws -> EpisodeTranscript {
    let (data, responseType) = try await fetch(url)
    let contentType = normalizedContentType(declaredType) ?? responseType
    switch contentType {
    case "text/vtt":
      return try parseWebVTT(data)
    case "text/plain", "text/html":
      return try parsePlainText(data)
    case "application/srt", "application/x-subrip", "text/srt":
      return try parseSubRip(data)
    case "application/json", "application/json+transcript":
      return try parseJSONTranscript(data)
    default:
      throw SupplementalContentError.unsupportedFormat
    }
  }

  public func chapters(from url: URL) async throws -> [PlaybackChapter] {
    let (data, _) = try await fetch(url)
    let envelope: ChapterEnvelope
    do {
      envelope = try JSONDecoder().decode(ChapterEnvelope.self, from: data)
    } catch {
      throw SupplementalContentError.malformedContent
    }
    guard !envelope.chapters.isEmpty else {
      throw SupplementalContentError.malformedContent
    }

    var result: [PlaybackChapter] = []
    for chapter in envelope.chapters {
      guard
        chapter.startTime.isFinite,
        chapter.startTime >= 0,
        chapter.startTime <= Double(Int64.max) / 1_000
      else {
        throw SupplementalContentError.malformedContent
      }
      let linkURL = chapter.url.flatMap(URL.init(string:)).flatMap(Self.networkURL)
      let imageURL = chapter.img.flatMap(URL.init(string:)).flatMap(Self.networkURL)
      do {
        result.append(
          try PlaybackChapter(
            startMilliseconds: Int64((chapter.startTime * 1_000).rounded()),
            title: chapter.title,
            source: .podcastIndex,
            linkURL: linkURL,
            imageURL: imageURL
          )
        )
      } catch {
        throw SupplementalContentError.malformedContent
      }
    }
    return ChapterMerger.merge(result)
  }

  private func fetch(_ url: URL) async throws -> (Data, String?) {
    guard Self.networkURL(url) != nil else {
      throw SupplementalContentError.invalidURL
    }
    var request = URLRequest(
      url: url,
      cachePolicy: .returnCacheDataElseLoad,
      timeoutInterval: 30
    )
    request.setValue(
      "text/vtt, text/plain, application/json;q=0.9",
      forHTTPHeaderField: "Accept"
    )
    let (data, response) = try await loader.data(for: request)
    guard
      let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      let finalURL = response.url,
      Self.networkURL(finalURL) != nil
    else {
      throw SupplementalContentError.invalidResponse
    }
    guard
      response.expectedContentLength <= 0
        || response.expectedContentLength <= Int64(maximumBodyBytes),
      data.count <= maximumBodyBytes
    else {
      throw SupplementalContentError.responseTooLarge
    }
    return (
      data,
      normalizedContentType(response.value(forHTTPHeaderField: "Content-Type"))
    )
  }

  private func parsePlainText(_ data: Data) throws -> EpisodeTranscript {
    guard let text = String(data: data, encoding: .utf8) else {
      throw SupplementalContentError.malformedContent
    }
    return try EpisodeTranscript(plainText: text, cues: [])
  }

  private func parseWebVTT(_ data: Data) throws -> EpisodeTranscript {
    guard var text = String(data: data, encoding: .utf8) else {
      throw SupplementalContentError.malformedContent
    }
    if text.hasPrefix("\u{feff}") {
      text.removeFirst()
    }
    let lines = text.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "WEBVTT" else {
      throw SupplementalContentError.malformedContent
    }
    var cues: [TranscriptCue] = []
    var index = 1
    while index < lines.count {
      let line = lines[index].trimmingCharacters(in: .whitespaces)
      guard line.contains("-->") else {
        index += 1
        continue
      }
      let timestamps = line.components(separatedBy: "-->")
      guard
        timestamps.count == 2,
        let start = parseVTTTimestamp(timestamps[0]),
        let endToken = timestamps[1].split(whereSeparator: \.isWhitespace).first,
        let end = parseVTTTimestamp(String(endToken))
      else {
        throw SupplementalContentError.malformedContent
      }
      index += 1
      var cueLines: [String] = []
      while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
        cueLines.append(lines[index])
        index += 1
      }
      do {
        cues.append(
          try TranscriptCue(
            startMilliseconds: start,
            endMilliseconds: end,
            text: cueLines.joined(separator: "\n")
          )
        )
      } catch {
        throw SupplementalContentError.malformedContent
      }
    }
    guard !cues.isEmpty else {
      throw SupplementalContentError.malformedContent
    }
    return try EpisodeTranscript(
      plainText: cues.map(\.text).joined(separator: "\n\n"),
      cues: cues
    )
  }

  private func parseSubRip(_ data: Data) throws -> EpisodeTranscript {
    guard let text = String(data: data, encoding: .utf8) else {
      throw SupplementalContentError.malformedContent
    }
    let lines = text.components(separatedBy: .newlines)
    var cues: [TranscriptCue] = []
    var index = 0
    while index < lines.count {
      let line = lines[index].trimmingCharacters(in: .whitespaces)
      guard line.contains("-->") else {
        index += 1
        continue
      }
      let timestamps = line.components(separatedBy: "-->")
      guard
        timestamps.count == 2,
        let start = parseVTTTimestamp(timestamps[0].replacingOccurrences(of: ",", with: ".")),
        let end = parseVTTTimestamp(timestamps[1].replacingOccurrences(of: ",", with: "."))
      else {
        throw SupplementalContentError.malformedContent
      }
      index += 1
      var cueLines: [String] = []
      while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
        cueLines.append(lines[index])
        index += 1
      }
      do {
        cues.append(
          try TranscriptCue(
            startMilliseconds: start,
            endMilliseconds: end,
            text: cueLines.joined(separator: "\n")
          )
        )
      } catch {
        throw SupplementalContentError.malformedContent
      }
    }
    guard !cues.isEmpty else {
      throw SupplementalContentError.malformedContent
    }
    return try EpisodeTranscript(
      plainText: cues.map(\.text).joined(separator: "\n\n"),
      cues: cues
    )
  }

  private func parseJSONTranscript(_ data: Data) throws -> EpisodeTranscript {
    let envelope: TranscriptEnvelope
    do {
      envelope = try JSONDecoder().decode(TranscriptEnvelope.self, from: data)
    } catch {
      throw SupplementalContentError.malformedContent
    }
    guard !envelope.segments.isEmpty else {
      throw SupplementalContentError.malformedContent
    }
    var cues: [TranscriptCue] = []
    for segment in envelope.segments {
      guard
        segment.startTime.isFinite,
        segment.startTime >= 0,
        segment.startTime <= Double(Int64.max) / 1_000,
        segment.endTime.map({
          $0.isFinite && $0 >= segment.startTime && $0 <= Double(Int64.max) / 1_000
        }) ?? true,
        let text = segment.body ?? segment.text
      else {
        throw SupplementalContentError.malformedContent
      }
      do {
        cues.append(
          try TranscriptCue(
            startMilliseconds: Int64((segment.startTime * 1_000).rounded()),
            endMilliseconds: segment.endTime.map { Int64(($0 * 1_000).rounded()) },
            text: text
          )
        )
      } catch {
        throw SupplementalContentError.malformedContent
      }
    }
    return try EpisodeTranscript(
      plainText: cues.map(\.text).joined(separator: "\n\n"),
      cues: cues
    )
  }

  private func parseVTTTimestamp(_ value: String) -> Int64? {
    let fields = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
    guard fields.count == 2 || fields.count == 3 else { return nil }
    let hours: Double
    let minutes: Double
    let seconds: Double
    if fields.count == 3 {
      guard
        let parsedHours = Double(fields[0]),
        let parsedMinutes = Double(fields[1]),
        let parsedSeconds = Double(fields[2])
      else { return nil }
      hours = parsedHours
      minutes = parsedMinutes
      seconds = parsedSeconds
    } else {
      guard
        let parsedMinutes = Double(fields[0]),
        let parsedSeconds = Double(fields[1])
      else { return nil }
      hours = 0
      minutes = parsedMinutes
      seconds = parsedSeconds
    }
    let total = hours * 3_600 + minutes * 60 + seconds
    guard
      total.isFinite,
      hours >= 0,
      minutes >= 0,
      minutes < 60,
      seconds >= 0,
      seconds < 60,
      total <= Double(Int64.max) / 1_000
    else { return nil }
    return Int64((total * 1_000).rounded())
  }

  private func normalizedContentType(_ value: String?) -> String? {
    value?
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func networkURL(_ url: URL) -> URL? {
    guard
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host?.isEmpty == false
    else { return nil }
    return url
  }
}

private struct ChapterEnvelope: Decodable {
  let chapters: [ChapterPayload]
}

private struct ChapterPayload: Decodable {
  let startTime: Double
  let title: String
  let url: String?
  let img: String?
}

private struct TranscriptEnvelope: Decodable {
  let segments: [TranscriptSegment]
}

private struct TranscriptSegment: Decodable {
  let startTime: Double
  let endTime: Double?
  let body: String?
  let text: String?
}
