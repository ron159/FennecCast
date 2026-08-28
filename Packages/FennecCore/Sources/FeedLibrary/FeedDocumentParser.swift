import Foundation

public struct FeedDocumentParser: Sendable {
  public init() {}

  public func parse(data: Data, sourceURL: URL) throws -> ParsedFeed {
    guard !containsDocumentTypeDeclaration(data) else {
      throw FeedParseError.prohibitedDTD
    }
    let accumulator = FeedXMLAccumulator(sourceURL: sourceURL)
    let parser = XMLParser(data: data)
    parser.delegate = accumulator
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false

    guard parser.parse() else {
      throw FeedParseError.malformedXML
    }
    return try accumulator.result()
  }
}

private func containsDocumentTypeDeclaration(_ data: Data) -> Bool {
  let marker = Array("<!doctype".utf8)
  var matched = 0
  for byte in data {
    guard byte != 0 else { continue }
    let normalized = byte >= 65 && byte <= 90 ? byte + 32 : byte
    if normalized == marker[matched] {
      matched += 1
      if matched == marker.count {
        return true
      }
    } else {
      matched = normalized == marker[0] ? 1 : 0
    }
  }
  return false
}

private final class FeedXMLAccumulator: NSObject, XMLParserDelegate {
  private struct Element {
    let name: String
    let namespace: String
    let qualifiedName: String
    let attributes: [String: String]
    var text = ""

    var isITunes: Bool {
      namespace.contains("itunes") || qualifiedName.hasPrefix("itunes:")
    }

    var isContentEncoded: Bool {
      (namespace.contains("purl.org/rss/1.0/modules/content")
        || qualifiedName.hasPrefix("content:")) && name == "encoded"
    }
  }

  private struct EpisodeBuilder {
    var guid: String?
    var enclosureURL: URL?
    var linkURL: URL?
    var title: String?
    var preferredTitle: String?
    var publicationDate: Date?
    var durationMilliseconds: Int64?
    var summaryHTML: String?
    var summaryPriority = 0
    var mimeType: String?

    mutating func setSummary(_ value: String?, priority: Int) {
      guard let value, priority >= summaryPriority else {
        return
      }
      summaryHTML = value
      summaryPriority = priority
    }

    func build() -> ParsedEpisode {
      ParsedEpisode(
        guid: guid,
        enclosureURL: enclosureURL,
        linkURL: linkURL,
        title: preferredTitle ?? title ?? "",
        publicationDate: publicationDate,
        durationMilliseconds: durationMilliseconds,
        summaryHTML: summaryHTML,
        mimeType: mimeType
      )
    }
  }

  private let sourceURL: URL
  private var stack: [Element] = []
  private var format: FeedFormat?
  private var feedTitle: String?
  private var preferredFeedTitle: String?
  private var feedAuthor: String?
  private var preferredFeedAuthor: String?
  private var feedSummary: String?
  private var feedImageURL: URL?
  private var episodes: [ParsedEpisode] = []
  private var episode: EpisodeBuilder?

  init(sourceURL: URL) {
    self.sourceURL = sourceURL
  }

  func result() throws -> ParsedFeed {
    guard let format else {
      throw FeedParseError.unsupportedDocument
    }
    guard let title = clean(preferredFeedTitle ?? feedTitle) else {
      throw FeedParseError.missingFeedTitle
    }
    return ParsedFeed(
      format: format,
      title: title,
      author: clean(preferredFeedAuthor ?? feedAuthor),
      summaryHTML: clean(feedSummary),
      imageURL: feedImageURL,
      episodes: episodes
    )
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let element = Element(
      name: elementName.lowercased(),
      namespace: (namespaceURI ?? "").lowercased(),
      qualifiedName: (qName ?? elementName).lowercased(),
      attributes: Dictionary(
        uniqueKeysWithValues: attributeDict.map { ($0.key.lowercased(), $0.value) }
      )
    )
    if stack.isEmpty {
      switch element.name {
      case "rss":
        format = .rss
      case "feed":
        format = .atom
      default:
        break
      }
    }
    stack.append(element)

    if element.name == "item" || element.name == "entry" {
      episode = EpisodeBuilder()
      return
    }

    if element.isITunes, element.name == "image", episode == nil,
      let href = element.attributes["href"]
    {
      feedImageURL = networkURL(href)
    }

    guard episode != nil else {
      return
    }
    switch element.name {
    case "enclosure":
      if let url = element.attributes["url"] {
        episode?.enclosureURL = networkURL(url)
      }
      episode?.mimeType = clean(element.attributes["type"])
    case "link" where format == .atom:
      let relation = clean(element.attributes["rel"])?.lowercased() ?? "alternate"
      guard let href = element.attributes["href"] else {
        return
      }
      if relation == "enclosure" {
        episode?.enclosureURL = networkURL(href)
        episode?.mimeType = clean(element.attributes["type"])
      } else if relation == "alternate", episode?.linkURL == nil {
        episode?.linkURL = networkURL(href)
      }
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text += string
  }

  func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text += String(decoding: cdataBlock, as: UTF8.self)
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard let element = stack.popLast() else {
      return
    }
    let parentName = stack.last?.name
    let value = clean(element.text)

    if element.name == "item" || element.name == "entry" {
      if let episode {
        episodes.append(episode.build())
      }
      episode = nil
      return
    }

    if episode != nil {
      applyEpisodeElement(element, value: value)
    } else {
      applyFeedElement(element, parentName: parentName, value: value)
    }
  }

