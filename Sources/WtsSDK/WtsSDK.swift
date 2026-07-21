import Foundation

#if canImport(UIKit)
  import UIKit
#endif

public actor WtsSDK {
  public static let shared = WtsSDK()
  public static let version = "0.5.0-alpha.1"

  private let transport: HTTPTransport
  private let identity: InstallIdentityProviding
  private let store: EventStoring
  private let identityStore: IdentityMutationStoring
  private let identityBindingStore: IdentityBindingStoring
  private let experienceInteractionStore: ExperienceInteractionStoring
  private let testSessionStore: TestSessionStoring
  private let consentStore: ConsentStoring
  private let legacyStateCleaner: LegacyStateCleaning
  private let experienceManifestCacheStore: ExperienceManifestCacheStoring
  private let experienceRootPublicKey: String
  private let experienceClock: @Sendable () -> Date
  private let encoder = JSONEncoder.wts
  private let decoder = JSONDecoder.wts
  private var appKey: String?
  private var options = WtsOptions()
  private var cache = ResolveCache()
  private var retryAttempt = 0
  private var retryTask: Task<Void, Never>?
  private var identityBound = false
  private var identitySessionId = UUID().uuidString.lowercased()
  private var consentState: WtsConsentState = .pending
  private var experienceDecisionMode: String?
  private var experienceManifest: ExperienceBootstrapResponse.Manifest?
  private var experienceCandidateVersionIds: [String] = []
  private var experienceManifestExpiresAt: Date?
  private var experienceManifestRefreshAt: Date?
  private var experienceQueue: [WtsExperience] = []
  private var experienceGrants: [String: String] = [:]
  private var experienceActionHandler:
    (@Sendable (WtsExperience, WtsExperienceAction) async -> Bool)?
  private var experienceLastErrorCode: String?
  private var presentingExperience: WtsExperience?
  private var experienceSessionOverlayPresentations = 0
  private var experienceSessionImpressions = 0
  private var experiencePresentationCooldownUntil: Date?
  private var experienceTestDeviceToken = UUID().uuidString.lowercased()
  private var testSession: PersistedTestSession?
  private var testSessionLastErrorCode: String?
  private var testSessionRetryTask: Task<Void, Never>?
  private var testSessionRetryAttempt = 0
  private var experienceRefreshTimer: Task<Void, Never>?
  private var experienceRefreshTask: Task<ExperienceManifestRefreshResult, Error>?
  private var experienceManifestETag: String?

  private enum ExperienceManifestRefreshResult: Sendable {
    case notModified
    case response(Data, String?)
  }

  private static let maximumExperienceSessionOverlayPresentations = 2
  private static let maximumExperienceSessionImpressions = 5
  private static let experiencePresentationCooldown: TimeInterval = 3

  public init() {
    transport = URLSessionTransport()
    identity = KeychainInstallIdentity()
    store = FileEventStore()
    identityStore = FileIdentityMutationStore()
    identityBindingStore = FileIdentityBindingStore()
    experienceInteractionStore = FileExperienceInteractionStore()
    testSessionStore = FileTestSessionStore()
    consentStore = KeychainConsentStore()
    legacyStateCleaner = FileLegacyStateCleaner()
    experienceManifestCacheStore = FileExperienceManifestCacheStore()
    experienceRootPublicKey = ExperienceTrust.rootPublicKey
    experienceClock = { Date() }
  }

  init(
    transport: HTTPTransport,
    identity: InstallIdentityProviding,
    store: EventStoring,
    identityStore: IdentityMutationStoring = FileIdentityMutationStore(),
    identityBindingStore: IdentityBindingStoring = FileIdentityBindingStore(),
    experienceInteractionStore: ExperienceInteractionStoring =
      FileExperienceInteractionStore(),
    testSessionStore: TestSessionStoring = FileTestSessionStore(),
    consentStore: ConsentStoring = KeychainConsentStore(),
    legacyStateCleaner: LegacyStateCleaning = FileLegacyStateCleaner(),
    experienceManifestCacheStore: ExperienceManifestCacheStoring =
      FileExperienceManifestCacheStore(),
    experienceRootPublicKey: String = ExperienceTrust.rootPublicKey,
    experienceClock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.identity = identity
    self.store = store
    self.identityStore = identityStore
    self.identityBindingStore = identityBindingStore
    self.experienceInteractionStore = experienceInteractionStore
    self.testSessionStore = testSessionStore
    self.consentStore = consentStore
    self.legacyStateCleaner = legacyStateCleaner
    self.experienceManifestCacheStore = experienceManifestCacheStore
    self.experienceRootPublicKey = experienceRootPublicKey
    self.experienceClock = experienceClock
  }

  public func configure(appKey: String, options: WtsOptions = WtsOptions()) throws {
    let normalized = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count >= 8 else { throw WtsSDKError.invalidAppKey }
    if self.appKey != normalized {
      experienceTestDeviceToken = UUID().uuidString.lowercased()
    }
    self.appKey = normalized
    self.options = options
    cache.removeAll()
    try legacyStateCleaner.clear()
    consentState = try consentStore.load(sourceKey: normalized)
    if consentState == .granted {
      restoreExperienceManifestCache(sourceKey: normalized)
      identityBound = (try? identityBindingStore.load())?.sourceKey == normalized
      if let restored = try? testSessionStore.load(),
        restored.sourceKey == normalized,
        testSessionExpiry(restored.expiresAt) > Date()
      {
        testSession = restored
        if restored.compatible, !restored.pendingSignals.isEmpty {
          Task { [weak self] in try? await self?.flushTestSessionSignals() }
        }
      } else {
        clearTestSession()
      }
      scheduleFlush(after: 0)
      startExperienceRefreshTimer()
      Task { [weak self] in try? await self?.refreshExperienceManifest() }
    }
  }

  public func handle(url: URL) async throws -> WtsDeepLink {
    let sourceURL = try unwrap(url)
    guard consentState == .granted else {
      let response: FunctionalResolveResponse = try await post(
        path: "sdk/v4/functional-resolve",
        body: FunctionalResolveRequest(url: sourceURL.absoluteString),
        fallbackURL: sourceURL
      )
      guard response.matched, let path = response.path, path.hasPrefix("/") else {
        throw WtsSDKError.noMatch(fallbackURL: response.destination ?? sourceURL)
      }
      return WtsDeepLink(
        path: path,
        parameters: response.parameters,
        isDeferred: false
      )
    }
    let cacheKey = sourceURL.absoluteString
    if let cached = cache.value(for: cacheKey, now: Date()) {
      recordTestSessionSignal(
        type: "deep_link_resolved",
        outcome: "observed",
        method: "handle",
        resultCode: "RESOLVED",
        feature: "deeplink"
      )
      return cached
    }
    let request = ResolveRequest(
      schemaVersion: 4,
      clientEventId: UUID().uuidString.lowercased(),
      installId: try identity.value(),
      occurredAt: Date(),
      metadata: .current,
      url: cacheKey
    )
    let response: ResolveResponse = try await post(
      path: "sdk/v4/resolve",
      body: request,
      fallbackURL: sourceURL
    )
    guard response.match, response.link.path.hasPrefix("/") else {
      throw WtsSDKError.invalidResponse(fallbackURL: sourceURL)
    }
    let result = WtsDeepLink(
      path: response.link.path,
      parameters: response.link.parameters,
      linkId: response.link.id,
      attributionId: response.attributionId,
      isDeferred: response.isDeferred
    )
    cache.insert(result, for: cacheKey, expiresAt: Date().addingTimeInterval(options.cacheTTL))
    recordTestSessionSignal(
      type: "deep_link_resolved",
      outcome: "observed",
      method: "handle",
      resultCode: "RESOLVED",
      feature: "deeplink"
    )
    return result
  }

  public func getDeferredDeepLink() async -> WtsDeepLink? {
    guard consentState == .granted else { return nil }
    // iOS does not expose a deterministic install-referrer API.
    return nil
  }

  public func setConsent(_ consent: WtsConsentState) async throws {
    let sourceKey = try configuredAppKey()
    guard consent != .pending else {
      throw WtsSDKError.invalidProfile(reason: "setConsent accepts only granted or denied.")
    }
    try consentStore.save(consent, sourceKey: sourceKey)
    consentState = consent
    recordTestSessionSignal(type: "consent", outcome: "observed", feature: "consent")
    if consent == .denied {
      experienceRefreshTimer?.cancel()
      experienceRefreshTimer = nil
      retryTask?.cancel()
      retryTask = nil
      testSessionRetryTask?.cancel()
      testSessionRetryTask = nil
      try store.save([])
      try identityStore.save([])
      try identityBindingStore.clear()
      try identity.clear()
      clearTestSession()
      try clearExperienceRuntime(clearInteractionQueue: true)
      try experienceManifestCacheStore.clear()
      identityBound = false
      identitySessionId = UUID().uuidString.lowercased()
      cache.removeAll()
      return
    }
    identityBound = (try? identityBindingStore.load())?.sourceKey == sourceKey
    if let restored = try? testSessionStore.load(),
      restored.sourceKey == sourceKey,
      testSessionExpiry(restored.expiresAt) > Date()
    {
      testSession = restored
    }
    scheduleFlush(after: 0)
    startExperienceRefreshTimer()
    do { try await refreshExperienceManifest() } catch {
      experienceLastErrorCode = "EXPERIENCE_MANIFEST_UNAVAILABLE"
    }
  }

  public func getConsentState() -> WtsConsentState { consentState }

  public func identify(
    _ externalUserId: String,
    attributes: [String: WtsUserValue] = [:]
  ) throws {
    try requireProfileConsent()
    guard !externalUserId.isEmpty, externalUserId.utf16.count <= 128 else {
      throw WtsSDKError.invalidProfile(reason: "externalUserId must contain 1 to 128 characters.")
    }
    try validate(attributes: attributes)
    try enqueueIdentity(
      type: "identify",
      externalUserId: externalUserId,
      attributes: attributes.isEmpty ? nil : attributes
    )
  }

  public func updateUser(_ update: WtsUserUpdate) throws {
    try requireProfileConsent()
    try validate(update: update)
    try enqueueIdentity(
      type: "update_user",
      operations: UserUpdateOperations(
        set: update.set.isEmpty ? nil : update.set,
        setOnce: update.setOnce.isEmpty ? nil : update.setOnce,
        unset: update.unset.isEmpty ? nil : update.unset,
        increment: update.increment.isEmpty ? nil : update.increment
      )
    )
  }

  public func setReportedAttribution(_ attribution: WtsReportedAttribution) throws {
    try requireProfileConsent()
    guard !attribution.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      attribution.source.count <= 120
    else {
      throw WtsSDKError.invalidProfile(
        reason: "Attribution source must contain 1 to 120 characters.")
    }
    try enqueueIdentity(type: "reported_attribution", attribution: attribution)
  }

  public func resetIdentity() throws {
    try requireProfileConsent()
    try setIdentityBound(false)
    try enqueueIdentity(type: "reset_identity")
    identitySessionId = UUID().uuidString.lowercased()
  }

  public func track(
    eventKey: String,
    properties: [String: WtsValue] = [:],
    revenue: WtsRevenue? = nil,
    linkId: String? = nil
  ) async throws {
    guard appKey != nil else { throw WtsSDKError.notConfigured }
    guard consentState == .granted else { return }
    try validate(eventKey: eventKey, properties: properties, revenue: revenue)
    var queue = try store.load()
    queue.append(
      EventRequest(
        clientEventId: UUID().uuidString.lowercased(),
        installId: try identity.value(),
        sessionId: identitySessionId,
        occurredAt: Date(),
        metadata: .current,
        type: "custom",
        eventKey: eventKey,
        properties: properties,
        revenue: revenue,
        linkId: linkId
      ))
    trim(&queue)
    try store.save(queue)
    recordTestSessionSignal(
      type: "event_recorded",
      outcome: "observed",
      eventKey: eventKey,
      propertyKeys: properties.keys.sorted(),
      propertyTypes: properties.mapValues(\.testSessionType),
      revenue: revenue.map { TestSessionRevenueDescriptor(present: true, currency: $0.currency) },
      feature: "events"
    )
    scheduleFlush(after: 0)
    let context = ExperienceContextWire(
        trigger: .init(
          type: "custom_event",
          match: nil,
          screenName: nil,
          eventKey: eventKey,
          conditions: []
        ),
        screenName: nil,
        eventKey: eventKey,
        properties: properties,
        triggerEventId: queue.last?.clientEventId
      )
    Task { [weak self] in await self?.evaluateExperiences(context: context) }
  }

  public func screen(
    _ name: String,
    properties: [String: WtsValue] = [:]
  ) async throws {
    guard appKey != nil else { throw WtsSDKError.notConfigured }
    guard consentState == .granted else { return }
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 120 else {
      throw WtsSDKError.invalidEvent(reason: "Screen name must contain 1 to 120 characters.")
    }
    try validateProperties(properties)
    var queue = try store.load()
    queue.append(
      EventRequest(
        clientEventId: UUID().uuidString.lowercased(),
        installId: try identity.value(),
        sessionId: identitySessionId,
        occurredAt: Date(),
        metadata: .current,
        type: "screen_view",
        screenName: normalized,
        properties: properties
      ))
    trim(&queue)
    try store.save(queue)
    recordTestSessionSignal(
      type: "screen_recorded",
      outcome: "observed",
      screenName: normalized,
      propertyKeys: properties.keys.sorted(),
      propertyTypes: properties.mapValues(\.testSessionType),
      feature: "screen"
    )
    scheduleFlush(after: 0)
    let context = ExperienceContextWire(
        trigger: .init(
          type: "screen_view",
          match: nil,
          screenName: normalized,
          eventKey: nil,
          conditions: []
        ),
        screenName: normalized,
        eventKey: nil,
        properties: properties,
        triggerEventId: queue.last?.clientEventId
      )
    Task { [weak self] in await self?.evaluateExperiences(context: context) }
  }

  public func onExperienceAction(
    _ handler: (@Sendable (WtsExperience, WtsExperienceAction) async -> Bool)?
  ) {
    experienceActionHandler = handler
  }

  private func presentNextExperience() async -> WtsExperience? {
    guard consentState == .granted else { return nil }
    guard experiencePresentationAdmissionFailureCode() == nil,
      presentingExperience == nil,
      !experienceQueue.isEmpty
    else { return nil }
    let experience = experienceQueue.removeFirst()
    await presentAutomatically(experience)
    return experience
  }

  public func dismissCurrentExperience() {
    guard presentingExperience != nil else { return }
    #if canImport(UIKit)
      Task { @MainActor in WtsExperiencePresenter.dismissCurrent() }
    #else
      presentingExperience = nil
    #endif
  }

  public func getExperienceDiagnostics() -> WtsExperienceDiagnostics {
    WtsExperienceDiagnostics(
      enabled: consentState == .granted,
      consent: consentState,
      decisionMode: experienceDecisionMode,
      queued: experienceQueue.count,
      presenting: presentingExperience != nil,
      testDeviceToken: experienceTestDeviceToken,
      lastErrorCode: experienceLastErrorCode
    )
  }

  /// Returns a stable reason when delivery must stop before an Experience is
  /// rendered. Both automatic and manual paths call this boundary so an
  /// expired signed manifest, session safety cap, or active cooldown cannot be
  /// bypassed by a host callback.
  private func experiencePresentationAdmissionFailureCode() -> String? {
    if let expiresAt = experienceManifestExpiresAt,
      (experienceManifest == nil || expiresAt <= experienceClock())
    {
      try? clearExperienceRuntime(clearInteractionQueue: false)
      experienceLastErrorCode = "EXPERIENCE_MANIFEST_EXPIRED"
      return "EXPERIENCE_MANIFEST_EXPIRED"
    }
    guard experienceManifest != nil else { return "EXPERIENCE_MANIFEST_UNAVAILABLE" }
    if let cooldownUntil = experiencePresentationCooldownUntil, cooldownUntil > experienceClock() {
      return "EXPERIENCE_COOLDOWN_ACTIVE"
    }
    guard
      experienceSessionOverlayPresentations < Self.maximumExperienceSessionOverlayPresentations,
      experienceSessionImpressions < Self.maximumExperienceSessionImpressions
    else {
      clearQueuedExperiences()
      experienceLastErrorCode = "EXPERIENCE_SESSION_CAP_REACHED"
      return "EXPERIENCE_SESSION_CAP_REACHED"
    }
    return nil
  }

  private func clearExperienceRuntime(clearInteractionQueue: Bool) throws {
    experienceRefreshTask?.cancel()
    experienceRefreshTask = nil
    experienceManifest = nil
    experienceCandidateVersionIds = []
    experienceManifestExpiresAt = nil
    experienceManifestRefreshAt = nil
    experienceManifestETag = nil
    experienceGrants = [:]
    clearQueuedExperiences()
    presentingExperience = nil
    experiencePresentationCooldownUntil = nil
    #if canImport(UIKit)
      Task { @MainActor in WtsExperiencePresenter.dismissCurrent(notify: false) }
    #endif
    if clearInteractionQueue {
      try experienceInteractionStore.save([])
    }
  }

  private func clearQueuedExperiences() {
    for experience in experienceQueue {
      experienceGrants.removeValue(forKey: experience.assignmentId)
    }
    experienceQueue = []
  }

  /**
   * Explicitly joins a dashboard-created SDK Test & Validate session. No test
   * traffic or test observations are emitted until this call succeeds.
   */
  public func joinTestSession(
    _ pairing: WtsTestSessionPairing,
    sdkFamily: WtsTestSessionSDKFamily = .nativeSwift
  ) async -> WtsTestSessionJoinResult {
    guard consentState == .granted else {
      return WtsTestSessionJoinResult(
        accepted: false,
        joined: false,
        compatible: false,
        requiredSDKVersion: nil,
        checks: [],
        sessionId: nil,
        expiresAt: nil,
        testProfileExternalUserId: nil,
        errorCode: "CONSENT_REQUIRED"
      )
    }
    do {
      let pair: TestSessionPairResponse = try await postTest(
        path: "pair",
        body: TestSessionPairRequest(
          pairingToken: pairing.pairingToken,
          pairingCode: pairing.pairingCode,
          metadata: testSessionMetadata(sdkFamily)
        )
      )
      let handshake: TestSessionHandshakeResponse = try await postTest(
        path: "handshake",
        body: TestSessionHandshakeRequest(
          participantId: pair.participant.id,
          sessionToken: pair.sessionToken,
          metadata: testSessionMetadata(sdkFamily),
          capabilities: testSessionCapabilities,
          consent: testSessionConsent
        )
      )
      let active = PersistedTestSession(
        sourceKey: try configuredAppKey(),
        sessionId: pair.session.id,
        participantId: pair.participant.id,
        sessionToken: pair.sessionToken,
        expiresAt: pair.session.expiresAt,
        compatible: handshake.accepted && handshake.compatible,
        requiredSdkVersion: handshake.requiredSdkVersion,
        sdkFamily: sdkFamily.rawValue,
        checks: handshake.checks,
        testPlan: handshake.testPlan,
        testExperienceDecisionReady: false,
        pendingSignals: []
      )
      testSession = active
      testSessionLastErrorCode = nil
      try testSessionStore.save(active)
      if active.compatible {
        recordTestSessionSignal(
          type: "sdk_connected",
          outcome: "passed",
          feature: "sdk_test_session"
        )
      }
      return WtsTestSessionJoinResult(
        accepted: handshake.accepted,
        joined: true,
        compatible: active.compatible,
        requiredSDKVersion: handshake.requiredSdkVersion,
        checks: handshake.checks.map(\.publicValue),
        sessionId: pair.session.id,
        expiresAt: testSessionExpiry(pair.session.expiresAt),
        testProfileExternalUserId: pair.testProfile.externalUserId,
        errorCode: nil
      )
    } catch {
      clearTestSession()
      testSessionLastErrorCode = testSessionErrorCode(error)
      return WtsTestSessionJoinResult(
        accepted: false,
        joined: false,
        compatible: false,
        requiredSDKVersion: nil,
        checks: [],
        sessionId: nil,
        expiresAt: nil,
        testProfileExternalUserId: nil,
        errorCode: testSessionLastErrorCode
      )
    }
  }

  public func leaveTestSession() async -> Bool {
    guard let active = activeTestSession() else { return true }
    if active.compatible {
      recordTestSessionSignal(
        type: "sdk_left",
        outcome: "observed",
        feature: "sdk_test_session"
      )
      try? await flushTestSessionSignals()
    }
    do {
      let response: TestSessionLeaveResponse = try await postTest(
        path: "leave",
        body: TestSessionLeaveRequest(
          participantId: active.participantId,
          sessionToken: active.sessionToken
        )
      )
      if response.accepted { clearTestSession() }
      return response.accepted
    } catch {
      testSessionLastErrorCode = testSessionErrorCode(error)
      persistTestSession()
      return false
    }
  }

  public func getTestSessionDiagnostics() -> WtsTestSessionDiagnostics {
    let active = activeTestSession()
    return WtsTestSessionDiagnostics(
      joined: active != nil,
      compatible: active?.compatible ?? false,
      sessionId: active?.sessionId,
      expiresAt: active.map { testSessionExpiry($0.expiresAt) },
      requiredSDKVersion: active?.requiredSdkVersion,
      checks: active?.checks.map(\.publicValue) ?? [],
      pendingSignals: active?.pendingSignals.count ?? 0,
      lastErrorCode: testSessionLastErrorCode
    )
  }

  public func probeTestSessionURL(_ url: URL) async throws -> WtsTestSessionProbeResult {
    guard url.scheme?.lowercased() == "https", url.absoluteString.utf8.count <= 2_048 else {
      throw WtsSDKError.invalidURL(fallbackURL: nil)
    }
    let active = try requireActiveTestSession()
    do {
      let response: TestSessionResolveResponse = try await postTest(
        path: "resolve",
        body: TestSessionResolveRequest(
          participantId: active.participantId,
          sessionToken: active.sessionToken,
          url: url.absoluteString
        )
      )
      recordTestSessionSignal(
        type: "probe_completed",
        outcome: response.match ? "passed" : "blocked",
        method: "resolve",
        resultCode: response.code,
        feature: "deeplink"
      )
      guard let originalURL = URL(string: response.originalUrl),
        let fallbackURL = URL(string: response.fallbackUrl)
      else { throw WtsSDKError.invalidResponse(fallbackURL: nil) }
      return WtsTestSessionProbeResult(
        match: response.match,
        status: response.status,
        code: response.code,
        originalURL: originalURL,
        fallbackURL: fallbackURL,
        link: response.link.map {
          WtsTestSessionProbeLink(id: $0.id, path: $0.path, parameters: $0.parameters)
        }
      )
    } catch {
      testSessionLastErrorCode = testSessionErrorCode(error)
      recordTestSessionSignal(
        type: "probe_completed",
        outcome: "failed",
        method: "resolve",
        resultCode: testSessionLastErrorCode,
        feature: "deeplink"
      )
      throw error
    }
  }

  /**
   * Runs synthetic checks exclusively over the test-session protocol. It never
   * creates production identities, events, screens, or Experience interactions.
   */
  public func runTestSessionProbes() async throws -> WtsTestSessionProbeRunResult {
    let active = try requireActiveTestSession()
    var emitted: [String] = []
    var skipped: [String] = []
    let identityMethods: [String] = if let profile = active.testPlan.profile,
      profile.selected, profile.available
    {
      profile.allowedMethods
    } else {
      []
    }
    if !identityMethods.isEmpty {
      for method in identityMethods {
        recordTestSessionSignal(
          type: "identity_recorded",
          outcome: "passed",
          method: method,
          propertyKeys: method == "increment" ? ["sdk_test_increment"] : nil,
          propertyTypes: method == "increment" ? ["sdk_test_increment": "number"] : nil,
          feature: "identity"
        )
      }
      emitted.append("identity")
    } else {
      skipped.append("identity")
    }
    if let event = active.testPlan.events.first {
      recordTestSessionSignal(
        type: "event_recorded",
        outcome: "passed",
        eventKey: event.eventKey,
        propertyKeys: event.properties.map(\.key),
        propertyTypes: Dictionary(uniqueKeysWithValues: event.properties.map { ($0.key, $0.type) }),
        revenue: event.revenueEnabled
          ? TestSessionRevenueDescriptor(present: true, currency: "USD")
          : nil,
        feature: "events"
      )
      emitted.append("event")
    } else {
      skipped.append("event")
    }
    if active.testPlan.screen?.selected == true {
      recordTestSessionSignal(
        type: "screen_recorded", outcome: "passed", screenName: "sdk_test_screen", feature: "screen")
      emitted.append("screen")
    } else {
      skipped.append("screen")
    }
    var experienceDecision: WtsTestSessionExperienceDecision?
    if consentState == .granted,
      let experience = active.testPlan.experience,
      experience.selected, experience.available
    {
      let response = await runTestSessionExperienceProbe(active)
      experienceDecision = response.map(\.publicValue)
      if response?.outcome == "ready" {
        testSession = active.withTestExperienceDecisionReady()
        persistTestSession()
        if let response { await presentTestSessionExperience(response) }
        emitted.append("experiences")
      } else {
        skipped.append("experiences")
      }
    } else {
      skipped.append("experiences")
    }
    try? await flushTestSessionSignals()
    return WtsTestSessionProbeRunResult(
      accepted: active.compatible,
      emitted: emitted,
      skipped: skipped,
      pendingSignals: activeTestSession()?.pendingSignals.count ?? 0,
      experienceDecision: experienceDecision
    )
  }

  /**
   * Records a manual interaction with the isolated decision returned by
   * [runTestSessionProbes]. Production Experience lifecycle events are never
   * copied into the SDK Test & Validate transport.
   */
  public func reportTestSessionExperienceInteraction(
    _ interaction: WtsTestSessionExperienceInteraction
  ) async -> Bool {
    guard let active = try? requireActiveTestSession(), active.testExperienceDecisionReady == true else {
      return false
    }
    recordTestSessionSignal(
      type: interaction == .impression ? "experience_impression" : "experience_action",
      outcome: "observed",
      feature: "experiences"
    )
    try? await flushTestSessionSignals()
    return true
  }

  public func flush() async {
    guard appKey != nil, consentState == .granted else { return }
    do {
      try await flushIdentity()
      do {
        try await flushExperienceInteractions()
      } catch {
        scheduleRetry()
      }
      try? await flushTestSessionSignals()
      let queue = try store.load()
      guard !queue.isEmpty else {
        retryAttempt = 0
        return
      }
      var batch = Array(queue.prefix(50))
      while batch.count > 1
        && encodedSize(EventBatchRequest(schemaVersion: 4, events: batch)) > 65_536
      {
        batch.removeLast()
      }
      let response: EventBatchResponse = try await post(
        path: "sdk/v4/events/batch",
        body: EventBatchRequest(schemaVersion: 4, events: batch),
        fallbackURL: nil
      )
      let terminal = Set(
        response.accepted + response.duplicates
          + response.rejected.filter { !$0.retryable }.map(\.clientEventId))
      let remaining = queue.filter { !terminal.contains($0.clientEventId) }
      try store.save(remaining)
      if response.rejected.contains(where: \.retryable) {
        scheduleRetry()
      } else {
        retryAttempt = 0
        if !remaining.isEmpty { scheduleFlush(after: 0) }
      }
    } catch let error as WtsSDKError {
      if case .server(let status, _) = error, (400..<500).contains(status), status != 429 {
        log(.error, "Discarding an invalid event batch (HTTP \(status)).")
        if var queue = try? store.load() {
          queue.removeFirst(min(50, queue.count))
          try? store.save(queue)
        }
        return
      }
      scheduleRetry()
    } catch { scheduleRetry() }
  }

  private func flushIdentity() async throws {
    let queue = try identityStore.load()
    guard !queue.isEmpty else { return }
    var batch = Array(queue.prefix(50))
    while batch.count > 1
      && encodedSize(IdentityMutationBatchRequest(schemaVersion: 1, mutations: batch)) > 65_536
    {
      batch.removeLast()
    }
    do {
      let response: IdentityMutationBatchResponse = try await post(
        path: "sdk/v2/identity/mutations",
        body: IdentityMutationBatchRequest(schemaVersion: 1, mutations: batch),
        fallbackURL: nil
      )
      let terminal = Set(
        response.accepted
          + response.duplicates
          + response.rejected.filter { !$0.retryable }.map(\.clientMutationId)
      )
      try updateIdentityBinding(
        afterApplying: batch,
        acceptedOrDuplicate: Set(response.accepted + response.duplicates)
      )
      let remaining = queue.filter { !terminal.contains($0.clientMutationId) }
      try identityStore.save(remaining)
      if response.rejected.contains(where: \.retryable) {
        throw RetryableBatchRejection()
      }
    } catch let error as WtsSDKError {
      if case .server(let status, _) = error,
        (400..<500).contains(status),
        status != 429
      {
        try identityStore.save(Array(queue.dropFirst(batch.count)))
        log(.error, "Discarding an invalid identity batch (HTTP \(status)).")
        return
      }
      throw error
    }
  }

  private func configuredAppKey() throws -> String {
    guard let appKey else { throw WtsSDKError.notConfigured }
    return appKey
  }

  private func updateIdentityBinding(
    afterApplying mutations: [IdentityMutationRequest],
    acceptedOrDuplicate: Set<String>
  ) throws {
    for mutation in mutations where acceptedOrDuplicate.contains(mutation.clientMutationId) {
      switch mutation.type {
      case "identify":
        try setIdentityBound(true)
      case "reset_identity":
        try setIdentityBound(false)
      default:
        continue
      }
    }
  }

  private func setIdentityBound(_ bound: Bool) throws {
    guard bound else {
      try identityBindingStore.clear()
      identityBound = false
      return
    }
    try identityBindingStore.save(.init(sourceKey: try configuredAppKey()))
    identityBound = true
  }

  private func activeTestSession() -> PersistedTestSession? {
    guard let active = testSession else { return nil }
    guard active.sourceKey == appKey, testSessionExpiry(active.expiresAt) > Date() else {
      clearTestSession()
      return nil
    }
    return active
  }

  private func requireActiveTestSession() throws -> PersistedTestSession {
    guard let active = activeTestSession(), active.compatible else {
      throw WtsSDKError.invalidEvent(reason: "No compatible SDK Test & Validate session is active.")
    }
    return active
  }

  private func clearTestSession() {
    testSessionRetryTask?.cancel()
    testSessionRetryTask = nil
    testSessionRetryAttempt = 0
    testSession = nil
    try? testSessionStore.clear()
  }

  private func persistTestSession() {
    guard let active = testSession else { return }
    do {
      try testSessionStore.save(active)
    } catch {
      testSessionLastErrorCode = WtsSDKError.storage.code
    }
  }

  private func recordTestSessionSignal(
    type: String,
    outcome: String,
    method: String? = nil,
    eventKey: String? = nil,
    screenName: String? = nil,
    propertyKeys: [String]? = nil,
    propertyTypes: [String: String]? = nil,
    revenue: TestSessionRevenueDescriptor? = nil,
    resultCode: String? = nil,
    feature: String? = nil
  ) {
    guard var active = activeTestSession(), active.compatible else { return }
    if (type == "experience_impression" || type == "experience_action")
      && active.testExperienceDecisionReady != true
    {
      return
    }
    guard testSessionSignalIsAllowed(
      active.testPlan,
      type: type,
      method: method,
      eventKey: eventKey,
      hasRevenue: revenue != nil
    ) else { return }
    var pending = active.pendingSignals
    pending.append(
      TestSessionSignal(
        type: type,
        outcome: outcome,
        method: method,
        eventKey: eventKey,
        screenName: screenName,
        propertyKeys: propertyKeys.map { Array($0.prefix(20)) },
        propertyTypes: propertyTypes.map {
          Dictionary(uniqueKeysWithValues: $0.prefix(20).map { ($0.key, $0.value) })
        },
        revenue: revenue,
        resultCode: resultCode,
        feature: feature
      )
    )
    while pending.count > 50 { pending.removeFirst() }
    active = PersistedTestSession(
      sourceKey: active.sourceKey,
      sessionId: active.sessionId,
      participantId: active.participantId,
      sessionToken: active.sessionToken,
      expiresAt: active.expiresAt,
      compatible: active.compatible,
      requiredSdkVersion: active.requiredSdkVersion,
      sdkFamily: active.sdkFamily,
      checks: active.checks,
      testPlan: active.testPlan,
      testExperienceDecisionReady: active.testExperienceDecisionReady,
      pendingSignals: pending
    )
    testSession = active
    persistTestSession()
    Task { [weak self] in try? await self?.flushTestSessionSignals() }
  }

  private func testSessionSignalIsAllowed(
    _ plan: TestSessionPlan,
    type: String,
    method: String?,
    eventKey: String?,
    hasRevenue: Bool = false
  ) -> Bool {
    switch type {
    case "identity_recorded":
      guard let profile = plan.profile else { return false }
      return profile.selected && profile.available
        && method.map(profile.allowedMethods.contains) == true
    case "event_recorded":
      return eventKey.map { key in
        plan.events.contains(where: { $0.eventKey == key && (!hasRevenue || $0.revenueEnabled) })
      } ?? false
    case "screen_recorded":
      return plan.screen?.selected == true
    case "deep_link_resolved", "probe_completed":
      return plan.deepLink?.selected == true && plan.deepLink?.available == true
    case "experience_impression", "experience_action":
      return plan.experience?.selected == true && plan.experience?.available == true
    default:
      return true
    }
  }

  private func flushTestSessionSignals() async throws {
    guard let active = activeTestSession(), active.compatible, !active.pendingSignals.isEmpty else {
      return
    }
    let batch = Array(active.pendingSignals.prefix(50))
    do {
      let response: TestSessionSignalBatchResponse = try await postTest(
        path: "signals/batch",
        body: TestSessionSignalBatchRequest(
          participantId: active.participantId,
          sessionToken: active.sessionToken,
          signals: batch
        )
      )
      let terminal = Set(
        response.accepted + response.duplicates
          + response.rejected.filter { !$0.retryable }.map(\.clientSignalId)
      )
      guard let refreshed = activeTestSession() else { return }
      testSession = PersistedTestSession(
        sourceKey: refreshed.sourceKey,
        sessionId: refreshed.sessionId,
        participantId: refreshed.participantId,
        sessionToken: refreshed.sessionToken,
        expiresAt: refreshed.expiresAt,
        compatible: refreshed.compatible,
        requiredSdkVersion: refreshed.requiredSdkVersion,
        sdkFamily: refreshed.sdkFamily,
        checks: refreshed.checks,
        testPlan: refreshed.testPlan,
        testExperienceDecisionReady: refreshed.testExperienceDecisionReady,
        pendingSignals: refreshed.pendingSignals.filter { !terminal.contains($0.clientSignalId) }
      )
      if response.rejected.contains(where: \.retryable) {
        scheduleTestSessionRetry()
      } else {
        testSessionRetryAttempt = 0
      }
      persistTestSession()
    } catch let error as WtsSDKError {
      testSessionLastErrorCode = error.code
      if case .server(let status, _) = error, [401, 403, 404].contains(status) {
        clearTestSession()
      } else if case .server(let status, _) = error,
        (400..<500).contains(status), status != 429
      {
        guard let refreshed = activeTestSession() else { return }
        testSession = PersistedTestSession(
          sourceKey: refreshed.sourceKey,
          sessionId: refreshed.sessionId,
          participantId: refreshed.participantId,
          sessionToken: refreshed.sessionToken,
          expiresAt: refreshed.expiresAt,
          compatible: refreshed.compatible,
          requiredSdkVersion: refreshed.requiredSdkVersion,
          sdkFamily: refreshed.sdkFamily,
          checks: refreshed.checks,
          testPlan: refreshed.testPlan,
          testExperienceDecisionReady: refreshed.testExperienceDecisionReady,
          pendingSignals: Array(refreshed.pendingSignals.dropFirst(batch.count))
        )
        persistTestSession()
      } else {
        scheduleTestSessionRetry()
      }
    } catch {
      testSessionLastErrorCode = testSessionErrorCode(error)
      scheduleTestSessionRetry()
    }
  }

  private func scheduleTestSessionRetry() {
    guard testSessionRetryTask == nil, activeTestSession()?.compatible == true else { return }
    let base = min(pow(2, Double(testSessionRetryAttempt)) * 1, 60)
    testSessionRetryAttempt = min(testSessionRetryAttempt + 1, 6)
    let delay = base * Double.random(in: 0.8...1.2)
    testSessionRetryTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.clearTestSessionRetryTask()
      try? await self?.flushTestSessionSignals()
    }
  }

  private func clearTestSessionRetryTask() {
    testSessionRetryTask = nil
  }

  private func startExperienceRefreshTimer() {
    experienceRefreshTimer?.cancel()
    experienceRefreshTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.refreshExperienceManifestFromTimer()
      }
    }
  }

  private func refreshExperienceManifestFromTimer() async {
    guard consentState == .granted else { return }
    do { try await refreshExperienceManifest() } catch {
      if let expiresAt = experienceManifestExpiresAt, expiresAt <= experienceClock() {
        try? clearExperienceRuntime(clearInteractionQueue: false)
        experienceLastErrorCode = "EXPERIENCE_MANIFEST_EXPIRED"
      }
    }
  }

  private func runTestSessionExperienceProbe(
    _ active: PersistedTestSession
  ) async -> TestSessionExperienceDecisionResponse? {
    do {
      let response: TestSessionExperienceDecisionResponse = try await postTest(
        path: "experiences/decide",
        body: TestSessionExperienceDecisionRequest(
          participantId: active.participantId,
          sessionToken: active.sessionToken,
          context: .init(
            type: "screen_view",
            pathname: nil,
            pageName: nil,
            screenName: "sdk_test_screen",
            eventKey: nil,
            properties: nil,
            locale: WtsMetadata.current.locale
          )
        )
      )
      return response
    } catch {
      testSessionLastErrorCode = testSessionErrorCode(error)
      return nil
    }
  }

  private func presentTestSessionExperience(
    _ response: TestSessionExperienceDecisionResponse
  ) async {
    guard response.renderMode == "automatic", response.queue == "isolated_test",
      let decision = response.decision,
      let variant = decision.variant,
      let placement = WtsExperiencePlacement(rawValue: decision.placement),
      let contentData = try? encoder.encode(variant.content),
      let content = try? decoder.decode(WtsExperienceContent.self, from: contentData)
    else { return }
    let experience = WtsExperience(
      campaignId: decision.campaignId,
      campaignVersionId: decision.campaignVersionId,
      assignmentId: "test-session",
      variantId: variant.id,
      exposureId: UUID().uuidString.lowercased(),
      placement: placement,
      priority: Int.max,
      content: content,
      assetURL: variant.asset?.url
    )
    #if canImport(UIKit)
      _ = await WtsExperiencePresenter.present(
        experience,
        onImpression: { [weak self] in
          Task {
            await self?.recordTestSessionSignal(
              type: "experience_impression", outcome: "observed", feature: "experiences")
          }
        },
        onAction: { [weak self] _ in
          await self?.recordTestSessionSignal(
            type: "experience_action", outcome: "observed", feature: "experiences")
          return true
        },
        onDismiss: { _ in }
      )
    #endif
  }

  private func postTest<Request: Encodable, Response: Decodable>(
    path: String,
    body: Request
  ) async throws -> Response {
    try await post(path: "sdk/test/v2/\(path)", body: body, fallbackURL: nil)
  }

  private func testSessionMetadata(_ sdkFamily: WtsTestSessionSDKFamily) -> TestSessionMetadata {
    let metadata = WtsMetadata.current
    return TestSessionMetadata(
      sdkFamily: sdkFamily.rawValue,
      appVersion: metadata.appVersion,
      osVersion: metadata.osVersion,
      locale: metadata.locale
    )
  }

  private var testSessionCapabilities: TestSessionCapabilities {
    TestSessionCapabilities(
      deeplink: true,
      identity: true,
      screen: true,
      experiences: true,
      offlineQueue: true
    )
  }

  private var testSessionConsent: String { consentState.rawValue }

  private func testSessionExpiry(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) ?? .distantPast
  }

  private func testSessionErrorCode(_ error: Error) -> String {
    if let error = error as? WtsSDKError { return error.code }
    return "TEST_SESSION_TRANSPORT_ERROR"
  }

  private func post<Request: Encodable, Response: Decodable>(
    path: String,
    body: Request,
    fallbackURL: URL?
  ) async throws -> Response {
    guard let appKey else { throw WtsSDKError.notConfigured }
    var request = URLRequest(
      url: options.apiBaseURL.appendingPathComponent(path),
      timeoutInterval: options.requestTimeout
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(appKey, forHTTPHeaderField: "X-WTS-App-Key")
    request.httpBody = try encoder.encode(body)
    do {
      let (data, response) = try await transport.data(for: request)
      guard (200..<300).contains(response.statusCode) else {
        if response.statusCode == 404, let fallbackURL {
          throw WtsSDKError.noMatch(fallbackURL: fallbackURL)
        }
        throw WtsSDKError.server(statusCode: response.statusCode, fallbackURL: fallbackURL)
      }
      do { return try decoder.decode(Response.self, from: data) } catch {
        throw WtsSDKError.invalidResponse(fallbackURL: fallbackURL)
      }
    } catch let error as WtsSDKError { throw error } catch let error as URLError
      where error.code == .timedOut
    { throw WtsSDKError.timeout(fallbackURL: fallbackURL) } catch {
      throw WtsSDKError.network(fallbackURL: fallbackURL)
    }
  }

  private func refreshExperienceManifest() async throws {
    guard let appKey else { throw WtsSDKError.notConfigured }
    guard consentState == .granted else { return }
    let task: Task<ExperienceManifestRefreshResult, Error>
    if let current = experienceRefreshTask {
      task = current
    } else {
      var request = URLRequest(
        url: options.collectorBaseURL.appendingPathComponent("experiences/v2/bootstrap"),
        timeoutInterval: options.requestTimeout
      )
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(appKey, forHTTPHeaderField: "X-WTS-Source-Key")
      if let experienceManifestETag {
        request.setValue(experienceManifestETag, forHTTPHeaderField: "If-None-Match")
      }
      request.httpBody = try encoder.encode(
        ExperienceBootstrapRequest(
          actorId: try identity.value(),
          sessionId: identitySessionId,
          metadata: .current,
          testDeviceToken: experienceTestDeviceToken
        )
      )
      let transport = self.transport
      task = Task {
        let (data, response) = try await transport.data(for: request)
        if response.statusCode == 304 { return .notModified }
        guard (200..<300).contains(response.statusCode) else {
          throw WtsSDKError.server(statusCode: response.statusCode, fallbackURL: nil)
        }
        return .response(data, response.value(forHTTPHeaderField: "ETag"))
      }
      experienceRefreshTask = task
    }
    let result: ExperienceManifestRefreshResult
    do {
      result = try await task.value
    } catch let error as WtsSDKError {
      experienceRefreshTask = nil
      throw error
    } catch let error as URLError where error.code == .timedOut {
      experienceRefreshTask = nil
      throw WtsSDKError.timeout(fallbackURL: nil)
    } catch {
      experienceRefreshTask = nil
      throw WtsSDKError.network(fallbackURL: nil)
    }
    experienceRefreshTask = nil
    if case .notModified = result {
      guard let expiresAt = experienceManifestExpiresAt, expiresAt > experienceClock() else {
        throw WtsSDKError.invalidResponse(fallbackURL: nil)
      }
      experienceManifestRefreshAt = min(
        expiresAt,
        experienceClock().addingTimeInterval(60)
      )
      return
    }
    guard case .response(let data, let etag) = result,
      let response = try? decoder.decode(ExperienceBootstrapResponse.self, from: data)
    else { throw WtsSDKError.invalidResponse(fallbackURL: nil) }
    guard let manifest = ExperienceManifestVerifier.verify(
      response: response,
      rootPublicKey: experienceRootPublicKey,
      expectedSourceKey: appKey,
      now: experienceClock(),
      decoder: decoder
    ), manifest.expiresAt > experienceClock() else {
      throw WtsSDKError.invalidResponse(fallbackURL: nil)
    }
    experienceManifest = manifest
    experienceCandidateVersionIds = manifest.campaigns.map(\.campaignVersionId)
    experienceManifestExpiresAt = manifest.expiresAt
    experienceManifestRefreshAt = min(
      manifest.expiresAt,
      experienceClock().addingTimeInterval(60)
    )
    experienceManifestETag = etag
    try experienceManifestCacheStore.save(
      CachedExperienceManifestEnvelope(sourceKey: appKey, etag: etag, responseData: data)
    )
    experienceLastErrorCode = nil
  }

  private func restoreExperienceManifestCache(sourceKey: String) {
    guard let cached = try? experienceManifestCacheStore.load(),
      cached.sourceKey == sourceKey,
      let response = try? decoder.decode(
        ExperienceBootstrapResponse.self,
        from: cached.responseData
      ),
      let manifest = ExperienceManifestVerifier.verify(
        response: response,
        rootPublicKey: experienceRootPublicKey,
        expectedSourceKey: sourceKey,
        now: experienceClock(),
        decoder: decoder
      )
    else {
      try? experienceManifestCacheStore.clear()
      return
    }
    experienceManifest = manifest
    experienceCandidateVersionIds = manifest.campaigns.map(\.campaignVersionId)
    experienceManifestExpiresAt = manifest.expiresAt
    experienceManifestRefreshAt = experienceClock()
    experienceManifestETag = cached.etag
  }

  private func evaluateExperiences(context: ExperienceContextWire) async {
    guard consentState == .granted else { return }
    do {
      if experienceManifestRefreshAt == nil || experienceManifestRefreshAt! <= experienceClock() {
        do { try await refreshExperienceManifest() } catch {
          guard let expiresAt = experienceManifestExpiresAt, expiresAt > experienceClock() else {
            throw error
          }
        }
      }
      if !identityBound {
        do {
          try await flushIdentity()
        } catch {
          scheduleRetry()
        }
      }
      guard let appKey, !experienceCandidateVersionIds.isEmpty else { return }
      let decisions: [ExperienceDecisionResponse.Decision]
      do {
        let response: ExperienceDecisionResponse = try await postExperience(
          path: "experiences/v2/decide",
          sourceKey: appKey,
          body: ExperienceDecisionRequest(
            actorId: try identity.value(),
            sessionId: identitySessionId,
            metadata: .current,
            testDeviceToken: experienceTestDeviceToken,
            candidateVersionIds: experienceCandidateVersionIds,
            context: context
          )
        )
        experienceDecisionMode = response.mode
        decisions = response.decisions
      } catch {
        guard let manifest = experienceManifest,
          manifest.expiresAt > experienceClock()
        else { throw error }
        experienceDecisionMode = "contextual"
        decisions = contextualExperienceDecisions(manifest: manifest, context: context)
      }
      var interactions: [ExperienceInteractionRequest] = []
      for decision in decisions.prefix(5) {
        if decision.holdout {
          interactions.append(
            experienceInteraction(
              decision: decision,
              exposureId: nil,
              type: "assigned_holdout",
              triggerEventId: context.triggerEventId
            )
          )
          continue
        }
        guard let variantId = decision.variantId, let variant = decision.content else { continue }
        let experience = WtsExperience(
          campaignId: decision.campaignId,
          campaignVersionId: decision.campaignVersionId,
          assignmentId: decision.assignmentId,
          variantId: variantId,
          exposureId: UUID().uuidString.lowercased(),
          placement: decision.placement,
          priority: decision.priority,
          content: variant.content,
          assetURL: variant.asset?.url
        )
        guard
          !experienceQueue.contains(where: {
            $0.campaignVersionId == experience.campaignVersionId
          }),
          presentingExperience?.campaignVersionId != experience.campaignVersionId
        else { continue }
        experienceGrants[experience.assignmentId] = decision.grant
        experienceQueue.append(experience)
        experienceQueue.sort {
          $0.priority == $1.priority
            ? $0.campaignId < $1.campaignId
            : $0.priority > $1.priority
        }
        if experienceQueue.count > 5 {
          let dropped = experienceQueue.removeLast()
          experienceGrants.removeValue(forKey: dropped.assignmentId)
        }
        let survivedQueueCap = experienceQueue.contains {
          $0.exposureId == experience.exposureId
        }
        for type in survivedQueueCap
          ? ["assigned_variant", "eligible", "queued"]
          : ["assigned_variant", "eligible"]
        {
          interactions.append(
            experienceInteraction(
              decision: decision,
              exposureId: experience.exposureId,
              type: type,
              triggerEventId: context.triggerEventId
            )
          )
        }
      }
      if !interactions.isEmpty {
        do {
          try await sendExperienceInteractions(interactions)
        } catch {
          scheduleRetry()
        }
      }
      _ = await presentNextExperience()
    } catch let error as WtsSDKError {
      experienceLastErrorCode = error.code
      log(.error, "Experience decision failed (\(error.code)).")
    } catch {
      experienceLastErrorCode = "EXPERIENCE_RUNTIME_ERROR"
      log(.error, "Experience decision failed.")
    }
  }

  private func contextualExperienceDecisions(
    manifest: ExperienceBootstrapResponse.Manifest,
    context: ExperienceContextWire
  ) -> [ExperienceDecisionResponse.Decision] {
    manifest.campaigns
      .filter { !$0.requiresPersonalization }
      .filter { experienceTriggerMatches($0.trigger, context: context) }
      .filter {
        experienceTargetMatches(
          $0.targeting,
          sourceId: manifest.sourceId,
          environment: manifest.environment,
          metadata: .current
        )
      }
      .sorted {
        $0.priority == $1.priority ? $0.campaignId < $1.campaignId : $0.priority > $1.priority
      }
      .compactMap { campaign in
        guard let branch = campaign.assignment, let grant = campaign.grant else { return nil }
        let variant = branch.variantId.flatMap { variantId in
          campaign.variants.first(where: { $0.id == variantId })
        }
        return ExperienceDecisionResponse.Decision(
          campaignId: campaign.campaignId,
          campaignVersionId: campaign.campaignVersionId,
          assignmentId: branch.assignmentId,
          variantId: branch.variantId,
          holdout: branch.kind == "holdout",
          placement: campaign.placement,
          priority: campaign.priority,
          content: variant.map {
            ExperienceDecisionResponse.Decision.Variant(
              id: $0.id,
              content: $0.content,
              asset: $0.asset.map {
                ExperienceDecisionResponse.Decision.Variant.Asset(url: $0.url)
              }
            )
          },
          grant: grant
        )
      }
  }

  private func sendExperienceInteractions(
    _ interactions: [ExperienceInteractionRequest]
  ) async throws {
    guard !interactions.isEmpty else { return }
    var queue = try experienceInteractionStore.load()
    queue.append(contentsOf: interactions)
    while queue.count > 100 || encodedSize(queue) > 1_048_576 {
      queue.removeFirst()
    }
    try experienceInteractionStore.save(queue)
    try await flushExperienceInteractions()
  }

  private func flushExperienceInteractions() async throws {
    guard consentState == .granted, let appKey
    else { return }
    let queue = try experienceInteractionStore.load()
    guard !queue.isEmpty else { return }
    let actorId = try identity.value()
    var batch = Array(queue.prefix(50))
    while batch.count > 1
      && encodedSize(
        ExperienceInteractionBatchRequest(
          actorId: actorId,
          sessionId: identitySessionId,
          interactions: batch
        )
      ) > 65_536
    {
      batch.removeLast()
    }
    do {
      let response: ExperienceInteractionBatchResponse = try await postExperience(
        path: "experiences/v2/interactions/batch",
        sourceKey: appKey,
        body: ExperienceInteractionBatchRequest(
          actorId: actorId,
          sessionId: identitySessionId,
          interactions: batch
        )
      )
      let terminal = Set(
        response.accepted
          + response.duplicates
          + response.rejected.filter { !$0.retryable }
          .map(\.clientInteractionId)
      )
      try experienceInteractionStore.save(
        queue.filter { !terminal.contains($0.clientInteractionId) }
      )
      if response.rejected.contains(where: \.retryable) {
        throw RetryableBatchRejection()
      }
    } catch let error as WtsSDKError {
      if case .server(let status, _) = error,
        (400..<500).contains(status),
        status != 429
      {
        try experienceInteractionStore.save(Array(queue.dropFirst(batch.count)))
        log(.error, "Discarding an invalid Experience interaction batch (HTTP \(status)).")
        return
      }
      throw error
    }
  }

  private func recordExperience(
    _ experience: WtsExperience,
    type: String,
    actionId: String? = nil,
    actionOutcome: String? = nil,
    failureCode: String? = nil
  ) async {
    guard let grant = experienceGrants[experience.assignmentId] else { return }
    let interaction = ExperienceInteractionRequest(
      clientInteractionId: UUID().uuidString.lowercased(),
      grant: grant,
      campaignId: experience.campaignId,
      campaignVersionId: experience.campaignVersionId,
      assignmentId: experience.assignmentId,
      variantId: experience.variantId,
      exposureId: experience.exposureId,
      type: type,
      actionId: actionId,
      actionOutcome: actionOutcome,
      triggerEventId: nil,
      occurredAt: Date(),
      metadata: .current,
      failureCode: failureCode
    )
    do {
      try await sendExperienceInteractions([interaction])
    } catch {
      scheduleRetry()
    }
  }

  private func presentAutomatically(_ experience: WtsExperience) async {
    guard presentingExperience == nil else { return }
    presentingExperience = experience
    await recordExperience(experience, type: "render_started")
    if experience.content.delaySeconds > 0 {
      try? await Task.sleep(
        nanoseconds: UInt64(experience.content.delaySeconds * 1_000_000_000)
      )
      guard !Task.isCancelled else {
        presentingExperience = nil
        return
      }
    }
    guard presentingExperience?.exposureId == experience.exposureId else { return }
    guard experiencePresentationAdmissionFailureCode() == nil else {
      // `experiencePresentationAdmissionFailureCode` clears stale runtime
      // state itself. Do not emit a post-expiry interaction through a grant
      // that is no longer authorized.
      return
    }
    #if canImport(UIKit)
      let presented = await WtsExperiencePresenter.present(
        experience,
        onImpression: { [weak self] in
          Task { await self?.experienceDidImpress(experience) }
        },
        onAction: { [weak self] action in
          await self?.handleExperienceAction(experience, action: action) ?? false
        },
        onDismiss: { [weak self] reason in
          Task { await self?.experienceDidDismiss(experience, reason: reason) }
        }
      )
      if presented {
        experienceSessionOverlayPresentations += 1
        await recordExperience(experience, type: "render_succeeded")
      } else {
        presentingExperience = nil
        await recordExperience(
          experience,
          type: "render_failed",
          failureCode: "PRESENTER_UNAVAILABLE"
        )
      }
    #else
      presentingExperience = nil
      await recordExperience(
        experience,
        type: "render_failed",
        failureCode: "PLATFORM_UNAVAILABLE"
      )
    #endif
  }

  private func experienceDidImpress(_ experience: WtsExperience) async {
    guard presentingExperience?.exposureId == experience.exposureId else { return }
    guard experienceSessionImpressions < Self.maximumExperienceSessionImpressions else { return }
    experienceSessionImpressions += 1
    await recordExperience(experience, type: "impression")
  }

  private func experienceDidDismiss(
    _ experience: WtsExperience,
    reason: WtsExperienceDismissReason
  ) async {
    guard presentingExperience?.exposureId == experience.exposureId else { return }
    presentingExperience = nil
    await recordExperience(experience, type: experienceTerminalInteractionType(reason))
    experiencePresentationCooldownUntil = experienceClock()
      .addingTimeInterval(Self.experiencePresentationCooldown)
    try? await Task.sleep(
      nanoseconds: UInt64(Self.experiencePresentationCooldown * 1_000_000_000)
    )
    _ = await presentNextExperience()
  }

  private func handleExperienceAction(
    _ experience: WtsExperience,
    action: WtsExperienceAction
  ) async -> Bool {
    let handled: Bool
    if action.type == .openInternalRoute || action.type == .customCallback {
      if isExperienceActionAllowed(action) {
        handled = await experienceActionHandler?(experience, action) ?? false
      } else {
        handled = false
      }
    } else {
      handled = await performSafeExperienceAction(action)
    }
    if !handled { experienceLastErrorCode = "EXPERIENCE_ACTION_UNHANDLED" }
    await recordExperience(
      experience,
      type: isPrimaryExperienceAction(experience, id: action.id)
        ? "primary_action" : "secondary_action",
      actionId: action.id,
      actionOutcome: handled ? "handled" : "unhandled"
    )
    if handled && action.isNavigationAction { clearQueuedExperiences() }
    return handled
  }

  private func isExperienceActionAllowed(_ action: WtsExperienceAction) -> Bool {
    switch action.type {
    case .dismiss:
      return true
    case .copyCode:
      return action.target?.isEmpty == false
    case .openInternalRoute:
      return action.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    case .customCallback:
      return action.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    case .openWebURL:
      guard
        let target = action.target,
        let url = URL(string: target),
        url.scheme?.lowercased() == "https",
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        components.host != nil
      else { return false }
      return true
    case .openDeepLink:
      guard
        let target = action.target,
        let url = URL(string: target),
        let scheme = url.scheme?.lowercased()
      else { return false }
      guard !isUnsafeExperienceScheme(scheme) else { return false }
      return scheme == "https" ? url.host != nil : isSafeCustomScheme(scheme)
    }
  }

  private func performSafeExperienceAction(_ action: WtsExperienceAction) async -> Bool {
    switch action.type {
    case .dismiss:
      dismissCurrentExperience()
      return true
    case .customCallback, .openInternalRoute:
      return false
    case .copyCode:
      guard let target = action.target, !target.isEmpty else { return false }
      #if canImport(UIKit)
        await MainActor.run { UIPasteboard.general.string = target }
      #endif
      return true
    case .openWebURL:
      guard let target = action.target,
        let url = URL(string: target), url.scheme?.lowercased() == "https", url.host != nil
      else { return false }
      #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.open(url) }
      #endif
      return true
    case .openDeepLink:
      guard let target = action.target, let url = URL(string: target),
        let scheme = url.scheme?.lowercased()
      else { return false }
      guard !isUnsafeExperienceScheme(scheme),
        scheme == "https" ? url.host != nil : isSafeCustomScheme(scheme)
      else { return false }
      #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.open(url) }
      #endif
      return true
    }
  }

  private func isSafeCustomScheme(_ scheme: String) -> Bool {
    scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil
      && !isUnsafeExperienceScheme(scheme)
  }

  private func isUnsafeExperienceScheme(_ scheme: String) -> Bool {
    ["about", "blob", "data", "file", "filesystem", "http", "javascript", "vbscript"]
      .contains(scheme)
  }

  private func experienceInteraction(
    decision: ExperienceDecisionResponse.Decision,
    exposureId: String?,
    type: String,
    triggerEventId: String?
  ) -> ExperienceInteractionRequest {
    ExperienceInteractionRequest(
      clientInteractionId: UUID().uuidString.lowercased(),
      grant: decision.grant,
      campaignId: decision.campaignId,
      campaignVersionId: decision.campaignVersionId,
      assignmentId: decision.assignmentId,
      variantId: decision.variantId,
      exposureId: exposureId,
      type: type,
      actionId: nil,
      actionOutcome: nil,
      triggerEventId: triggerEventId,
      occurredAt: Date(),
      metadata: .current,
      failureCode: nil
    )
  }

  private func postExperience<Request: Encodable, Response: Decodable>(
    path: String,
    sourceKey: String,
    body: Request
  ) async throws -> Response {
    var request = URLRequest(
      url: options.collectorBaseURL.appendingPathComponent(path),
      timeoutInterval: options.requestTimeout
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sourceKey, forHTTPHeaderField: "X-WTS-Source-Key")
    request.httpBody = try encoder.encode(body)
    do {
      let (data, response) = try await transport.data(for: request)
      guard (200..<300).contains(response.statusCode) else {
        throw WtsSDKError.server(statusCode: response.statusCode, fallbackURL: nil)
      }
      return try decoder.decode(Response.self, from: data)
    } catch let error as WtsSDKError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw WtsSDKError.timeout(fallbackURL: nil)
    } catch {
      throw WtsSDKError.network(fallbackURL: nil)
    }
  }

  private func unwrap(_ url: URL) throws -> URL {
    if url.scheme == "http" || url.scheme == "https" { return url }
    guard url.host == "open",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
      let wrapped = URL(string: raw),
      wrapped.scheme == "https"
    else { throw WtsSDKError.invalidURL(fallbackURL: nil) }
    return wrapped
  }

  private func validate(eventKey: String, properties: [String: WtsValue], revenue: WtsRevenue?)
    throws
  {
    guard eventKey.range(of: "^[a-z][a-z0-9_]{1,63}$", options: .regularExpression) != nil else {
      throw WtsSDKError.invalidEvent(reason: "eventKey must use lowercase snake_case.")
    }
    try validateProperties(properties)
    if let revenue {
      guard
        revenue.amount.range(of: "^-?\\d{1,12}(?:\\.\\d{1,6})?$", options: .regularExpression)
          != nil,
        revenue.currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
      else {
        throw WtsSDKError.invalidEvent(
          reason: "Revenue requires a decimal amount and ISO-4217 currency.")
      }
    }
  }

  private func validateProperties(_ properties: [String: WtsValue]) throws {
    guard properties.count <= 20 else {
      throw WtsSDKError.invalidEvent(reason: "Events support at most 20 properties.")
    }
    for (key, value) in properties {
      guard key.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil else {
        throw WtsSDKError.invalidEvent(reason: "Event property keys must use lowercase snake_case.")
      }
      if case .string(let string) = value, string.count > 512 {
        throw WtsSDKError.invalidEvent(
          reason: "String event properties cannot exceed 512 characters.")
      }
      if case .number(let number) = value, !number.isFinite {
        throw WtsSDKError.invalidEvent(reason: "Numeric event properties must be finite.")
      }
    }
  }

  private func enqueueIdentity(
    type: String,
    externalUserId: String? = nil,
    attributes: [String: WtsUserValue]? = nil,
    operations: UserUpdateOperations? = nil,
    attribution: WtsReportedAttribution? = nil
  ) throws {
    guard appKey != nil else { throw WtsSDKError.notConfigured }
    let mutation = IdentityMutationRequest(
      schemaVersion: 1,
      clientMutationId: UUID().uuidString.lowercased(),
      occurredAt: Date(),
      identity: IdentityContext(
        installId: try identity.value(),
        sessionId: identitySessionId
      ),
      type: type,
      externalUserId: externalUserId,
      attributes: attributes,
      operations: operations,
      attribution: attribution,
      metadata: .current
    )
    guard
      encodedSize(
        IdentityMutationBatchRequest(schemaVersion: 1, mutations: [mutation])
      ) <= 65_536
    else {
      throw WtsSDKError.invalidProfile(reason: "Identity mutation cannot exceed 64 KiB.")
    }
    var queue = try identityStore.load()
    queue.append(mutation)
    while queue.count > 100 || encodedSize(queue) > 1_048_576 {
      queue.removeFirst()
    }
    try identityStore.save(queue)
    for method in testSessionIdentityMethods(type: type, operations: operations) {
      recordTestSessionSignal(
        type: "identity_recorded",
        outcome: "observed",
        method: method,
        propertyKeys: method == "increment" ? ["sdk_test_increment"] : nil,
        propertyTypes: method == "increment" ? ["sdk_test_increment": "number"] : nil,
        feature: "identity"
      )
    }
    scheduleFlush(after: 0)
  }

  private func requireProfileConsent() throws {
    guard consentState == .granted else { throw WtsSDKError.profileConsentRequired }
  }

  private func testSessionIdentityMethods(
    type: String,
    operations: UserUpdateOperations?
  ) -> [String] {
    switch type {
    case "identify", "reported_attribution", "reset_identity":
      return [type]
    case "update_user":
      var methods: [String] = []
      if operations?.set?.isEmpty == false { methods.append("update_user") }
      if operations?.setOnce?.isEmpty == false { methods.append("set_once") }
      if operations?.increment?.isEmpty == false { methods.append("increment") }
      return methods.isEmpty ? ["update_user"] : methods
    default:
      return []
    }
  }

  private func validate(attributes: [String: WtsUserValue]) throws {
    guard attributes.count <= 50 else {
      throw WtsSDKError.invalidProfile(reason: "A profile mutation supports at most 50 attributes.")
    }
    for (key, value) in attributes {
      try validateAttributeKey(key)
      switch value {
      case .string(let item):
        guard item.count <= 2_048 else {
          throw WtsSDKError.invalidProfile(
            reason: "String attributes cannot exceed 2048 characters.")
        }
      case .date(let item):
        guard ISO8601DateFormatter().date(from: item) != nil else {
          throw WtsSDKError.invalidProfile(reason: "Date attributes must use ISO-8601.")
        }
      case .stringArray(let items):
        guard items.count <= 50, items.allSatisfy({ $0.count <= 512 }) else {
          throw WtsSDKError.invalidProfile(
            reason: "String-array attributes support 50 values of at most 512 characters.")
        }
      case .number, .boolean:
        break
      }
    }
  }

  private func validate(update: WtsUserUpdate) throws {
    let keys =
      Array(update.set.keys) + Array(update.setOnce.keys) + update.unset
      + Array(update.increment.keys)
    guard !keys.isEmpty, keys.count <= 50, Set(keys).count == keys.count else {
      throw WtsSDKError.invalidProfile(
        reason: "Profile updates require 1 to 50 unique attribute operations."
      )
    }
    try validate(attributes: update.set)
    try validate(attributes: update.setOnce)
    for key in update.unset + Array(update.increment.keys) {
      try validateAttributeKey(key)
    }
    guard update.increment.values.allSatisfy({ $0.isFinite }) else {
      throw WtsSDKError.invalidProfile(reason: "Increment values must be finite numbers.")
    }
  }

  private func validateAttributeKey(_ key: String) throws {
    guard
      key.range(
        of: "^[a-z][a-z0-9_]{0,63}$",
        options: .regularExpression
      ) != nil
    else {
      throw WtsSDKError.invalidProfile(
        reason: "Attribute keys must use lowercase snake_case."
      )
    }
  }

  private func trim(_ queue: inout [EventRequest]) {
    while queue.count > 100 || encodedSize(queue) > 1_048_576 { queue.removeFirst() }
  }

  private func encodedSize<Value: Encodable>(_ value: Value) -> Int {
    (try? encoder.encode(value).count) ?? Int.max
  }

  private func scheduleRetry() {
    retryAttempt = min(retryAttempt + 1, 6)
    let base = min(pow(2, Double(retryAttempt - 1)) * 60, 3_600)
    let jitter = Double.random(in: 0.8...1.2)
    scheduleFlush(after: base * jitter)
  }

  private func scheduleFlush(after seconds: TimeInterval) {
    retryTask?.cancel()
    retryTask = Task { [weak self] in
      if seconds > 0 {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      }
      guard !Task.isCancelled else { return }
      await self?.flush()
    }
  }

  private func log(_ level: WtsLogLevel, _ message: String) {
    guard options.logLevel.rawValue >= level.rawValue else { return }
    print("[WtsSDK] \(message)")
  }
}

