import Foundation

public enum PlaybackChapterSource: Int, Codable, Equatable, Hashable, Sendable {
  case feed = 0
  case podcastIndex = 1
  case embedded = 2
}

public struct PlaybackChapter: Codable, Equatable, Hashable, Sendable {
  public let startMilliseconds: Int64
  public let title: String
  public let source: PlaybackChapterSource
  public let linkURL: URL?
  public let imageURL: URL?

  public init(
    startMilliseconds: Int64,
    title: String,
    source: PlaybackChapterSource,
    linkURL: URL? = nil,
    imageURL: URL? = nil
  ) throws {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard startMilliseconds >= 0, !normalizedTitle.isEmpty else {
      throw PlaybackPolicyError.invalidChapter
    }
    self.startMilliseconds = startMilliseconds
    self.title = normalizedTitle
    self.source = source
    self.linkURL = linkURL
    self.imageURL = imageURL
  }
}

public enum ChapterMerger {
  public static func merge(_ chapters: [PlaybackChapter]) -> [PlaybackChapter] {
    Dictionary(grouping: chapters, by: \.startMilliseconds)
      .compactMap { _, candidates in
        candidates.sorted(by: isPreferred).first
      }
      .sorted { lhs, rhs in
        if lhs.startMilliseconds != rhs.startMilliseconds {
          return lhs.startMilliseconds < rhs.startMilliseconds
        }
        return lhs.title < rhs.title
      }
  }

  private static func isPreferred(_ lhs: PlaybackChapter, _ rhs: PlaybackChapter) -> Bool {
    if lhs.source != rhs.source {
      return lhs.source.rawValue > rhs.source.rawValue
    }
    return lhs.title < rhs.title
  }
}
