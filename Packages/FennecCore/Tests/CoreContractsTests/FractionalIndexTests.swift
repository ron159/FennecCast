import Foundation
import Testing

@testable import CoreContracts

struct FractionalIndexTests {
  @Test
  func createsInitialPrependAndAppendTokens() throws {
    let initial = try FractionalIndex.between(lower: nil, upper: nil)
    let prepended = try FractionalIndex.between(lower: nil, upper: initial)
    let appended = try FractionalIndex.between(lower: initial, upper: nil)

    #expect(initial.rawValue == "7fffffffffffffff")
    #expect(prepended.rawValue == "3fffffffffffffff")
    #expect(appended.rawValue == "bfffffffffffffff")
    #expect(prepended < initial)
    #expect(initial < appended)
    #expect(prepended.rawValue < initial.rawValue)
  }

  @Test
  func insertsBetweenExistingTokens() throws {
    let lower = try FractionalIndex(rawValue: "2000000000000000")
    let upper = try FractionalIndex(rawValue: "4000000000000000")

    let middle = try FractionalIndex.between(lower: lower, upper: upper)

    #expect(middle.rawValue == "3000000000000000")
  }

  @Test
  func rejectsMalformedAndZeroTokens() {
    #expect(throws: FractionalIndexError.invalidToken("1")) {
      try FractionalIndex(rawValue: "1")
    }
    #expect(throws: FractionalIndexError.invalidToken("0000000000000000")) {
      try FractionalIndex(rawValue: "0000000000000000")
    }
    #expect(throws: FractionalIndexError.invalidToken("7FFFFFFFFFFFFFFF")) {
      try FractionalIndex(rawValue: "7FFFFFFFFFFFFFFF")
    }
  }

  @Test
  func rejectsInvalidBoundsAndExhaustedGap() throws {
    let one = try FractionalIndex(rawValue: "0000000000000001")
    let two = try FractionalIndex(rawValue: "0000000000000002")

    #expect(throws: FractionalIndexError.invalidBounds) {
      try FractionalIndex.between(lower: two, upper: one)
    }
    #expect(throws: FractionalIndexError.exhaustedSpace) {
      try FractionalIndex.between(lower: one, upper: two)
    }
    #expect(throws: FractionalIndexError.exhaustedSpace) {
      try FractionalIndex.between(lower: nil, upper: one)
    }
  }

  @Test
  func rebaseAssignsDeterministicEvenSpacing() throws {
    let rebased = try FractionalIndex.rebase(count: 3)

    #expect(
      rebased.map(\.rawValue) == [
        "3fffffffffffffff",
        "7ffffffffffffffe",
        "bffffffffffffffd",
      ]
    )
    #expect(try FractionalIndex.rebase(count: 0).isEmpty)
  }

  @Test
  func codableUsesTheTokenString() throws {
    let token = try FractionalIndex(rawValue: "3000000000000000")
    let data = try JSONEncoder().encode(token)

    #expect(String(decoding: data, as: UTF8.self) == "\"3000000000000000\"")
    #expect(try JSONDecoder().decode(FractionalIndex.self, from: data) == token)
  }
}
