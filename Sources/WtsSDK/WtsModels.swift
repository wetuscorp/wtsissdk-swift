import Foundation

public enum WtsValue: Codable, Sendable, Equatable {
  case string(String)
  case number(Double)
  case boolean(Bool)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .string(try container.decode(String.self))
    }
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
    if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode([String].self) {
      self = .stringArray(value)
    } else {
      self = .string(try container.decode(String.self))
    }
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

/** An explicit dashboard-issued credential for a short-lived SDK Test & Validate session. */
public struct WtsTestSessionPairing: Sendable, Equatable {
  public let pairingToken: String?
  public let pairingCode: String?

  public init(pairingToken: String? = nil, pairingCode: String? = nil) throws {
    guard (pairingToken != nil) != (pairingCode != nil) else {
      throw WtsSDKError.invalidTestSessionPairing
    }
    if let pairingToken {
      guard (32...512).contains(pairingToken.count) else {
        throw WtsSDKError.invalidTestSessionPairing
      }
      self.pairingToken = pairingToken
      self.pairingCode = nil
      return
    }
    let normalized = pairingCode!.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard normalized.range(of: "^[A-Z2-9]{16}$", options: .regularExpression) != nil else {
      throw WtsSDKError.invalidTestSessionPairing
    }
    self.pairingToken = nil
    self.pairingCode = normalized
  }

  public static func parse(_ value: String) throws -> WtsTestSessionPairing {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw WtsSDKError.invalidTestSessionPairing }
    if let url = URL(string: trimmed),
      url.scheme == "https",
      (url.path == "/_wts/test/pair"
        || (["wts.is", "www.wts.is"].contains(url.host?.lowercased() ?? "")
          && url.path == "/sdk-test/pair")),
      let pairing = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "pairing" })?.value
    {
      return try WtsTestSessionPairing(pairingToken: pairing)
    }
    if trimmed.range(of: "^[A-Z2-9]{16}$", options: [.regularExpression, .caseInsensitive]) != nil {
      return try WtsTestSessionPairing(pairingCode: trimmed)
    }
    return try WtsTestSessionPairing(pairingToken: trimmed)
  }
}

public enum WtsTestSessionSDKFamily: String, Sendable, Equatable {
  case nativeSwift = "swift"
  case flutter
  case reactNative = "react_native"
}

public struct WtsTestSessionCheck: Sendable, Equatable {
  public let key: String
  public let status: String
  public let code: String?
  public let message: String?

  public init(key: String, status: String, code: String? = nil, message: String? = nil) {
    self.key = key
    self.status = status
    self.code = code
    self.message = message
  }
}

public struct WtsTestSessionJoinResult: Sendable, Equatable {
  public let accepted: Bool
  public let joined: Bool
  public let compatible: Bool
  public let requiredSDKVersion: String?
  public let checks: [WtsTestSessionCheck]
  public let sessionId: String?
  public let expiresAt: Date?
  /** Returned only to the direct pairing caller; never persisted in test observations. */
  public let testProfileExternalUserId: String?
  public let errorCode: String?
}

public struct WtsTestSessionDiagnostics: Sendable, Equatable {
  public let joined: Bool
  public let compatible: Bool
  public let sessionId: String?
  public let expiresAt: Date?
  public let requiredSDKVersion: String?
  public let checks: [WtsTestSessionCheck]
  public let pendingSignals: Int
  public let lastErrorCode: String?
}

public struct WtsTestSessionProbeLink: Sendable, Equatable {
  public let id: String
  public let path: String
  public let parameters: [String: WtsValue]
}

public struct WtsTestSessionProbeResult: Sendable, Equatable {
  public let match: Bool
  public let status: String
  public let code: String
  public let originalURL: URL
  public let fallbackURL: URL
  public let link: WtsTestSessionProbeLink?
}

public struct WtsTestSessionProbeRunResult: Sendable, Equatable {
  public let accepted: Bool
  public let emitted: [String]
  public let skipped: [String]
  public let pendingSignals: Int
  /**
   * An isolated test-only decision. It is intentionally not passed to the
   * production Experience runtime or rendered automatically.
   */
  public let experienceDecision: WtsTestSessionExperienceDecision?
}

public enum WtsTestSessionExperienceInteraction: Sendable, Equatable {
  case impression
  case action
}

public struct WtsTestSessionExperienceDecision: Sendable, Equatable {
  public let outcome: String
  public let reason: String?
  public let testGrant: WtsTestSessionExperienceGrant?
  public let decision: WtsTestSessionExperienceCampaign?
}

public struct WtsTestSessionExperienceGrant: Sendable, Equatable {
  public let fixtureId: String
  public let expiresAt: String
}

public struct WtsTestSessionExperienceCampaign: Sendable, Equatable {
  public let campaignId: String
  public let campaignVersionId: String
  public let placement: String
  public let defaultLocale: String
  public let variant: WtsTestSessionExperienceVariant?
}

public struct WtsTestSessionExperienceVariant: Sendable, Equatable {
  public let id: String
  public let key: String
  public let content: WtsTestSessionJSONValue
  public let assetURL: URL?
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
  public var collectorBaseURL: URL
  public var experiences: WtsExperienceOptions

  public init(
    apiBaseURL: URL = URL(string: "https://api.wts.is/api/v1")!,
    requestTimeout: TimeInterval = 2,
    cacheTTL: TimeInterval = 60,
    logLevel: WtsLogLevel = .off,
    collectorBaseURL: URL = URL(string: "https://collect.wts.is")!,
    experiences: WtsExperienceOptions = WtsExperienceOptions()
  ) {
    self.apiBaseURL = apiBaseURL
    self.requestTimeout = requestTimeout
    self.cacheTTL = cacheTTL
    self.logLevel = logLevel
    self.collectorBaseURL = collectorBaseURL
    self.experiences = experiences
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
  case invalidTestSessionPairing
  case profileConsentRequired
  case experienceProfileConsentRequired
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
    case .invalidTestSessionPairing: "INVALID_TEST_SESSION_PAIRING"
    case .profileConsentRequired: "PROFILE_CONSENT_REQUIRED"
    case .experienceProfileConsentRequired: "EXPERIENCE_PROFILE_CONSENT_REQUIRED"
    case .storage: "STORAGE_ERROR"
    }
  }

  public var fallbackURL: URL? {
    switch self {
    case .invalidURL(let url), .timeout(let url), .network(let url),
      .server(_, let url), .invalidResponse(let url):
      url
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
    case .invalidTestSessionPairing: "The SDK Test & Validate pairing credential is invalid."
    case .profileConsentRequired: "Profile consent must be granted before using identity APIs."
    case .experienceProfileConsentRequired: "Personalized Experiences require profile consent."
    case .storage: "The wts.is local event queue could not be persisted."
    }
  }
}
