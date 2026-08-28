import CoreContracts
import Foundation
import LocalData
import Testing

@testable import StateSyncFeature

struct StateSyncEngineTests {
  @Test
  func synchronizesOutboxRemoteChangesCursorAndSharedClock() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeSettings() }
    let feedKey = FeedKey(rawValue: "feed")
    let feedURL = URL(string: "https://example.com/feed.xml")!
    _ = try await fixture.store.recordLocalMutation(
      .subscription(
        SubscriptionState(feedKey: feedKey, feedURL: feedURL, subscribed: true)
      ),
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      createdAtMilliseconds: 100
    )
    let remoteState = SubscriptionState(
      feedKey: feedKey,
      feedURL: feedURL,
      subscribed: false
    )
    let remoteChange = try SyncChange(
      serverSequence: 10,
      deviceID: DeviceID("android-phone"),
      hlc: HLCTimestamp(wallMilliseconds: 200, counter: 3),
      entityType: .subscription,
      entityKey: feedKey.rawValue,
      payload: .subscription(remoteState)
    )
    let transport = RecordingSyncTransport(
      result: .success(
        try SyncResponse(
          acceptedLocalSequence: 1,
          nextCursor: 10,
          changes: [remoteChange]
        )
      )
    )
    let engine = fixture.makeEngine(transport: transport)

    let result = try await engine.synchronize(trigger: .manual)

    #expect(result.uploadedMutationCount == 1)
    #expect(result.receivedChangeCount == 1)
    #expect(result.cursor == 10)
    let request = try #require(await transport.requests.first)
    #expect(request.deviceID == DeviceID(rawValue: "ios-phone"))
    #expect(request.cursor == 0)
    #expect(request.mutations.map(\.localSequence) == [1])
    #expect(try await fixture.store.pendingMutationCount() == 0)
    #expect((try await fixture.store.syncCursor()).serverSequence == 10)
    #expect((try await fixture.store.subscriptionState(for: feedKey))?.value == remoteState)
    let expectedClock = try HLCTimestamp(wallMilliseconds: 200, counter: 4)
    #expect(await fixture.clock.last == expectedClock)
    let snapshot = await engine.snapshot()
    #expect(snapshot.phase == .succeeded)
    #expect(snapshot.lastError == nil)
    #expect(snapshot.pendingMutationCount == 0)
  }

  @Test
  func failedTransportPreservesOutboxAndCursorWithTypedStatus() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeSettings() }
    _ = try await fixture.store.recordLocalMutation(
      .subscription(
        SubscriptionState(
          feedKey: FeedKey(rawValue: "feed"),
          feedURL: URL(string: "https://example.com/feed.xml")!,
          subscribed: true
        )
      ),
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      createdAtMilliseconds: 100
    )
    let engine = fixture.makeEngine(
      transport: RecordingSyncTransport(result: .failure(.network))
    )

    await #expect(throws: StateSyncEngineError.network) {
      try await engine.synchronize(trigger: .manual)
    }

    #expect(try await fixture.store.pendingMutationCount() == 1)
    #expect((try await fixture.store.syncCursor()).serverSequence == 0)
    let snapshot = await engine.snapshot()
    #expect(snapshot.phase == .failed)
    #expect(snapshot.lastError == .network)
    #expect(snapshot.pendingMutationCount == 1)
  }

  @Test
  func rejectsMissingConfigurationWithoutCallingTransport() async throws {
    let suiteName = "StateSyncEngineTests-Missing-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let transport = RecordingSyncTransport(
      result: .success(
        try SyncResponse(acceptedLocalSequence: 0, nextCursor: 0, changes: [])
      )
    )
    let engine = StateSyncEngine(
      store: store,
      transport: transport,
      settingsStore: StateSyncSettingsStore(
        userDefaults: defaults,
        credentialStore: MemoryCredentialStore()
      ),
      clock: StateSyncClock()
    )

    await #expect(throws: StateSyncEngineError.notConfigured) {
      try await engine.synchronize(trigger: .foreground)
    }

    #expect(await transport.requests.isEmpty)
    #expect(await engine.snapshot().phase == .notConfigured)
  }

  @Test
  func allowsOnlyOneInFlightSynchronization() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeSettings() }
    let response = try SyncResponse(
      acceptedLocalSequence: 0,
      nextCursor: 0,
      changes: []
    )
    let transport = BlockingSyncTransport(response: response)
    let engine = fixture.makeEngine(transport: transport)
    let first = Task {
      try await engine.synchronize(trigger: .foreground)
    }
    await transport.waitUntilStarted()

    await #expect(throws: StateSyncEngineError.alreadySynchronizing) {
      try await engine.synchronize(trigger: .manual)
    }
    await transport.release()
    _ = try await first.value
    #expect(await transport.callCount == 1)
  }

  @Test
  func debouncesMutationTriggersAndRetriesOneNetworkFailure() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeSettings() }
    let response = try SyncResponse(
      acceptedLocalSequence: 0,
      nextCursor: 0,
      changes: []
    )
    let transport = SequencedSyncTransport(results: [
      .failure(.network),
      .success(response),
    ])
    let engine = StateSyncEngine(
      store: fixture.store,
      transport: transport,
      settingsStore: fixture.settings,
      clock: fixture.clock,
      timeMilliseconds: { 150 },
      debounceNanoseconds: 20_000_000,
      baseRetryNanoseconds: 1_000_000,
      maximumRetryNanoseconds: 1_000_000,
      maximumRetryCount: 1
    )

    await engine.scheduleDebounced()
    await engine.scheduleDebounced()
    await transport.waitForCallCount(2)
    for await snapshot in await engine.snapshots() {
      if snapshot.phase == .succeeded { break }
    }

    #expect(await transport.callCount == 2)
    #expect(await engine.snapshot().phase == .succeeded)
  }

  @Test
  func limitsOutboxBatchToMaximumEncodedRequestSize() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeSettings() }
    for index in 0..<500 {
      let url = try #require(
        URL(
          string: "https://example.com/feed?index=\(index)&padding="
            + String(repeating: "a", count: 2_500)
        )
      )
      let feedKey = try FeedKey(canonicalURL: url)
      _ = try await fixture.store.recordLocalMutation(
        .subscription(
          SubscriptionState(feedKey: feedKey, feedURL: url, subscribed: true)
        ),
        hlc: HLCTimestamp(wallMilliseconds: Int64(index + 1), counter: 0),
        createdAtMilliseconds: Int64(index + 1)
      )
    }
    let transport = AcknowledgingSyncTransport()
    let engine = fixture.makeEngine(transport: transport)

    let result = try await engine.synchronize(trigger: .manual)

    #expect(result.uploadedMutationCount > 0)
    #expect(result.uploadedMutationCount < 500)
    let request = try #require(await transport.requests.first)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(request).count <= StateSyncHTTPClient.defaultMaximumBodyBytes)
    #expect(try await fixture.store.pendingMutationCount() == 500 - result.uploadedMutationCount)
  }

  @Test
  func rejectsAcknowledgementBeyondUploadedBatch() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.removeSettings() }
    for index in 0..<501 {
      let url = try #require(URL(string: "https://example.com/feed/\(index)"))
      let feedKey = try FeedKey(canonicalURL: url)
      _ = try await fixture.store.recordLocalMutation(
        .subscription(
          SubscriptionState(feedKey: feedKey, feedURL: url, subscribed: true)
        ),
        hlc: HLCTimestamp(wallMilliseconds: Int64(index + 1), counter: 0),
        createdAtMilliseconds: Int64(index + 1)
      )
    }
    let transport = OverAcknowledgingSyncTransport()
    let engine = fixture.makeEngine(transport: transport)

    await #expect(throws: StateSyncEngineError.invalidResponse) {
      try await engine.synchronize(trigger: .manual)
    }

    #expect(try await fixture.store.pendingMutationCount() == 501)
    #expect((try await fixture.store.syncCursor()).serverSequence == 0)
  }
}

