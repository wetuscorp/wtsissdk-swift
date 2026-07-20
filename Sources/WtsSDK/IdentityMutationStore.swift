import Foundation

protocol IdentityMutationStoring: Sendable {
  func load() throws -> [IdentityMutationRequest]
  func save(_ mutations: [IdentityMutationRequest]) throws
}

struct FileIdentityMutationStore: IdentityMutationStoring {
  let fileURL: URL
  private let encoder = JSONEncoder.wts
  private let decoder = JSONDecoder.wts

  init(fileURL: URL? = nil) {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!.appendingPathComponent("co.wetus.wts-sdk", isDirectory: true)
    self.fileURL = fileURL ?? directory.appendingPathComponent("identity-v2.json")
  }

  func load() throws -> [IdentityMutationRequest] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      return try decoder.decode(
        [IdentityMutationRequest].self,
        from: Data(contentsOf: fileURL)
      )
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      return []
    }
  }

  func save(_ mutations: [IdentityMutationRequest]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    if mutations.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
      return
    }
    try encoder.encode(mutations).write(
      to: fileURL,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
  }
}
