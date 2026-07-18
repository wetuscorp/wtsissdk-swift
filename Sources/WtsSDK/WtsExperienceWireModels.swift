import Foundation

struct ExperienceSettingsWire: Encodable {
  let allowedInternalRoutes: [String]
  let allowedCallbackKeys: [String]
  let allowedDeepLinkHosts: [String]
  let allowedDeepLinkSchemes: [String]
  let allowedWebOrigins: [String]
}

struct ExperienceBootstrapRequest: Encodable {
  let schemaVersion = 1
  let consent: WtsExperienceConsent
  let profileConsentGranted: Bool
  let actorId: String
  let sessionId: String
  let metadata: WtsMetadata
  let settings: ExperienceSettingsWire
  let testDeviceToken: String
}

struct ExperienceBootstrapResponse: Decodable {
  struct Manifest: Decodable {
    struct Campaign: Decodable {
      struct Branch: Decodable {
        let assignmentId: String
        let kind: String
        let variantId: String?
      }

      struct Variant: Decodable {
        struct Asset: Decodable { let url: URL }
        let id: String
        let content: WtsExperienceContent
        let asset: Asset?
      }

      let campaignId: String
      let campaignVersionId: String
      let priority: Int
      let placement: WtsExperiencePlacement
      let trigger: ExperienceManifestTrigger
      let targeting: ExperienceTargetNode
      let variants: [Variant]
      let requiresPersonalization: Bool
      let grant: String?
      let assignment: Branch?
    }

    let sourceId: String
    let sourceManifestVersion: Int
    let environment: String
    let expiresAt: Date
    let campaigns: [Campaign]
  }
  /// The unsigned compatibility copy returned by the collector.
  ///
  /// It is decoded only so the response shape remains compatible with the
  /// protocol. Runtime behavior must use the separately verified
  /// `signedPayload`, never this value.
  let manifest: ExperienceDiscardedJSONValue
  let signedPayload: String
  let signature: String
  let keyId: String
  let expiresAt: String
}

indirect enum ExperienceDiscardedJSONValue: Decodable {
  case object([String: ExperienceDiscardedJSONValue])
  case array([ExperienceDiscardedJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: ExperienceDiscardedJSONValue].self) {
      self = .object(value)
    } else {
      self = .array(try container.decode([ExperienceDiscardedJSONValue].self))
    }
  }
}

struct ExperienceManifestTrigger: Decodable {
  struct Match: Decodable {
    let kind: String
    let value: String
  }

  struct PropertyCondition: Decodable {
    let key: String
    let `operator`: String
    let value: ExperienceTargetValue?
  }

  let type: String
  let match: Match?
  let screenName: String?
  let eventKey: String?
  let conditions: [PropertyCondition]?
}

indirect enum ExperienceTargetNode: Decodable {
  case condition(field: String, operator: String, value: ExperienceTargetValue?)
  case all([ExperienceTargetNode])
  case any([ExperienceTargetNode])
  case not(ExperienceTargetNode)

  private enum CodingKeys: String, CodingKey {
    case kind, field, `operator`, value, conditions, condition
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "condition":
      self = .condition(
        field: try container.decode(String.self, forKey: .field),
        operator: try container.decode(String.self, forKey: .operator),
        value: try container.decodeIfPresent(ExperienceTargetValue.self, forKey: .value)
      )
    case "all":
      self = .all(try container.decode([ExperienceTargetNode].self, forKey: .conditions))
    case "any":
      self = .any(try container.decode([ExperienceTargetNode].self, forKey: .conditions))
    case "not":
      self = .not(try container.decode(ExperienceTargetNode.self, forKey: .condition))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unsupported Experience target node."
      )
    }
  }
}

enum ExperienceTargetValue: Decodable, Equatable {
  case scalar(WtsValue)
  case list([WtsValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let values = try? container.decode([WtsValue].self) {
      self = .list(values)
    } else {
      self = .scalar(try container.decode(WtsValue.self))
    }
  }
}

struct ExperienceContextWire: Encodable {
  struct Trigger: Encodable {
    struct Match: Encodable {
      let kind: String
      let value: String?
    }
    let type: String
    let match: Match?
    let screenName: String?
    let eventKey: String?
    let conditions: [String]
  }
  let trigger: Trigger
  let screenName: String?
  let eventKey: String?
  let properties: [String: WtsValue]
  let triggerEventId: String?
}

struct ExperienceDecisionRequest: Encodable {
  let schemaVersion = 1
  let consent: WtsExperienceConsent
  let profileConsentGranted: Bool
  let actorId: String
  let sessionId: String
  let metadata: WtsMetadata
  let settings: ExperienceSettingsWire
  let testDeviceToken: String
  let candidateVersionIds: [String]
  let context: ExperienceContextWire
}

struct ExperienceDecisionResponse: Decodable {
  struct Decision: Decodable {
    struct Variant: Decodable {
      struct Asset: Decodable { let url: URL }
      let id: String
      let content: WtsExperienceContent
      let asset: Asset?
    }
    let campaignId: String
    let campaignVersionId: String
    let assignmentId: String
    let variantId: String?
    let holdout: Bool
    let placement: WtsExperiencePlacement
    let priority: Int
    let content: Variant?
    let grant: String
  }
  let decisions: [Decision]
}

struct ExperienceInteractionRequest: Codable {
  let clientInteractionId: String
  let grant: String
  let campaignId: String
  let campaignVersionId: String
  let assignmentId: String?
  let variantId: String?
  let exposureId: String?
  let type: String
  let actionId: String?
  let triggerEventId: String?
  let occurredAt: Date
  let metadata: WtsMetadata
  let failureCode: String?
}

struct ExperienceInteractionBatchRequest: Encodable {
  let schemaVersion = 1
  let consent: WtsExperienceConsent
  let profileConsentGranted: Bool
  let actorId: String
  let sessionId: String
  let interactions: [ExperienceInteractionRequest]
}

struct ExperienceInteractionBatchResponse: Decodable {
  struct Rejected: Decodable {
    let clientInteractionId: String
    let retryable: Bool
  }
  let accepted: [String]
  let duplicates: [String]
  let rejected: [Rejected]
}
