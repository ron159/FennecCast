import Foundation

public enum FeedFormat: Equatable, Sendable {
  case rss
  case atom
}

public enum FeedParseError: Error, Equatable, Sendable {
  case malformedXML
  case unsupportedDocument
  case missingFeedTitle
  case prohibitedDTD
}

public struct ParsedFeed: Equatable, Sendable {
  public let format: FeedFormat
  public let title: String
  public let author: String?
  public let summaryHTML: String?
  public let imageURL: URL?
  public let episodes: [ParsedEpisode]

  public init(
    format: FeedFormat,
    title: String,
    author: String?,
    summaryHTML: String?,
    imageURL: URL?,
    episodes: [ParsedEpisode]
  ) {
    self.format = format
    self.title = title
    self.author = author
    self.summaryHTML = summaryHTML
    self.imageURL = imageURL
    self.episodes = episodes
  }
}

public struct ParsedEpisode: Equatable, Sendable {
  public let guid: String?
  public let enclosureURL: URL?
  public let linkURL: URL?
  public let title: String
  public let publicationDate: Date?
  public let durationMilliseconds: Int64?
  public let summaryHTML: String?
  public let mimeType: String?
  public let transcriptURL: URL?
  public let transcriptType: String?
  public let chaptersURL: URL?
  public let chaptersType: String?

  public init(
    guid: String?,
    enclosureURL: URL?,
    linkURL: URL?,
    title: String,
    publicationDate: Date?,
    durationMilliseconds: Int64?,
    summaryHTML: String?,
    mimeType: String?,
    transcriptURL: URL? = nil,
    transcriptType: String? = nil,
    chaptersURL: URL? = nil,
    chaptersType: String? = nil
  ) {
    self.guid = guid
    self.enclosureURL = enclosureURL
    self.linkURL = linkURL
    self.title = title
    self.publicationDate = publicationDate
    self.durationMilliseconds = durationMilliseconds
    self.summaryHTML = summaryHTML
    self.mimeType = mimeType
    self.transcriptURL = transcriptURL
    self.transcriptType = transcriptType
    self.chaptersURL = chaptersURL
    self.chaptersType = chaptersType
  }
}
