import CoreContracts
import Testing

@testable import LocalData

struct AliasPersistenceTests {
  @Test
  func resolvesForwardAliasChainsAndLeavesCanonicalKeysUnchanged() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))

    try await store.recordAlias(
      from: "feed_old",
      to: "feed_redirected",
      kind: .feed,
      updatedAtMilliseconds: 1
    )
    try await store.recordAlias(
      from: "feed_redirected",
      to: "feed_current",
      kind: .feed,
      updatedAtMilliseconds: 2
    )

    #expect(try await store.resolveCanonicalKey("feed_old", kind: .feed) == "feed_current")
    #expect(
      try await store.resolveCanonicalKey("feed_redirected", kind: .feed) == "feed_current"
    )
    #expect(try await store.resolveCanonicalKey("feed_current", kind: .feed) == "feed_current")
  }

  @Test
  func repeatingAnIdenticalAliasIsIdempotent() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))

    try await store.recordAlias(
      from: "episode_old",
      to: "episode_current",
      kind: .episode,
      updatedAtMilliseconds: 1
    )
    try await store.recordAlias(
      from: "episode_old",
      to: "episode_current",
      kind: .episode,
      updatedAtMilliseconds: 2
    )

    #expect(
      try await store.resolveCanonicalKey("episode_old", kind: .episode) == "episode_current"
    )
  }

  @Test
  func rejectsRemappingAnExistingAlias() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    try await store.recordAlias(
      from: "feed_old",
      to: "feed_first",
      kind: .feed,
      updatedAtMilliseconds: 1
    )

    await #expect(
      throws: LocalDataError.aliasConflict(existing: "feed_first", requested: "feed_second")
    ) {
      try await store.recordAlias(
        from: "feed_old",
        to: "feed_second",
        kind: .feed,
        updatedAtMilliseconds: 2
      )
    }
    #expect(try await store.resolveCanonicalKey("feed_old", kind: .feed) == "feed_first")
  }

  @Test
  func rejectsDirectAndIndirectCycles() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))
    await #expect(throws: LocalDataError.aliasCycle) {
      try await store.recordAlias(
        from: "same",
        to: "same",
        kind: .feed,
        updatedAtMilliseconds: 1
      )
    }

    try await store.recordAlias(
      from: "a",
      to: "b",
      kind: .episode,
      updatedAtMilliseconds: 1
    )
    try await store.recordAlias(
      from: "b",
      to: "c",
      kind: .episode,
      updatedAtMilliseconds: 2
    )
    await #expect(throws: LocalDataError.aliasCycle) {
      try await store.recordAlias(
        from: "c",
        to: "a",
        kind: .episode,
        updatedAtMilliseconds: 3
      )
    }
    #expect(try await store.resolveCanonicalKey("a", kind: .episode) == "c")
  }

  @Test
  func rejectsEmptyKeysNegativeTimeAndCrossKindReuse() async throws {
    let store = try LocalDataStore.inMemory(deviceID: DeviceID("ios-phone"))

    await #expect(throws: LocalDataError.emptyAliasKey) {
      try await store.recordAlias(
        from: " ",
        to: "canonical",
        kind: .feed,
        updatedAtMilliseconds: 1
      )
    }
    await #expect(throws: LocalDataError.negativeTimestamp) {
      try await store.recordAlias(
        from: "old",
        to: "canonical",
        kind: .feed,
        updatedAtMilliseconds: -1
      )
    }

    try await store.recordAlias(
      from: "shared",
      to: "feed_current",
      kind: .feed,
      updatedAtMilliseconds: 1
    )
    await #expect(throws: LocalDataError.aliasKindMismatch) {
      try await store.resolveCanonicalKey("shared", kind: .episode)
    }
  }
}
