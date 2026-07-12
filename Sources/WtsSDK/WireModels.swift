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
