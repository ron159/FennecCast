import CoreContracts
import Foundation
import Testing

@testable import StateSyncFeature

struct StateSyncHTTPClientTests {
  @Test
  func postsBoundedJSONWithBearerAuthentication() async throws {
    let response = try SyncResponse(
      acceptedLocalSequence: 0,
      nextCursor: 0,
      changes: []
    )
    let loader = RecordingSyncLoader(
      data: try JSONEncoder().encode(response),
      response: try httpResponse(
        url: "https://nas.example.com/v1/sync",
        status: 200,
        contentType: "application/json"
      )
    )
    let client = StateSyncHTTPClient(loader: loader)
    let request = try SyncRequest(
      deviceID: DeviceID("ios-phone"),
      cursor: 0,
      mutations: []
    )
    let configuration = try configuration()

    #expect(try await client.synchronize(request, configuration: configuration) == response)
    let sent = try #require(await loader.lastRequest)
    let authorization = sent.value(forHTTPHeaderField: "Authorization")
    #expect(sent.httpMethod == "POST")
    #expect(sent.url == configuration.endpointURL)
    #expect(authorization == "Bearer \(configuration.token.rawValue)")
    #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(try JSONDecoder().decode(SyncRequest.self, from: #require(sent.httpBody)) == request)
  }

  @Test
  func rejectsStatusOriginContentTypeSizeAndMalformedJSON() async throws {
    let configuration = try configuration()
    let request = try SyncRequest(
      deviceID: DeviceID("ios-phone"),
      cursor: 0,
      mutations: []
    )
    let unauthorized = RecordingSyncLoader(
      data: Data(),
      response: try httpResponse(
        url: "https://nas.example.com/v1/sync",
        status: 401,
        contentType: "application/json"
      )
    )
    await #expect(throws: StateSyncHTTPError.unauthorized) {
      try await StateSyncHTTPClient(loader: unauthorized).synchronize(
        request,
        configuration: configuration
      )
    }

    let redirected = RecordingSyncLoader(
      data: Data("{}".utf8),
      response: try httpResponse(
        url: "https://attacker.example/v1/sync",
        status: 200,
        contentType: "application/json"
      )
    )
    await #expect(throws: StateSyncHTTPError.crossOriginResponse) {
      try await StateSyncHTTPClient(loader: redirected).synchronize(
        request,
        configuration: configuration
      )
    }

    let invalidType = RecordingSyncLoader(
      data: Data("{}".utf8),
      response: try httpResponse(
        url: "https://nas.example.com/v1/sync",
        status: 200,
        contentType: "text/html"
      )
    )
    await #expect(throws: StateSyncHTTPError.invalidContentType) {
      try await StateSyncHTTPClient(loader: invalidType).synchronize(
        request,
        configuration: configuration
      )
    }

    let oversized = RecordingSyncLoader(
      data: Data(repeating: 1, count: 11),
      response: try httpResponse(
        url: "https://nas.example.com/v1/sync",
        status: 200,
        contentType: "application/json"
      )
    )
    await #expect(throws: StateSyncHTTPError.responseTooLarge) {
      try await StateSyncHTTPClient(
        loader: oversized,
        maximumResponseBytes: 10
      ).synchronize(request, configuration: configuration)
    }

    let malformed = RecordingSyncLoader(
      data: Data("{}".utf8),
      response: try httpResponse(
        url: "https://nas.example.com/v1/sync",
        status: 200,
        contentType: "application/json"
      )
    )
    await #expect(throws: StateSyncHTTPError.invalidResponse) {
      try await StateSyncHTTPClient(loader: malformed).synchronize(
        request,
        configuration: configuration
      )
    }
  }

  @Test
  func rejectsOversizedRequestBeforeCallingLoader() async throws {
    let loader = RecordingSyncLoader(
      data: Data(),
      response: try httpResponse(
        url: "https://nas.example.com/v1/sync",
        status: 200,
        contentType: "application/json"
      )
    )
    let request = try SyncRequest(
      deviceID: DeviceID("ios-phone"),
      cursor: 0,
      mutations: []
    )

    await #expect(throws: StateSyncHTTPError.requestTooLarge) {
      try await StateSyncHTTPClient(
        loader: loader,
        maximumRequestBytes: 1
      ).synchronize(request, configuration: try configuration())
    }
    #expect(await loader.lastRequest == nil)
  }

  private func configuration() throws -> StateSyncConfiguration {
    try StateSyncConfiguration(
      serverURL: #require(URL(string: "https://nas.example.com")),
      token: SyncToken(String(repeating: "s", count: 32))
    )
  }

  private func httpResponse(
    url: String,
    status: Int,
    contentType: String
  ) throws -> HTTPURLResponse {
    let responseURL = try #require(URL(string: url))
    return try #require(
      HTTPURLResponse(
        url: responseURL,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": contentType]
      )
    )
  }
}

private actor RecordingSyncLoader: StateSyncDataLoading {
  let data: Data
  let response: URLResponse
  private(set) var lastRequest: URLRequest?

  init(data: Data, response: URLResponse) {
    self.data = data
    self.response = response
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lastRequest = request
    return (data, response)
  }
}
