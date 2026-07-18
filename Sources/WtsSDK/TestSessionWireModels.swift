import Foundation

struct TestSessionMetadata: Encodable, Sendable {
  let platform: String = "ios"
  let sdkFamily: String
  let sdkVersion: String = WtsSDK.version
  let appVersion: String?
  let osVersion: String?
  let locale: String
}

struct TestSessionPairRequest: Encodable, Sendable {
  let schemaVersion: Int = 1
  let pairingToken: String?
  let pairingCode: String?
  let metadata: TestSessionMetadata
}

struct TestSessionPairResponse: Codable, Sendable {
  struct Session: Codable, Sendable {
    let id: String
    let status: String
    let expiresAt: String
  }

  struct Participant: Codable, Sendable {
    let id: String
    let sourceId: String
    let sourceType: String
    let status: String
  }

  struct TestProfile: Codable, Sendable { let externalUserId: String }

  let session: Session
  let participant: Participant
  let sessionToken: String
  let testProfile: TestProfile
  let requiredSdkVersion: String
  let testPlan: TestSessionPlan
}

struct TestSessionCapabilities: Codable, Sendable {
  let deeplink: Bool
  let identity: Bool
  let screen: Bool
  let experiences: Bool
  let offlineQueue: Bool
}

struct TestSessionConsent: Codable, Sendable {
  let analytics: String
  let profile: Bool?
  let experience: String?
}

struct TestSessionHandshakeRequest: Encodable, Sendable {
  let schemaVersion: Int = 1
  let participantId: String
  let sessionToken: String
  let metadata: TestSessionMetadata
  let capabilities: TestSessionCapabilities
  let consent: TestSessionConsent
}

struct TestSessionHandshakeResponse: Codable, Sendable {
  struct Check: Codable, Sendable {
    let key: String
    let status: String
    let code: String?
    let message: String?
  }

  let accepted: Bool
  let compatible: Bool
  let requiredSdkVersion: String
  let checks: [Check]
  let testPlan: TestSessionPlan
}

struct TestSessionPlan: Codable, Sendable {
  struct Profile: Codable, Sendable {
    let selected: Bool
    let available: Bool
    let allowedMethods: [String]
  }

  struct Event: Codable, Sendable {
    struct Property: Codable, Sendable {
      let key: String
      let type: String
      let required: Bool
    }

    let eventKey: String
    let properties: [Property]
    let revenueEnabled: Bool
  }

  struct DeepLink: Codable, Sendable {
    let selected: Bool
    let available: Bool
    let linkId: String?
  }

  struct Experience: Codable, Sendable {
    let selected: Bool
    let available: Bool
    let campaignId: String?
    let versionId: String?
  }

  struct Screen: Codable, Sendable { let selected: Bool }

  let profile: Profile?
  let events: [Event]
  let deepLink: DeepLink?
  let experience: Experience?
  let screen: Screen?
}

struct TestSessionSignal: Codable, Sendable, Equatable {
  let clientSignalId: String
  let type: String
  let outcome: String
  let occurredAt: Date
  let method: String?
  let eventKey: String?
  let screenName: String?
  let propertyKeys: [String]?
  let propertyTypes: [String: String]?
  let revenue: TestSessionRevenueDescriptor?
  let resultCode: String?
  let feature: String?

  init(
    clientSignalId: String = UUID().uuidString.lowercased(),
    type: String,
    outcome: String,
    occurredAt: Date = Date(),
    method: String? = nil,
    eventKey: String? = nil,
    screenName: String? = nil,
    propertyKeys: [String]? = nil,
    propertyTypes: [String: String]? = nil,
    revenue: TestSessionRevenueDescriptor? = nil,
    resultCode: String? = nil,
    feature: String? = nil
  ) {
    self.clientSignalId = clientSignalId
    self.type = type
    self.outcome = outcome
    self.occurredAt = occurredAt
    self.method = method
    self.eventKey = eventKey
    self.screenName = screenName
    self.propertyKeys = propertyKeys
    self.propertyTypes = propertyTypes
    self.revenue = revenue
    self.resultCode = resultCode
    self.feature = feature
  }
}

struct TestSessionRevenueDescriptor: Codable, Sendable, Equatable {
  let present: Bool
  let currency: String
}

struct TestSessionSignalBatchRequest: Encodable, Sendable {
  let schemaVersion: Int = 1
  let participantId: String
  let sessionToken: String
  let signals: [TestSessionSignal]
}

struct TestSessionSignalBatchResponse: Codable, Sendable {
  struct Rejected: Codable, Sendable {
    let clientSignalId: String
    let code: String
    let message: String
    let retryable: Bool
  }

  let accepted: [String]
  let duplicates: [String]
  let rejected: [Rejected]
}

struct TestSessionResolveRequest: Encodable, Sendable {
  let schemaVersion: Int = 1
  let participantId: String
  let sessionToken: String
  let url: String
}

struct TestSessionResolveResponse: Codable, Sendable {
  struct Link: Codable, Sendable {
    let id: String
    let path: String
    let parameters: [String: WtsValue]
  }

  let match: Bool
  let status: String
  let code: String
  let originalUrl: String
  let fallbackUrl: String
  let link: Link?
}

struct TestSessionExperienceDecisionRequest: Encodable, Sendable {
  struct Context: Encodable, Sendable {
    let type: String
    let pathname: String?
    let pageName: String?
    let screenName: String?
    let eventKey: String?
    let properties: [String: WtsValue]?
    let locale: String
  }

  let schemaVersion: Int = 1
  let participantId: String
  let sessionToken: String
  let context: Context
}

struct TestSessionExperienceDecisionResponse: Codable, Sendable {
  struct TestGrant: Codable, Sendable {
    let fixtureId: String
    let expiresAt: String
  }

  struct Decision: Codable, Sendable {
    struct Variant: Codable, Sendable {
      struct Asset: Codable, Sendable { let url: URL }
      let id: String
      let key: String
      let content: WtsTestSessionJSONValue
      let asset: Asset?
    }

    let campaignId: String
    let campaignVersionId: String
    let placement: String
    let defaultLocale: String
    let variant: Variant?
  }

  let outcome: String
  let reason: String?
  let testGrant: TestGrant?
  let decision: Decision?
}

struct TestSessionLeaveRequest: Encodable, Sendable {
  let schemaVersion: Int = 1
  let participantId: String
  let sessionToken: String
}

struct TestSessionLeaveResponse: Codable, Sendable { let accepted: Bool }

struct PersistedTestSession: Codable, Sendable {
  let sourceKey: String
  let sessionId: String
  let participantId: String
  let sessionToken: String
  let expiresAt: String
  let compatible: Bool
  let requiredSdkVersion: String
  let sdkFamily: String
  let checks: [TestSessionHandshakeResponse.Check]
  let testPlan: TestSessionPlan
  let testExperienceDecisionReady: Bool?
  let pendingSignals: [TestSessionSignal]
}

public enum WtsTestSessionJSONValue: Codable, Sendable, Equatable {
  case object([String: WtsTestSessionJSONValue])
  case array([WtsTestSessionJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: WtsTestSessionJSONValue].self) {
      self = .object(value)
    } else {
      self = .array(try container.decode([WtsTestSessionJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}
