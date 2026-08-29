import CoreContracts
import Foundation
import LocalData
import PlaybackFeature
import QueueFeature
import Testing

struct PlaybackEngineTests {
  @Test
  func podcastRateOverrideDoesNotLeakIntoOtherPodcasts() async throws {
    let fixture = try await Fixture.make()
    let otherEpisodeKey = try await addPodcast(
      to: fixture.store,
      feedURL: "https://example.com/other-feed.xml",
      guid: "other-episode"
    )
    try await fixture.store.saveFeedPreferences(
      FeedPreferences(playbackRate: 1.5),
      for: fixture.feedKey
    )
    let driver = DriverSpy()
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver
    )

    try await engine.load(otherEpisodeKey)
    try await engine.setRate(PlaybackRate(1.25))
    try await engine.load(fixture.keys[0])
    #expect((await engine.snapshot()).rate == (try PlaybackRate(1.5)))

    try await engine.load(otherEpisodeKey)
    #expect((await engine.snapshot()).rate == (try PlaybackRate(1.25)))
    #expect((await driver.lastLoad())?.rate == (try PlaybackRate(1.25)))
  }

  @Test
  func appliesPerPodcastPlaybackRulesAndFinishesAtSkippedEnding() async throws {
    let fixture = try await Fixture.make()
    try await fixture.store.saveFeedPreferences(
      FeedPreferences(
        playbackRate: 1.5,
        skipIntroMilliseconds: 30_000,
        skipEndingMilliseconds: 20_000
      ),
      for: fixture.feedKey
    )
    _ = try await fixture.queue.enqueue(fixture.keys[0], at: .tail)
    _ = try await fixture.queue.enqueue(fixture.keys[1], at: .tail)
    let driver = DriverSpy()
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver,
      timeMilliseconds: { 9_000 }
    )

    try await engine.load(fixture.keys[0], autoplay: true)

    let firstLoad = try #require(await driver.lastLoad())
    #expect(firstLoad.positionMilliseconds == 30_000)
    #expect(firstLoad.rate == (try PlaybackRate(1.5)))
    #expect((await engine.snapshot()).rate == (try PlaybackRate(1.5)))

    try await engine.handleDriverEvent(
      .progress(
        generation: firstLoad.generation,
        positionMilliseconds: 100_000,
        durationMilliseconds: 120_000
      )
    )

    #expect((await engine.snapshot()).item?.episodeKey == fixture.keys[1])
    #expect((await driver.lastLoad())?.positionMilliseconds == 30_000)
    #expect((try await fixture.store.playbackState(for: fixture.keys[0]))?.value.played == true)
  }

  @Test
  func identifiesVideoEpisodesWithoutCreatingAnotherPlaybackSession() async throws {
    let fixture = try await Fixture.make(mimeType: "video/mp4")
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: DriverSpy()
    )

    try await engine.load(fixture.keys[0])

    #expect((await engine.snapshot()).item?.isVideo == true)
  }

  @Test
  func loadsPersistedPositionAndAppliesCommands() async throws {
    let fixture = try await Fixture.make()
    _ = try await fixture.store.recordPlaybackMutation(
      episodeKey: fixture.keys[0],
      intent: .playbackPause,
      positionMilliseconds: 15_000,
      durationMilliseconds: 120_000,
      played: false,
      hlc: HLCTimestamp(wallMilliseconds: 2, counter: 0),
      createdAtMilliseconds: 2
    )
    let driver = DriverSpy()
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver,
      timeMilliseconds: { 10_000 }
    )

    try await engine.load(fixture.keys[0])
    #expect((await engine.snapshot()).phase == .paused)
    #expect((await engine.snapshot()).positionMilliseconds == 15_000)
    #expect((await driver.lastLoad())?.positionMilliseconds == 15_000)

    try await engine.play()
    try await engine.setRate(PlaybackRate(1.5))
    try await engine.seek(toMilliseconds: 40_000)
    try await engine.skipForward(milliseconds: 30_000)
    try await engine.skipBackward(milliseconds: 10_000)
    try await engine.pause()

    let snapshot = await engine.snapshot()
    #expect(snapshot.phase == .paused)
    #expect(snapshot.positionMilliseconds == 60_000)
    #expect(snapshot.rate == (try PlaybackRate(1.5)))
    #expect(await driver.isPlaying() == false)
    #expect(await driver.currentRate() == (try PlaybackRate(1.5)))
    let state = try #require(await fixture.store.playbackState(for: fixture.keys[0]))
    #expect(state.value.intent == .playbackPause)
    #expect(state.value.positionMilliseconds == 60_000)
  }

  @Test
  func chapterFetchDoesNotDelayPlaybackLoad() async throws {
    let chaptersURL = try #require(URL(string: "https://example.com/chapters.json"))
    let fixture = try await Fixture.make(chaptersURL: chaptersURL)
    let driver = DriverSpy()
    let loader = BlockingSupplementalLoader()
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver,
      supplementalContentClient: SupplementalContentClient(loader: loader)
    )
    let load = Task {
      try await engine.load(fixture.keys[0], autoplay: true)
    }

    await loader.waitUntilStarted()

    #expect(await driver.loadCount() == 1)
    #expect((await engine.snapshot()).phase == .playing)
    await loader.release()
    try await load.value
  }

  @Test
  func checkpointsAtIntervalAndIgnoresStaleDriverEvents() async throws {
    let fixture = try await Fixture.make()
    let driver = DriverSpy()
    let monotonic = LockedClock(0)
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver,
      timeMilliseconds: { 20_000 },
      monotonicMilliseconds: { monotonic.value }
    )
    try await engine.load(fixture.keys[0], autoplay: true)
    let generation = try #require(await driver.lastLoad()?.generation)

    try await engine.handleDriverEvent(
      .progress(
        generation: generation + 1,
        positionMilliseconds: 80_000,
        durationMilliseconds: 120_000
      )
    )
    #expect((await engine.snapshot()).positionMilliseconds == 0)
    try await engine.handleDriverEvent(
      .progress(
        generation: generation,
        positionMilliseconds: 29_999,
        durationMilliseconds: 120_000
      )
    )
    #expect(try await fixture.store.pendingMutationCount() == 1)
    monotonic.value = 30_000
    try await engine.handleDriverEvent(
      .progress(
        generation: generation,
        positionMilliseconds: 30_000,
        durationMilliseconds: 120_000
      )
    )
    #expect(try await fixture.store.pendingMutationCount() == 2)
    let state = try #require(await fixture.store.playbackState(for: fixture.keys[0]))
    #expect(state.value.intent == .checkpoint)
    #expect(state.value.positionMilliseconds == 30_000)
  }

  @Test
  func completionPersistsPlayedRemovesCurrentAndAutoplaysNext() async throws {
    let fixture = try await Fixture.make()
    _ = try await fixture.queue.enqueue(fixture.keys[0], at: .tail)
    _ = try await fixture.queue.enqueue(fixture.keys[1], at: .tail)
    let driver = DriverSpy()
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver,
      timeMilliseconds: { 30_000 }
    )
    try await engine.load(fixture.keys[0], autoplay: true)
    let generation = try #require(await driver.lastLoad()?.generation)

    try await engine.handleDriverEvent(.ended(generation: generation))

    let snapshot = await engine.snapshot()
    #expect(snapshot.item?.episodeKey == fixture.keys[1])
    #expect(snapshot.phase == .playing)
    #expect(try await fixture.queue.currentQueue().map(\.episodeKey) == [fixture.keys[1]])
    #expect((try await fixture.store.playbackState(for: fixture.keys[0]))?.value.played == true)
    #expect(await driver.loadCount() == 2)
  }

  @Test
  func episodeCountSleepRemovesCompletedItemWithoutLoadingNext() async throws {
    let fixture = try await Fixture.make()
    _ = try await fixture.queue.enqueue(fixture.keys[0], at: .tail)
    _ = try await fixture.queue.enqueue(fixture.keys[1], at: .tail)
    let driver = DriverSpy()
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver,
      timeMilliseconds: { 35_000 }
    )
    try await engine.load(fixture.keys[0], autoplay: true)
    try await engine.startSleepTimer(.afterEpisodes(1))
    let generation = try #require(await driver.lastLoad()?.generation)

    try await engine.handleDriverEvent(.ended(generation: generation))

    #expect((await engine.snapshot()).item?.episodeKey == fixture.keys[0])
    #expect((await engine.snapshot()).phase == .paused)
    #expect(try await fixture.queue.currentQueue().map(\.episodeKey) == [fixture.keys[1]])
    #expect(await driver.loadCount() == 1)
  }

  @Test
  func sleepDeadlinePausesAndFlushesProgress() async throws {
    let fixture = try await Fixture.make()
    let driver = DriverSpy()
    let monotonic = LockedClock(1_000)
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver,
      timeMilliseconds: { 40_000 },
      monotonicMilliseconds: { monotonic.value }
    )
    try await engine.load(fixture.keys[0], autoplay: true)
    try await engine.startSleepTimer(.after(milliseconds: 1_000))
    monotonic.value = 2_000
    let generation = try #require(await driver.lastLoad()?.generation)

    try await engine.handleDriverEvent(
      .progress(
        generation: generation,
        positionMilliseconds: 12_000,
        durationMilliseconds: 120_000
      )
    )

    #expect((await engine.snapshot()).phase == .paused)
    #expect((await engine.snapshot()).sleepTimerActive == false)
    #expect(await driver.isPlaying() == false)
    #expect(
      (try await fixture.store.playbackState(for: fixture.keys[0]))?.value.intent
        == .playbackPause
    )
  }

  @Test
  func audioInterruptionAndHeadphoneDisconnectControlPlayback() async throws {
    let fixture = try await Fixture.make()
    let driver = DriverSpy()
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: driver,
      timeMilliseconds: { 45_000 }
    )
    try await engine.load(fixture.keys[0], autoplay: true)
    let generation = try #require(await driver.lastLoad()?.generation)

    try await engine.handleDriverEvent(.interruptionBegan(generation: generation))
    #expect((await engine.snapshot()).phase == .paused)
    try await engine.handleDriverEvent(
      .interruptionEnded(generation: generation, shouldResume: true)
    )
    #expect((await engine.snapshot()).phase == .playing)
    try await engine.handleDriverEvent(
      .routeChanged(generation: generation, shouldPause: true)
    )
    #expect((await engine.snapshot()).phase == .paused)
  }

  @Test
  func rejectsMissingEpisodeAndMissingNetworkEnclosure() async throws {
    let fixture = try await Fixture.make(includeMissingEnclosure: true)
    let engine = PlaybackEngine(
      store: fixture.store,
      queueService: fixture.queue,
      driver: DriverSpy(),
      timeMilliseconds: { 50_000 }
    )

    await #expect(throws: LocalDataError.episodeNotFound) {
      try await engine.load(EpisodeKey(rawValue: "missing"))
    }
    await #expect(throws: PlaybackEngineError.missingMediaSource) {
      try await engine.load(fixture.keys[2])
    }
  }
}

