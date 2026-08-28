import Foundation

public enum ConflictResolutionError: Error, Equatable, Sendable {
  case entityKeyMismatch
}

public struct VersionedState<Value: Equatable & Sendable>: Equatable, Sendable {
  public let value: Value
  public let version: VersionStamp

  public init(value: Value, version: VersionStamp) {
    self.value = value
    self.version = version
  }
}

public enum ConflictResolver {
  public static func resolveSubscription(
    current: VersionedState<SubscriptionState>,
    incoming: VersionedState<SubscriptionState>
  ) throws -> VersionedState<SubscriptionState> {
    guard current.value.feedKey == incoming.value.feedKey else {
      throw ConflictResolutionError.entityKeyMismatch
    }
    return lastWriterWins(current: current, incoming: incoming)
  }

  public static func resolveQueueEntry(
    current: VersionedState<QueueEntryState>,
    incoming: VersionedState<QueueEntryState>
  ) throws -> VersionedState<QueueEntryState> {
    guard current.value.episodeKey == incoming.value.episodeKey else {
      throw ConflictResolutionError.entityKeyMismatch
    }
    return lastWriterWins(current: current, incoming: incoming)
  }

  public static func resolvePlayback(
    current: VersionedState<EpisodePlayback>,
    incoming: VersionedState<EpisodePlayback>
  ) throws -> VersionedState<EpisodePlayback> {
    guard current.value.episodeKey == incoming.value.episodeKey else {
      throw ConflictResolutionError.entityKeyMismatch
    }

    let currentPriority = current.value.intent.conflictPriority
    let incomingPriority = incoming.value.intent.conflictPriority
    if currentPriority != incomingPriority {
      return incomingPriority > currentPriority ? incoming : current
    }
    return lastWriterWins(current: current, incoming: incoming)
  }

  private static func lastWriterWins<Value>(
    current: VersionedState<Value>,
    incoming: VersionedState<Value>
  ) -> VersionedState<Value> where Value: Equatable & Sendable {
    incoming.version > current.version ? incoming : current
  }
}

extension PlaybackIntent {
  fileprivate var conflictPriority: Int {
    switch self {
    case .checkpoint, .playbackPause:
      0
    case .seek, .markPlayed, .markUnplayed:
      1
    }
  }
}
