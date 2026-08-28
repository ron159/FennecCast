import CoreContracts
import Foundation

public protocol StateSyncDataLoading: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

public protocol StateSyncTransporting: Sendable {
  func synchronize(
    _ request: SyncRequest,
    configuration: StateSyncConfiguration
  ) async throws -> SyncResponse
}

public struct URLSessionStateSyncLoader: StateSyncDataLoading {
  public init() {}

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let delegate = SameOriginRedirectDelegate(origin: request.url)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    let session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: nil
    )
    defer { session.finishTasksAndInvalidate() }
    return try await session.data(for: request)
  }
}

public enum StateSyncHTTPError: Error, Equatable, Sendable {
  case requestTooLarge
  case nonHTTPResponse
  case crossOriginResponse
  case unauthorized
  case serverStatus(Int)
  case invalidContentType
  case responseTooLarge
  case invalidResponse
  case network
}

public struct StateSyncHTTPClient: Sendable, StateSyncTransporting {
  public static let defaultMaximumBodyBytes = 1_024 * 1_024

  private let loader: any StateSyncDataLoading
  private let maximumRequestBytes: Int
  private let maximumResponseBytes: Int

  public init(
    loader: any StateSyncDataLoading = URLSessionStateSyncLoader(),
    maximumRequestBytes: Int = StateSyncHTTPClient.defaultMaximumBodyBytes,
    maximumResponseBytes: Int = StateSyncHTTPClient.defaultMaximumBodyBytes
  ) {
    self.loader = loader
    self.maximumRequestBytes = max(1, maximumRequestBytes)
    self.maximumResponseBytes = max(1, maximumResponseBytes)
  }

  public func synchronize(
    _ syncRequest: SyncRequest,
    configuration: StateSyncConfiguration
  ) async throws -> SyncResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = try encoder.encode(syncRequest)
    guard body.count <= maximumRequestBytes else {
      throw StateSyncHTTPError.requestTooLarge
    }
    var request = URLRequest(
      url: configuration.endpointURL,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 30
    )
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Bearer \(configuration.token.rawValue)",
      forHTTPHeaderField: "Authorization"
    )

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await loader.data(for: request)
    } catch let error as StateSyncHTTPError {
      throw error
    } catch {
      throw StateSyncHTTPError.network
    }
    guard let response = response as? HTTPURLResponse else {
      throw StateSyncHTTPError.nonHTTPResponse
    }
    guard
      let finalURL = response.url,
      Self.sameOrigin(finalURL, configuration.endpointURL)
    else {
      throw StateSyncHTTPError.crossOriginResponse
    }
    if response.statusCode == 401 || response.statusCode == 403 {
      throw StateSyncHTTPError.unauthorized
    }
    guard (200..<300).contains(response.statusCode) else {
      throw StateSyncHTTPError.serverStatus(response.statusCode)
    }
    guard Self.isJSON(response.value(forHTTPHeaderField: "Content-Type")) else {
      throw StateSyncHTTPError.invalidContentType
    }
    guard
      response.expectedContentLength <= Int64(maximumResponseBytes),
      data.count <= maximumResponseBytes
    else {
      throw StateSyncHTTPError.responseTooLarge
    }
    do {
      return try JSONDecoder().decode(SyncResponse.self, from: data)
    } catch {
      throw StateSyncHTTPError.invalidResponse
    }
  }

  private static func isJSON(_ value: String?) -> Bool {
    guard let mediaType = value?.split(separator: ";", maxSplits: 1).first else {
      return false
    }
    let normalized = mediaType.trimmingCharacters(in: .whitespaces).lowercased()
    return normalized == "application/json" || normalized.hasSuffix("+json")
  }

  static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && normalizedPort(lhs) == normalizedPort(rhs)
  }

  private static func normalizedPort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "https":
      return 443
    case "http":
      return 80
    default:
      return nil
    }
  }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let origin: URL?

  init(origin: URL?) {
    self.origin = origin
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard
      let origin,
      let redirectedURL = request.url,
      StateSyncHTTPClient.sameOrigin(origin, redirectedURL)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