private func addPodcast(
  to store: LocalDataStore,
  feedURL: String,
  guid: String
) async throws -> EpisodeKey {
  let url = try #require(URL(string: feedURL))
  let feedKey = try FeedKey(canonicalURL: url)
  let episodeKey = try EpisodeKey(
    input: EpisodeIdentityInput(feedKey: feedKey, guid: guid)
  )
  _ = try await store.saveInitialSubscription(
    feed: FeedMetadata(
      feedKey: feedKey,
      canonicalURL: url,
      title: "Other Cast",
      author: nil,
      summaryHTML: nil,
      imageURL: nil,
      eTag: nil,
      lastModified: nil
    ),
    episodes: [
      EpisodeMetadata(
        episodeKey: episodeKey,
        feedKey: feedKey,
        guid: guid,
        enclosureURL: URL(string: "https://cdn.example.com/other.mp3"),
        linkURL: nil,
        title: "Other Episode",
        publicationDateMilliseconds: 2_000,
        durationMilliseconds: 120_000,
        summaryHTML: nil,
        mimeType: "audio/mpeg"
      )
    ],
    markNewEpisodesInbox: false,
    hlc: HLCTimestamp(wallMilliseconds: 2, counter: 0),
    timestampMilliseconds: 2
  )
  return episodeKey
}

