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
    case storage

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
        case .storage: "The wts.is local event queue could not be persisted."
        }
    }
}
