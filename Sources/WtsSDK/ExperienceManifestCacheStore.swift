import Foundation

struct CachedExperienceManifestEnvelope: Codable, Sendable {
  let sourceKey: String
  let etag: String?
  let responseData: Data
}
protocol ExperienceManifestCacheStoring: Sendable {
  func load() throws -> CachedExperienceManifestEnvelope?
  func save(_ value: CachedExperienceManifestEnvelope) throws
  func clear() throws
}

struct FileExperienceManifestCacheStore: ExperienceManifestCacheStoring {
  let fileURL: URL
  private let encoder = JSONEncoder.wts
  private let decoder = JSONDecoder.wts

  init(fileURL: URL? = nil) {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!.appendingPathComponent("co.wetus.wts-sdk", isDirectory: true)
    self.fileURL = fileURL ?? directory.appendingPathComponent("experience-manifest-v2.json")
  }

  func load() throws -> CachedExperienceManifestEnvelope? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    do {
      return try decoder.decode(
        CachedExperienceManifestEnvelope.self,
        from: Data(contentsOf: fileURL)
      )
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
  }

  func save(_ value: CachedExperienceManifestEnvelope) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encoder.encode(value).write(
      to: fileURL,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
  }

  func clear() throws { try? FileManager.default.removeItem(at: fileURL) }
}
