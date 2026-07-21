import Foundation
import Security

protocol LegacyStateCleaning: Sendable {
  func clear() throws
}

/// Deletes the 0.4 namespace without reading or migrating any value.
struct FileLegacyStateCleaner: LegacyStateCleaning {
  private let directory: URL
  private let installIdentityService: String

  init(
    directory: URL? = nil,
    installIdentityService: String = "co.wetus.wts-sdk"
  ) {
    self.directory = directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("co.wetus.wts-sdk", isDirectory: true)
    self.installIdentityService = installIdentityService
  }

  func clear() throws {
    for filename in [
      "events-v1.json",
      "identity-v1.json",
      "identity-binding-v1.json",
      "experience-interactions-v1.json",
      "sdk-test-session-v1.json",
    ] {
      let file = directory.appendingPathComponent(filename)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
    }
    let status = SecItemDelete([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: installIdentityService,
    ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw WtsSDKError.storage
    }
  }
}
