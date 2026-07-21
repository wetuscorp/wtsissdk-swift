import Foundation

public enum WtsExperiencePlacement: String, Codable, Sendable {
  case modal
  case bottomSheet = "bottom_sheet"
}

public enum WtsExperienceActionType: String, Codable, Sendable {
  case dismiss = "DISMISS"
  case openInternalRoute = "OPEN_INTERNAL_ROUTE"
  case openDeepLink = "OPEN_DEEP_LINK"
  case openWebURL = "OPEN_WEB_URL"
  case copyCode = "COPY_CODE"
  case customCallback = "CUSTOM_CALLBACK"
}

public struct WtsExperienceAction: Codable, Sendable, Equatable {
  public let id: String
  public let label: String
  public let type: WtsExperienceActionType
  public let target: String?
}

public struct WtsExperienceLocalizedContent: Codable, Sendable, Equatable {
  public let title: String
  public let description: String
  public let primaryAction: WtsExperienceAction?
  public let secondaryAction: WtsExperienceAction?
}

public struct WtsExperienceContent: Codable, Sendable, Equatable {
  public let translations: [String: WtsExperienceLocalizedContent]
  public let closeable: Bool
  public let themePreset: String
  public let delaySeconds: Double
  public let autoCloseSeconds: Double?
}

public struct WtsExperience: Sendable, Equatable {
  public let campaignId: String
  public let campaignVersionId: String
  public let assignmentId: String
  public let variantId: String
  /// Internal correlation only. Public manual callbacks expose the opaque
  /// `WtsExperiencePresentationHandle` instead of an exposure identifier.
  let exposureId: String
  public let placement: WtsExperiencePlacement
  public let priority: Int
  public let content: WtsExperienceContent
  public let assetURL: URL?
}

public enum WtsExperienceDismissReason: Sendable, Equatable {
  case dismissed
  case autoClosed
  case renderFailed
}

public struct WtsExperienceDiagnostics: Sendable, Equatable {
  public let enabled: Bool
  public let consent: WtsConsentState
  public let decisionMode: String?
  public let queued: Int
  public let presenting: Bool
  public let testDeviceToken: String
  public let lastErrorCode: String?
}
