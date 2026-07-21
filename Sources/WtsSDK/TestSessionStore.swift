import Foundation

protocol TestSessionStoring: Sendable {
  func load() throws -> PersistedTestSession?
  func save(_ session: PersistedTestSession) throws
  func clear() throws
}

struct FileTestSessionStore: TestSessionStoring {
  let fileURL: URL
  private let encoder = JSONEncoder.wts
  private let decoder = JSONDecoder.wts

  init(fileURL: URL? = nil) {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!.appendingPathComponent("co.wetus.wts-sdk", isDirectory: true)
    self.fileURL = fileURL ?? directory.appendingPathComponent("sdk-test-session-v2.json")
  }

  func load() throws -> PersistedTestSession? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    do {
      return try decoder.decode(PersistedTestSession.self, from: Data(contentsOf: fileURL))
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
  }

  func save(_ session: PersistedTestSession) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encoder.encode(session).write(
      to: fileURL,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
  }

  func clear() throws {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
