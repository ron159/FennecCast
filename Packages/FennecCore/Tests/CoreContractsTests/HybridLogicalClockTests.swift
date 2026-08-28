import Foundation
import Testing

@testable import CoreContracts

struct HybridLogicalClockTests {
  @Test
  func timestampValidationAndOrdering() throws {
    #expect(throws: ClockError.negativeWallMilliseconds) {
      try HLCTimestamp(wallMilliseconds: -1, counter: 0)
    }
    #expect(throws: ClockError.negativeCounter) {
      try HLCTimestamp(wallMilliseconds: 0, counter: -1)
    }

    let olderWall = try HLCTimestamp(wallMilliseconds: 99, counter: 20)
    let olderCounter = try HLCTimestamp(wallMilliseconds: 100, counter: 1)
    let newerCounter = try HLCTimestamp(wallMilliseconds: 100, counter: 2)

    #expect(olderWall < olderCounter)
    #expect(olderCounter < newerCounter)
  }

  @Test
  func localTicksNeverMoveBackward() throws {
    var clock = HybridLogicalClock()

    let first = try clock.tick(physicalTimeMilliseconds: 100)
    let sameWall = try clock.tick(physicalTimeMilliseconds: 100)
    let clockRollback = try clock.tick(physicalTimeMilliseconds: 90)

    #expect(first == HLCTimestamp(uncheckedWallMilliseconds: 100, counter: 0))
    #expect(sameWall == HLCTimestamp(uncheckedWallMilliseconds: 100, counter: 1))
    #expect(clockRollback == HLCTimestamp(uncheckedWallMilliseconds: 100, counter: 2))
  }

  @Test
  func observingRemoteTimestampFollowsMaxWallAlgorithm() throws {
    var clock = HybridLogicalClock(
      initial: try HLCTimestamp(wallMilliseconds: 100, counter: 3)
    )

    let sameWall = try clock.observe(
      try HLCTimestamp(wallMilliseconds: 100, counter: 7),
      physicalTimeMilliseconds: 90
    )
    #expect(sameWall == HLCTimestamp(uncheckedWallMilliseconds: 100, counter: 8))

    let remoteAhead = try clock.observe(
      try HLCTimestamp(wallMilliseconds: 120, counter: 2),
      physicalTimeMilliseconds: 110
    )
    #expect(remoteAhead == HLCTimestamp(uncheckedWallMilliseconds: 120, counter: 3))

    let physicalAhead = try clock.observe(
      try HLCTimestamp(wallMilliseconds: 110, counter: 50),
      physicalTimeMilliseconds: 130
    )
    #expect(physicalAhead == HLCTimestamp(uncheckedWallMilliseconds: 130, counter: 0))
  }

  @Test
  func versionStampUsesDeviceIDAsFinalTieBreaker() throws {
    let timestamp = try HLCTimestamp(wallMilliseconds: 100, counter: 2)
    let ios = VersionStamp(timestamp: timestamp, deviceID: try DeviceID("ios-phone"))
    let android = VersionStamp(timestamp: timestamp, deviceID: try DeviceID("android-phone"))

    #expect(android < ios)
    #expect(ios > android)
    #expect(throws: ClockError.emptyDeviceID) {
      try DeviceID("  ")
    }
  }

  @Test
  func timestampUsesWireCodingKeys() throws {
    let timestamp = try HLCTimestamp(wallMilliseconds: 1_787_935_800_123, counter: 2)
    let data = try JSONEncoder().encode(timestamp)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Int64]
    )

    #expect(object == ["wall_ms": 1_787_935_800_123, "counter": 2])
    #expect(try JSONDecoder().decode(HLCTimestamp.self, from: data) == timestamp)
  }

  @Test
  func clockRejectsNegativePhysicalTimeAndCounterOverflow() throws {
    var clock = HybridLogicalClock(
      initial: try HLCTimestamp(wallMilliseconds: 100, counter: Int64.max)
    )

    #expect(throws: ClockError.negativePhysicalTime) {
      try clock.tick(physicalTimeMilliseconds: -1)
    }
    #expect(throws: ClockError.counterOverflow) {
      try clock.tick(physicalTimeMilliseconds: 100)
    }
  }
}
