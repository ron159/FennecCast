import CryptoKit
import Foundation

public enum CanonicalIdentityError: Error, Equatable, Sendable {
  case invalidURL(String)
  case unsupportedURLScheme(String)
  case missingEpisodeLocator
}

public struct FeedKey: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(canonicalURL: URL) throws {
    let normalizedURL = try CanonicalURL.normalize(canonicalURL)
    self.init(rawValue: StableHash.sha256("feed:v1:\(normalizedURL)"))
  }
}

public struct EpisodeKey: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(input: EpisodeIdentityInput) throws {
    let locator = try input.canonicalLocator()
    self.init(
      rawValue: StableHash.sha256(
        "episode:v1:\(input.feedKey.rawValue):\(locator)"
      )
    )
  }
}

public struct EpisodeIdentityInput: Equatable, Sendable {
  public let feedKey: FeedKey
  public let guid: String?
  public let enclosureURL: URL?
  public let linkURL: URL?
  public let publicationDate: Date?
  public let title: String?
  public let durationMilliseconds: Int64?

  public init(
    feedKey: FeedKey,
    guid: String? = nil,
    enclosureURL: URL? = nil,
    linkURL: URL? = nil,
    publicationDate: Date? = nil,
    title: String? = nil,
    durationMilliseconds: Int64? = nil
  ) {
    self.feedKey = feedKey
    self.guid = guid
    self.enclosureURL = enclosureURL
    self.linkURL = linkURL
    self.publicationDate = publicationDate
    self.title = title
    self.durationMilliseconds = durationMilliseconds
  }

  fileprivate func canonicalLocator() throws -> String {
    if let guid = guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty {
      return guid
    }

    if let enclosureURL {
      return try CanonicalURL.normalize(enclosureURL)
    }

    if let linkURL, let publicationDate {
      return try "\(CanonicalURL.normalize(linkURL))|\(publicationDate.millisecondsSince1970)"
    }

    if let title,
      let publicationDate,
      let durationMilliseconds,
      durationMilliseconds >= 0
    {
      let normalizedTitle = title.normalizedIdentityText
      if !normalizedTitle.isEmpty {
        return "\(normalizedTitle)|\(publicationDate.millisecondsSince1970)|\(durationMilliseconds)"
      }
    }

    throw CanonicalIdentityError.missingEpisodeLocator
  }
}

private enum CanonicalURL {
  static func normalize(_ url: URL) throws -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw CanonicalIdentityError.invalidURL(url.absoluteString)
    }

    let scheme = components.scheme?.lowercased() ?? ""
    guard scheme == "http" || scheme == "https" else {
      throw CanonicalIdentityError.unsupportedURLScheme(scheme)
    }
    guard let host = components.host, !host.isEmpty else {
      throw CanonicalIdentityError.invalidURL(url.absoluteString)
    }

    components.scheme = scheme
    components.host = host.lowercased()
    components.fragment = nil

    if (scheme == "http" && components.port == 80)
      || (scheme == "https" && components.port == 443)
    {
      components.port = nil
    }

    if components.path == "/" {
      components.path = ""
    }

    if let queryItems = components.queryItems, !queryItems.isEmpty {
      components.queryItems = queryItems.sorted {
        if $0.name != $1.name {
          return $0.name < $1.name
        }
        return ($0.value ?? "") < ($1.value ?? "")
      }
    }

    guard let normalized = components.string else {
      throw CanonicalIdentityError.invalidURL(url.absoluteString)
    }
    return normalized
  }
}

private enum StableHash {
  static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

extension Date {
  fileprivate var millisecondsSince1970: Int64 {
    Int64((timeIntervalSince1970 * 1_000).rounded())
  }
}

extension String {
  fileprivate var normalizedIdentityText: String {
    precomposedStringWithCompatibilityMapping
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .lowercased(with: Locale(identifier: "en_US_POSIX"))
  }
}
