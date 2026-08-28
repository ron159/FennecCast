import Foundation
import Testing

@testable import ImportExportFeature

struct OPMLCodecTests {
  @Test
  func parsesNestedOutlinesSkipsInvalidURLsAndDeduplicatesCanonicalFeeds() throws {
    let document = Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <opml version="2.0">
        <head><title>My Podcasts</title></head>
        <body>
          <outline text="News">
            <outline text="Example &amp; Show" type="rss"
              xmlUrl="HTTPS://Example.com/feed.xml" htmlUrl="https://example.com/"/>
            <outline title="Duplicate" xmlUrl="https://example.com/feed.xml"/>
            <outline title="Local file" xmlUrl="file:///tmp/feed.xml"/>
          </outline>
          <outline title="Second" xmlUrl="http://feeds.example.net/rss"/>
        </body>
      </opml>
      """.utf8
    )

    let subscriptions = try OPMLCodec().decode(document)

    #expect(subscriptions.count == 2)
    #expect(subscriptions[0].title == "Example & Show")
    #expect(subscriptions[0].feedURL.absoluteString == "HTTPS://Example.com/feed.xml")
    #expect(subscriptions[0].siteURL == URL(string: "https://example.com/"))
    #expect(subscriptions[1].title == "Second")
  }

  @Test
  func rejectsDTDMalformedOversizedAndEmptyDocuments() throws {
    let codec = OPMLCodec(maximumBytes: 100, maximumSubscriptions: 5)

    #expect(throws: OPMLCodecError.prohibitedDTD) {
      try codec.decode(Data("<!DOCTYPE opml><opml><body/></opml>".utf8))
    }
    #expect(throws: OPMLCodecError.malformedDocument) {
      try codec.decode(Data("<opml><body>".utf8))
    }
    #expect(throws: OPMLCodecError.documentTooLarge) {
      try codec.decode(Data(repeating: 0x20, count: 101))
    }
    #expect(throws: OPMLCodecError.noSubscriptions) {
      try codec.decode(Data("<opml version=\"2.0\"><body/></opml>".utf8))
    }
  }

  @Test
  func enforcesSubscriptionLimit() throws {
    let codec = OPMLCodec(maximumBytes: 1_024, maximumSubscriptions: 1)
    let data = Data(
      """
      <opml version="2.0"><body>
        <outline xmlUrl="https://one.example/feed"/>
        <outline xmlUrl="https://two.example/feed"/>
      </body></opml>
      """.utf8
    )

    #expect(throws: OPMLCodecError.tooManySubscriptions) {
      try codec.decode(data)
    }
  }

  @Test
  func encodesEscapedDeterministicDocumentThatRoundTrips() throws {
    let codec = OPMLCodec()
    let values = [
      OPMLSubscription(
        title: "A & <Show>",
        feedURL: try #require(URL(string: "https://example.com/a?x=1&y=2")),
        siteURL: URL(string: "https://example.com/a")
      ),
      OPMLSubscription(
        title: nil,
        feedURL: try #require(URL(string: "https://example.net/feed"))
      ),
    ]

    let data = try codec.encode(values, title: "FennecCast & Friends")
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(text.contains("A &amp; &lt;Show&gt;"))
    #expect(text.contains("x=1&amp;y=2"))
    #expect(try codec.decode(data) == values)
  }
}
