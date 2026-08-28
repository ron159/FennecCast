import CoreContracts
import Foundation
import LocalData
import PlaybackFeature
import Testing

struct PlaybackPersistenceTests {
  @Test
  func recordsPlaybackIntentWithCanonicalEpisodeMetadata() async throws {
    let fixture = try await Fixture.make()

    let mutation = try await fixture.store.recordPlaybackMutation(
      episodeKey: fixture.episodeKey,
      intent: .playbackPause,
      positionMilliseconds: 42_000,
      durationMilliseconds: 120_000,
      played: false,
      hlc: HLCTimestamp(wallMilliseconds: 2, counter: 0),
      createdAtMilliseconds: 2
    )

    #expect(mutation.localSequence == 2)
    #expect(mutation.entityType == .episodePlayback)
    let state = try #require(await fixture.store.playbackState(for: fixture.episodeKey))
    #expect(state.value.intent == .playbackPause)
    #expect(state.value.positionMilliseconds == 42_000)
    #expect(state.value.durationMilliseconds == 120_000)
    #expect(state.value.feedURL == fixture.feedURL)
    #expect(state.value.guid == "episode-1")
    #expect(try await fixture.store.pendingMutationCount() == 2)
  }

  @Test
  func missingEpisodeDoesNotAllocateSequenceOrOutbox() async throws {
    let fixture = try await Fixture.make()

    await #expect(throws: LocalDataError.episodeNotFound) {
      try await fixture.store.recordPlaybackMutation(
        episodeKey: EpisodeKey(rawValue: "missing"),
        intent: .seek,
        positionMilliseconds: 0,
        durationMilliseconds: nil,
        played: false,
        hlc: HLCTimestamp(wallMilliseconds: 2, counter: 0),
        createdAtMilliseconds: 2
      )
    }

    #expect((try await fixture.store.syncCursor()).lastLocalSequence == 1)
    #expect(try await fixture.store.pendingMutationCount() == 1)
  }
}

private struct Fixture {
  let store: LocalDataStore
  let episodeKey: EpisodeKey
  let feedURL: URL

  static func make() async throws -> Fixture {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let feedURL = try #require(URL(string: "https://example.com/feed.xml"))
    let feedKey = try FeedKey(canonicalURL: feedURL)
    let episodeKey = try EpisodeKey(
      input: EpisodeIdentityInput(feedKey: feedKey, guid: "episode-1")
    )
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
      episodes: [
        EpisodeMetadata(
          episodeKey: episodeKey,
          feedKey: feedKey,
          guid: "episode-1",
          enclosureURL: URL(string: "https://cdn.example.com/episode.mp3"),
          linkURL: nil,
          title: "Episode 1",
          publicationDateMilliseconds: 1_000,
          durationMilliseconds: 120_000,
          summaryHTML: nil,
          mimeType: "audio/mpeg"
        )
      ],
      markNewEpisodesInbox: false,
      hlc: HLCTimestamp(wallMilliseconds: 1, counter: 0),
      timestampMilliseconds: 1
    )
    return Fixture(store: store, episodeKey: episodeKey, feedURL: feedURL)
  }
}
