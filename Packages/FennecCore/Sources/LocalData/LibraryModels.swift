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
  public let transcriptURL: URL?
  public let transcriptType: String?
  public let chaptersURL: URL?
  public let chaptersType: String?

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
    mimeType: String?,
    transcriptURL: URL? = nil,
    transcriptType: String? = nil,
    chaptersURL: URL? = nil,
    chaptersType: String? = nil
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
    self.transcriptURL = transcriptURL
    self.transcriptType = transcriptType
    self.chaptersURL = chaptersURL
    self.chaptersType = chaptersType
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

public struct StoredQueueItem: Equatable, Sendable {
  public let state: VersionedState<QueueEntryState>
  public let episode: StoredEpisode?

  public var episodeKey: EpisodeKey { state.value.episodeKey }
  public var orderToken: FractionalIndex { state.value.orderToken }

  public init(
    state: VersionedState<QueueEntryState>,
    episode: StoredEpisode?
  ) {
    self.state = state
    self.episode = episode
  }
}

public struct FeedPreferences: Equatable, Sendable {
  public static let `default` = FeedPreferences()

  public let autoDownload: Bool
  public let autoDeletePlayed: Bool
  public let downloadRetentionLimit: Int?
  public let playbackRate: Float?
  public let skipIntroMilliseconds: Int64
  public let skipEndingMilliseconds: Int64
  public let tags: [String]

  public init(
    autoDownload: Bool = false,
    autoDeletePlayed: Bool = false,
    downloadRetentionLimit: Int? = nil,
    playbackRate: Float? = nil,
    skipIntroMilliseconds: Int64 = 0,
    skipEndingMilliseconds: Int64 = 0,
    tags: [String] = []
  ) {
    self.autoDownload = autoDownload
    self.autoDeletePlayed = autoDeletePlayed
    self.downloadRetentionLimit = downloadRetentionLimit
    self.playbackRate = playbackRate
    self.skipIntroMilliseconds = skipIntroMilliseconds
    self.skipEndingMilliseconds = skipEndingMilliseconds
    self.tags = tags
  }
}

public struct FeedStatistics: Equatable, Sendable {
  public let feedKey: FeedKey
  public let feedTitle: String
  public let listeningMilliseconds: Int64
  public let completedEpisodeCount: Int
  public let downloadedBytes: Int64

  public init(
    feedKey: FeedKey,
    feedTitle: String,
    listeningMilliseconds: Int64,
    completedEpisodeCount: Int,
    downloadedBytes: Int64
  ) {
    self.feedKey = feedKey
    self.feedTitle = feedTitle
    self.listeningMilliseconds = listeningMilliseconds
    self.completedEpisodeCount = completedEpisodeCount
    self.downloadedBytes = downloadedBytes
  }
}

public struct LibraryStatistics: Equatable, Sendable {
  public let listeningMilliseconds: Int64
  public let completedEpisodeCount: Int
  public let downloadedBytes: Int64
  public let feeds: [FeedStatistics]

  public init(
    listeningMilliseconds: Int64,
    completedEpisodeCount: Int,
    downloadedBytes: Int64,
    feeds: [FeedStatistics]
  ) {
    self.listeningMilliseconds = listeningMilliseconds
    self.completedEpisodeCount = completedEpisodeCount
    self.downloadedBytes = downloadedBytes
    self.feeds = feeds
  }
}

public enum EpisodeListFilter: Equatable, Sendable {
  case all
  case inbox
  case favorites
  case unplayed
  case archived
}

public enum EpisodePlaybackFilter: CaseIterable, Equatable, Hashable, Sendable {
  case any
  case played
  case unplayed
  case inProgress
  case notInProgress
}

public enum EpisodeQueueFilter: CaseIterable, Equatable, Hashable, Sendable {
  case any
  case queued
  case notQueued
}

public enum EpisodeDownloadFilter: CaseIterable, Equatable, Hashable, Sendable {
  case any
  case downloaded
  case notDownloaded
}

public enum EpisodeMediaFilter: CaseIterable, Equatable, Hashable, Sendable {
  case any
  case hasMedia
  case noMedia
}

public struct EpisodeListCriteria: Equatable, Hashable, Sendable {
  public static let all = EpisodeListCriteria()

  public var inbox: Bool?
  public var favorite: Bool?
  public var archived: Bool?
  public var playback: EpisodePlaybackFilter
  public var queue: EpisodeQueueFilter
  public var download: EpisodeDownloadFilter
  public var media: EpisodeMediaFilter

  public init(
    inbox: Bool? = nil,
    favorite: Bool? = nil,
    archived: Bool? = nil,
    playback: EpisodePlaybackFilter = .any,
    queue: EpisodeQueueFilter = .any,
    download: EpisodeDownloadFilter = .any,
    media: EpisodeMediaFilter = .any
  ) {
    self.inbox = inbox
    self.favorite = favorite
    self.archived = archived
    self.playback = playback
    self.queue = queue
    self.download = download
    self.media = media
  }

  public var isEmpty: Bool { self == .all }
}

public enum EpisodeListSort: CaseIterable, Equatable, Hashable, Sendable {
  case newestFirst
  case oldestFirst
  case episodeTitleAscending
  case episodeTitleDescending
  case podcastTitleAscending
  case podcastTitleDescending
  case durationShortestFirst
  case durationLongestFirst
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
