import CoreContracts
import Foundation
import LocalData
import PlaybackFeature
import QueueFeature
import Testing

struct PlaybackEngineTests {
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
  let keys: [EpisodeKey]

  static func make(includeMissingEnclosure: Bool = false) async throws -> Fixture {
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
        mimeType: "audio/mpeg"
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
      keys: keys
    )
  }
}