private func experienceTriggerMatches(
  _ trigger: ExperienceManifestTrigger,
  context: ExperienceContextWire
) -> Bool {
  if trigger.type == "screen_view" {
    return context.screenName == trigger.screenName
  }
  guard trigger.type == "custom_event", context.eventKey == trigger.eventKey else {
    return false
  }
  return (trigger.conditions ?? []).allSatisfy {
    experienceValueMatches(
      current: context.properties[$0.key],
      operator: $0.operator,
      expected: $0.value
    )
  }
}

private func experienceTargetMatches(
  _ target: ExperienceTargetNode,
  sourceId: String,
  environment: String,
  metadata: WtsMetadata
) -> Bool {
  switch target {
  case .all(let conditions):
    return conditions.allSatisfy {
      experienceTargetMatches(
        $0,
        sourceId: sourceId,
        environment: environment,
        metadata: metadata
      )
    }
  case .any(let conditions):
    return conditions.contains {
      experienceTargetMatches(
        $0,
        sourceId: sourceId,
        environment: environment,
        metadata: metadata
      )
    }
  case .not(let condition):
    return !experienceTargetMatches(
      condition,
      sourceId: sourceId,
      environment: environment,
      metadata: metadata
    )
  case .condition(let field, let operation, let expected):
    let current: WtsValue? =
      switch field {
      case "platform": .string(metadata.platform)
      case "environment": .string(environment)
      case "locale": .string(metadata.locale)
      case "source_id": .string(sourceId)
      case "actor_type": .string("anonymous")
      default: nil
      }
    return experienceValueMatches(current: current, operator: operation, expected: expected)
  }
}

