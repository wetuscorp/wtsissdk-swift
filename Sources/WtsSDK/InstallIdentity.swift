import Foundation
import Security

protocol InstallIdentityProviding: Sendable {
  func value() throws -> String
  func clear() throws
}

struct KeychainInstallIdentity: InstallIdentityProviding {
  private let service = "co.wetus.wts-sdk.v0.5"
  private let account = "install-id"

  func value() throws -> String {
    var result: CFTypeRef?
    let query =
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
      ] as CFDictionary
    let status = SecItemCopyMatching(query, &result)
    if status == errSecSuccess,
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    {
      return value
    }
    guard status == errSecItemNotFound else { throw WtsSDKError.storage }

    let value = UUID().uuidString.lowercased()
    let attributes =
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecValueData: Data(value.utf8),
      ] as CFDictionary
    guard SecItemAdd(attributes, nil) == errSecSuccess else { throw WtsSDKError.storage }
    return value
  }

  func clear() throws {
    let status = SecItemDelete([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw WtsSDKError.storage
    }
  }
}
