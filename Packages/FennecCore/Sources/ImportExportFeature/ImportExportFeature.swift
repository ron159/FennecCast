import CoreContracts
import Foundation

public enum OPMLCodecError: Error, Equatable, Sendable {
  case documentTooLarge
  case prohibitedDTD
  case malformedDocument
  case noSubscriptions
  case tooManySubscriptions
  case invalidSubscriptionURL
}

public struct OPMLSubscription: Equatable, Sendable {
  public let title: String?
  public let feedURL: URL
  public let siteURL: URL?

  public init(title: String?, feedURL: URL, siteURL: URL? = nil) {
    self.title = title
    self.feedURL = feedURL
    self.siteURL = siteURL
  }
}

public struct OPMLCodec: Sendable {
  public static let defaultMaximumBytes = 5 * 1_024 * 1_024
  public static let defaultMaximumSubscriptions = 5_000

  private let maximumBytes: Int
  private let maximumSubscriptions: Int

  public init(
    maximumBytes: Int = Self.defaultMaximumBytes,
    maximumSubscriptions: Int = Self.defaultMaximumSubscriptions
  ) {
    self.maximumBytes = max(1, maximumBytes)
    self.maximumSubscriptions = max(1, maximumSubscriptions)
  }

  public func decode(_ data: Data) throws -> [OPMLSubscription] {
    guard data.count <= maximumBytes else {
      throw OPMLCodecError.documentTooLarge
    }
    guard !containsDocumentTypeDeclaration(data) else {
      throw OPMLCodecError.prohibitedDTD
    }

    let accumulator = OPMLAccumulator(maximumSubscriptions: maximumSubscriptions)
    let parser = XMLParser(data: data)
    parser.delegate = accumulator
    parser.shouldProcessNamespaces = true
    parser.shouldReportNamespacePrefixes = false
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), accumulator.hasOPMLRoot else {
      if let failure = accumulator.failure {
        throw failure
      }
      throw OPMLCodecError.malformedDocument
    }
    if let failure = accumulator.failure {
      throw failure
    }
    guard !accumulator.subscriptions.isEmpty else {
      throw OPMLCodecError.noSubscriptions
    }
    return accumulator.subscriptions
  }

  public func encode(
    _ subscriptions: [OPMLSubscription],
    title: String = "FennecCast Subscriptions"
  ) throws -> Data {
    guard !subscriptions.isEmpty else {
      throw OPMLCodecError.noSubscriptions
    }
    guard subscriptions.count <= maximumSubscriptions else {
      throw OPMLCodecError.tooManySubscriptions
    }

    var seen = Set<FeedKey>()
    var outlines: [String] = []
    for subscription in subscriptions {
      guard
        isNetworkURL(subscription.feedURL),
        subscription.siteURL.map(isNetworkURL) ?? true
      else {
        throw OPMLCodecError.invalidSubscriptionURL
      }
      let key: FeedKey
      do {
        key = try FeedKey(canonicalURL: subscription.feedURL)
      } catch {
        throw OPMLCodecError.invalidSubscriptionURL
      }
      guard seen.insert(key).inserted else { continue }
      var attributes = [
        "type=\"rss\"",
        "xmlUrl=\"\(escape(subscription.feedURL.absoluteString))\"",
      ]
      if let displayTitle = clean(subscription.title) {
        attributes.insert("title=\"\(escape(displayTitle))\"", at: 0)
        attributes.insert("text=\"\(escape(displayTitle))\"", at: 0)
      }
      if let siteURL = subscription.siteURL {
        attributes.append("htmlUrl=\"\(escape(siteURL.absoluteString))\"")
      }
      outlines.append("    <outline \(attributes.joined(separator: " "))/>")
    }
    guard !outlines.isEmpty else {
      throw OPMLCodecError.noSubscriptions
    }

    let document =
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <opml version="2.0">
        <head><title>\(escape(title))</title></head>
        <body>
      \(outlines.joined(separator: "\n"))
        </body>
      </opml>

      """
    guard let data = document.data(using: .utf8), data.count <= maximumBytes else {
      throw OPMLCodecError.documentTooLarge
    }
    return data
  }
}

private final class OPMLAccumulator: NSObject, XMLParserDelegate {
  private let maximumSubscriptions: Int
  private var stack: [String] = []
  private var seen = Set<FeedKey>()

  private(set) var hasOPMLRoot = false
  private(set) var subscriptions: [OPMLSubscription] = []
  private(set) var failure: OPMLCodecError?

  init(maximumSubscriptions: Int) {
    self.maximumSubscriptions = maximumSubscriptions
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = elementName.lowercased()
    if stack.isEmpty {
      hasOPMLRoot = name == "opml"
    }
    let isInsideBody = stack.contains("body")
    stack.append(name)
    guard hasOPMLRoot, isInsideBody, name == "outline" else { return }

    var attributes: [String: String] = [:]
    for (key, value) in attributeDict {
      attributes[key.lowercased()] = value
    }
    guard
      let rawFeedURL = clean(attributes["xmlurl"]),
      let feedURL = URL(string: rawFeedURL),
      isNetworkURL(feedURL)
    else { return }
    let feedKey: FeedKey
    do {
      feedKey = try FeedKey(canonicalURL: feedURL)
    } catch {
      return
    }
    guard seen.insert(feedKey).inserted else { return }
    guard subscriptions.count < maximumSubscriptions else {
      failure = .tooManySubscriptions
      parser.abortParsing()
      return
    }
    let siteURL = clean(attributes["htmlurl"])
      .flatMap(URL.init(string:))
      .flatMap { isNetworkURL($0) ? $0 : nil }
    subscriptions.append(
      OPMLSubscription(
        title: clean(attributes["title"]) ?? clean(attributes["text"]),
        feedURL: feedURL,
        siteURL: siteURL
      )
    )
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    _ = stack.popLast()
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

private func isNetworkURL(_ url: URL) -> Bool {
  guard
    let scheme = url.scheme?.lowercased(),
    scheme == "http" || scheme == "https"
  else { return false }
  return url.host?.isEmpty == false
}

private func clean(_ value: String?) -> String? {
  guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    return nil
  }
  return value
}

private func escape(_ value: String) -> String {
  value
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "\"", with: "&quot;")
    .replacingOccurrences(of: "'", with: "&apos;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
}
