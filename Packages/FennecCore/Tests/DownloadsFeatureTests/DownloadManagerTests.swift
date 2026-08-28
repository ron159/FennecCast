import CoreContracts
import Foundation
import LocalData
import PlaybackFeature
import Testing

@testable import DownloadsFeature

struct DownloadManagerTests {
  @Test
  func downloadsProgressesAndCompletesWithoutSyncMutation() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeFiles() }
    let manager = fixture.makeManager()

    try await manager.startDownload(fixture.episodeKeys[0])
    var record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .running)
    #expect(record.taskIdentifier == 41)
    await #expect(throws: DownloadManagerError.alreadyRequested) {
      try await manager.startDownload(fixture.episodeKeys[0])
    }

    await manager.handleTransportEvent(
      .progress(taskIdentifier: 41, downloadedBytes: 40, contentLength: 100)
    )
    record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.downloadedBytes == 40)

    let stagedURL = try fixture.stagedFile(bytes: 100)
    await manager.handleTransportEvent(
      .completed(
        taskIdentifier: 41,
        stagedFileURL: stagedURL,
        response: DownloadResponseMetadata(
          statusCode: 200,
          finalURL: URL(string: "https://cdn.example.com/episode-1.mp3")!,
          contentLength: 100,
          mimeType: "audio/mpeg",
          eTag: "v1",
          lastModified: "Sat, 29 Aug 2026 00:00:00 GMT"
        )
      )
    )

    record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .completed)
    #expect(record.localRelativePath?.hasPrefix("Media/") == true)
    #expect(record.checksumSHA256?.count == 64)
    let localURL = try #require(
      record.localRelativePath.map { fixture.root.appendingPathComponent($0) }
    )
    #expect(FileManager.default.fileExists(atPath: localURL.path))
    #expect(try await fixture.store.pendingMutationCount() == 1)

    try await manager.removeDownload(fixture.episodeKeys[0])
    record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .notRequested)
    #expect(!FileManager.default.fileExists(atPath: localURL.path))
    #expect(try await fixture.store.pendingMutationCount() == 1)
  }

  @Test
  func suspendsResumesCancelsFailsAndRetries() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeFiles() }
    let manager = fixture.makeManager()
    await fixture.transport.setSuspendData(Data([1, 2, 3]))

    try await manager.startDownload(fixture.episodeKeys[0])
    try await manager.suspendDownload(fixture.episodeKeys[0])
    var record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .suspended)
    #expect(record.resumeData == Data([1, 2, 3]))

    try await manager.resumeDownload(fixture.episodeKeys[0])
    record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .running)
    #expect(record.taskIdentifier == 42)
    #expect(await fixture.transport.lastResumeData() == Data([1, 2, 3]))

    try await manager.cancelDownload(fixture.episodeKeys[0])
    record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .notRequested)

    try await manager.startDownload(fixture.episodeKeys[0])
    await manager.handleTransportEvent(
      .failed(
        taskIdentifier: 43,
        resumeData: Data([4, 5]),
        error: .network
      )
    )
    record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .failed)
    #expect(record.lastError == .network)

    try await manager.retryDownload(fixture.episodeKeys[0])
    record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .running)
    #expect(record.taskIdentifier == 44)
    #expect(await fixture.transport.lastResumeData() == Data([4, 5]))
  }

  @Test
  func rejectsInvalidCompletionAndRemovesStagedFile() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeFiles() }
    let manager = fixture.makeManager()
    try await manager.startDownload(fixture.episodeKeys[0])
    let stagedURL = try fixture.stagedFile(bytes: 5)

    await manager.handleTransportEvent(
      .completed(
        taskIdentifier: 41,
        stagedFileURL: stagedURL,
        response: DownloadResponseMetadata(
          statusCode: 503,
          finalURL: URL(string: "https://cdn.example.com/error")!,
          contentLength: 5,
          mimeType: "text/html",
          eTag: nil,
          lastModified: nil
        )
      )
    )

    let record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .failed)
    #expect(record.lastError == .invalidResponse)
    #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
  }

  @Test
  func rejectsUnownedStagedPathWithoutDeletingIt() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeFiles() }
    let manager = fixture.makeManager()
    try await manager.startDownload(fixture.episodeKeys[0])
    let unownedURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("FennecCast-Unowned-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: unownedURL) }
    try Data("abc".utf8).write(to: unownedURL)

    await manager.handleTransportEvent(
      .completed(
        taskIdentifier: 41,
        stagedFileURL: unownedURL,
        response: DownloadResponseMetadata(
          statusCode: 200,
          finalURL: URL(string: "https://cdn.example.com/episode-1.mp3")!,
          contentLength: 3,
          mimeType: "audio/mpeg",
          eTag: nil,
          lastModified: nil
        )
      )
    )

    let record = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    #expect(record.state == .failed)
    #expect(record.lastError == .fileSystem)
    #expect(FileManager.default.fileExists(atPath: unownedURL.path))
  }

  @Test
  func reconcilesRestoredAndMissingTasks() async throws {
    let fixture = try await Fixture.make(episodeCount: 2)
    defer { fixture.removeFiles() }
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: fixture.episodeKeys[0],
        state: .queued,
        taskIdentifier: 77,
        updatedAtMilliseconds: 2
      )
    )
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: fixture.episodeKeys[1],
        state: .queued,
        taskIdentifier: 88,
        updatedAtMilliseconds: 2
      )
    )
    try await fixture.store.saveLocalMediaRecord(
      LocalMediaRecord(
        episodeKey: fixture.episodeKeys[1],
        state: .running,
        taskIdentifier: 88,
        updatedAtMilliseconds: 3
      )
    )
    await fixture.transport.setRestoredTasks([
      DownloadTransportTask(
        taskIdentifier: 77,
        episodeKey: fixture.episodeKeys[0],
        originalURL: URL(string: "https://cdn.example.com/episode-1.mp3")!,
        state: .running
      ),
      DownloadTransportTask(
        taskIdentifier: 99,
        episodeKey: EpisodeKey(rawValue: "missing"),
        originalURL: URL(string: "https://cdn.example.com/missing.mp3")!,
        state: .running
      ),
    ])
    let manager = fixture.makeManager()

    try await manager.connectAndReconcile()

    let restored = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[0])
    )
    let missing = try #require(
      await fixture.store.localMediaRecord(for: fixture.episodeKeys[1])
    )
    #expect(restored.state == .running)
    #expect(missing.state == .failed)
    #expect(missing.lastError == .unknown)
    #expect(await fixture.transport.cancelledTaskIdentifiers() == [99])
  }

  @Test
  func localPlaybackResolverVerifiesFileAndFallsBackToStreaming() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeFiles() }
    let manager = fixture.makeManager()
    try await manager.startDownload(fixture.episodeKeys[0])
    let stagedURL = try fixture.stagedFile(data: Data("abc".utf8))
    await manager.handleTransportEvent(
      .completed(
        taskIdentifier: 41,
        stagedFileURL: stagedURL,
        response: DownloadResponseMetadata(
          statusCode: 200,
          finalURL: URL(string: "https://cdn.example.com/episode-1.mp3")!,
          contentLength: 3,
          mimeType: "audio/mpeg",
          eTag: nil,
          lastModified: nil
        )
      )
    )
    let episode = try #require(
      await fixture.store.libraryEpisode(for: fixture.episodeKeys[0])
    )
    let resolver = LocalFirstPlaybackSourceResolver(
      store: fixture.store,
      storageRoot: fixture.root
    )

    let localURL = try await resolver.sourceURL(for: episode)
    #expect(localURL.isFileURL)

    try Data("abd".utf8).write(to: localURL)
    let fallbackURL = try await resolver.sourceURL(for: episode)
    #expect(fallbackURL == episode.metadata.enclosureURL)
  }
}

