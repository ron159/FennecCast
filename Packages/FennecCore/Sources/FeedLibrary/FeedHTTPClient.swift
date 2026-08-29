import Foundation

public protocol FeedDataLoading: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public final class URLSessionFeedLoader: FeedDataLoading, @unchecked Sendable {
  private let session: URLSession
  private let redirectDelegate: FeedRedirectDelegate

  public init(configuration: URLSessionConfiguration = .ephemeral) {
    let redirectDelegate = FeedRedirectDelegate()
    self.redirectDelegate = redirectDelegate
    session = URLSession(
      configuration: configuration,
      delegate: redirectDelegate,
      delegateQueue: nil
    )
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    // `data(for:)` creates and resumes a URLSession data task for this request.
    // Source: https://developer.apple.com/documentation/foundation/urlsession/data(for:)
    try await session.data(for: request)
  }

  static func redirectedRequest(
    _ request: URLRequest,
    from originalURL: URL
  ) -> URLRequest {
    guard let destinationURL = request.url,
      Self.origin(of: destinationURL) == Self.origin(of: originalURL)
    else {
      var sanitized = request
      sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
      return sanitized
    }
    return request
  }

  private static func origin(of url: URL) -> String? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased()
    else { return nil }
    let port = components.port ?? (scheme == "https" ? 443 : 80)
    return "\(scheme)://\(host):\(port)"
  }
}

private final class FeedRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let originalURL = task.originalRequest?.url else {
      completionHandler(nil)
      return
    }
    completionHandler(
      URLSessionFeedLoader.redirectedRequest(request, from: originalURL)
    )
  }
}

public enum FeedFetchError: Error, Equatable, Sendable {
  case invalidURL
  case nonHTTPResponse
  case httpStatus(Int)
  case responseTooLarge
  case insecureAuthentication
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
    lastModified: String? = nil,
    credentials: FeedCredentials? = nil
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
    if let credentials {
      guard url.scheme?.lowercased() == "https" else {
        throw FeedFetchError.insecureAuthentication
      }
      let value = Data("\(credentials.username):\(credentials.password)".utf8)
        .base64EncodedString()
      request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
    }
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
    if credentials != nil, finalURL.scheme?.lowercased() != "https" {
      throw FeedFetchError.insecureAuthentication
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
