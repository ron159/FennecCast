import CoreContracts
import Foundation
import LocalData

public enum StateSyncTrigger: Equatable, Sendable {
  case foreground
  case userMutation
  case playback
  case background
  case networkRecovery
  case manual
  case retry
}

public enum StateSyncPhase: Equatable, Sendable {
  case idle
  case synchronizing
  case succeeded
  case failed
  case notConfigured
}

public enum StateSyncEngineError: Error, Equatable, Sendable {
  case notConfigured
  case alreadySynchronizing
  case credentials
  case authentication
  case network
  case requestTooLarge
  case invalidResponse
  case server
  case localData
  case clock
}

public struct StateSyncSnapshot: Equatable, Sendable {
  public let phase: StateSyncPhase
  public let trigger: StateSyncTrigger?
  public let cursor: Int64
  public let pendingMutationCount: Int
  public let lastSuccessfulAtMilliseconds: Int64?
  public let lastError: StateSyncEngineError?

  public init(
    phase: StateSyncPhase,
    trigger: StateSyncTrigger?,
    cursor: Int64,
    pendingMutationCount: Int,
    lastSuccessfulAtMilliseconds: Int64?,
    lastError: StateSyncEngineError?
  ) {
    self.phase = phase
    self.trigger = trigger
    self.cursor = cursor
    self.pendingMutationCount = pendingMutationCount
    self.lastSuccessfulAtMilliseconds = lastSuccessfulAtMilliseconds
    self.lastError = lastError
  }
}

public struct StateSyncRunResult: Equatable, Sendable {
  public let uploadedMutationCount: Int
  public let receivedChangeCount: Int
  public let cursor: Int64

  public init(
    uploadedMutationCount: Int,
    receivedChangeCount: Int,
    cursor: Int64
  ) {
    self.uploadedMutationCount = uploadedMutationCount
    self.receivedChangeCount = receivedChangeCount
    self.cursor = cursor
  }
}

