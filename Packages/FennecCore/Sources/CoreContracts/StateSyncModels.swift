import Foundation

public enum StateSyncProtocol {
  public static let version = 1
}

public enum SyncEntityType: String, Codable, CaseIterable, Sendable {
  case subscription
  case episodePlayback = "episode_playback"
  case queueEntry = "queue_entry"
}

public enum PlaybackIntent: String, Codable, CaseIterable, Sendable {
  case checkpoint
  case playbackPause = "playback_pause"
  case seek
  case markPlayed = "mark_played"
  case markUnplayed = "mark_unplayed"
}

public enum SyncModelError: Error, Equatable, Sendable {
  case negativeLocalSequence
  case negativeServerSequence
  case negativeCursor
  case negativePosition
  case negativeDuration
  case emptyEntityKey
  case entityPayloadMismatch(expected: SyncEntityType, actual: SyncEntityType)
  case entityKeyMismatch
}

public struct SubscriptionState: Codable, Equatable, Hashable, Sendable {
  public let feedKey: FeedKey
  public let feedURL: URL
  public let subscribed: Bool

  public init(feedKey: FeedKey, feedURL: URL, subscribed: Bool) {
    self.feedKey = feedKey
    self.feedURL = feedURL
    self.subscribed = subscribed
  }

  private enum CodingKeys: String, CodingKey {
    case feedKey = "feed_key"
    case feedURL = "feed_url"
    case subscribed
  }
}

public struct EpisodePlayback: Codable, Equatable, Hashable, Sendable {
  public let episodeKey: EpisodeKey
  public let intent: PlaybackIntent
  public let positionMilliseconds: Int64
  public let durationMilliseconds: Int64?
  public let played: Bool
  public let feedURL: URL?
  public let guid: String?

  public init(
    episodeKey: EpisodeKey,
    intent: PlaybackIntent,
    positionMilliseconds: Int64,
    durationMilliseconds: Int64?,
    played: Bool,
    feedURL: URL? = nil,
    guid: String? = nil
  ) throws {
    guard positionMilliseconds >= 0 else {
      throw SyncModelError.negativePosition
    }
    if let durationMilliseconds, durationMilliseconds < 0 {
      throw SyncModelError.negativeDuration
    }

    self.episodeKey = episodeKey
    self.intent = intent
    self.positionMilliseconds = positionMilliseconds
    self.durationMilliseconds = durationMilliseconds
    self.played = played
    self.feedURL = feedURL
    self.guid = guid
  }

  private enum CodingKeys: String, CodingKey {
    case episodeKey = "episode_key"
    case intent
    case positionMilliseconds = "position_ms"
    case durationMilliseconds = "duration_ms"
    case played
    case feedURL = "feed_url"
    case guid
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      episodeKey: container.decode(EpisodeKey.self, forKey: .episodeKey),
      intent: container.decode(PlaybackIntent.self, forKey: .intent),
      positionMilliseconds: container.decode(Int64.self, forKey: .positionMilliseconds),
      durationMilliseconds: container.decodeIfPresent(
        Int64.self,
        forKey: .durationMilliseconds
      ),
      played: container.decode(Bool.self, forKey: .played),
      feedURL: container.decodeIfPresent(URL.self, forKey: .feedURL),
      guid: container.decodeIfPresent(String.self, forKey: .guid)
    )
  }
}

public struct QueueEntryState: Codable, Equatable, Hashable, Sendable {
  public let episodeKey: EpisodeKey
  public let orderToken: FractionalIndex
  public let present: Bool

  public init(episodeKey: EpisodeKey, orderToken: FractionalIndex, present: Bool) {
    self.episodeKey = episodeKey
    self.orderToken = orderToken
    self.present = present
  }

  private enum CodingKeys: String, CodingKey {
    case episodeKey = "episode_key"
    case orderToken = "order_token"
    case present
  }
}

public enum SyncPayload: Equatable, Hashable, Sendable {
  case subscription(SubscriptionState)
  case episodePlayback(EpisodePlayback)
  case queueEntry(QueueEntryState)

  public var entityType: SyncEntityType {
    switch self {
    case .subscription:
      .subscription
    case .episodePlayback:
      .episodePlayback
    case .queueEntry:
      .queueEntry
    }
  }

  public var entityKey: String {
    switch self {
    case .subscription(let state):
      state.feedKey.rawValue
    case .episodePlayback(let state):
      state.episodeKey.rawValue
    case .queueEntry(let state):
      state.episodeKey.rawValue
    }
  }
}

public struct SyncMutation: Codable, Equatable, Hashable, Sendable {
  public let localSequence: Int64
  public let hlc: HLCTimestamp
  public let entityType: SyncEntityType
  public let entityKey: String
  public let payload: SyncPayload

