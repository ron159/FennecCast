import Foundation

public enum FractionalIndexError: Error, Equatable, Sendable {
  case invalidToken(String)
  case invalidBounds
  case exhaustedSpace
  case invalidCount
}

public struct FractionalIndex: Codable, Hashable, Comparable, Sendable {
  public let rawValue: String

  private let numericValue: UInt64

  public init(rawValue: String) throws {
    guard
      rawValue.utf8.count == 16,
      rawValue.utf8.allSatisfy({
        (Character("0").asciiValue!...Character("9").asciiValue!).contains($0)
          || (Character("a").asciiValue!...Character("f").asciiValue!).contains($0)
      }),
      let numericValue = UInt64(rawValue, radix: 16),
      numericValue > 0
    else {
      throw FractionalIndexError.invalidToken(rawValue)
    }

    self.rawValue = rawValue
    self.numericValue = numericValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public static func between(
    lower: Self?,
    upper: Self?
  ) throws -> Self {
    let lowerValue = lower?.numericValue ?? 0
    let upperValue = upper?.numericValue ?? UInt64.max

    if lower != nil, upper != nil, lowerValue >= upperValue {
      throw FractionalIndexError.invalidBounds
    }
    guard lowerValue < upperValue, upperValue - lowerValue > 1 else {
      throw FractionalIndexError.exhaustedSpace
    }

    return make(uncheckedValue: lowerValue + (upperValue - lowerValue) / 2)
  }

  public static func rebase(count: Int) throws -> [Self] {
    guard count >= 0 else {
      throw FractionalIndexError.invalidCount
    }
    guard count > 0 else {
      return []
    }

    let denominator = UInt64(count) + 1
    let step = UInt64.max / denominator
    guard step > 0 else {
      throw FractionalIndexError.exhaustedSpace
    }

    return (1...count).map { index in
      make(uncheckedValue: step * UInt64(index))
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(rawValue: container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private init(uncheckedValue: UInt64) {
    numericValue = uncheckedValue
    let hexadecimal = String(uncheckedValue, radix: 16, uppercase: false)
    rawValue = String(repeating: "0", count: 16 - hexadecimal.count) + hexadecimal
  }

  private static func make(uncheckedValue: UInt64) -> Self {
    Self(uncheckedValue: uncheckedValue)
  }
}
