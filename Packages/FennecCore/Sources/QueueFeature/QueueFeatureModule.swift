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
  case invalidReorder
}

public enum QueueSortOrder: CaseIterable, Equatable, Hashable, Sendable {
  case oldestFirst
  case newestFirst
  case episodeTitleAscending
  case episodeTitleDescending
  case podcastTitleAscending
  case podcastTitleDescending
  case durationShortestFirst
  case durationLongestFirst
  case smartShuffleOldestFirst
  case smartShuffleNewestFirst
}

public enum QueueSorter {
  public static func sortedEpisodeKeys(
    _ items: [StoredQueueItem],
    by order: QueueSortOrder
  ) -> [EpisodeKey] {
    let sorted: [StoredQueueItem]
    switch order {
    case .oldestFirst:
      sorted = items.sorted { compareDate($0, $1, ascending: true) }
    case .newestFirst:
      sorted = items.sorted { compareDate($0, $1, ascending: false) }
    case .episodeTitleAscending:
      sorted = items.sorted {
        compareText($0.episode?.title, $1.episode?.title, $0, $1, ascending: true)
      }
    case .episodeTitleDescending:
      sorted = items.sorted {
        compareText($0.episode?.title, $1.episode?.title, $0, $1, ascending: false)
      }
    case .podcastTitleAscending:
      sorted = items.sorted {
        compareText($0.episode?.feedTitle, $1.episode?.feedTitle, $0, $1, ascending: true)
      }
    case .podcastTitleDescending:
      sorted = items.sorted {
        compareText($0.episode?.feedTitle, $1.episode?.feedTitle, $0, $1, ascending: false)
      }
    case .durationShortestFirst:
      sorted = items.sorted { compareDuration($0, $1, ascending: true) }
    case .durationLongestFirst:
      sorted = items.sorted { compareDuration($0, $1, ascending: false) }
    case .smartShuffleOldestFirst:
      sorted = smartShuffle(items, ascending: true)
    case .smartShuffleNewestFirst:
      sorted = smartShuffle(items, ascending: false)
    }
    return sorted.map(\.episodeKey)
  }

  private static func compareDate(
    _ lhs: StoredQueueItem,
    _ rhs: StoredQueueItem,
    ascending: Bool
  ) -> Bool {
    compareNumber(
      lhs.episode?.metadata.publicationDateMilliseconds,
      rhs.episode?.metadata.publicationDateMilliseconds,
      lhs,
      rhs,
      ascending: ascending
    )
  }

  private static func compareDuration(
    _ lhs: StoredQueueItem,
    _ rhs: StoredQueueItem,
    ascending: Bool
  ) -> Bool {
    compareNumber(
      lhs.episode?.metadata.durationMilliseconds,
      rhs.episode?.metadata.durationMilliseconds,
      lhs,
      rhs,
      ascending: ascending
    )
  }

  private static func compareText(
    _ lhs: String?,
    _ rhs: String?,
    _ lhsItem: StoredQueueItem,
    _ rhsItem: StoredQueueItem,
    ascending: Bool
  ) -> Bool {
    guard let lhs else { return rhs == nil && compareKeys(lhsItem, rhsItem) }
    guard let rhs else { return true }
    let comparison = lhs.caseInsensitiveCompare(rhs)
    if comparison != .orderedSame {
      return ascending
        ? comparison == .orderedAscending
        : comparison == .orderedDescending
    }
    return compareKeys(lhsItem, rhsItem)
  }

  private static func compareNumber(
    _ lhs: Int64?,
    _ rhs: Int64?,
    _ lhsItem: StoredQueueItem,
    _ rhsItem: StoredQueueItem,
    ascending: Bool
  ) -> Bool {
    guard let lhs else { return rhs == nil && compareKeys(lhsItem, rhsItem) }
    guard let rhs else { return true }
    if lhs != rhs {
      return ascending ? lhs < rhs : lhs > rhs
    }
    return compareKeys(lhsItem, rhsItem)
  }

  private static func compareKeys(
    _ lhs: StoredQueueItem,
    _ rhs: StoredQueueItem
  ) -> Bool {
    lhs.episodeKey.rawValue < rhs.episodeKey.rawValue
  }