  public init(
    localSequence: Int64,
    hlc: HLCTimestamp,
    entityType: SyncEntityType,
    entityKey: String,
    payload: SyncPayload
  ) throws {
    guard localSequence >= 0 else {
      throw SyncModelError.negativeLocalSequence
    }
    try validateEnvelope(entityType: entityType, entityKey: entityKey, payload: payload)

    self.localSequence = localSequence
    self.hlc = hlc
    self.entityType = entityType
    self.entityKey = entityKey
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case localSequence = "local_seq"
    case hlc
    case entityType = "entity_type"
    case entityKey = "entity_key"
    case payload
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entityType = try container.decode(SyncEntityType.self, forKey: .entityType)
    let payload = try container.decodePayload(entityType, forKey: .payload)
    try self.init(
      localSequence: container.decode(Int64.self, forKey: .localSequence),
      hlc: container.decode(HLCTimestamp.self, forKey: .hlc),
      entityType: entityType,
      entityKey: container.decode(String.self, forKey: .entityKey),
      payload: payload
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(localSequence, forKey: .localSequence)
    try container.encode(hlc, forKey: .hlc)
    try container.encode(entityType, forKey: .entityType)
    try container.encode(entityKey, forKey: .entityKey)
    try container.encodePayload(payload, forKey: .payload)
  }
}

public struct SyncChange: Codable, Equatable, Hashable, Sendable {
  public let serverSequence: Int64
  public let deviceID: DeviceID
  public let hlc: HLCTimestamp
  public let entityType: SyncEntityType
  public let entityKey: String
  public let payload: SyncPayload

  public init(
    serverSequence: Int64,
    deviceID: DeviceID,
    hlc: HLCTimestamp,
    entityType: SyncEntityType,
    entityKey: String,
    payload: SyncPayload
  ) throws {
    guard serverSequence >= 0 else {
      throw SyncModelError.negativeServerSequence
    }
    try validateEnvelope(entityType: entityType, entityKey: entityKey, payload: payload)

    self.serverSequence = serverSequence
    self.deviceID = deviceID
    self.hlc = hlc
    self.entityType = entityType
    self.entityKey = entityKey
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case serverSequence = "server_seq"
    case deviceID = "device_id"
    case hlc
    case entityType = "entity_type"
    case entityKey = "entity_key"
    case payload
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entityType = try container.decode(SyncEntityType.self, forKey: .entityType)
    let payload = try container.decodePayload(entityType, forKey: .payload)
    try self.init(
      serverSequence: container.decode(Int64.self, forKey: .serverSequence),
      deviceID: container.decode(DeviceID.self, forKey: .deviceID),
      hlc: container.decode(HLCTimestamp.self, forKey: .hlc),
      entityType: entityType,
      entityKey: container.decode(String.self, forKey: .entityKey),
      payload: payload
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(serverSequence, forKey: .serverSequence)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(hlc, forKey: .hlc)
    try container.encode(entityType, forKey: .entityType)
    try container.encode(entityKey, forKey: .entityKey)
    try container.encodePayload(payload, forKey: .payload)
  }
}

public struct SyncRequest: Codable, Equatable, Hashable, Sendable {
  public let deviceID: DeviceID
  public let cursor: Int64
  public let mutations: [SyncMutation]

  public init(deviceID: DeviceID, cursor: Int64, mutations: [SyncMutation]) throws {
    guard cursor >= 0 else {
      throw SyncModelError.negativeCursor
    }
    self.deviceID = deviceID
    self.cursor = cursor
    self.mutations = mutations
  }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case cursor
    case mutations
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      deviceID: container.decode(DeviceID.self, forKey: .deviceID),
      cursor: container.decode(Int64.self, forKey: .cursor),
      mutations: container.decode([SyncMutation].self, forKey: .mutations)
    )
  }
}

public struct SyncResponse: Codable, Equatable, Hashable, Sendable {
  public let acceptedLocalSequence: Int64
  public let nextCursor: Int64
  public let changes: [SyncChange]

  public init(
    acceptedLocalSequence: Int64,
    nextCursor: Int64,
    changes: [SyncChange]
  ) throws {
    guard acceptedLocalSequence >= 0 else {
      throw SyncModelError.negativeLocalSequence
    }
    guard nextCursor >= 0 else {
      throw SyncModelError.negativeCursor
    }
    self.acceptedLocalSequence = acceptedLocalSequence
    self.nextCursor = nextCursor
    self.changes = changes
  }

  private enum CodingKeys: String, CodingKey {
    case acceptedLocalSequence = "accepted_local_seq"
    case nextCursor = "next_cursor"
    case changes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      acceptedLocalSequence: container.decode(Int64.self, forKey: .acceptedLocalSequence),
      nextCursor: container.decode(Int64.self, forKey: .nextCursor),
      changes: container.decode([SyncChange].self, forKey: .changes)
    )
  }
}

private func validateEnvelope(
  entityType: SyncEntityType,
  entityKey: String,
  payload: SyncPayload
) throws {
  guard !entityKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw SyncModelError.emptyEntityKey
  }
  guard entityType == payload.entityType else {
    throw SyncModelError.entityPayloadMismatch(
      expected: entityType,
      actual: payload.entityType
    )
  }
  guard entityKey == payload.entityKey else {
    throw SyncModelError.entityKeyMismatch
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodePayload(
    _ entityType: SyncEntityType,
    forKey key: Key
  ) throws -> SyncPayload {
    switch entityType {
    case .subscription:
      .subscription(try decode(SubscriptionState.self, forKey: key))
    case .episodePlayback:
      .episodePlayback(try decode(EpisodePlayback.self, forKey: key))
    case .queueEntry:
      .queueEntry(try decode(QueueEntryState.self, forKey: key))
    }
  }
}

extension KeyedEncodingContainer {
  fileprivate mutating func encodePayload(
    _ payload: SyncPayload,
    forKey key: Key
  ) throws {
    switch payload {
    case .subscription(let state):
      try encode(state, forKey: key)
    case .episodePlayback(let state):
      try encode(state, forKey: key)
    case .queueEntry(let state):
      try encode(state, forKey: key)
    }
  }
}
