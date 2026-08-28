import Foundation

public protocol FeedDataLoading: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionFeedLoader: FeedDataLoading {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    // `data(for:)` creates and resumes a URLSession data task for this request.
    // Source: https://developer.apple.com/documentation/foundation/urlsession/data(for:)
    try await session.data(for: request)
  }
}

public enum FeedFetchError: Error, Equatable, Sendable {
  case invalidURL
  case nonHTTPResponse
  case httpStatus(Int)
  case responseTooLarge
}

public enum FeedFetchResult: Equatable, Sendable {
  case notModified
  case document(
    data: Data,
    finalURL: URL,
    eTag: String?,
    lastModified: String?
  )
}

public struct FeedHTTPClient: Sendable {
  public static let defaultMaximumResponseBytes = 10 * 1_024 * 1_024

  private let loader: any FeedDataLoading
  private let maximumResponseBytes: Int

  public init(
    loader: any FeedDataLoading = URLSessionFeedLoader(),
    maximumResponseBytes: Int = FeedHTTPClient.defaultMaximumResponseBytes
  ) {
    self.loader = loader
    self.maximumResponseBytes = max(1, maximumResponseBytes)
  }

  public func fetch(
    _ url: URL,
    eTag: String? = nil,
    lastModified: String? = nil
  ) async throws -> FeedFetchResult {
    guard Self.isNetworkURL(url) else {
      throw FeedFetchError.invalidURL
    }
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 30
    )
    request.setValue(
      "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.1",
      forHTTPHeaderField: "Accept"
    )
    if let eTag, !eTag.isEmpty {
      request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
    }
    if let lastModified, !lastModified.isEmpty {
      request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
    }

    let (data, response) = try await loader.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw FeedFetchError.nonHTTPResponse
    }
    guard let finalURL = response.url, Self.isNetworkURL(finalURL) else {
      throw FeedFetchError.invalidURL
    }
    if response.statusCode == 304 {
      return .notModified
    }
    guard (200...299).contains(response.statusCode) else {
      throw FeedFetchError.httpStatus(response.statusCode)
    }
    if response.expectedContentLength > Int64(maximumResponseBytes)
      || data.count > maximumResponseBytes
    {
      throw FeedFetchError.responseTooLarge
    }
    return .document(
      data: data,
      finalURL: finalURL,
      eTag: response.value(forHTTPHeaderField: "ETag"),
      lastModified: response.value(forHTTPHeaderField: "Last-Modified")
    )
  }

  private static func isNetworkURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host != nil
  }
}