  private static func smartShuffle(
    _ items: [StoredQueueItem],
    ascending: Bool
  ) -> [StoredQueueItem] {
    var grouped: [String: [StoredQueueItem]] = [:]
    for item in items {
      let groupKey =
        item.episode?.metadata.feedKey.rawValue ?? "missing:\(item.episodeKey.rawValue)"
      grouped[groupKey, default: []].append(item)
    }
    var groups = grouped.map { key, values in
      (key: key, items: values.sorted { compareDate($0, $1, ascending: ascending) })
    }
    groups.sort {
      if $0.items.count != $1.items.count {
        return $0.items.count > $1.items.count
      }
      return $0.key < $1.key
    }

    var result = [StoredQueueItem?](repeating: nil, count: items.count)
    var emptySlots = Array(items.indices)
    for group in groups {
      let spread = Double(emptySlots.count) / Double(group.items.count + 1)
      var remainingSlots: [Int] = []
      var skipped = 0
      var placed = 0
      for (slotIndex, slot) in emptySlots.enumerated() {
        skipped += 1
        if Double(skipped) >= spread * Double(placed + 1) {
          result[slot] = group.items[placed]
          placed += 1
          if placed == group.items.count {
            remainingSlots.append(contentsOf: emptySlots.dropFirst(slotIndex + 1))
            break
          }
        } else {
          remainingSlots.append(slot)
        }
      }
      emptySlots = remainingSlots
    }
    return result.compactMap { $0 }
  }
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
  public func enqueue(_ episodeKeys: [EpisodeKey]) async throws -> [SyncMutation] {
    var seen = Set<EpisodeKey>()
    let uniqueKeys = episodeKeys.filter { seen.insert($0).inserted }
    guard !uniqueKeys.isEmpty else { return [] }
    guard try await store.libraryContainsEpisodes(uniqueKeys) else {
      throw LocalDataError.episodeNotFound
    }
    let current = try await store.currentQueue()
    let currentKeys = current.map(\.episodeKey)
    guard uniqueKeys.allSatisfy({ !currentKeys.contains($0) }) else {
      throw QueueServiceError.alreadyQueued
    }
    let currentTokens = Dictionary(
      uniqueKeysWithValues: current.map { ($0.episodeKey, $0.orderToken) }
    )
    do {
      var lower = current.last?.orderToken
      var payloads: [SyncPayload] = []
      for episodeKey in uniqueKeys {
        let token = try FractionalIndex.between(lower: lower, upper: nil)
        payloads.append(
          .queueEntry(
            QueueEntryState(episodeKey: episodeKey, orderToken: token, present: true)
          )
        )
        lower = token
      }
      return try await persist(payloads)
    } catch FractionalIndexError.exhaustedSpace {
      return try await rebase(
        currentKeys + uniqueKeys,
        alwaysInclude: Set(uniqueKeys),
        currentTokens: currentTokens
      )
    } catch FractionalIndexError.invalidBounds {
      return try await rebase(
        currentKeys + uniqueKeys,
        alwaysInclude: Set(uniqueKeys),
        currentTokens: currentTokens
      )
    }
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
    guard let mutation = try await remove([episodeKey]).first else {
      throw QueueServiceError.entryNotQueued
    }
    return mutation
  }

  @discardableResult
  public func remove(_ episodeKeys: [EpisodeKey]) async throws -> [SyncMutation] {
    var seen = Set<EpisodeKey>()
    let uniqueKeys = episodeKeys.filter { seen.insert($0).inserted }
    guard !uniqueKeys.isEmpty else { return [] }
    let current = try await store.currentQueue()
    let currentByKey = Dictionary(uniqueKeysWithValues: current.map { ($0.episodeKey, $0) })
    guard uniqueKeys.allSatisfy({ currentByKey[$0] != nil }) else {
      throw QueueServiceError.entryNotQueued
    }
    let payloads = uniqueKeys.compactMap { episodeKey -> SyncPayload? in
      guard let item = currentByKey[episodeKey] else { return nil }
      return .queueEntry(
        QueueEntryState(
          episodeKey: episodeKey,
          orderToken: item.orderToken,
          present: false
        )
      )
    }
    return try await persist(payloads)
  }

  @discardableResult
  public func reorder(_ episodeKeys: [EpisodeKey]) async throws -> [SyncMutation] {
    let current = try await store.currentQueue()
    let currentKeys = current.map(\.episodeKey)
    guard
      episodeKeys.count == currentKeys.count,
      Set(episodeKeys).count == episodeKeys.count,
      Set(episodeKeys) == Set(currentKeys)
    else {
      throw QueueServiceError.invalidReorder
    }
    guard episodeKeys != currentKeys else { return [] }
    let currentTokens = Dictionary(
      uniqueKeysWithValues: current.map { ($0.episodeKey, $0.orderToken) }
    )
    let tokens = try FractionalIndex.rebase(count: episodeKeys.count)
    let payloads: [SyncPayload] = zip(episodeKeys, tokens).compactMap { episodeKey, token in
      guard currentTokens[episodeKey] != token else { return nil }
      return .queueEntry(
        QueueEntryState(episodeKey: episodeKey, orderToken: token, present: true)
      )
    }
    return try await persist(payloads)
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
        alwaysInclude: [episodeKey],
        currentTokens: tokens
      )
    } catch FractionalIndexError.invalidBounds {
      return try await rebase(
        desiredOrder,
        alwaysInclude: [episodeKey],
        currentTokens: tokens
      )
    }
  }

  private func rebase(
    _ desiredOrder: [EpisodeKey],
    alwaysInclude changedEpisodeKeys: Set<EpisodeKey>,
    currentTokens: [EpisodeKey: FractionalIndex]
  ) async throws -> [SyncMutation] {
    let tokens = try FractionalIndex.rebase(count: desiredOrder.count)
    let payloads: [SyncPayload] = zip(desiredOrder, tokens).compactMap {
      episodeKey, token -> SyncPayload? in
      guard changedEpisodeKeys.contains(episodeKey) || currentTokens[episodeKey] != token else {
        return nil
      }
      return SyncPayload.queueEntry(
        QueueEntryState(episodeKey: episodeKey, orderToken: token, present: true)
      )
    }
    return try await persist(payloads)
  }

  private func persist(_ payloads: [SyncPayload]) async throws -> [SyncMutation] {
    guard !payloads.isEmpty else { return [] }
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
