import Foundation

/// Stores only whether the current installation has a server-accepted identity
/// binding for a source. External user identifiers are never persisted here.
protocol IdentityBindingStoring: Sendable {
  func load() throws -> PersistedIdentityBinding?
  func save(_ binding: PersistedIdentityBinding) throws
  func clear() throws
}

struct PersistedIdentityBinding: Codable, Sendable, Equatable {
  let sourceKey: String
}

struct FileIdentityBindingStore: IdentityBindingStoring {
  let fileURL: URL
  private let encoder = JSONEncoder.wts
  private let decoder = JSONDecoder.wts

  init(fileURL: URL? = nil) {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!.appendingPathComponent("co.wetus.wts-sdk", isDirectory: true)
    self.fileURL = fileURL ?? directory.appendingPathComponent("identity-binding-v1.json")
  }

  func load() throws -> PersistedIdentityBinding? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    do {
      return try decoder.decode(PersistedIdentityBinding.self, from: Data(contentsOf: fileURL))
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
  }

  func save(_ binding: PersistedIdentityBinding) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try encoder.encode(binding).write(
      to: fileURL,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
  }

  func clear() throws {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
