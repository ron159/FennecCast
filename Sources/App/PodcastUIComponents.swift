import Foundation
import SwiftUI

enum SubscriptionLayout: String, CaseIterable, Identifiable {
  case list
  case compactGrid
  case artworkGrid

  static let storageKey = "subscriptions.layout"

  var id: String { rawValue }

  static func restored(from rawValue: String?) -> SubscriptionLayout {
    rawValue.flatMap(Self.init(rawValue:)) ?? .artworkGrid
  }

  var titleKey: LocalizedStringKey {
    switch self {
    case .list: "subscriptions.layout.list"
    case .compactGrid: "subscriptions.layout.compact"
    case .artworkGrid: "subscriptions.layout.artwork"
    }
  }

  var systemImage: String {
    switch self {
    case .list: "list.bullet"
    case .compactGrid: "square.grid.3x3"
    case .artworkGrid: "square.grid.2x2"
    }
  }

  var minimumColumnWidth: CGFloat {
    switch self {
    case .list: 0
    case .compactGrid: 92
    case .artworkGrid: 148
    }
  }
}

enum FeedMarkup {
  static let maximumCharacterCount = 200_000

  static func plainText(from html: String) -> String {
    var value = sanitizedHTML(html)
    value = value.replacingOccurrences(
      of: #"(?i)<br\s*/?>"#,
      with: "\n",
      options: .regularExpression
    )
    value = value.replacingOccurrences(
      of: #"(?i)</(p|div|section|article|h[1-6])\s*>"#,
      with: "\n\n",
      options: .regularExpression
    )
    value = value.replacingOccurrences(
      of: #"(?i)<li\b[^>]*>"#,
      with: "• ",
      options: .regularExpression
    )
    value = value.replacingOccurrences(
      of: #"(?i)</(li|tr)\s*>"#,
      with: "\n",
      options: .regularExpression
    )
    value = value.replacingOccurrences(
      of: #"(?i)</(ul|ol|table|blockquote)\s*>"#,
      with: "\n\n",
      options: .regularExpression
    )
    value = value.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: "<", with: "")
    value = value.replacingOccurrences(of: ">", with: "")
    return normalizeWhitespace(decodeHTMLEntities(value))
  }

  static func attributedString(from html: String) -> AttributedString {
    let safeHTML = sanitizedHTML(html)
    guard
      let data = safeHTML.data(using: .utf8),
      let imported = try? NSAttributedString(
        data: data,
        options: [
          .documentType: NSAttributedString.DocumentType.html,
          .characterEncoding: String.Encoding.utf8.rawValue,
        ],
        documentAttributes: nil
      ),
      !imported.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return AttributedString(plainText(from: html))
    }
    return AttributedString(imported)
  }

  private static func sanitizedHTML(_ html: String) -> String {
    var value = String(html.prefix(maximumCharacterCount))
    value = value.replacingOccurrences(
      of: #"(?is)<(script|style|iframe|object|svg)\b[^>]*>.*?</\1\s*>"#,
      with: "",
      options: .regularExpression
    )
    value = value.replacingOccurrences(
      of: #"(?is)<(img|embed|source|video|audio)\b[^>]*>"#,
      with: "",
      options: .regularExpression
    )
    value = value.replacingOccurrences(
      of: #"(?is)<(link|meta|base|form|input|button|textarea|select)\b[^>]*>"#,
      with: "",
      options: .regularExpression
    )
    value = value.replacingOccurrences(
      of: #"(?is)</?a\b[^>]*>"#,
      with: "",
      options: .regularExpression
    )
    value = value.replacingOccurrences(
      of: #"(?is)\s+(style|class|id|on[a-z]+)\s*=\s*(\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
      with: "",
      options: .regularExpression
    )
    return value
  }

  private static func decodeHTMLEntities(_ value: String) -> String {
    var result = ""
    var index = value.startIndex
    while index < value.endIndex {
      guard value[index] == "&",
        let semicolon = value[index...].firstIndex(of: ";"),
        value.distance(from: index, to: semicolon) <= 12
      else {
        result.append(value[index])
        index = value.index(after: index)
        continue
      }
      let entityStart = value.index(after: index)
      let entity = String(value[entityStart..<semicolon])
      if let decoded = decodedEntity(entity) {
        result.append(decoded)
        index = value.index(after: semicolon)
      } else {
        result.append(contentsOf: value[index...semicolon])
        index = value.index(after: semicolon)
      }
    }
    return result
  }

  private static func decodedEntity(_ entity: String) -> Character? {
    let named: [String: Character] = [
      "amp": "&", "apos": "'", "gt": ">", "lt": "<", "nbsp": " ", "quot": "\"",
    ]
    if let value = named[entity.lowercased()] {
      return value
    }
    let number: UInt32?
    if entity.lowercased().hasPrefix("#x") {
      number = UInt32(entity.dropFirst(2), radix: 16)
    } else if entity.hasPrefix("#") {
      number = UInt32(entity.dropFirst(), radix: 10)
    } else {
      number = nil
    }
    guard let number, let scalar = UnicodeScalar(number) else { return nil }
    return Character(scalar)
  }

  private static func normalizeWhitespace(_ value: String) -> String {
    let normalized =
      value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
      .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
      .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
    return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct PodcastArtwork: View {
  let url: URL?
  let title: String
  var cornerRadius: CGFloat = 12

  var body: some View {
    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .scaledToFill()
      case .empty:
        placeholder
          .overlay { ProgressView().controlSize(.small) }
      case .failure:
        placeholder
      @unknown default:
        placeholder
      }
    }
    .aspectRatio(1, contentMode: .fill)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .accessibilityLabel(title)
  }

  private var placeholder: some View {
    ZStack {
      Color.secondary.opacity(0.12)
      Text(monogram)
        .font(.title2.weight(.bold))
        .foregroundStyle(.secondary)
    }
  }

  private var monogram: String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.first.map { String($0).uppercased() } ?? "F"
  }
}

struct FeedMarkupText: View {
  let html: String

  var body: some View {
    Text(FeedMarkup.attributedString(from: html))
      .font(.body)
      .lineSpacing(5)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }
}
