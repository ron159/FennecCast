import Foundation
import Testing

@testable import FeedLibrary

struct FeedHTTPClientTests {
  @Test
  func sendsConditionalHeadersAndReturnsValidatedMetadata() async throws {
    let requestedURL = try url("https://example.com/original.xml")
    let finalURL = try url("https://cdn.example.com/current.xml")
    let loader = StubFeedLoader(
      responses: [
        try response(
          data: Data("<rss/>".utf8),
          url: finalURL,
          status: 200,
          headers: ["ETag": "etag-v2", "Last-Modified": "Fri, 01 Jan 2027 00:00:00 GMT"]
        )
      ]
    )
    let client = FeedHTTPClient(loader: loader)

    let result = try await client.fetch(
      requestedURL,
      eTag: "etag-v1",
      lastModified: "Thu, 01 Jan 2026 00:00:00 GMT"
    )

    #expect(
      result
        == .document(
          data: Data("<rss/>".utf8),
          finalURL: finalURL,
          eTag: "etag-v2",
          lastModified: "Fri, 01 Jan 2027 00:00:00 GMT"
        )
    )
    let request = try #require(await loader.requests.first)
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == "etag-v1")
    #expect(
      request.value(forHTTPHeaderField: "If-Modified-Since")
        == "Thu, 01 Jan 2026 00:00:00 GMT"
    )
    #expect(request.value(forHTTPHeaderField: "Accept")?.contains("application/rss+xml") == true)
  }

  @Test
  func handlesNotModifiedStatusWithoutBody() async throws {
    let feedURL = try url("https://example.com/feed.xml")
    let loader = StubFeedLoader(
      responses: [try response(data: Data(), url: feedURL, status: 304)]
    )

    #expect(try await FeedHTTPClient(loader: loader).fetch(feedURL) == .notModified)
  }

  @Test
  func rejectsInvalidStatusOversizeBodiesAndNonNetworkURLs() async throws {
    let feedURL = try url("https://example.com/feed.xml")
    let statusLoader = StubFeedLoader(
      responses: [try response(data: Data("no".utf8), url: feedURL, status: 503)]
    )
    await #expect(throws: FeedFetchError.httpStatus(503)) {
      try await FeedHTTPClient(loader: statusLoader).fetch(feedURL)
    }

    let sizeLoader = StubFeedLoader(
      responses: [try response(data: Data(repeating: 0, count: 11), url: feedURL, status: 200)]
    )
    await #expect(throws: FeedFetchError.responseTooLarge) {
      try await FeedHTTPClient(loader: sizeLoader, maximumResponseBytes: 10).fetch(feedURL)
    }

    await #expect(throws: FeedFetchError.invalidURL) {
      try await FeedHTTPClient(loader: statusLoader).fetch(try url("file:///tmp/feed.xml"))
    }
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

actor StubFeedLoader: FeedDataLoading {
  struct Response: @unchecked Sendable {
    let data: Data
    let response: URLResponse
  }

  private var responses: [Response]
  private(set) var requests: [URLRequest] = []

  init(responses: [Response]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard !responses.isEmpty else {
      throw StubError.missingResponse
    }
    let response = responses.removeFirst()
    return (response.data, response.response)
  }

  enum StubError: Error {
    case missingResponse
  }
}