private actor DriverSpy: PlaybackDriving {
  struct Load: Equatable, Sendable {
    let url: URL
    let positionMilliseconds: Int64
    let rate: PlaybackRate
    let generation: UInt64
  }

  private var loads: [Load] = []
  private var playing = false
  private var rate = try! PlaybackRate(1)
  private var positionMilliseconds: Int64 = 0
  private var eventHandler: (@Sendable (PlaybackDriverEvent) -> Void)?

  func setEventHandler(
    _ handler: @escaping @Sendable (PlaybackDriverEvent) -> Void
  ) async {
    eventHandler = handler
  }

  func load(
    url: URL,
    positionMilliseconds: Int64,
    rate: PlaybackRate,
    generation: UInt64
  ) async throws {
    loads.append(
      Load(
        url: url,
        positionMilliseconds: positionMilliseconds,
        rate: rate,
        generation: generation
      )
    )
    self.positionMilliseconds = positionMilliseconds
    self.rate = rate
    playing = false
  }

  func play(rate: PlaybackRate) async throws {
    self.rate = rate
    playing = true
  }

  func pause() async {
    playing = false
  }

  func seek(toMilliseconds positionMilliseconds: Int64) async throws {
    self.positionMilliseconds = positionMilliseconds
  }

  func setRate(_ rate: PlaybackRate) async throws {
    self.rate = rate
  }

  func stop() async {
    playing = false
  }

  func lastLoad() -> Load? { loads.last }
  func loadCount() -> Int { loads.count }
  func isPlaying() -> Bool { playing }
  func currentRate() -> PlaybackRate { rate }
}

