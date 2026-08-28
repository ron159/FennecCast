import Foundation
import Testing

@testable import CoreContracts

struct StateSyncModelsTests {
  @Test
  func playbackMutationMatchesGoldenJSON() throws {
    let mutation = try SyncMutation(
      localSequence: 157,
      hlc: HLCTimestamp(wallMilliseconds: 1_787_935_800_123, counter: 2),
      entityType: .episodePlayback,
      entityKey: "ep_6f1c",
      payload: .episodePlayback(
        try EpisodePlayback(
          episodeKey: EpisodeKey(rawValue: "ep_6f1c"),
          intent: .playbackPause,
          positionMilliseconds: 1_264_000,
          durationMilliseconds: 3_600_000,
          played: false,
          feedURL: url("https://example.com/feed.xml"),
          guid: "episode-guid"
        )
      )
    )

    let data = try JSONEncoder().encode(mutation)
    let actual = try jsonObject(data)
    let expected = try jsonObject(
      Data(
        #"""
        {
          "local_seq": 157,
          "hlc": { "wall_ms": 1787935800123, "counter": 2 },
          "entity_type": "episode_playback",
          "entity_key": "ep_6f1c",
          "payload": {
            "episode_key": "ep_6f1c",
            "intent": "playback_pause",
            "position_ms": 1264000,
            "duration_ms": 3600000,
            "played": false,
            "feed_url": "https://example.com/feed.xml",
            "guid": "episode-guid"
          }
        }
        """#.utf8
      )
    )

    #expect(actual == expected)
    #expect(try JSONDecoder().decode(SyncMutation.self, from: data) == mutation)
  }

  @Test
  func requestAndResponseUseCursorWireKeys() throws {
    let subscription = SubscriptionState(
      feedKey: FeedKey(rawValue: "feed_a"),
      feedURL: try url("https://example.com/feed.xml"),
      subscribed: false
    )
    let mutation = try SyncMutation(
      localSequence: 4,
      hlc: HLCTimestamp(wallMilliseconds: 100, counter: 0),
      entityType: .subscription,
      entityKey: "feed_a",
      payload: .subscription(subscription)
    )
    let request = try SyncRequest(
      deviceID: DeviceID("ios-phone"),
      cursor: 1_842,
      mutations: [mutation]
    )
    let change = try SyncChange(
      serverSequence: 1_849,
      deviceID: DeviceID("android-phone"),
      hlc: HLCTimestamp(wallMilliseconds: 101, counter: 0),
      entityType: .subscription,
      entityKey: "feed_a",
      payload: .subscription(subscription)
    )
    let response = try SyncResponse(
      acceptedLocalSequence: 4,
      nextCursor: 1_851,
      changes: [change]
    )

    let requestObject = try jsonDictionary(JSONEncoder().encode(request))
    let responseObject = try jsonDictionary(JSONEncoder().encode(response))

    #expect(requestObject["device_id"] as? String == "ios-phone")
    #expect(requestObject["cursor"] as? Int == 1_842)
    #expect((requestObject["mutations"] as? [Any])?.count == 1)
    #expect(responseObject["accepted_local_seq"] as? Int == 4)
    #expect(responseObject["next_cursor"] as? Int == 1_851)
    #expect((responseObject["changes"] as? [Any])?.count == 1)
    #expect(
      try JSONDecoder().decode(SyncRequest.self, from: JSONEncoder().encode(request)) == request)
    #expect(
      try JSONDecoder().decode(SyncResponse.self, from: JSONEncoder().encode(response))
        == response
    )
  }

  @Test
  func queuePayloadUsesFractionalTokenString() throws {
    let queue = QueueEntryState(
      episodeKey: EpisodeKey(rawValue: "ep_queue"),
      orderToken: try FractionalIndex(rawValue: "3000000000000000"),
      present: false
    )
    let mutation = try SyncMutation(
      localSequence: 5,
      hlc: HLCTimestamp(wallMilliseconds: 200, counter: 1),
      entityType: .queueEntry,
      entityKey: "ep_queue",
      payload: .queueEntry(queue)
    )
    let object = try jsonDictionary(JSONEncoder().encode(mutation))
    let payload = try #require(object["payload"] as? [String: AnyHashable])

    #expect(payload["episode_key"] as? String == "ep_queue")
    #expect(payload["order_token"] as? String == "3000000000000000")
    #expect(payload["present"] as? Bool == false)
  }

  @Test
  func rejectsEntityAndPayloadMismatch() throws {
    let playback = try EpisodePlayback(
      episodeKey: EpisodeKey(rawValue: "ep_1"),
      intent: .checkpoint,
      positionMilliseconds: 1,
      durationMilliseconds: nil,
      played: false
    )

    #expect(
      throws: SyncModelError.entityPayloadMismatch(
        expected: .subscription,
        actual: .episodePlayback
      )
    ) {
      try SyncMutation(
        localSequence: 1,
        hlc: HLCTimestamp(wallMilliseconds: 1, counter: 0),
        entityType: .subscription,
        entityKey: "ep_1",
        payload: .episodePlayback(playback)
      )
    }
  }

  @Test
  func rejectsEntityKeyMismatch() throws {
    let payload = SubscriptionState(
      feedKey: FeedKey(rawValue: "feed_payload"),
      feedURL: try url("https://example.com/feed"),
      subscribed: true
    )

    #expect(throws: SyncModelError.entityKeyMismatch) {
      try SyncMutation(
        localSequence: 1,
        hlc: HLCTimestamp(wallMilliseconds: 1, counter: 0),
        entityType: .subscription,
        entityKey: "feed_envelope",
        payload: .subscription(payload)
      )
    }
  }

  @Test
  func rejectsNegativeNumbers() throws {
    #expect(throws: SyncModelError.negativePosition) {
      try EpisodePlayback(
        episodeKey: EpisodeKey(rawValue: "ep"),
        intent: .checkpoint,
        positionMilliseconds: -1,
        durationMilliseconds: nil,
        played: false
      )
    }
    #expect(throws: SyncModelError.negativeDuration) {
      try EpisodePlayback(
        episodeKey: EpisodeKey(rawValue: "ep"),
        intent: .checkpoint,
        positionMilliseconds: 0,
        durationMilliseconds: -1,
        played: false
      )
    }
    #expect(throws: SyncModelError.negativeCursor) {
      try SyncRequest(deviceID: DeviceID("ios"), cursor: -1, mutations: [])
    }
    #expect(throws: SyncModelError.negativeLocalSequence) {
      try SyncResponse(acceptedLocalSequence: -1, nextCursor: 0, changes: [])
    }
  }

  @Test
  func decoderRejectsPayloadOutsideDeclaredEntity() {
    let data = Data(
      #"""
      {
        "local_seq": 1,
        "hlc": { "wall_ms": 1, "counter": 0 },
        "entity_type": "subscription",
        "entity_key": "ep_1",
        "payload": {
          "episode_key": "ep_1",
          "intent": "checkpoint",
          "position_ms": 0,
          "played": false
        }
      }
      """#.utf8
    )

    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(SyncMutation.self, from: data)
    }
  }

  private func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }

  private func jsonObject(_ data: Data) throws -> AnyHashable {
    try #require(JSONSerialization.jsonObject(with: data) as? AnyHashable)
  }

  private func jsonDictionary(_ data: Data) throws -> [String: AnyHashable] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
  }
}
