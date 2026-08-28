import CoreContracts
import Foundation

public struct FeedMetadata: Equatable, Sendable {
  public let feedKey: FeedKey
  public let canonicalURL: URL
  public let title: String
  public let author: String?
  public let summaryHTML: String?
  public let imageURL: URL?
  public let eTag: String?
  public let lastModified: String?

  public init(
    feedKey: FeedKey,
    canonicalURL: URL,
    title: String,
    author: String?,
    summaryHTML: String?,
    imageURL: URL?,
    eTag: String?,
    lastModified: String?
  ) {
    self.feedKey = feedKey
    self.canonicalURL = canonicalURL
    self.title = title
    self.author = author
    self.summaryHTML = summaryHTML
    self.imageURL = imageURL
    self.eTag = eTag
    self.lastModified = lastModified
  }
}

public struct EpisodeMetadata: Equatable, Sendable {
  public let episodeKey: EpisodeKey
  public let feedKey: FeedKey
  public let guid: String?
  public let enclosureURL: URL?
  public let linkURL: URL?
  public let title: String
  public let publicationDateMilliseconds: Int64?
  public let durationMilliseconds: Int64?
  public let summaryHTML: String?
  public let mimeType: String?

  public init(
    episodeKey: EpisodeKey,
    feedKey: FeedKey,
    guid: String?,
    enclosureURL: URL?,
    linkURL: URL?,
    title: String,
    publicationDateMilliseconds: Int64?,
    durationMilliseconds: Int64?,
    summaryHTML: String?,
    mimeType: String?
  ) {
    self.episodeKey = episodeKey
    self.feedKey = feedKey
    self.guid = guid
    self.enclosureURL = enclosureURL
    self.linkURL = linkURL
    self.title = title
    self.publicationDateMilliseconds = publicationDateMilliseconds
    self.durationMilliseconds = durationMilliseconds
    self.summaryHTML = summaryHTML
    self.mimeType = mimeType
  }
}

public struct StoredFeed: Equatable, Sendable {
  public let metadata: FeedMetadata
  public let subscribed: Bool
  public let archived: Bool
  public let lastRefreshAtMilliseconds: Int64?

  public var feedKey: FeedKey { metadata.feedKey }
  public var title: String { metadata.title }

  public init(
    metadata: FeedMetadata,
    subscribed: Bool,
    archived: Bool,
    lastRefreshAtMilliseconds: Int64?
  ) {
    self.metadata = metadata
    self.subscribed = subscribed
    self.archived = archived
    self.lastRefreshAtMilliseconds = lastRefreshAtMilliseconds
  }
}

public struct StoredEpisode: Equatable, Sendable {
  public let metadata: EpisodeMetadata
  public let feedTitle: String
  public let inbox: Bool
  public let favorite: Bool
  public let archived: Bool
  public let played: Bool
  public let positionMilliseconds: Int64
  public let playedDurationMilliseconds: Int64

  public var episodeKey: EpisodeKey { metadata.episodeKey }
  public var title: String { metadata.title }

  public init(
    metadata: EpisodeMetadata,
    feedTitle: String,
    inbox: Bool,
    favorite: Bool,
    archived: Bool,
    played: Bool,
    positionMilliseconds: Int64,
    playedDurationMilliseconds: Int64
  ) {
    self.metadata = metadata
    self.feedTitle = feedTitle
    self.inbox = inbox
    self.favorite = favorite
    self.archived = archived
    self.played = played
    self.positionMilliseconds = positionMilliseconds
    self.playedDurationMilliseconds = playedDurationMilliseconds
  }
}

public enum EpisodeListFilter: Equatable, Sendable {
  case all
  case inbox
  case favorites
  case unplayed
  case archived
}

public enum EpisodeListSort: Equatable, Sendable {
  case newestFirst
  case oldestFirst
}

public struct FeedRefreshResult: Equatable, Sendable {
  public let insertedEpisodeKeys: [EpisodeKey]

  public init(insertedEpisodeKeys: [EpisodeKey]) {
    self.insertedEpisodeKeys = insertedEpisodeKeys
  }
}

public struct InitialSubscriptionResult: Equatable, Sendable {
  public let insertedEpisodeKeys: [EpisodeKey]
  public let subscriptionMutation: SyncMutation

  public init(insertedEpisodeKeys: [EpisodeKey], subscriptionMutation: SyncMutation) {
    self.insertedEpisodeKeys = insertedEpisodeKeys
    self.subscriptionMutation = subscriptionMutation
  }
}
