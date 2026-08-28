import CryptoKit
import Foundation
import Testing

@testable import CoreContracts

struct CanonicalIdentityTests {
  @Test
  func feedKeyNormalizesNetworkURL() throws {
    let key = try FeedKey(
      canonicalURL: url("HTTPS://Example.COM:443/feed.xml?b=2&a=1#fragment")
    )
    let normalized = "https://example.com/feed.xml?a=1&b=2"

    #expect(key.rawValue == sha256("feed:v1:\(normalized)"))
  }

  @Test
  func feedKeyTreatsRootSlashAsEmptyPath() throws {
    let withSlash = try FeedKey(canonicalURL: url("https://example.com/"))
    let withoutSlash = try FeedKey(canonicalURL: url("https://example.com"))

    #expect(withSlash == withoutSlash)
  }

  @Test
  func feedKeyRejectsNonNetworkURL() {
    #expect(throws: CanonicalIdentityError.self) {
      try FeedKey(canonicalURL: url("file:///tmp/feed.xml"))
    }
  }

  @Test
  func episodeKeyUsesLocatorPriority() throws {
    let feedKey = try FeedKey(canonicalURL: url("https://example.com/feed"))
    let input = EpisodeIdentityInput(
      feedKey: feedKey,
      guid: "  episode-guid  ",
      enclosureURL: try url("HTTPS://CDN.Example.com:443/audio.mp3#part"),
      linkURL: try url("https://example.com/episode"),
      publicationDate: Date(timeIntervalSince1970: 1_700_000_000),
      title: "Episode One",
      durationMilliseconds: 3_600_000
    )

    let key = try EpisodeKey(input: input)

    #expect(key.rawValue == sha256("episode:v1:\(feedKey.rawValue):episode-guid"))
  }

  @Test
  func episodeKeyFallsBackToNormalizedEnclosure() throws {
    let feedKey = try FeedKey(canonicalURL: url("https://example.com/feed"))
    let input = EpisodeIdentityInput(
      feedKey: feedKey,
      enclosureURL: try url("HTTPS://CDN.Example.com:443/audio.mp3#part")
    )

    let key = try EpisodeKey(input: input)

    #expect(
      key.rawValue
        == sha256(
          "episode:v1:\(feedKey.rawValue):https://cdn.example.com/audio.mp3"
        )
    )
  }

  @Test
  func episodeKeyFallsBackToLinkThenMetadata() throws {
    let feedKey = try FeedKey(canonicalURL: url("https://example.com/feed"))
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let linkKey = try EpisodeKey(
      input: EpisodeIdentityInput(
        feedKey: feedKey,
        linkURL: try url("https://example.com/episode"),
        publicationDate: date,
        title: "ignored",
        durationMilliseconds: 100
      )
    )
    let metadataKey = try EpisodeKey(
      input: EpisodeIdentityInput(
        feedKey: feedKey,
        publicationDate: date,
        title: "  EPISODE\n One  ",
        durationMilliseconds: 100
      )
    )

    #expect(
      linkKey.rawValue
        == sha256(
          "episode:v1:\(feedKey.rawValue):https://example.com/episode|1700000000000"
        )
    )
    #expect(
      metadataKey.rawValue
        == sha256(
          "episode:v1:\(feedKey.rawValue):episode one|1700000000000|100"
        )
    )
  }

  @Test
  func episodeKeyRejectsIncompleteFallback() throws {
    let feedKey = try FeedKey(canonicalURL: url("https://example.com/feed"))

    #expect(throws: CanonicalIdentityError.missingEpisodeLocator) {
      try EpisodeKey(
        input: EpisodeIdentityInput(
          feedKey: feedKey,
          title: "Episode without date or duration"
        )
      )
    }
  }

  private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }
}
