import CoreContracts
import Foundation
import LocalData

public enum FeedLibraryError: Error, Equatable, Sendable {
  case unexpectedNotModified
  case redirectedExistingFeedRequiresMigration
}

public enum FeedRefreshOutcome: Equatable, Sendable {
  case notModified
  case updated(FeedRefreshResult)
}

public actor FeedLibraryService {
  private let store: LocalDataStore
  private let httpClient: FeedHTTPClient
  private let parser: FeedDocumentParser
  private let timeMilliseconds: @Sendable () -> Int64
  private let clock: StateSyncClock
  private let mutationDidCommit: @Sendable () async -> Void

  public init(
    store: LocalDataStore,
    httpClient: FeedHTTPClient = FeedHTTPClient(),
    parser: FeedDocumentParser = FeedDocumentParser(),
    clock: StateSyncClock = StateSyncClock(),
    mutationDidCommit: @escaping @Sendable () async -> Void = {},
    timeMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
  ) {
    self.store = store
    self.httpClient = httpClient
    self.parser = parser
    self.clock = clock
    self.mutationDidCommit = mutationDidCommit
    self.timeMilliseconds = timeMilliseconds
  }

  public func addSubscription(
    from requestedURL: URL,
    markNewEpisodesInbox: Bool = true
  ) async throws -> InitialSubscriptionResult {
    let requestedFeedKey = try FeedKey(canonicalURL: requestedURL)
    let fetchResult = try await httpClient.fetch(requestedURL)
    guard
      case .document(let data, let finalURL, let eTag, let lastModified) = fetchResult
    else {
      throw FeedLibraryError.unexpectedNotModified
    }
    let parsedFeed = try parser.parse(data: data, sourceURL: finalURL)
    let finalFeedKey = try FeedKey(canonicalURL: finalURL)
    let timestamp = timeMilliseconds()
    let hlc = try await clock.tick(physicalTimeMilliseconds: timestamp)
    let result = try await store.saveInitialSubscription(
      feed: Self.feedMetadata(
        parsedFeed,
        feedKey: finalFeedKey,
        canonicalURL: finalURL,
        eTag: eTag,
        lastModified: lastModified
      ),
      episodes: try Self.episodeMetadata(parsedFeed.episodes, feedKey: finalFeedKey),
      markNewEpisodesInbox: markNewEpisodesInbox,
      hlc: hlc,
      timestampMilliseconds: timestamp,
      redirectedFromFeedKey: requestedFeedKey == finalFeedKey ? nil : requestedFeedKey
    )
    await mutationDidCommit()
    return result
  }

  public func refresh(
    feedKey: FeedKey,
    markNewEpisodesInbox: Bool = true
  ) async throws -> FeedRefreshOutcome {
    guard let storedFeed = try await store.feed(for: feedKey) else {
      throw LocalDataError.feedNotFound
    }
    let fetchResult = try await httpClient.fetch(
      storedFeed.metadata.canonicalURL,
      eTag: storedFeed.metadata.eTag,
      lastModified: storedFeed.metadata.lastModified
    )
    guard
      case .document(let data, let finalURL, let eTag, let lastModified) = fetchResult
    else {
      return .notModified
    }
    guard try FeedKey(canonicalURL: finalURL) == feedKey else {
      throw FeedLibraryError.redirectedExistingFeedRequiresMigration
    }
    let parsedFeed = try parser.parse(data: data, sourceURL: finalURL)
    let timestamp = timeMilliseconds()
    return .updated(
      try await store.saveFeedRefresh(
        feed: Self.feedMetadata(
          parsedFeed,
          feedKey: feedKey,
          canonicalURL: finalURL,
          eTag: eTag,
          lastModified: lastModified
        ),
        episodes: try Self.episodeMetadata(parsedFeed.episodes, feedKey: feedKey),
        markNewEpisodesInbox: markNewEpisodesInbox,
        refreshedAtMilliseconds: timestamp
      )
    )
  }

  public func unsubscribe(feedKey: FeedKey) async throws -> SyncMutation {
    guard let storedFeed = try await store.feed(for: feedKey) else {
      throw LocalDataError.feedNotFound
    }
    let timestamp = timeMilliseconds()
    let hlc = try await clock.tick(physicalTimeMilliseconds: timestamp)
    let mutation = try await store.recordLocalMutation(
      .subscription(
        SubscriptionState(
          feedKey: feedKey,
          feedURL: storedFeed.metadata.canonicalURL,
          subscribed: false
        )
      ),
      hlc: hlc,
      createdAtMilliseconds: timestamp
    )
    await mutationDidCommit()
    return mutation
  }

  private static func feedMetadata(
    _ parsedFeed: ParsedFeed,
    feedKey: FeedKey,
    canonicalURL: URL,
    eTag: String?,
    lastModified: String?
  ) -> FeedMetadata {
    FeedMetadata(
      feedKey: feedKey,
      canonicalURL: canonicalURL,
      title: parsedFeed.title,
      author: parsedFeed.author,
      summaryHTML: parsedFeed.summaryHTML,
      imageURL: parsedFeed.imageURL,
      eTag: eTag,
      lastModified: lastModified
    )
  }

  private static func episodeMetadata(
    _ parsedEpisodes: [ParsedEpisode],
    feedKey: FeedKey
  ) throws -> [EpisodeMetadata] {
    var result: [EpisodeMetadata] = []
    for episode in parsedEpisodes {
      guard !episode.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        continue
      }
      let episodeKey: EpisodeKey
      do {
        episodeKey = try EpisodeKey(
          input: EpisodeIdentityInput(
            feedKey: feedKey,
            guid: episode.guid,
            enclosureURL: episode.enclosureURL,
            linkURL: episode.linkURL,
            publicationDate: episode.publicationDate,
            title: episode.title,
            durationMilliseconds: episode.durationMilliseconds
          )
        )
      } catch CanonicalIdentityError.missingEpisodeLocator {
        continue
      }
      result.append(
        EpisodeMetadata(
          episodeKey: episodeKey,
          feedKey: feedKey,
          guid: episode.guid,
          enclosureURL: episode.enclosureURL,
          linkURL: episode.linkURL,
          title: episode.title,
          publicationDateMilliseconds: episode.publicationDate.map {
            Int64(($0.timeIntervalSince1970 * 1_000).rounded())
          },
          durationMilliseconds: episode.durationMilliseconds,
          summaryHTML: episode.summaryHTML,
          mimeType: episode.mimeType,
          transcriptURL: episode.transcriptURL,
          transcriptType: episode.transcriptType,
          chaptersURL: episode.chaptersURL,
          chaptersType: episode.chaptersType
        )
      )
    }
    return result
  }
}