private func experienceValueMatches(
  current: WtsValue?,
  operator operation: String,
  expected: ExperienceTargetValue?
) -> Bool {
  if operation == "exists" { return current != nil }
  let scalar: WtsValue?
  let list: [WtsValue]?
  switch expected {
  case .scalar(let value):
    scalar = value
    list = nil
  case .list(let values):
    scalar = nil
    list = values
  case nil:
    scalar = nil
    list = nil
  }
  switch operation {
  case "equals": return current == scalar
  case "not_equals": return current != scalar
  case "in": return current.map { list?.contains($0) == true } ?? false
  case "not_in": return current.map { list?.contains($0) != true } ?? true
  case "gt", "gte", "lt", "lte":
    guard let current, let scalar, case .number(let left) = current,
      case .number(let right) = scalar
    else {
      return false
    }
    switch operation {
    case "gt": return left > right
    case "gte": return left >= right
    case "lt": return left < right
    default: return left <= right
    }
  default:
    return false
  }
}

func experienceTerminalInteractionType(_ reason: WtsExperienceDismissReason) -> String {
  switch reason {
  case .dismissed:
    return "dismissed"
  case .autoClosed:
    return "auto_closed"
  case .renderFailed:
    return "render_failed"
  }
}

private func experienceAction(
  _ experience: WtsExperience,
  id: String
) -> WtsExperienceAction? {
  for content in experience.content.translations.values {
    if content.primaryAction?.id == id { return content.primaryAction }
    if content.secondaryAction?.id == id { return content.secondaryAction }
  }
  return nil
}

