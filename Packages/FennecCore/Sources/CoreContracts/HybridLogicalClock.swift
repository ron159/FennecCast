import Foundation

public enum ClockError: Error, Equatable, Sendable {
  case negativeWallMilliseconds
  case negativeCounter
  case negativePhysicalTime
  case counterOverflow
  case emptyDeviceID
}

public struct HLCTimestamp: Codable, Hashable, Comparable, Sendable {
  public static let zero = HLCTimestamp(uncheckedWallMilliseconds: 0, counter: 0)

  public let wallMilliseconds: Int64
  public let counter: Int64

  public init(wallMilliseconds: Int64, counter: Int64) throws {
    guard wallMilliseconds >= 0 else {
      throw ClockError.negativeWallMilliseconds
    }
    guard counter >= 0 else {
      throw ClockError.negativeCounter
    }
    self.wallMilliseconds = wallMilliseconds
    self.counter = counter
  }

  init(uncheckedWallMilliseconds: Int64, counter: Int64) {
    wallMilliseconds = uncheckedWallMilliseconds
    self.counter = counter
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.wallMilliseconds != rhs.wallMilliseconds {
      return lhs.wallMilliseconds < rhs.wallMilliseconds
    }
    return lhs.counter < rhs.counter
  }

  private enum CodingKeys: String, CodingKey {
    case wallMilliseconds = "wall_ms"
    case counter
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      wallMilliseconds: container.decode(Int64.self, forKey: .wallMilliseconds),
      counter: container.decode(Int64.self, forKey: .counter)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(wallMilliseconds, forKey: .wallMilliseconds)
    try container.encode(counter, forKey: .counter)
  }
}

public struct DeviceID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw ClockError.emptyDeviceID
    }
    self.rawValue = trimmed
  }

  public init?(rawValue: String) {
    try? self.init(rawValue)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct VersionStamp: Codable, Hashable, Comparable, Sendable {
  public let timestamp: HLCTimestamp
  public let deviceID: DeviceID

  public init(timestamp: HLCTimestamp, deviceID: DeviceID) {
    self.timestamp = timestamp
    self.deviceID = deviceID
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.timestamp != rhs.timestamp {
      return lhs.timestamp < rhs.timestamp
    }
    return lhs.deviceID < rhs.deviceID
  }

  private enum CodingKeys: String, CodingKey {
    case timestamp = "hlc"
    case deviceID = "device_id"
  }
}

public struct HybridLogicalClock: Sendable {
  public private(set) var last: HLCTimestamp

  public init(initial: HLCTimestamp = .zero) {
    last = initial
  }

  @discardableResult
  public mutating func tick(physicalTimeMilliseconds: Int64) throws -> HLCTimestamp {
    try validatePhysicalTime(physicalTimeMilliseconds)

    if physicalTimeMilliseconds > last.wallMilliseconds {
      last = HLCTimestamp(
        uncheckedWallMilliseconds: physicalTimeMilliseconds,
        counter: 0
      )
    } else {
      last = HLCTimestamp(
        uncheckedWallMilliseconds: last.wallMilliseconds,
        counter: try increment(last.counter)
      )
    }
    return last
  }

  @discardableResult
  public mutating func observe(
    _ remote: HLCTimestamp,
    physicalTimeMilliseconds: Int64
  ) throws -> HLCTimestamp {
    try validatePhysicalTime(physicalTimeMilliseconds)

    let wall = max(last.wallMilliseconds, remote.wallMilliseconds, physicalTimeMilliseconds)
    let counter: Int64
    if wall == last.wallMilliseconds && wall == remote.wallMilliseconds {
      counter = try increment(max(last.counter, remote.counter))
    } else if wall == last.wallMilliseconds {
      counter = try increment(last.counter)
    } else if wall == remote.wallMilliseconds {
      counter = try increment(remote.counter)
    } else {
      counter = 0
    }

    last = HLCTimestamp(uncheckedWallMilliseconds: wall, counter: counter)
    return last
  }

  private func validatePhysicalTime(_ value: Int64) throws {
    guard value >= 0 else {
      throw ClockError.negativePhysicalTime
    }
  }

  private func increment(_ value: Int64) throws -> Int64 {
    let (result, overflow) = value.addingReportingOverflow(1)
    guard !overflow else {
      throw ClockError.counterOverflow
    }
    return result
  }
}

public actor StateSyncClock {
  private var clock: HybridLogicalClock

  public init(initial: HLCTimestamp = .zero) {
    self.clock = HybridLogicalClock(initial: initial)
  }

  public var last: HLCTimestamp {
    clock.last
  }

  public func restore(_ timestamp: HLCTimestamp) {
    guard timestamp > clock.last else { return }
    clock = HybridLogicalClock(initial: timestamp)
  }

  @discardableResult
  public func tick(physicalTimeMilliseconds: Int64) throws -> HLCTimestamp {
    try clock.tick(physicalTimeMilliseconds: physicalTimeMilliseconds)
  }

  @discardableResult
  public func observe(
    _ remote: HLCTimestamp,
    physicalTimeMilliseconds: Int64
  ) throws -> HLCTimestamp {
    try clock.observe(remote, physicalTimeMilliseconds: physicalTimeMilliseconds)
  }
}
