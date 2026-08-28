import CoreContracts
import Testing

struct StateSyncClockTests {
  @Test
  func serializesConcurrentTicksAndRestoresWithoutRegression() async throws {
    let initial = try HLCTimestamp(wallMilliseconds: 100, counter: 2)
    let expectedThird = try HLCTimestamp(wallMilliseconds: 100, counter: 3)
    let expectedFourth = try HLCTimestamp(wallMilliseconds: 100, counter: 4)
    let restored = try HLCTimestamp(wallMilliseconds: 200, counter: 1)
    let clock = StateSyncClock(initial: initial)

    async let first = clock.tick(physicalTimeMilliseconds: 90)
    async let second = clock.tick(physicalTimeMilliseconds: 90)
    let timestamps = try await [first, second].sorted()

    #expect(timestamps == [expectedThird, expectedFourth])
    await clock.restore(try HLCTimestamp(wallMilliseconds: 50, counter: 0))
    #expect(await clock.last == expectedFourth)
    await clock.restore(restored)
    #expect(await clock.last == restored)
  }

  @Test
  func observingRemoteTimestampAdvancesTheSharedClock() async throws {
    let clock = StateSyncClock()

    let remote = try HLCTimestamp(wallMilliseconds: 500, counter: 7)
    let expectedObserved = try HLCTimestamp(wallMilliseconds: 500, counter: 8)
    let expectedLocal = try HLCTimestamp(wallMilliseconds: 500, counter: 9)
    let observed = try await clock.observe(
      remote,
      physicalTimeMilliseconds: 100
    )
    let local = try await clock.tick(physicalTimeMilliseconds: 100)

    #expect(observed == expectedObserved)
    #expect(local == expectedLocal)
  }
}