private actor MockDownloadTransport: DownloadTransporting {
  private var nextTaskIdentifier = 41
  private var handler: (@Sendable (DownloadTransportEvent) async -> Void)?
  private var suspendData: Data?
  private var resumedWith: Data?
  private var restoredTasks: [DownloadTransportTask] = []
  private var cancelled: [Int] = []

  func setEventHandler(
    _ handler: @escaping @Sendable (DownloadTransportEvent) async -> Void
  ) {
    self.handler = handler
  }

  func makeTask(episodeKey: EpisodeKey, url: URL, resumeData: Data?) -> Int {
    resumedWith = resumeData
    defer { nextTaskIdentifier += 1 }
    return nextTaskIdentifier
  }

  func startTask(taskIdentifier: Int) {}

  func suspendTask(taskIdentifier: Int) -> Data? {
    suspendData
  }

  func cancelTask(taskIdentifier: Int) {
    cancelled.append(taskIdentifier)
  }

  func currentTasks() -> [DownloadTransportTask] {
    restoredTasks
  }

  func setSuspendData(_ data: Data?) {
    suspendData = data
  }

  func lastResumeData() -> Data? {
    resumedWith
  }

  func setRestoredTasks(_ tasks: [DownloadTransportTask]) {
    restoredTasks = tasks
  }

  func cancelledTaskIdentifiers() -> [Int] {
    cancelled
  }
}

private struct Fixture {
  let store: LocalDataStore
  let transport: MockDownloadTransport
  let root: URL
  let episodeKeys: [EpisodeKey]

  static func make(episodeCount: Int = 1) async throws -> Fixture {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("FennecCast-Downloads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let feedURL = URL(string: "https://example.com/feed.xml")!
    let feedKey = try FeedKey(canonicalURL: feedURL)
    let episodeKeys = try (1...episodeCount).map { index in
      try EpisodeKey(input: EpisodeIdentityInput(feedKey: feedKey, guid: "episode-\(index)"))
    }
    let episodes = zip(episodeKeys, 1...episodeCount).map { key, index in
      EpisodeMetadata(
        episodeKey: key,
        feedKey: feedKey,
        guid: "episode-\(index)",
        enclosureURL: URL(string: "https://cdn.example.com/episode-\(index).mp3"),
        linkURL: nil,
        title: "Episode \(index)",
        publicationDateMilliseconds: Int64(index * 1_000),
        durationMilliseconds: 120_000,
        summaryHTML: nil,
        mimeType: "audio/mpeg"
      )
    }
    _ = try await store.saveInitialSubscription(
      feed: FeedMetadata(
        feedKey: feedKey,
        canonicalURL: feedURL,
        title: "Download Cast",
        author: nil,
        summaryHTML: nil,
        imageURL: nil,
        eTag: nil,
        lastModified: nil
      ),
      episodes: episodes,
      markNewEpisodesInbox: false,
      hlc: HLCTimestamp(wallMilliseconds: 1, counter: 0),
      timestampMilliseconds: 1
    )
    return Fixture(
      store: store,
      transport: MockDownloadTransport(),
      root: root,
      episodeKeys: episodeKeys
    )
  }

  func makeManager() -> DownloadManager {
    DownloadManager(
      store: store,
      transport: transport,
      storageRoot: root,
      timeMilliseconds: { 10 }
    )
  }

  func stagedFile(bytes: Int) throws -> URL {
    try stagedFile(data: Data(repeating: 7, count: bytes))
  }

  func stagedFile(data: Data) throws -> URL {
    let directory = root.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
  }

  func removeFiles() {
    try? FileManager.default.removeItem(at: root)
  }
}
