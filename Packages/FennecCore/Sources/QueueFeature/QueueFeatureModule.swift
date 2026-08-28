import CoreContracts
import Foundation
import LocalData

public enum QueuePlacement: Equatable, Sendable {
  case head
  case tail
  case before(EpisodeKey)
  case after(EpisodeKey)
}

public enum QueueServiceError: Error, Equatable, Sendable {
  case alreadyQueued
  case entryNotQueued
  case targetNotQueued
  case notCurrentEpisode
}

public actor QueueService {
  private let store: LocalDataStore
  private let timeMilliseconds: @Sendable () -> Int64
  private let clock: StateSyncClock
  private let mutationDidCommit: @Sendable () async -> Void

  public init(
    store: LocalDataStore,
    clock: StateSyncClock = StateSyncClock(),
    mutationDidCommit: @escaping @Sendable () async -> Void = {},
    timeMilliseconds: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    }
  ) {
    self.store = store
    self.clock = clock
    self.mutationDidCommit = mutationDidCommit
    self.timeMilliseconds = timeMilliseconds
  }

  public func currentQueue() async throws -> [StoredQueueItem] {
    try await store.currentQueue()
  }

  @discardableResult
  public func enqueue(
    _ episodeKey: EpisodeKey,
    at placement: QueuePlacement
  ) async throws -> [SyncMutation] {
    guard try await store.libraryEpisode(for: episodeKey) != nil else {
      throw LocalDataError.episodeNotFound
    }
    let current = try await store.currentQueue()
    guard !current.contains(where: { $0.episodeKey == episodeKey }) else {
      throw QueueServiceError.alreadyQueued
    }

    let desired = try inserting(episodeKey, into: current.map(\.episodeKey), at: placement)
    return try await persistPlacement(
      episodeKey,
      desiredOrder: desired,
      current: current
    )
  }

  @discardableResult
  public func move(
    _ episodeKey: EpisodeKey,
    to placement: QueuePlacement
  ) async throws -> [SyncMutation] {
    let current = try await store.currentQueue()
    let currentKeys = current.map(\.episodeKey)
    guard currentKeys.contains(episodeKey) else {
      throw QueueServiceError.entryNotQueued
    }
    if placement.target == episodeKey {
      return []
    }
    if let target = placement.target, !currentKeys.contains(target) {
      throw QueueServiceError.targetNotQueued
    }

    let remaining = currentKeys.filter { $0 != episodeKey }
    let desired = try inserting(episodeKey, into: remaining, at: placement)
    guard desired != currentKeys else {
      return []
    }
    return try await persistPlacement(
      episodeKey,
      desiredOrder: desired,
      current: current
    )
  }

  @discardableResult
  public func remove(_ episodeKey: EpisodeKey) async throws -> SyncMutation {
    let current = try await store.currentQueue()
    guard let item = current.first(where: { $0.episodeKey == episodeKey }) else {
      throw QueueServiceError.entryNotQueued
    }
    let timestamp = timeMilliseconds()
    let hlc = try await clock.tick(physicalTimeMilliseconds: timestamp)
    let mutation = try await store.recordLocalMutation(
      .queueEntry(
        QueueEntryState(
          episodeKey: episodeKey,
          orderToken: item.orderToken,
          present: false
        )
      ),
      hlc: hlc,
      createdAtMilliseconds: timestamp
    )
    await mutationDidCommit()
    return mutation
  }

  @discardableResult
  public func autoAdvance(completedEpisodeKey: EpisodeKey) async throws -> EpisodeKey? {
    let current = try await store.currentQueue()
    guard current.first?.episodeKey == completedEpisodeKey else {
      throw QueueServiceError.notCurrentEpisode
    }
    _ = try await remove(completedEpisodeKey)
    return current.dropFirst().first?.episodeKey
  }

  private func persistPlacement(
    _ episodeKey: EpisodeKey,
    desiredOrder: [EpisodeKey],
    current: [StoredQueueItem]
  ) async throws -> [SyncMutation] {
    let index = desiredOrder.firstIndex(of: episodeKey)!
    let tokens = Dictionary(uniqueKeysWithValues: current.map { ($0.episodeKey, $0.orderToken) })
    let lower = index > 0 ? tokens[desiredOrder[index - 1]] : nil
    let upper = index + 1 < desiredOrder.count ? tokens[desiredOrder[index + 1]] : nil

    do {
      let token = try FractionalIndex.between(lower: lower, upper: upper)
      return try await persist([
        .queueEntry(
          QueueEntryState(episodeKey: episodeKey, orderToken: token, present: true)
        )
      ])
    } catch FractionalIndexError.exhaustedSpace {
      return try await rebase(
        desiredOrder,
        alwaysInclude: episodeKey,
        currentTokens: tokens
      )
    } catch FractionalIndexError.invalidBounds {
      return try await rebase(
        desiredOrder,
        alwaysInclude: episodeKey,
        currentTokens: tokens
      )
    }
  }

  private func rebase(
    _ desiredOrder: [EpisodeKey],
    alwaysInclude changedEpisodeKey: EpisodeKey,
    currentTokens: [EpisodeKey: FractionalIndex]
  ) async throws -> [SyncMutation] {
    let tokens = try FractionalIndex.rebase(count: desiredOrder.count)
    let payloads: [SyncPayload] = zip(desiredOrder, tokens).compactMap {
      episodeKey, token -> SyncPayload? in
      guard episodeKey == changedEpisodeKey || currentTokens[episodeKey] != token else {
        return nil
      }
      return SyncPayload.queueEntry(
        QueueEntryState(episodeKey: episodeKey, orderToken: token, present: true)
      )
    }
    return try await persist(payloads)
  }

  private func persist(_ payloads: [SyncPayload]) async throws -> [SyncMutation] {
    let timestamp = timeMilliseconds()
    let hlc = try await clock.tick(physicalTimeMilliseconds: timestamp)
    let mutations = try await store.recordLocalMutations(
      payloads,
      hlc: hlc,
      createdAtMilliseconds: timestamp
    )
    await mutationDidCommit()
    return mutations
  }

  private func inserting(
    _ episodeKey: EpisodeKey,
    into keys: [EpisodeKey],
    at placement: QueuePlacement
  ) throws -> [EpisodeKey] {
    var result = keys
    switch placement {
    case .head:
      result.insert(episodeKey, at: 0)
    case .tail:
      result.append(episodeKey)
    case .before(let target):
      guard let index = result.firstIndex(of: target) else {
        throw QueueServiceError.targetNotQueued
      }
      result.insert(episodeKey, at: index)
    case .after(let target):
      guard let index = result.firstIndex(of: target) else {
        throw QueueServiceError.targetNotQueued
      }
      result.insert(episodeKey, at: index + 1)
    }
    return result
  }
}

extension QueuePlacement {
  fileprivate var target: EpisodeKey? {
    switch self {
    case .head, .tail:
      nil
    case .before(let target), .after(let target):
      target
    }
  }
}
