import Foundation

public enum WtsValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }

    public var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value
        case .boolean(let value): value
        }
    }
}

public enum WtsUserValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case date(String)
    case stringArray([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String].self) { self = .stringArray(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value), .date(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .stringArray(let value): try container.encode(value)
        }
    }
}

public struct WtsUserUpdate: Sendable, Equatable {
    public var set: [String: WtsUserValue]
    public var setOnce: [String: WtsUserValue]
    public var unset: [String]
    public var increment: [String: Double]

    public init(
        set: [String: WtsUserValue] = [:],
        setOnce: [String: WtsUserValue] = [:],
        unset: [String] = [],
        increment: [String: Double] = [:]
    ) {
        self.set = set
        self.setOnce = setOnce
        self.unset = unset
        self.increment = increment
    }
}

public struct WtsReportedAttribution: Codable, Sendable, Equatable {
    public let source: String
    public let medium: String?
    public let campaign: String?
    public let externalRef: String?

    public init(
        source: String,
        medium: String? = nil,
        campaign: String? = nil,
        externalRef: String? = nil
    ) {
        self.source = source
        self.medium = medium
        self.campaign = campaign
        self.externalRef = externalRef
    }
}

public enum WtsProfileConsent: Sendable, Equatable {
    case granted
    case denied
}

public struct WtsDeepLink: Sendable, Equatable {
    public let path: String
    public let parameters: [String: WtsValue]
    public let linkId: String
    public let attributionId: String
    public let isDeferred: Bool

    public init(
        path: String,
        parameters: [String: WtsValue],
        linkId: String,
        attributionId: String,
        isDeferred: Bool
    ) {
        self.path = path
        self.parameters = parameters
        self.linkId = linkId
        self.attributionId = attributionId
        self.isDeferred = isDeferred
    }
}

public struct WtsRevenue: Codable, Sendable, Equatable {
    public let amount: String
    public let currency: String

    public init(amount: Decimal, currency: String) {
        self.amount = NSDecimalNumber(decimal: amount).stringValue
        self.currency = currency.uppercased()
    }

    public init(amount: String, currency: String) {
        self.amount = amount
        self.currency = currency.uppercased()
    }
}

public enum WtsLogLevel: Int, Sendable {
    case off = 0
    case error = 1
    case debug = 2
}

public struct WtsOptions: Sendable {
    public var apiBaseURL: URL
    public var requestTimeout: TimeInterval
    public var cacheTTL: TimeInterval
    public var logLevel: WtsLogLevel

    public init(
        apiBaseURL: URL = URL(string: "https://api.wts.is/api/v1")!,
        requestTimeout: TimeInterval = 2,
        cacheTTL: TimeInterval = 60,
        logLevel: WtsLogLevel = .off
    ) {
        self.apiBaseURL = apiBaseURL
        self.requestTimeout = requestTimeout
        self.cacheTTL = cacheTTL
        self.logLevel = logLevel
    }
}

public enum WtsSDKError: Error, Sendable, Equatable {
    case notConfigured
    case invalidAppKey
    case invalidURL(fallbackURL: URL?)
    case noMatch(fallbackURL: URL)
    case timeout(fallbackURL: URL?)
    case network(fallbackURL: URL?)
    case server(statusCode: Int, fallbackURL: URL?)
    case invalidResponse(fallbackURL: URL?)
    case invalidEvent(reason: String)
    case invalidProfile(reason: String)
    case profileConsentRequired
    case storage

    public var code: String {
        switch self {
        case .notConfigured: "NOT_CONFIGURED"
        case .invalidAppKey: "INVALID_APP_KEY"
        case .invalidURL: "INVALID_URL"
        case .noMatch: "NO_MATCH"
        case .timeout: "TIMEOUT"
        case .network: "NETWORK_ERROR"
        case .server: "SERVER_ERROR"
        case .invalidResponse: "INVALID_RESPONSE"
        case .invalidEvent: "INVALID_EVENT"
        case .invalidProfile: "INVALID_PROFILE"
        case .profileConsentRequired: "PROFILE_CONSENT_REQUIRED"
        case .storage: "STORAGE_ERROR"
        }
    }

    public var fallbackURL: URL? {
        switch self {
        case .invalidURL(let url), .timeout(let url), .network(let url),
             .server(_, let url), .invalidResponse(let url): url
        case .noMatch(let url): url
        default: nil
        }
    }
}

extension WtsSDKError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured: "WtsSDK is not configured."
        case .invalidAppKey: "The wts.is app key is invalid."
        case .invalidURL: "The deep link URL is invalid."
        case .noMatch: "No active deep link matched the URL."
        case .timeout: "The wts.is request timed out."
        case .network: "The wts.is request failed because the network is unavailable."
        case .server(let statusCode, _): "The wts.is API returned HTTP \(statusCode)."
        case .invalidResponse: "The wts.is API response was invalid."
        case .invalidEvent(let reason): reason
        case .invalidProfile(let reason): reason
        case .profileConsentRequired: "Profile consent must be granted before using identity APIs."
        case .storage: "The wts.is local event queue could not be persisted."
        }
    }
}
