import Foundation

protocol ExperienceInteractionStoring: Sendable {
  func load() throws -> [ExperienceInteractionRequest]
  func save(_ interactions: [ExperienceInteractionRequest]) throws
}

struct FileExperienceInteractionStore: ExperienceInteractionStoring {
  let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileURL: URL? = nil) {
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!.appendingPathComponent("co.wetus.wts-sdk", isDirectory: true)
    self.fileURL = fileURL ?? directory.appendingPathComponent("experience-interactions-v1.json")
    encoder = JSONEncoder.wts
    decoder = JSONDecoder.wts
  }

  func load() throws -> [ExperienceInteractionRequest] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      return try decoder.decode(
        [ExperienceInteractionRequest].self,
        from: Data(contentsOf: fileURL)
      )
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      return []
    }
  }

  func save(_ interactions: [ExperienceInteractionRequest]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    if interactions.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
      return
    }
    try encoder.encode(interactions).write(
      to: fileURL,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
  }
}
