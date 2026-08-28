import CoreContracts
import Foundation
import LocalData
import QueueFeature

public enum PlaybackEngineError: Error, Equatable, Sendable {
  case missingMediaSource
  case unsupportedMediaSource
  case noCurrentItem
  case invalidTime
  case generationOverflow
  case noNextQueueItem
}

public enum PlaybackDriverEvent: Equatable, Sendable {
  case progress(
    generation: UInt64,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64?
  )
  case buffering(generation: UInt64, isBuffering: Bool)
  case ended(generation: UInt64)
  case failed(generation: UInt64)
  case interruptionBegan(generation: UInt64)
  case interruptionEnded(generation: UInt64, shouldResume: Bool)
  case routeChanged(generation: UInt64, shouldPause: Bool)

  fileprivate var generation: UInt64 {
    switch self {
    case .progress(let generation, _, _),
      .buffering(let generation, _),
      .ended(let generation),
      .failed(let generation),
      .interruptionBegan(let generation),
      .interruptionEnded(let generation, _),
      .routeChanged(let generation, _):
      generation
    }
  }
}

public protocol PlaybackDriving: Sendable {
  func setEventHandler(
    _ handler: @escaping @Sendable (PlaybackDriverEvent) -> Void
  ) async
  func load(
    url: URL,
    positionMilliseconds: Int64,
    rate: PlaybackRate,
    generation: UInt64
  ) async throws
  func play(rate: PlaybackRate) async throws
  func pause() async
  func seek(toMilliseconds positionMilliseconds: Int64) async throws
  func setRate(_ rate: PlaybackRate) async throws
  func stop() async
}

public protocol PlaybackSourceResolving: Sendable {
  func sourceURL(for episode: StoredEpisode) async throws -> URL
}

public struct StreamingPlaybackSourceResolver: PlaybackSourceResolving {
  public init() {}

  public func sourceURL(for episode: StoredEpisode) async throws -> URL {
    guard let url = episode.metadata.enclosureURL else {
      throw PlaybackEngineError.missingMediaSource
    }
    guard Self.isNetworkURL(url) else {
      throw PlaybackEngineError.unsupportedMediaSource
    }
    return url
  }

  private static func isNetworkURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }
}

