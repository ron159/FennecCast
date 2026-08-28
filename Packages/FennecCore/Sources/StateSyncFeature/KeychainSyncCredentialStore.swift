import Foundation
import Security

public struct KeychainSyncCredentialStore: SyncCredentialStoring {
  private let service: String
  private let account: String

  public init(
    service: String = "com.ron159.FennecCast.StateSync",
    account: String = "bearer-token"
  ) {
    self.service = service
    self.account = account
  }

  public func readToken() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard
      status == errSecSuccess,
      let data = result as? Data,
      let token = String(data: data, encoding: .utf8)
    else {
      throw StateSyncSettingsError.credentialStore
    }
    return token
  }

  public func saveToken(_ token: String) throws {
    guard let data = token.data(using: .utf8) else {
      throw StateSyncSettingsError.credentialStore
    }
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      attributes as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw StateSyncSettingsError.credentialStore
    }
    var query = baseQuery
    for (key, value) in attributes {
      query[key] = value
    }
    guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
      throw StateSyncSettingsError.credentialStore
    }
  }

  public func deleteToken() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StateSyncSettingsError.credentialStore
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
