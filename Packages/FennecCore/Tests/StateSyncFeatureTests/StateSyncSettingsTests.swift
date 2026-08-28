import Foundation
import Testing

@testable import StateSyncFeature

struct StateSyncSettingsTests {
  @Test
  func validatesServerURLsAndBearerTokens() throws {
    let tokenValue = String(repeating: "a", count: 32)
    let token = try SyncToken(tokenValue)
    let secure = try StateSyncConfiguration(
      serverURL: #require(URL(string: "https://nas.example.com/sync/")),
      token: token
    )
    let loopback = try StateSyncConfiguration(
      serverURL: #require(URL(string: "http://127.0.0.1:8080")),
      token: token
    )

    #expect(secure.endpointURL.absoluteString == "https://nas.example.com/sync/v1/sync")
    #expect(loopback.endpointURL.absoluteString == "http://127.0.0.1:8080/v1/sync")
    #expect(throws: StateSyncSettingsError.insecureServerURL) {
      try StateSyncConfiguration(
        serverURL: #require(URL(string: "http://nas.example.com")),
        token: token
      )
    }
    #expect(throws: StateSyncSettingsError.invalidServerURL) {
      try StateSyncConfiguration(
        serverURL: #require(URL(string: "https://user:password@nas.example.com")),
        token: token
      )
    }
    #expect(throws: StateSyncSettingsError.invalidServerURL) {
      try StateSyncConfiguration(
        serverURL: #require(URL(string: "https://nas.example.com?token=bad")),
        token: token
      )
    }
    #expect(throws: StateSyncSettingsError.invalidToken) {
      try SyncToken("too-short")
    }
    #expect(throws: StateSyncSettingsError.invalidToken) {
      try SyncToken(String(repeating: "a", count: 31) + " ")
    }
  }

  @Test
  func storesOnlyServerURLInPreferencesAndTokenInCredentialStore() throws {
    let suiteName = "StateSyncSettingsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let credentials = MemoryCredentialStore()
    let settings = StateSyncSettingsStore(
      userDefaults: defaults,
      credentialStore: credentials
    )
    let tokenValue = String(repeating: "b", count: 40)

    try settings.save(
      serverURL: #require(URL(string: "https://nas.example.com")),
      tokenValue: tokenValue
    )
    let loaded = try #require(try settings.load())

    #expect(loaded.serverURL.absoluteString == "https://nas.example.com")
    #expect(loaded.token.rawValue == tokenValue)
    #expect(credentials.token == tokenValue)
    let tokenLeaked = defaults.dictionaryRepresentation().values.contains { value in
      String(describing: value).contains(tokenValue)
    }
    #expect(!tokenLeaked)

    try settings.clear()
    #expect(try settings.load() == nil)
    #expect(credentials.token == nil)
  }
}

private final class MemoryCredentialStore: @unchecked Sendable, SyncCredentialStoring {
  private let lock = NSLock()
  private var storedToken: String?

  var token: String? {
    lock.withLock { storedToken }
  }

  func readToken() throws -> String? {
    token
  }

  func saveToken(_ token: String) throws {
    lock.withLock { storedToken = token }
  }

  func deleteToken() throws {
    lock.withLock { storedToken = nil }
  }
}