public actor PlaybackEngine {
  private let store: LocalDataStore
  private let queueService: QueueService
  private let driver: any PlaybackDriving
  private let sourceResolver: any PlaybackSourceResolving
  private let timeMilliseconds: @Sendable () -> Int64
  private let monotonicMilliseconds: @Sendable () -> Int64
  private let checkpointIntervalMilliseconds: Int64
  private let completionPolicy: PlaybackCompletionPolicy
  private let clock: StateSyncClock

  private var phase = PlaybackPhase.idle
  private var item: PlaybackItem?
  private var positionMilliseconds: Int64 = 0
  private var durationMilliseconds: Int64?
  private var rate = PlaybackRate.normal
  private var played = false
  private var generation: UInt64 = 0
  private var lastCheckpointMonotonicMilliseconds: Int64 = 0
  private var sleepTimer = PlaybackSleepTimer()
  private var isDriverConnected = false
  private var snapshotContinuations: [UUID: AsyncStream<PlaybackSnapshot>.Continuation] = [:]

  public init(
    store: LocalDataStore,
    queueService: QueueService,
    driver: any PlaybackDriving,
    sourceResolver: any PlaybackSourceResolving = StreamingPlaybackSourceResolver(),
    checkpointIntervalMilliseconds: Int64 = 30_000,
    completionPolicy: PlaybackCompletionPolicy = PlaybackCompletionPolicy(),
    clock: StateSyncClock = StateSyncClock(),
    timeMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    },
    monotonicMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((ProcessInfo.processInfo.systemUptime * 1_000).rounded())
    }
  ) {
    self.store = store
    self.queueService = queueService
    self.driver = driver
    self.sourceResolver = sourceResolver
    self.checkpointIntervalMilliseconds = max(1, checkpointIntervalMilliseconds)
    self.completionPolicy = completionPolicy
    self.clock = clock
    self.timeMilliseconds = timeMilliseconds
    self.monotonicMilliseconds = monotonicMilliseconds
  }

  public func snapshot() -> PlaybackSnapshot {
    PlaybackSnapshot(
      phase: phase,
      item: item,
      positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds,
      rate: rate,
      sleepTimerActive: sleepTimer.isActive
    )
  }

  public func snapshots() -> AsyncStream<PlaybackSnapshot> {
    let identifier = UUID()
    return AsyncStream { continuation in
      snapshotContinuations[identifier] = continuation
      continuation.yield(snapshot())
      continuation.onTermination = { [weak self] _ in
        Task {
          await self?.removeSnapshotContinuation(identifier)
        }
      }
    }
  }

  public func load(_ episodeKey: EpisodeKey, autoplay: Bool = false) async throws {
    defer { publishSnapshot() }
    try await loadEpisode(episodeKey, autoplay: autoplay, flushExisting: true)
  }

  private func loadEpisode(
    _ episodeKey: EpisodeKey,
    autoplay: Bool,
    flushExisting: Bool
  ) async throws {
    await connectDriverIfNeeded()
    guard let episode = try await store.libraryEpisode(for: episodeKey) else {
      throw LocalDataError.episodeNotFound
    }
    let sourceURL = try await sourceResolver.sourceURL(for: episode)
    let storedPlayback = try await store.playbackState(for: episodeKey)?.value
    let resumePosition =
      storedPlayback?.played == true
      ? 0
      : storedPlayback?.positionMilliseconds ?? 0
    let knownDuration =
      episode.metadata.durationMilliseconds
      ?? storedPlayback?.durationMilliseconds
    if flushExisting, item != nil {
      try await flushCurrent(intent: .playbackPause)
    }
    let (nextGeneration, overflow) = generation.addingReportingOverflow(1)
    guard !overflow else {
      throw PlaybackEngineError.generationOverflow
    }
    generation = nextGeneration
    phase = .preparing
    item = PlaybackItem(
      episodeKey: episodeKey,
      sourceURL: sourceURL,
      title: episode.title,
      podcastTitle: episode.feedTitle,
      durationMilliseconds: knownDuration
    )
    positionMilliseconds = resumePosition
    durationMilliseconds = knownDuration
    played = false
    lastCheckpointMonotonicMilliseconds = monotonicMilliseconds()
    do {
      try await driver.load(
        url: sourceURL,
        positionMilliseconds: resumePosition,
        rate: rate,
        generation: generation
      )
      phase = .paused
      if autoplay {
        try await play()
      }
    } catch {
      phase = .failed
      publishSnapshot()
      throw error
    }
  }

  private func connectDriverIfNeeded() async {
    guard !isDriverConnected else { return }
    isDriverConnected = true
    await driver.setEventHandler { [weak self] event in
      Task {
        await self?.handleDriverEventSafely(event)
      }
    }
  }

  private func handleDriverEventSafely(_ event: PlaybackDriverEvent) async {
    do {
      try await handleDriverEvent(event)
    } catch {
      phase = .failed
    }
  }

  public func execute(_ command: PlaybackCommand) async throws {
    switch command {
    case .play:
      try await play()
    case .pause:
      try await pause()
    case .togglePlayPause:
      if phase == .playing || phase == .buffering {
        try await pause()
      } else {
        try await play()
      }
    case .seek(let positionMilliseconds):
      try await seek(toMilliseconds: positionMilliseconds)
    case .skipForward(let milliseconds):
      try await skipForward(milliseconds: milliseconds)
    case .skipBackward(let milliseconds):
      try await skipBackward(milliseconds: milliseconds)
    case .setRate(let rate):
      try await setRate(rate)
    case .markPlayed:
      try await markPlayed()
    case .markUnplayed:
      try await markUnplayed()
    }
  }

  public func play() async throws {
    defer { publishSnapshot() }
    guard item != nil else {
      throw PlaybackEngineError.noCurrentItem
    }
    try await driver.play(rate: rate)
    phase = .playing
  }

  public func pause() async throws {
    defer { publishSnapshot() }
    guard item != nil else {
      throw PlaybackEngineError.noCurrentItem
    }
    await driver.pause()
    phase = .paused
    try await persist(intent: .playbackPause, played: played)
  }

  public func seek(toMilliseconds requestedPosition: Int64) async throws {
    defer { publishSnapshot() }
    guard item != nil else {
      throw PlaybackEngineError.noCurrentItem
    }
    guard requestedPosition >= 0 else {
      throw PlaybackEngineError.invalidTime
    }
    let target =
      durationMilliseconds.map { min(requestedPosition, $0) }
      ?? requestedPosition
    try await driver.seek(toMilliseconds: target)
    positionMilliseconds = target
    played = false
    try await persist(intent: .seek, played: false)
    lastCheckpointMonotonicMilliseconds = monotonicMilliseconds()
  }

  public func skipForward(milliseconds: Int64 = 30_000) async throws {
    guard milliseconds > 0 else {
      throw PlaybackEngineError.invalidTime
    }
    let (target, overflow) = positionMilliseconds.addingReportingOverflow(milliseconds)
    try await seek(toMilliseconds: overflow ? Int64.max : target)
  }

  public func skipBackward(milliseconds: Int64 = 10_000) async throws {
    guard milliseconds > 0 else {
      throw PlaybackEngineError.invalidTime
    }
    try await seek(toMilliseconds: max(0, positionMilliseconds - milliseconds))
  }

  public func setRate(_ newRate: PlaybackRate) async throws {
    defer { publishSnapshot() }
    guard item != nil else {
      throw PlaybackEngineError.noCurrentItem
    }
    try await driver.setRate(newRate)
    rate = newRate
  }

  public func markPlayed() async throws {
    defer { publishSnapshot() }
    guard item != nil else {
      throw PlaybackEngineError.noCurrentItem
    }
    played = true
    try await persist(intent: .markPlayed, played: true)
  }

  public func markUnplayed() async throws {
    defer { publishSnapshot() }
    guard item != nil else {
      throw PlaybackEngineError.noCurrentItem
    }
    try await driver.seek(toMilliseconds: 0)
    positionMilliseconds = 0
    played = false
    try await persist(intent: .markUnplayed, played: false)
    lastCheckpointMonotonicMilliseconds = monotonicMilliseconds()
  }

  public func startSleepTimer(_ mode: PlaybackSleepMode) throws {
    defer { publishSnapshot() }
    try sleepTimer.start(
      mode,
      monotonicNowMilliseconds: monotonicMilliseconds()
    )
  }

  public func cancelSleepTimer() {
    sleepTimer.cancel()
    publishSnapshot()
  }

  public func flush() async throws {
    try await flushCurrent(intent: .checkpoint)
  }

  public func stop() async throws {
    defer { publishSnapshot() }
    try await flushCurrent(intent: .playbackPause)
    await driver.stop()
    phase = .idle
    item = nil
    positionMilliseconds = 0
    durationMilliseconds = nil
    played = false
  }

  public func handleDriverEvent(_ event: PlaybackDriverEvent) async throws {
    guard event.generation == generation, item != nil else {
      return
    }
    switch event {
    case .progress(_, let newPosition, let newDuration):
      guard newPosition >= 0, newDuration.map({ $0 >= 0 }) ?? true else {
        throw PlaybackEngineError.invalidTime
      }
      positionMilliseconds = newPosition
      if let newDuration {
        durationMilliseconds = newDuration
      }
      let monotonicNow = monotonicMilliseconds()
      if sleepTimer.shouldPause(monotonicNowMilliseconds: monotonicNow) {
        try await pause()
        return
      }
      if phase == .playing,
        monotonicNow - lastCheckpointMonotonicMilliseconds
          >= checkpointIntervalMilliseconds
      {
        try await persist(intent: .checkpoint, played: false)
        lastCheckpointMonotonicMilliseconds = monotonicNow
      }
    case .buffering(_, let isBuffering):
      if phase == .playing || phase == .buffering {
        phase = isBuffering ? .buffering : .playing
      }
    case .ended:
      try await finishCurrentEpisode()
    case .failed:
      phase = .failed
    case .interruptionBegan:
      if phase == .playing || phase == .buffering {
        try await pause()
      }
    case .interruptionEnded(_, let shouldResume):
      if shouldResume, phase == .paused {
        try await play()
      }
    case .routeChanged(_, let shouldPause):
      if shouldPause, phase == .playing || phase == .buffering {
        try await pause()
      }
    }
    publishSnapshot()
  }

  public func skipToNext() async throws {
    guard let currentItem = item else {
      throw PlaybackEngineError.noCurrentItem
    }
    try await flushCurrent(intent: .playbackPause)
    let nextEpisodeKey: EpisodeKey?
    do {
      nextEpisodeKey = try await queueService.autoAdvance(
        completedEpisodeKey: currentItem.episodeKey
      )
    } catch QueueServiceError.notCurrentEpisode {
      throw PlaybackEngineError.noNextQueueItem
    }
    guard let nextEpisodeKey else {
      await driver.pause()
      phase = .paused
      publishSnapshot()
      throw PlaybackEngineError.noNextQueueItem
    }
    try await loadEpisode(nextEpisodeKey, autoplay: true, flushExisting: false)
    publishSnapshot()
  }

  private func finishCurrentEpisode() async throws {
    guard let completedItem = item else { return }
    if let durationMilliseconds {
      positionMilliseconds = durationMilliseconds
    }
    played = true
    try await persist(intent: .markPlayed, played: true)

    let stopAfterEpisode = sleepTimer.episodeDidEnd()
    let nextEpisodeKey: EpisodeKey?
    do {
      nextEpisodeKey = try await queueService.autoAdvance(
        completedEpisodeKey: completedItem.episodeKey
      )
    } catch QueueServiceError.notCurrentEpisode {
      nextEpisodeKey = nil
    }
    if stopAfterEpisode || nextEpisodeKey == nil {
      await driver.pause()
      phase = .paused
      return
    }
    guard let nextEpisodeKey else { return }
    try await loadEpisode(nextEpisodeKey, autoplay: true, flushExisting: false)
  }

  private func flushCurrent(intent: PlaybackIntent) async throws {
    guard item != nil else { return }
    let shouldMarkPlayed = try completionPolicy.shouldMarkPlayed(
      positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds
    )
    if shouldMarkPlayed {
      played = true
      try await persist(intent: .markPlayed, played: true)
    } else {
      try await persist(intent: intent, played: played)
    }
  }

  private func persist(intent: PlaybackIntent, played: Bool) async throws {
    guard let item else {
      throw PlaybackEngineError.noCurrentItem
    }
    let timestamp = timeMilliseconds()
    let hlc = try await clock.tick(physicalTimeMilliseconds: timestamp)
    _ = try await store.recordPlaybackMutation(
      episodeKey: item.episodeKey,
      intent: intent,
      positionMilliseconds: positionMilliseconds,
      durationMilliseconds: durationMilliseconds,
      played: played,
      hlc: hlc,
      createdAtMilliseconds: timestamp
    )
  }

  private func publishSnapshot() {
    let value = snapshot()
    for continuation in snapshotContinuations.values {
      continuation.yield(value)
    }
  }

  private func removeSnapshotContinuation(_ identifier: UUID) {
    snapshotContinuations[identifier] = nil
  }
}
