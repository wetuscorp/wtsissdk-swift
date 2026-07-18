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
  /// Trusted Ed25519 public keys indexed by the manifest key id (`kid`).
  ///
  /// Each value must be a base64-encoded SPKI DER public key obtained from the
  /// authenticated wts.is manifest-verification-keys API. Experience delivery
  /// fails closed when the collector returns an unknown `kid` or an invalid
  /// signature.
  public var manifestVerificationKeys: [String: String]
  public var allowedInternalRoutes: Set<String>
  public var allowedCallbackKeys: Set<String>
  public var allowedDeepLinkHosts: Set<String>
  public var allowedDeepLinkSchemes: Set<String>
  public var allowedWebOrigins: Set<String>

  public init(
    enabled: Bool = false,
    renderMode: WtsExperienceRenderMode = .automatic,
    manifestVerificationKeys: [String: String] = [:],
    allowedInternalRoutes: Set<String> = [],
    allowedCallbackKeys: Set<String> = [],
    allowedDeepLinkHosts: Set<String> = [],
    allowedDeepLinkSchemes: Set<String> = [],
    allowedWebOrigins: Set<String> = []
  ) {
    self.enabled = enabled
    self.renderMode = renderMode
    self.manifestVerificationKeys = manifestVerificationKeys
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
  /// Internal correlation only. Public manual callbacks expose the opaque
  /// `WtsExperiencePresentationHandle` instead of an exposure identifier.
  let exposureId: String
  public let placement: WtsExperiencePlacement
  public let priority: Int
  public let content: WtsExperienceContent
  public let assetURL: URL?
}

/// An opaque identifier for one manually presented Experience.
///
/// The handle contains no grant. Every lifecycle call is validated against the
/// current SDK session, so a stale or reconstructed handle cannot authorize an
/// Experience interaction on its own.
public struct WtsExperiencePresentationHandle: Sendable, Hashable {
  public let exposureId: String

  public init(exposureId: String) {
    precondition(!exposureId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "Experience exposure id must not be blank.")
    self.exposureId = exposureId
  }
}

/// An Experience made available to a host application in manual render mode.
public struct WtsExperienceManualPresentation: Sendable, Equatable {
  public let experience: WtsExperience
  public let handle: WtsExperiencePresentationHandle

  public init(experience: WtsExperience, handle: WtsExperiencePresentationHandle) {
    self.experience = experience
    self.handle = handle
  }
}

/// The result of a manual Experience lifecycle operation.
public struct WtsExperienceLifecycleOutcome: Sendable, Equatable {
  public let accepted: Bool
  public let idempotent: Bool
  public let code: String?

  public init(accepted: Bool, idempotent: Bool = false, code: String? = nil) {
    self.accepted = accepted
    self.idempotent = idempotent
    self.code = code
  }
}

public enum WtsExperienceDismissReason: Sendable, Equatable {
  case dismissed
  case autoClosed
  case renderFailed
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
  case manifestVerificationFailed
}
