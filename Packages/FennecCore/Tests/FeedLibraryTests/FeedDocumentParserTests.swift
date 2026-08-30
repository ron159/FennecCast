import Foundation
import Testing

@testable import FeedLibrary

struct FeedDocumentParserTests {
  @Test
  func parsesRSSMetadataNamespacesDatesAndDurations() throws {
    let document = try FeedDocumentParser().parse(
      data: Data(rssFixture.utf8),
      sourceURL: try url("https://example.com/podcast/feed.xml")
    )

    #expect(document.format == .rss)
    #expect(document.title == "Sample & Cast")
    #expect(document.author == "Example Author")
    #expect(document.summaryHTML == "<p>About the show</p>")
    #expect(document.imageURL == (try url("https://example.com/cover.jpg")))
    #expect(document.episodes.count == 2)

    let first = document.episodes[0]
    #expect(first.guid == "episode-1")
    #expect(first.title == "Preferred Episode Title")
    #expect(first.enclosureURL == (try url("https://cdn.example.com/one.mp3")))
    #expect(first.linkURL == (try url("https://example.com/podcast/episodes/one")))
    #expect(first.publicationDate?.millisecondsSince1970 == 784_903_526_000)
    #expect(first.durationMilliseconds == 3_723_000)
    #expect(first.summaryHTML == "<p>Full notes</p>")
    #expect(first.imageURL == (try url("https://example.com/episodes/one.jpg")))
    #expect(first.mimeType == "audio/mpeg")
    #expect(first.transcriptURL == (try url("https://cdn.example.com/one.vtt")))
    #expect(first.transcriptType == "text/vtt")
    #expect(first.chaptersURL == (try url("https://cdn.example.com/one-chapters.json")))
    #expect(first.chaptersType == "application/json+chapters")

    let second = document.episodes[1]
    #expect(second.guid == nil)
    #expect(second.enclosureURL == (try url("https://cdn.example.com/two.m4a")))
    #expect(second.durationMilliseconds == 90_500)
    #expect(second.imageURL == (try url("https://cdn.example.com/two.jpg")))
  }

  @Test
  func parsesAtomEntryLinksAndISO8601Dates() throws {
    let document = try FeedDocumentParser().parse(
      data: Data(atomFixture.utf8),
      sourceURL: try url("https://example.com/atom.xml")
    )

    #expect(document.format == .atom)
    #expect(document.title == "Atom Cast")
    #expect(document.author == "Atom Author")
    #expect(document.summaryHTML == "Atom summary")
    #expect(document.imageURL == (try url("https://example.com/images/atom.png")))
    #expect(document.episodes.count == 1)

    let episode = document.episodes[0]
    #expect(episode.guid == "tag:example.com,2026:episode-1")
    #expect(episode.title == "Atom Episode")
    #expect(episode.linkURL == (try url("https://example.com/episodes/atom-one")))
    #expect(episode.enclosureURL == (try url("https://cdn.example.com/atom-one.mp3")))
    #expect(episode.publicationDate?.millisecondsSince1970 == 1_767_324_096_789)
    #expect(episode.durationMilliseconds == 125_000)
    #expect(episode.summaryHTML == "Atom episode summary")
  }

  @Test
  func rejectsMalformedUnsupportedAndUntitledDocuments() throws {
    let parser = FeedDocumentParser()
    let sourceURL = try url("https://example.com/feed")

    #expect(throws: FeedParseError.malformedXML) {
      try parser.parse(data: Data("<rss><channel>".utf8), sourceURL: sourceURL)
    }
    #expect(throws: FeedParseError.unsupportedDocument) {
      try parser.parse(data: Data("<opml version=\"2.0\"/>".utf8), sourceURL: sourceURL)
    }
    #expect(throws: FeedParseError.prohibitedDTD) {
      try parser.parse(
        data: Data(
          "<!DOCTYPE rss [<!ENTITY expansion \"not allowed\">]><rss><channel><title>&expansion;</title></channel></rss>"
            .utf8
        ),
        sourceURL: sourceURL
      )
    }
    #expect(throws: FeedParseError.missingFeedTitle) {
      try parser.parse(
        data: Data(
          "<rss version=\"2.0\"><channel><description>x</description></channel></rss>".utf8),
        sourceURL: sourceURL
      )
    }
  }

  private var rssFixture: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"
         xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
         xmlns:content="http://purl.org/rss/1.0/modules/content/"
         xmlns:media="http://search.yahoo.com/mrss/"
         xmlns:podcast="https://podcastindex.org/namespace/1.0">
      <channel>
        <title>  Sample &amp; Cast  </title>
        <itunes:author>Example Author</itunes:author>
        <description><![CDATA[<p>About the show</p>]]></description>
        <itunes:image href="/cover.jpg"/>
        <item>
          <title>Fallback Episode Title</title>
          <itunes:title>Preferred Episode Title</itunes:title>
          <guid> episode-1 </guid>
          <link>episodes/one</link>
          <enclosure url="https://cdn.example.com/one.mp3" type="audio/mpeg" length="123"/>
          <pubDate>Tue, 15 Nov 1994 12:45:26 GMT</pubDate>
          <itunes:duration>01:02:03</itunes:duration>
          <description>Short notes</description>
          <content:encoded><![CDATA[<p>Full notes</p>]]></content:encoded>
          <itunes:image href="/episodes/one.jpg"/>
          <podcast:transcript url="https://cdn.example.com/one.vtt" type="text/vtt"/>
          <podcast:chapters url="https://cdn.example.com/one-chapters.json"
                            type="application/json+chapters"/>
        </item>
        <item>
          <title>Second Episode</title>
          <enclosure url="https://cdn.example.com/two.m4a" type="audio/mp4"/>
          <pubDate>15 Nov 1994 12:45:26 GMT</pubDate>
          <itunes:duration>90.5</itunes:duration>
          <media:thumbnail url="https://cdn.example.com/two.jpg"/>
        </item>
      </channel>
    </rss>
    """
  }

  private var atomFixture: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom"
          xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <title>Atom Cast</title>
      <author><name>Atom Author</name></author>
      <subtitle>Atom summary</subtitle>
      <logo>images/atom.png</logo>
      <entry>
        <id>tag:example.com,2026:episode-1</id>
        <title>Atom Episode</title>
        <link rel="alternate" href="/episodes/atom-one"/>
        <link rel="enclosure" href="https://cdn.example.com/atom-one.mp3" type="audio/mpeg"/>
        <published>2026-01-02T03:21:36.789Z</published>
        <summary type="html">Atom episode summary</summary>
        <itunes:duration>125</itunes:duration>
      </entry>
    </feed>
    """
  }

  private func url(_ value: String) throws -> URL {
    try #require(URL(string: value))
  }
}

extension Date {
  fileprivate var millisecondsSince1970: Int64 {
    Int64((timeIntervalSince1970 * 1_000).rounded())
  }
}
