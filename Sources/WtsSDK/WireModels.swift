import Foundation

struct WtsMetadata: Codable, Sendable {
  let platform: String
  let appVersion: String?
  let sdkVersion: String
  let osVersion: String
  let locale: String

  static var current: WtsMetadata {
    WtsMetadata(
      platform: "ios",
      appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
      sdkVersion: WtsSDK.version,
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      locale: Locale.current.identifier
    )
  }
}

struct ResolveRequest: Codable, Sendable {
  let schemaVersion: Int
  let clientEventId: String
  let installId: String
  let occurredAt: Date
  let metadata: WtsMetadata
  let url: String
}

struct FunctionalResolveRequest: Encodable, Sendable {
  let schemaVersion = 4
  let url: String
  let platform = "ios"
}

struct FunctionalResolveResponse: Codable, Sendable {
  let matched: Bool
  let destination: URL?
  let path: String?
  let parameters: [String: WtsValue]
}

struct ResolveResponse: Codable, Sendable {
  struct Link: Codable, Sendable {
    let id: String
    let path: String
    let parameters: [String: WtsValue]
  }
  let match: Bool
  let attributionId: String
  let isDeferred: Bool
  let link: Link
}

struct EventRequest: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let clientEventId: String
  let installId: String
  let occurredAt: Date
  let metadata: WtsMetadata
  let sessionId: String?
  let type: String
  let eventKey: String?
  let screenName: String?
  let properties: [String: WtsValue]
  let revenue: WtsRevenue?
  let linkId: String?

  static func == (lhs: EventRequest, rhs: EventRequest) -> Bool {
    lhs.clientEventId == rhs.clientEventId
  }

  init(
    schemaVersion: Int = 4,
    clientEventId: String = UUID().uuidString.lowercased(),
    installId: String,
    sessionId: String?,
    occurredAt: Date = Date(),
    metadata: WtsMetadata,
    type: String,
    eventKey: String? = nil,
    screenName: String? = nil,
    properties: [String: WtsValue],
    revenue: WtsRevenue? = nil,
    linkId: String? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.clientEventId = clientEventId
    self.installId = installId
    self.sessionId = sessionId
    self.occurredAt = occurredAt
    self.metadata = metadata
    self.type = type
    self.eventKey = eventKey
    self.screenName = screenName
    self.properties = properties
    self.revenue = revenue
    self.linkId = linkId
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = 4
    clientEventId = try container.decode(String.self, forKey: .clientEventId)
    installId = try container.decode(String.self, forKey: .installId)
    sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    occurredAt = try container.decode(Date.self, forKey: .occurredAt)
    metadata = try container.decode(WtsMetadata.self, forKey: .metadata)
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? "custom"
    eventKey = try container.decodeIfPresent(String.self, forKey: .eventKey)
    screenName = try container.decodeIfPresent(String.self, forKey: .screenName)
    properties = try container.decode([String: WtsValue].self, forKey: .properties)
    revenue = try container.decodeIfPresent(WtsRevenue.self, forKey: .revenue)
    linkId = try container.decodeIfPresent(String.self, forKey: .linkId)
  }
}

struct EventBatchRequest: Codable, Sendable {
  let schemaVersion: Int
  let events: [EventRequest]
}

struct EventBatchResponse: Codable, Sendable {
  struct Rejected: Codable, Sendable {
    let clientEventId: String
    let code: String
    let message: String
    let retryable: Bool
  }
  let accepted: [String]
  let duplicates: [String]
  let rejected: [Rejected]
}

struct IdentityContext: Codable, Sendable {
  let installId: String
  let sessionId: String?
}

struct UserUpdateOperations: Codable, Sendable {
  let set: [String: WtsUserValue]?
  let setOnce: [String: WtsUserValue]?
  let unset: [String]?
  let increment: [String: Double]?
}

struct IdentityMutationRequest: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let clientMutationId: String
  let occurredAt: Date
  let identity: IdentityContext
  let type: String
  let externalUserId: String?
  let attributes: [String: WtsUserValue]?
  let operations: UserUpdateOperations?
  let attribution: WtsReportedAttribution?
  let metadata: WtsMetadata

  static func == (lhs: IdentityMutationRequest, rhs: IdentityMutationRequest) -> Bool {
    lhs.clientMutationId == rhs.clientMutationId
  }
}

struct IdentityMutationBatchRequest: Codable, Sendable {
  let schemaVersion: Int
  let mutations: [IdentityMutationRequest]
}

struct IdentityMutationBatchResponse: Codable, Sendable {
  struct Rejected: Codable, Sendable {
    let clientMutationId: String
    let code: String
    let message: String
    let retryable: Bool
  }

  let accepted: [String]
  let duplicates: [String]
  let rejected: [Rejected]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accepted = try container.decode([String].self, forKey: .accepted)
    duplicates = try container.decode([String].self, forKey: .duplicates)
    rejected = try container.decodeIfPresent([Rejected].self, forKey: .rejected) ?? []
  }
}
