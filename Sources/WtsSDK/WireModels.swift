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
    let eventKey: String
    let properties: [String: WtsValue]
    let revenue: WtsRevenue?
    let linkId: String?

    static func == (lhs: EventRequest, rhs: EventRequest) -> Bool {
        lhs.clientEventId == rhs.clientEventId
    }
}

struct EventBatchRequest: Codable, Sendable { let schemaVersion: Int; let events: [EventRequest] }

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