private actor RecordingSyncTransport: StateSyncTransporting {
  let result: Result<SyncResponse, StateSyncHTTPError>
  private(set) var requests: [SyncRequest] = []

  init(result: Result<SyncResponse, StateSyncHTTPError>) {
    self.result = result
  }

  func synchronize(
    _ request: SyncRequest,
    configuration: StateSyncConfiguration
  ) async throws -> SyncResponse {
    requests.append(request)
    return try result.get()
  }
}

private actor BlockingSyncTransport: StateSyncTransporting {
  let response: SyncResponse
  private(set) var callCount = 0
  private var startedContinuations: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
  private var started = false
  private var released = false

  init(response: SyncResponse) {
    self.response = response
  }

  func synchronize(
    _ request: SyncRequest,
    configuration: StateSyncConfiguration
  ) async throws -> SyncResponse {
    callCount += 1
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
    return response
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

private actor SequencedSyncTransport: StateSyncTransporting {
  private var results: [Result<SyncResponse, StateSyncHTTPError>]
  private(set) var callCount = 0
  private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(results: [Result<SyncResponse, StateSyncHTTPError>]) {
    self.results = results
  }

  func synchronize(
    _ request: SyncRequest,
    configuration: StateSyncConfiguration
  ) async throws -> SyncResponse {
    callCount += 1
    let ready = callWaiters.filter { $0.0 <= callCount }
    callWaiters.removeAll { $0.0 <= callCount }
    for waiter in ready {
      waiter.1.resume()
    }
    guard !results.isEmpty else {
      throw StateSyncHTTPError.invalidResponse
    }
    return try results.removeFirst().get()
  }

  func waitForCallCount(_ target: Int) async {
    guard callCount < target else { return }
    await withCheckedContinuation { continuation in
      callWaiters.append((target, continuation))
    }
  }
}

private actor AcknowledgingSyncTransport: StateSyncTransporting {
  private(set) var requests: [SyncRequest] = []

  func synchronize(
    _ request: SyncRequest,
    configuration: StateSyncConfiguration
  ) throws -> SyncResponse {
    requests.append(request)
    return try SyncResponse(
      acceptedLocalSequence: request.mutations.last?.localSequence ?? 0,
      nextCursor: request.cursor,
      changes: []
    )
  }
}

private struct OverAcknowledgingSyncTransport: StateSyncTransporting {
  func synchronize(
    _ request: SyncRequest,
    configuration: StateSyncConfiguration
  ) throws -> SyncResponse {
    try SyncResponse(
      acceptedLocalSequence: (request.mutations.last?.localSequence ?? 0) + 1,
      nextCursor: request.cursor,
      changes: []
    )
  }
}

private final class MemoryCredentialStore: @unchecked Sendable, SyncCredentialStoring {
  private let lock = NSLock()
  private var storedToken: String?

  func readToken() throws -> String? {
    lock.withLock { storedToken }
  }

  func saveToken(_ token: String) throws {
    lock.withLock { storedToken = token }
  }

  func deleteToken() throws {
    lock.withLock { storedToken = nil }
  }
}

private struct Fixture {
  let store: LocalDataStore
  let settings: StateSyncSettingsStore
  let defaults: UserDefaults
  let suiteName: String
  let clock: StateSyncClock

  static func make() async throws -> Fixture {
    let suiteName = "StateSyncEngineTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let settings = StateSyncSettingsStore(
      userDefaults: defaults,
      credentialStore: MemoryCredentialStore()
    )
    try settings.save(
      serverURL: #require(URL(string: "https://nas.example.com")),
      tokenValue: String(repeating: "t", count: 32)
    )
    return Fixture(
      store: try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone")),
      settings: settings,
      defaults: defaults,
      suiteName: suiteName,
      clock: StateSyncClock()
    )
  }

  func makeEngine(transport: any StateSyncTransporting) -> StateSyncEngine {
    StateSyncEngine(
      store: store,
      transport: transport,
      settingsStore: settings,
      clock: clock,
      timeMilliseconds: { 150 },
      maximumRetryCount: 0
    )
  }

  func removeSettings() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}
