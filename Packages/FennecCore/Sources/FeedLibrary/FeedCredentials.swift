import CoreContracts
import Foundation
import Security

public enum FeedCredentialError: Error, Equatable, Sendable {
  case invalidUsername
  case invalidPassword
  case credentialStore
}

public struct FeedCredentials: Codable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let username: String
  public let password: String

  public init(username: String, password: String) throws {
    guard
      (1...256).contains(username.utf8.count),
      !Self.containsUnsafeControlCharacter(username)
    else {
      throw FeedCredentialError.invalidUsername
    }
    guard
      password.utf8.count <= 1_024,
      !Self.containsUnsafeControlCharacter(password)
    else {
      throw FeedCredentialError.invalidPassword
    }
    self.username = username
    self.password = password
  }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }

  private enum CodingKeys: String, CodingKey {
    case username
    case password
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      username: container.decode(String.self, forKey: .username),
      password: container.decode(String.self, forKey: .password)
    )
  }

  private static func containsUnsafeControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      scalar.value == 0 || scalar.value == 10 || scalar.value == 13
    }
  }
}

public protocol FeedCredentialStoring: Sendable {
  func readCredentials(for feedKey: FeedKey) throws -> FeedCredentials?
  func saveCredentials(_ credentials: FeedCredentials, for feedKey: FeedKey) throws
  func deleteCredentials(for feedKey: FeedKey) throws
}

public struct KeychainFeedCredentialStore: FeedCredentialStoring {
  private let service: String

  public init(service: String = "com.ron159.FennecCast.FeedCredentials") {
    self.service = service
  }

  public func readCredentials(for feedKey: FeedKey) throws -> FeedCredentials? {
    var query = baseQuery(for: feedKey)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      throw FeedCredentialError.credentialStore
    }
    do {
      return try JSONDecoder().decode(FeedCredentials.self, from: data)
    } catch {
      throw FeedCredentialError.credentialStore
    }
  }

  public func saveCredentials(
    _ credentials: FeedCredentials,
    for feedKey: FeedKey
  ) throws {
    let data: Data
    do {
      data = try JSONEncoder().encode(credentials)
    } catch {
      throw FeedCredentialError.credentialStore
    }
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(
      baseQuery(for: feedKey) as CFDictionary,
      attributes as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw FeedCredentialError.credentialStore
    }
    var query = baseQuery(for: feedKey)
    for (key, value) in attributes {
      query[key] = value
    }
    guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
      throw FeedCredentialError.credentialStore
    }
  }

  public func deleteCredentials(for feedKey: FeedKey) throws {
    let status = SecItemDelete(baseQuery(for: feedKey) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw FeedCredentialError.credentialStore
    }
  }

  private func baseQuery(for feedKey: FeedKey) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: feedKey.rawValue,
    ]
  }
}
