import CoreContracts
import FeedLibrary
import Foundation
import LocalData
import Testing

struct FeedLibraryServiceTests {
  @Test
  func storesRedirectedCredentialsAndReusesThemForRefresh() async throws {
    let originalURL = try url("https://example.com/old-private.xml")
    let finalURL = try url("https://example.com/private.xml")
    let loader = StubFeedLoader(
      responses: [
        try response(data: feedFixture, url: finalURL, status: 200),
        try response(data: Data(), url: finalURL, status: 304),
      ]
    )
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let credentials = try FeedCredentials(username: "listener", password: "secret")
    let credentialStore = MemoryFeedCredentialStore()
    let service = FeedLibraryService(
      store: store,
      httpClient: FeedHTTPClient(loader: loader),
      credentialStore: credentialStore,
      timeMilliseconds: { 900 }
    )

    _ = try await service.addSubscription(
      from: originalURL,
      credentials: credentials
    )

    let finalKey = try FeedKey(canonicalURL: finalURL)
    #expect(try credentialStore.readCredentials(for: finalKey) == credentials)
    #expect(try await service.hasCredentials(for: finalKey))
    #expect(try await service.refresh(feedKey: finalKey) == .notModified)
    let request = try #require(await loader.requests.last)
    #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)

    try await service.removeCredentials(for: finalKey)
    #expect(try credentialStore.readCredentials(for: finalKey) == nil)
  }

  @Test
  func addSubscriptionUsesFinalRedirectIdentityAndRecordsAlias() async throws {
    let originalURL = try url("https://example.com/old.xml")
    let finalURL = try url("https://example.com/current.xml")
    let loader = StubFeedLoader(
      responses: [
        try response(data: feedFixture, url: finalURL, status: 200, headers: ["ETag": "v1"])
      ]
    )
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let service = FeedLibraryService(
      store: store,
      httpClient: FeedHTTPClient(loader: loader),
      credentialStore: MemoryFeedCredentialStore(),
      timeMilliseconds: { 1_000 }
    )

    let result = try await service.addSubscription(from: originalURL)

    let originalKey = try FeedKey(canonicalURL: originalURL)
    let finalKey = try FeedKey(canonicalURL: finalURL)
    #expect(result.insertedEpisodeKeys.count == 1)
    #expect((try await store.subscribedFeeds()).map(\.feedKey) == [finalKey])
    #expect(
      try await store.resolveCanonicalKey(originalKey.rawValue, kind: .feed) == finalKey.rawValue)
    #expect(try await store.pendingMutationCount() == 1)
  }

  @Test
  func refreshUsesValidatorsSkipsInvalidEpisodesAndDoesNotCreateOutbox() async throws {
    let feedURL = try url("https://example.com/feed.xml")
    let loader = StubFeedLoader(
      responses: [
        try response(data: feedFixture, url: feedURL, status: 200, headers: ["ETag": "v1"]),
        try response(
          data: refreshedFeedFixture, url: feedURL, status: 200, headers: ["ETag": "v2"]),
      ]
    )
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let service = FeedLibraryService(
      store: store,
      httpClient: FeedHTTPClient(loader: loader),
      credentialStore: MemoryFeedCredentialStore(),
      timeMilliseconds: { 1_000 }
    )
    _ = try await service.addSubscription(from: feedURL)

    let outcome = try await service.refresh(feedKey: try FeedKey(canonicalURL: feedURL))

    guard case .updated(let result) = outcome else {
      Issue.record("Expected an updated refresh")
      return
    }
    #expect(result.insertedEpisodeKeys.count == 1)
    #expect(try await store.pendingMutationCount() == 1)
    #expect(try await store.libraryEpisodes(filter: .all, sort: .oldestFirst).count == 2)
    let refreshRequest = try #require(await loader.requests.last)
    #expect(refreshRequest.value(forHTTPHeaderField: "If-None-Match") == "v1")
    #expect((try await store.feed(for: try FeedKey(canonicalURL: feedURL)))?.metadata.eTag == "v2")
  }

  @Test
  func notModifiedRefreshDoesNotWriteAndUnsubscribeCreatesTombstone() async throws {
    let feedURL = try url("https://example.com/feed.xml")
    let loader = StubFeedLoader(
      responses: [
        try response(data: feedFixture, url: feedURL, status: 200),
        try response(data: Data(), url: feedURL, status: 304),
      ]
    )
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    let service = FeedLibraryService(
      store: store,
      httpClient: FeedHTTPClient(loader: loader),
      credentialStore: MemoryFeedCredentialStore(),
      timeMilliseconds: { 2_000 }
    )
    let feedKey = try FeedKey(canonicalURL: feedURL)
    _ = try await service.addSubscription(from: feedURL)

    #expect(try await service.refresh(feedKey: feedKey) == .notModified)
    #expect(try await store.pendingMutationCount() == 1)
    let mutation = try await service.unsubscribe(feedKey: feedKey)
    #expect(mutation.localSequence == 2)
    #expect((try await store.subscriptionState(for: feedKey))?.value.subscribed == false)
    #expect(try await store.subscribedFeeds().isEmpty)
  }

  private var feedFixture: Data {
    Data(
      """
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>Example Cast</title>
          <item>
            <guid>episode-1</guid>
            <title>Episode One</title>
            <enclosure url="https://cdn.example.com/one.mp3" type="audio/mpeg"/>
            <pubDate>Fri, 01 Jan 2027 00:00:00 GMT</pubDate>
            <itunes:duration>120</itunes:duration>
          </item>
        </channel>
      </rss>
      """.utf8
    )
  }

  private var refreshedFeedFixture: Data {
    Data(
      """
      <rss version="2.0">
        <channel>
          <title>Example Cast Updated</title>
          <item><guid>episode-1</guid><title>Episode One Updated</title></item>
          <item><guid>episode-2</guid><title>Episode Two</title></item>
          <item><title>Invalid Episode Without Locator</title></item>
        </channel>
      </rss>
      """.utf8
    )
  }

  private func response(
    data: Data,
    url: URL,
    status: Int,
    headers: [String: String] = [:]
  ) throws -> StubFeedLoader.Response {
    StubFeedLoader.Response(
      data: data,
      response: try #require(
        HTTPURLResponse(
          url: url,
          statusCode: status,
          httpVersion: "HTTP/1.1",
          headerFields: headers
        )
      )
    )
  }

  private func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }
}

private final class MemoryFeedCredentialStore: @unchecked Sendable,
  FeedCredentialStoring
{
  private let lock = NSLock()
  private var values: [FeedKey: FeedCredentials] = [:]

  func readCredentials(for feedKey: FeedKey) throws -> FeedCredentials? {
    lock.withLock { values[feedKey] }
  }

  func saveCredentials(_ credentials: FeedCredentials, for feedKey: FeedKey) throws {
    lock.withLock { values[feedKey] = credentials }
  }

  func deleteCredentials(for feedKey: FeedKey) throws {
    lock.withLock { values[feedKey] = nil }
  }
}
