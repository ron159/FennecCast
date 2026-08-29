import CoreContracts
import LocalData

public protocol PodcastAutomationDownloadManaging: Sendable {
  func startDownload(_ episodeKey: EpisodeKey) async throws
  func removeDownload(_ episodeKey: EpisodeKey) async throws
}

extension DownloadManager: PodcastAutomationDownloadManaging {}

public struct PodcastAutomationResult: Equatable, Sendable {
  public static let empty = PodcastAutomationResult()

  public let startedEpisodeKeys: [EpisodeKey]
  public let removedEpisodeKeys: [EpisodeKey]
  public let failedEpisodeKeys: [EpisodeKey]

  public init(
    startedEpisodeKeys: [EpisodeKey] = [],
    removedEpisodeKeys: [EpisodeKey] = [],
    failedEpisodeKeys: [EpisodeKey] = []
  ) {
    self.startedEpisodeKeys = startedEpisodeKeys
    self.removedEpisodeKeys = removedEpisodeKeys
    self.failedEpisodeKeys = failedEpisodeKeys
  }
}

public actor PodcastAutomationService {
  private let store: LocalDataStore
  private let downloadManager: any PodcastAutomationDownloadManaging
  private let automaticDownloadsPerRefresh: Int

  public init(
    store: LocalDataStore,
    downloadManager: any PodcastAutomationDownloadManaging,
    automaticDownloadsPerRefresh: Int = 3
  ) {
    self.store = store
    self.downloadManager = downloadManager
    self.automaticDownloadsPerRefresh = min(10, max(1, automaticDownloadsPerRefresh))
  }

  public func handleRefresh(
    feedKey: FeedKey,
    insertedEpisodeKeys: [EpisodeKey]
  ) async -> PodcastAutomationResult {
    guard let preferences = try? await store.feedPreferences(for: feedKey) else {
      return .empty
    }
    var started: [EpisodeKey] = []
    var failed: [EpisodeKey] = []
    if preferences.autoDownload,
      let candidates = try? await store.automaticDownloadCandidates(
        feedKey: feedKey,
        episodeKeys: insertedEpisodeKeys,
        limit: automaticDownloadsPerRefresh
      )
    {
      for episodeKey in candidates {
        do {
          try await downloadManager.startDownload(episodeKey)
          started.append(episodeKey)
        } catch {
          failed.append(episodeKey)
        }
      }
    }
    let cleanup = await cleanDownloads(feedKey: feedKey, preferences: preferences)
    failed.append(contentsOf: cleanup.failedEpisodeKeys)
    return PodcastAutomationResult(
      startedEpisodeKeys: started,
      removedEpisodeKeys: cleanup.removedEpisodeKeys,
      failedEpisodeKeys: failed
    )
  }

  public func runMaintenance() async -> PodcastAutomationResult {
    guard let preferencesByFeed = try? await store.allFeedPreferences() else {
      return .empty
    }
    var removed: [EpisodeKey] = []
    var failed: [EpisodeKey] = []
    for feedKey in preferencesByFeed.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      guard let preferences = preferencesByFeed[feedKey] else { continue }
      let result = await cleanDownloads(feedKey: feedKey, preferences: preferences)
      removed.append(contentsOf: result.removedEpisodeKeys)
      failed.append(contentsOf: result.failedEpisodeKeys)
    }
    return PodcastAutomationResult(
      removedEpisodeKeys: removed,
      failedEpisodeKeys: failed
    )
  }

  private func cleanDownloads(
    feedKey: FeedKey,
    preferences: FeedPreferences
  ) async -> PodcastAutomationResult {
    guard
      let candidates = try? await store.downloadCleanupCandidates(
        feedKey: feedKey,
        autoDeletePlayed: preferences.autoDeletePlayed,
        retentionLimit: preferences.downloadRetentionLimit,
        limit: 1_000
      )
    else {
      return .empty
    }
    var removed: [EpisodeKey] = []
    var failed: [EpisodeKey] = []
    for episodeKey in candidates {
      do {
        try await downloadManager.removeDownload(episodeKey)
        removed.append(episodeKey)
      } catch {
        failed.append(episodeKey)
      }
    }
    return PodcastAutomationResult(
      removedEpisodeKeys: removed,
      failedEpisodeKeys: failed
    )
  }
}
