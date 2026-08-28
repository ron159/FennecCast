import Foundation

public enum StateSyncSettingsError: Error, Equatable, Sendable {
  case invalidServerURL
  case insecureServerURL
  case invalidToken
  case incompleteConfiguration
  case credentialStore
}

public struct SyncToken: RawRepresentable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) throws {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/="
    )
    guard
      (32...4_096).contains(rawValue.utf8.count),
      rawValue.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw StateSyncSettingsError.invalidToken
    }
    self.rawValue = rawValue
  }

  public init?(rawValue: String) {
    try? self.init(rawValue)
  }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }
}

public struct StateSyncConfiguration: Equatable, Sendable {
  public let serverURL: URL
  public let token: SyncToken

  public var endpointURL: URL {
    serverURL
      .appendingPathComponent("v1", isDirectory: true)
      .appendingPathComponent("sync", isDirectory: false)
  }

  public init(serverURL: URL, token: SyncToken) throws {
    guard
      var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      scheme == "http" || scheme == "https"
    else {
      throw StateSyncSettingsError.invalidServerURL
    }
    if scheme == "http", !Self.isLoopback(host) {
      throw StateSyncSettingsError.insecureServerURL
    }
    while components.path.count > 1, components.path.hasSuffix("/") {
      components.path.removeLast()
    }
    guard let normalizedURL = components.url else {
      throw StateSyncSettingsError.invalidServerURL
    }
    self.serverURL = normalizedURL
    self.token = token
  }

  private static func isLoopback(_ host: String) -> Bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1"
  }
}

public protocol SyncCredentialStoring: Sendable {
  func readToken() throws -> String?
  func saveToken(_ token: String) throws
  func deleteToken() throws
}

public final class StateSyncSettingsStore: @unchecked Sendable {
  private static let serverURLKey = "fenneccast.statesync.server-url"

  private let userDefaults: UserDefaults
  private let credentialStore: any SyncCredentialStoring

  public init(
    userDefaults: UserDefaults = .standard,
    credentialStore: any SyncCredentialStoring = KeychainSyncCredentialStore()
  ) {
    self.userDefaults = userDefaults
    self.credentialStore = credentialStore
  }

  public func load() throws -> StateSyncConfiguration? {
    let serverURLValue = userDefaults.string(forKey: Self.serverURLKey)
    let tokenValue: String?
    do {
      tokenValue = try credentialStore.readToken()
    } catch {
      throw StateSyncSettingsError.credentialStore
    }
    if serverURLValue == nil, tokenValue == nil {
      return nil
    }
    guard
      let serverURLValue,
      let serverURL = URL(string: serverURLValue),
      let tokenValue
    else {
      throw StateSyncSettingsError.incompleteConfiguration
    }
    return try StateSyncConfiguration(
      serverURL: serverURL,
      token: SyncToken(tokenValue)
    )
  }

  public func save(serverURL: URL, tokenValue: String) throws {
    let configuration = try StateSyncConfiguration(
      serverURL: serverURL,
      token: SyncToken(tokenValue)
    )
    do {
      try credentialStore.saveToken(configuration.token.rawValue)
    } catch {
      throw StateSyncSettingsError.credentialStore
    }
    userDefaults.set(configuration.serverURL.absoluteString, forKey: Self.serverURLKey)
  }

  public func clear() throws {
    do {
      try credentialStore.deleteToken()
    } catch {
      throw StateSyncSettingsError.credentialStore
    }
    userDefaults.removeObject(forKey: Self.serverURLKey)
  }
}