  private func applyEpisodeElement(_ element: Element, value: String?) {
    switch element.name {
    case "title":
      if element.isITunes {
        episode?.preferredTitle = value
      } else {
        episode?.title = value
      }
    case "guid", "id":
      episode?.guid = value
    case "link" where format == .rss:
      if let value {
        episode?.linkURL = networkURL(value)
      }
    case "pubdate", "published":
      episode?.publicationDate = value.flatMap(FeedValueParser.date)
    case "updated" where episode?.publicationDate == nil:
      episode?.publicationDate = value.flatMap(FeedValueParser.date)
    case "duration" where element.isITunes:
      episode?.durationMilliseconds = value.flatMap(FeedValueParser.durationMilliseconds)
    case "encoded" where element.isContentEncoded:
      episode?.setSummary(value, priority: 2)
    case "description", "summary", "content":
      episode?.setSummary(value, priority: 1)
    default:
      break
    }
  }

  private func applyFeedElement(
    _ element: Element,
    parentName: String?,
    value: String?
  ) {
    switch element.name {
    case "title" where parentName == "channel" || parentName == "feed":
      if element.isITunes {
        preferredFeedTitle = value
      } else {
        feedTitle = value
      }
    case "author" where element.isITunes:
      preferredFeedAuthor = value
    case "managingeditor":
      feedAuthor = value
    case "name" where parentName == "author":
      feedAuthor = value
    case "description" where parentName == "channel":
      feedSummary = value
    case "subtitle" where parentName == "feed":
      feedSummary = value
    case "url" where parentName == "image":
      if let value {
        feedImageURL = networkURL(value)
      }
    case "logo",
      "icon" where parentName == "feed":
      if let value {
        feedImageURL = networkURL(value)
      }
    default:
      break
    }
  }

  private func networkURL(_ value: String) -> URL? {
    guard
      let url = URL(string: value, relativeTo: sourceURL)?.absoluteURL,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else {
      return nil
    }
    return url
  }
}

private enum FeedValueParser {
  static func date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
      return date
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) {
      return date
    }

    for format in [
      "EEE, dd MMM yyyy HH:mm:ss zzz",
      "EEE, d MMM yyyy HH:mm:ss zzz",
      "dd MMM yyyy HH:mm:ss zzz",
      "d MMM yyyy HH:mm:ss zzz",
    ] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return date
      }
    }
    return nil
  }

  static func durationMilliseconds(_ value: String) -> Int64? {
    let components = value.split(separator: ":", omittingEmptySubsequences: false)
    let seconds: Double
    switch components.count {
    case 1:
      guard let value = Double(components[0]) else { return nil }
      seconds = value
    case 2:
      guard
        let minutes = Double(components[0]),
        let remainder = Double(components[1]),
        remainder < 60
      else { return nil }
      seconds = minutes * 60 + remainder
    case 3:
      guard
        let hours = Double(components[0]),
        let minutes = Double(components[1]),
        let remainder = Double(components[2]),
        minutes < 60,
        remainder < 60
      else { return nil }
      seconds = hours * 3_600 + minutes * 60 + remainder
    default:
      return nil
    }
    guard seconds.isFinite, seconds >= 0, seconds <= Double(Int64.max) / 1_000 else {
      return nil
    }
    return Int64((seconds * 1_000).rounded())
  }
}

private func clean(_ value: String?) -> String? {
  guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    return nil
  }
  return value
}