public actor StateSyncEngine {
  private let store: LocalDataStore
  private let transport: any StateSyncTransporting
  private let settingsStore: StateSyncSettingsStore
  private let clock: StateSyncClock
  private let timeMilliseconds: @Sendable () -> Int64
  private let sleep: @Sendable (UInt64) async throws -> Void
  private let debounceNanoseconds: UInt64
  private let baseRetryNanoseconds: UInt64
  private let maximumRetryNanoseconds: UInt64
  private let maximumRetryCount: Int

  private var phase = StateSyncPhase.idle
  private var trigger: StateSyncTrigger?
  private var cursor: Int64 = 0
  private var pendingMutationCount = 0
  private var lastSuccessfulAtMilliseconds: Int64?
  private var lastError: StateSyncEngineError?
  private var isSynchronizing = false
  private var retryCount = 0
  private var scheduledTask: Task<Void, Never>?
  private var snapshotContinuations: [UUID: AsyncStream<StateSyncSnapshot>.Continuation] = [:]

  public init(
    store: LocalDataStore,
    transport: any StateSyncTransporting = StateSyncHTTPClient(),
    settingsStore: StateSyncSettingsStore = StateSyncSettingsStore(),
    clock: StateSyncClock,
    timeMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    },
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
      try await Task.sleep(nanoseconds: nanoseconds)
    },
    debounceNanoseconds: UInt64 = 2_000_000_000,
    baseRetryNanoseconds: UInt64 = 5_000_000_000,
    maximumRetryNanoseconds: UInt64 = 300_000_000_000,
    maximumRetryCount: Int = 5
  ) {
    self.store = store
    self.transport = transport
    self.settingsStore = settingsStore
    self.clock = clock
    self.timeMilliseconds = timeMilliseconds
    self.sleep = sleep
    self.debounceNanoseconds = debounceNanoseconds
    self.baseRetryNanoseconds = baseRetryNanoseconds
    self.maximumRetryNanoseconds = maximumRetryNanoseconds
    self.maximumRetryCount = max(0, maximumRetryCount)
  }

  deinit {
    scheduledTask?.cancel()
  }

  public func snapshot() -> StateSyncSnapshot {
    StateSyncSnapshot(
      phase: phase,
      trigger: trigger,
      cursor: cursor,
      pendingMutationCount: pendingMutationCount,
      lastSuccessfulAtMilliseconds: lastSuccessfulAtMilliseconds,
      lastError: lastError
    )
  }

  public func snapshots() -> AsyncStream<StateSyncSnapshot> {
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

  public func bootstrapClock() async throws {
    let persisted = try await store.syncClockTimestamp()
    await clock.restore(persisted)
  }

  @discardableResult
  public func synchronize(trigger requestedTrigger: StateSyncTrigger) async throws
    -> StateSyncRunResult
  {
    guard !isSynchronizing else {
      throw StateSyncEngineError.alreadySynchronizing
    }
    isSynchronizing = true
    defer { isSynchronizing = false }
    trigger = requestedTrigger
    phase = .synchronizing
    lastError = nil
    publishSnapshot()

    do {
      guard let configuration = try settingsStore.load() else {
        throw StateSyncEngineError.notConfigured
      }
      try await bootstrapClock()
      let cursorState = try await store.syncCursor()
      let mutations = try await store.pendingMutations(limit: 500)
      cursor = cursorState.serverSequence
      pendingMutationCount = mutations.count
      publishSnapshot()
      let (request, batchedMutations) = try Self.boundedRequest(
        deviceID: cursorState.deviceID,
        cursor: cursorState.serverSequence,
        mutations: mutations
      )
      let response = try await transport.synchronize(
        request,
        configuration: configuration
      )
      let maximumAcknowledgement =
        batchedMutations.last?.localSequence ?? cursorState.lastLocalSequence
      guard response.acceptedLocalSequence <= maximumAcknowledgement else {
        throw StateSyncEngineError.invalidResponse
      }
      try await store.applySyncResponse(response)
      if let maximumRemoteClock = response.changes.map(\.hlc).max() {
        _ = try await clock.observe(
          maximumRemoteClock,
          physicalTimeMilliseconds: timeMilliseconds()
        )
      }
      cursor = response.nextCursor
      pendingMutationCount = try await store.pendingMutationCount()
      lastSuccessfulAtMilliseconds = timeMilliseconds()
      phase = .succeeded
      retryCount = 0
      publishSnapshot()
      if pendingMutationCount > 0 {
        schedule(.retry, afterNanoseconds: debounceNanoseconds)
      }
      return StateSyncRunResult(
        uploadedMutationCount: batchedMutations.count,
        receivedChangeCount: response.changes.count,
        cursor: response.nextCursor
      )
    } catch {
      let mappedError = Self.map(error)
      pendingMutationCount = (try? await store.pendingMutationCount()) ?? pendingMutationCount
      phase = mappedError == .notConfigured ? .notConfigured : .failed
      lastError = mappedError
      publishSnapshot()
      if requestedTrigger != .manual {
        scheduleRetryIfNeeded(after: mappedError)
      }
      throw mappedError
    }
  }

  public func scheduleDebounced(_ requestedTrigger: StateSyncTrigger = .userMutation) {
    schedule(requestedTrigger, afterNanoseconds: debounceNanoseconds)
  }

  public func cancelScheduledSync() {
    scheduledTask?.cancel()
    scheduledTask = nil
    retryCount = 0
  }

  private func scheduleRetryIfNeeded(after error: StateSyncEngineError) {
    guard
      error == .network || error == .server,
      retryCount < maximumRetryCount
    else { return }
    retryCount += 1
    let shift = min(retryCount - 1, 6)
    let multiplier = UInt64(1) << UInt64(shift)
    let (candidate, overflow) = baseRetryNanoseconds.multipliedReportingOverflow(
      by: multiplier
    )
    let delay = overflow ? maximumRetryNanoseconds : min(candidate, maximumRetryNanoseconds)
    schedule(.retry, afterNanoseconds: delay)
  }

  private func schedule(
    _ requestedTrigger: StateSyncTrigger,
    afterNanoseconds delay: UInt64
  ) {
    scheduledTask?.cancel()
    let sleep = self.sleep
    scheduledTask = Task { [weak self] in
      do {
        try await sleep(delay)
        _ = try await self?.synchronize(trigger: requestedTrigger)
      } catch {
        return
      }
    }
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

  private static func boundedRequest(
    deviceID: DeviceID,
    cursor: Int64,
    mutations: [SyncMutation]
  ) throws -> (SyncRequest, [SyncMutation]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    func request(prefixCount: Int) throws -> (SyncRequest, [SyncMutation]) {
      let batch = Array(mutations.prefix(prefixCount))
      return (
        try SyncRequest(deviceID: deviceID, cursor: cursor, mutations: batch),
        batch
      )
    }

    var lowerBound = 0
    var upperBound = mutations.count
    while lowerBound < upperBound {
      let candidateCount = lowerBound + (upperBound - lowerBound + 1) / 2
      let (candidate, _) = try request(prefixCount: candidateCount)
      if try encoder.encode(candidate).count <= StateSyncHTTPClient.defaultMaximumBodyBytes {
        lowerBound = candidateCount
      } else {
        upperBound = candidateCount - 1
      }
    }
    if lowerBound == 0, !mutations.isEmpty {
      throw StateSyncEngineError.requestTooLarge
    }
    return try request(prefixCount: lowerBound)
  }

  private static func map(_ error: any Error) -> StateSyncEngineError {
    if let error = error as? StateSyncEngineError {
      return error
    }
    if let error = error as? StateSyncSettingsError {
      switch error {
      case .credentialStore:
        return .credentials
      case .invalidServerURL, .insecureServerURL, .invalidToken, .incompleteConfiguration:
        return .notConfigured
      }
    }
    if let error = error as? StateSyncHTTPError {
      switch error {
      case .unauthorized:
        return .authentication
      case .network:
        return .network
      case .requestTooLarge:
        return .requestTooLarge
      case .serverStatus:
        return .server
      case .nonHTTPResponse, .crossOriginResponse, .invalidContentType,
        .responseTooLarge, .invalidResponse:
        return .invalidResponse
      }
    }
    if error is ClockError {
      return .clock
    }
    return .localData
  }
}