private func isPrimaryExperienceAction(_ experience: WtsExperience, id: String) -> Bool {
  experience.content.translations.values.contains { $0.primaryAction?.id == id }
}

private extension WtsExperienceAction {
  var isNavigationAction: Bool {
    type == .openInternalRoute || type == .openDeepLink || type == .openWebURL
  }
}

private extension WtsValue {
  var testSessionType: String {
    switch self {
    case .string: "string"
    case .number: "number"
    case .boolean: "boolean"
    }
  }
}

private extension TestSessionHandshakeResponse.Check {
  var publicValue: WtsTestSessionCheck {
    WtsTestSessionCheck(key: key, status: status, code: code, message: message)
  }
}

private extension PersistedTestSession {
  func withTestExperienceDecisionReady() -> PersistedTestSession {
    PersistedTestSession(
      sourceKey: sourceKey,
      sessionId: sessionId,
      participantId: participantId,
      sessionToken: sessionToken,
      expiresAt: expiresAt,
      compatible: compatible,
      requiredSdkVersion: requiredSdkVersion,
      sdkFamily: sdkFamily,
      checks: checks,
      testPlan: testPlan,
      testExperienceDecisionReady: true,
      pendingSignals: pendingSignals
    )
  }
}

private extension TestSessionExperienceDecisionResponse {
  var publicValue: WtsTestSessionExperienceDecision {
    WtsTestSessionExperienceDecision(
      outcome: outcome,
      reason: reason,
      testGrant: testGrant.map {
        WtsTestSessionExperienceGrant(fixtureId: $0.fixtureId, expiresAt: $0.expiresAt)
      },
      decision: decision.map { value in
        WtsTestSessionExperienceCampaign(
          campaignId: value.campaignId,
          campaignVersionId: value.campaignVersionId,
          placement: value.placement,
          defaultLocale: value.defaultLocale,
          variant: value.variant.map { variant in
            WtsTestSessionExperienceVariant(
              id: variant.id,
              key: variant.key,
              content: variant.content,
              assetURL: variant.asset?.url
            )
          }
        )
      }
    )
  }
}

private struct RetryableBatchRejection: Error {}
