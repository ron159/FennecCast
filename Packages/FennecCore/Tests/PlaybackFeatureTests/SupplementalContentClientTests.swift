import Foundation
import PlaybackFeature
import Testing

struct SupplementalContentClientTests {
  @Test
  func loadsWebVTTTranscriptWithBoundedNetworkValidation() async throws {
    let url = try #require(URL(string: "https://cdn.example.com/transcript.vtt"))
    let loader = StubSupplementalLoader(
      result: try response(
        url: url,
        mimeType: "text/vtt",
        data: Data(
          """
          WEBVTT

          00:00:01.000 --> 00:00:03.500
          Hello world

          00:03.500 --> 00:05.000 align:start
          Second line

          """.utf8
        )
      )
    )
    let client = SupplementalContentClient(loader: loader)

    let transcript = try await client.transcript(from: url, declaredType: "text/vtt")

    #expect(transcript.plainText == "Hello world\n\nSecond line")
    #expect(transcript.cues.count == 2)
    #expect(transcript.cues[0].startMilliseconds == 1_000)
    #expect(transcript.cues[0].endMilliseconds == 3_500)
    #expect(await loader.requestedURLs == [url])
  }

  @Test
  func loadsAndNormalizesPodcasting20Chapters() async throws {
    let url = try #require(URL(string: "https://cdn.example.com/chapters.json"))
    let loader = StubSupplementalLoader(
      result: try response(
        url: url,
        mimeType: "application/json",
        data: Data(
          """
          {"version":"1.2.0","chapters":[
            {"startTime":30.5,"title":"Topic","url":"https://example.com/topic"},
            {"startTime":0,"title":"Intro","img":"https://example.com/intro.jpg"}
          ]}
          """.utf8
        )
      )
    )
    let client = SupplementalContentClient(loader: loader)

    let chapters = try await client.chapters(from: url)

    #expect(chapters.map(\.title) == ["Intro", "Topic"])
    #expect(chapters.map(\.startMilliseconds) == [0, 30_500])
    #expect(chapters.allSatisfy { $0.source == .podcastIndex })
  }

  @Test
  func rejectsInvalidStatusSizeFormatAndMalformedContent() async throws {
    let url = try #require(URL(string: "https://cdn.example.com/content"))
    let oversized = SupplementalContentClient(
      loader: StubSupplementalLoader(
        result: try response(
          url: url,
          mimeType: "text/plain",
          data: Data(repeating: 0x61, count: 11)
        )
      ),
      maximumBodyBytes: 10
    )
    await #expect(throws: SupplementalContentError.responseTooLarge) {
      try await oversized.transcript(from: url, declaredType: "text/plain")
    }

    let badStatus = SupplementalContentClient(
      loader: StubSupplementalLoader(
        result: try response(url: url, statusCode: 404, mimeType: "text/plain")
      )
    )
    await #expect(throws: SupplementalContentError.invalidResponse) {
      try await badStatus.transcript(from: url, declaredType: "text/plain")
    }

    let unsupported = SupplementalContentClient(
      loader: StubSupplementalLoader(
        result: try response(url: url, mimeType: "application/pdf")
      )
    )
    await #expect(throws: SupplementalContentError.unsupportedFormat) {
      try await unsupported.transcript(from: url, declaredType: nil)
    }

    let malformed = SupplementalContentClient(
      loader: StubSupplementalLoader(
        result: try response(
          url: url,
          mimeType: "application/json",
          data: Data("{}".utf8)
        )
      )
    )
    await #expect(throws: SupplementalContentError.malformedContent) {
      try await malformed.chapters(from: url)
    }
  }

  private func response(
    url: URL,
    statusCode: Int = 200,
    mimeType: String,
    data: Data = Data("content".utf8)
  ) throws -> (Data, URLResponse) {
    let response = try #require(
      HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": mimeType]
      )
    )
    return (data, response)
  }
}

private actor StubSupplementalLoader: SupplementalContentDataLoading {
  let result: (Data, URLResponse)
  private(set) var requestedURLs: [URL] = []

  init(result: (Data, URLResponse)) {
    self.result = result
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    if let url = request.url {
      requestedURLs.append(url)
    }
    return result
  }
}
