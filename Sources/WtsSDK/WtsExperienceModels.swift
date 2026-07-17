import Foundation

public enum WtsExperienceConsent: String, Codable, Sendable {
  case pending
  case contextual
  case personalized
  case denied
}

public enum WtsExperienceRenderMode: Sendable {
  case automatic
  case manual
}

public struct WtsExperienceOptions: Sendable {
  public var enabled: Bool
  public var renderMode: WtsExperienceRenderMode
  public var allowedInternalRoutes: Set<String>
  public var allowedCallbackKeys: Set<String>
  public var allowedDeepLinkHosts: Set<String>
  public var allowedDeepLinkSchemes: Set<String>
  public var allowedWebOrigins: Set<String>

  public init(
    enabled: Bool = false,
    renderMode: WtsExperienceRenderMode = .automatic,
    allowedInternalRoutes: Set<String> = [],
    allowedCallbackKeys: Set<String> = [],
    allowedDeepLinkHosts: Set<String> = [],
    allowedDeepLinkSchemes: Set<String> = [],
    allowedWebOrigins: Set<String> = []
  ) {
    self.enabled = enabled
    self.renderMode = renderMode
    self.allowedInternalRoutes = allowedInternalRoutes
    self.allowedCallbackKeys = allowedCallbackKeys
    self.allowedDeepLinkHosts = allowedDeepLinkHosts
    self.allowedDeepLinkSchemes = allowedDeepLinkSchemes
    self.allowedWebOrigins = allowedWebOrigins
  }
}

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
  public let exposureId: String
  public let placement: WtsExperiencePlacement
  public let priority: Int
  public let content: WtsExperienceContent
  public let assetURL: URL?
}

public struct WtsExperienceDiagnostics: Sendable, Equatable {
  public let enabled: Bool
  public let consent: WtsExperienceConsent
  public let queued: Int
  public let presenting: Bool
  public let testDeviceToken: String
  public let lastErrorCode: String?
}

public enum WtsExperienceResult: Sendable, Equatable {
  case accepted
  case featureDisabled
  case profileConsentRequired
}