private actor BlockingSupplementalLoader: SupplementalContentDataLoading {
  private var started = false
  private var released = false
  private var startedContinuations: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    started = true
    let waiters = startedContinuations
    startedContinuations.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    if !released {
      await withCheckedContinuation { continuation in
        releaseContinuations.append(continuation)
      }
    }
    let data = Data(#"{"chapters":[{"startTime":0,"title":"Opening"}]}"#.utf8)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (data, response)
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startedContinuations.append(continuation)
    }
  }

  func release() {
    released = true
    let waiters = releaseContinuations
    releaseContinuations.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private final class LockedClock: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Int64

  init(_ value: Int64) {
    storedValue = value
  }

  var value: Int64 {
    get {
      lock.withLock { storedValue }
    }
    set {
      lock.withLock { storedValue = newValue }
    }
  }
}

private struct Fixture {
  let store: LocalDataStore
  let queue: QueueService
  let feedKey: FeedKey
  let keys: [EpisodeKey]

  static func make(
    includeMissingEnclosure: Bool = false,
    chaptersURL: URL? = nil,
    mimeType: String = "audio/mpeg"
  ) async throws -> Fixture {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let feedURL = try #require(URL(string: "https://example.com/feed.xml"))
    let feedKey = try FeedKey(canonicalURL: feedURL)
    let keys = try (1...3).map { index in
      try EpisodeKey(input: EpisodeIdentityInput(feedKey: feedKey, guid: "episode-\(index)"))
    }
    let episodes = zip(keys, 1...3).map { key, index in
      EpisodeMetadata(
        episodeKey: key,
        feedKey: feedKey,
        guid: "episode-\(index)",
        enclosureURL: includeMissingEnclosure && index == 3
          ? nil
          : URL(string: "https://cdn.example.com/episode-\(index).mp3"),
        linkURL: nil,
        title: "Episode \(index)",
        publicationDateMilliseconds: Int64(index * 1_000),
        durationMilliseconds: 120_000,
        summaryHTML: nil,
        mimeType: mimeType,
        chaptersURL: chaptersURL,
        chaptersType: chaptersURL == nil ? nil : "application/json+chapters"
      )
    }
    _ = try await store.saveInitialSubscription(
      feed: FeedMetadata(
        feedKey: feedKey,
        canonicalURL: feedURL,
        title: "Playback Cast",
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
      queue: QueueService(store: store, timeMilliseconds: { 5_000 }),
      feedKey: feedKey,
      keys: keys
    )
  }
}
