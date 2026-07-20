import Foundation
import Security

protocol ConsentStoring: Sendable {
  func load(sourceKey: String) throws -> WtsConsentState
  func save(_ state: WtsConsentState, sourceKey: String) throws
}
/// Consent is the only SDK state that may be accessed before consent is granted.
/// It is source-bound and stored with this-device-only Keychain protection.
struct KeychainConsentStore: ConsentStoring {
  private let service = "co.wetus.wts-sdk.v0.5.consent"

  func load(sourceKey: String) throws -> WtsConsentState {
    var result: CFTypeRef?
    let status = SecItemCopyMatching([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: sourceKey,
      kSecReturnData: true,
    ] as CFDictionary, &result)
    if status == errSecItemNotFound { return .pending }
    guard status == errSecSuccess,
      let data = result as? Data,
      let raw = String(data: data, encoding: .utf8),
      let state = WtsConsentState(rawValue: raw),
      state != .pending
    else { throw WtsSDKError.storage }
    return state
  }

  func save(_ state: WtsConsentState, sourceKey: String) throws {
    guard state != .pending else { return }
    let base: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: sourceKey,
    ]
    SecItemDelete(base as CFDictionary)
    var value = base
    value[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    value[kSecValueData] = Data(state.rawValue.utf8)
    guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else {
      throw WtsSDKError.storage
    }
  }
}
