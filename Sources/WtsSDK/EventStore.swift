import Foundation

protocol EventStoring: Sendable {
  func load() throws -> [EventRequest]
  func save(_ events: [EventRequest]) throws
}

struct FileEventStore: EventStoring {
  let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(fileURL: URL? = nil) {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("co.wetus.wts-sdk", isDirectory: true)
    self.fileURL = fileURL ?? directory.appendingPathComponent("events-v1.json")
    encoder = JSONEncoder.wts
    decoder = JSONDecoder.wts
  }

  func load() throws -> [EventRequest] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do { return try decoder.decode([EventRequest].self, from: Data(contentsOf: fileURL)) } catch {
      try? FileManager.default.removeItem(at: fileURL)
      return []
    }
  }

  func save(_ events: [EventRequest]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if events.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
      return
    }
    let data = try encoder.encode(events)
    try data.write(
      to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}

extension JSONEncoder {
  static var wts: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var wts: JSONDecoder {
    let decoder = JSONDecoder()
    // Foundation's built-in `.iso8601` strategy does not consistently accept
    // fractional seconds across Apple platforms. The API serializes timestamps
    // with `Date#toISOString()`, so accept both its millisecond form and the
    // equivalent second-precision form explicitly.
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = WtsISO8601Date.parse(value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Expected an ISO-8601 timestamp with or without fractional seconds."
        )
      }
      return date
    }
    return decoder
  }
}

enum WtsISO8601Date {
  static func parse(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
      return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
