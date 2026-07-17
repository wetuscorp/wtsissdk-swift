import Foundation

#if canImport(UIKit)
  import UIKit
#endif

public actor WtsSDK {
  public static let shared = WtsSDK()
  public static let version = "0.3.0-alpha.1"

  private let transport: HTTPTransport
  private let identity: InstallIdentityProviding
  private let store: EventStoring
  private let identityStore: IdentityMutationStoring
  private let experienceInteractionStore: ExperienceInteractionStoring
  private let encoder = JSONEncoder.wts
  private let decoder = JSONDecoder.wts
  private var appKey: String?
  private var options = WtsOptions()
  private var cache = ResolveCache()
  private var retryAttempt = 0
  private var retryTask: Task<Void, Never>?
  private var profileConsentGranted = false
  private var identitySessionId = UUID().uuidString.lowercased()
  private var experienceConsent: WtsExperienceConsent = .pending
  private var experienceManifest: ExperienceBootstrapResponse.Manifest?
  private var experienceCandidateVersionIds: [String] = []
  private var experienceManifestExpiresAt: Date?
  private var experienceManifestRefreshAt: Date?
  private var experienceQueue: [WtsExperience] = []
  private var experienceGrants: [String: String] = [:]
  private var experienceHandler: (@Sendable (WtsExperience) -> Void)?
  private var experienceActionHandler: (@Sendable (WtsExperience, WtsExperienceAction) -> Bool)?
  private var experienceLastErrorCode: String?
  private var presentingExperience: WtsExperience?
  private var experienceSessionImpressions = 0
  private var experienceTestDeviceToken = UUID().uuidString.lowercased()

  public init() {
    transport = URLSessionTransport()
    identity = KeychainInstallIdentity()
    store = FileEventStore()
    identityStore = FileIdentityMutationStore()
    experienceInteractionStore = FileExperienceInteractionStore()
  }

  init(
    transport: HTTPTransport,
    identity: InstallIdentityProviding,
    store: EventStoring,
    identityStore: IdentityMutationStoring = FileIdentityMutationStore(),
    experienceInteractionStore: ExperienceInteractionStoring =
      FileExperienceInteractionStore()
  ) {
    self.transport = transport
    self.identity = identity
    self.store = store
    self.identityStore = identityStore
    self.experienceInteractionStore = experienceInteractionStore
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
    scheduleFlush(after: 0)
  }

  public func handle(url: URL) async throws -> WtsDeepLink {
    let sourceURL = try unwrap(url)
    let cacheKey = sourceURL.absoluteString
    if let cached = cache.value(for: cacheKey, now: Date()) { return cached }
    let request = ResolveRequest(
      schemaVersion: 3,
      clientEventId: UUID().uuidString.lowercased(),
      installId: try identity.value(),
      occurredAt: Date(),
      metadata: .current,
      url: cacheKey
    )
    let response: ResolveResponse = try await post(
      path: "sdk/v3/resolve",
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
    return result
  }

  public func getDeferredDeepLink() async -> WtsDeepLink? {
    // iOS does not expose a deterministic install-referrer API in V1.
    nil
  }

  public func setProfileConsent(_ consent: WtsProfileConsent) throws {
    if consent == .granted {
      profileConsentGranted = true
      return
    }
    profileConsentGranted = false
    try identityStore.save([])
    guard appKey != nil else {
      identitySessionId = UUID().uuidString.lowercased()
      return
    }
    try enqueueIdentity(type: "reset_identity")
    identitySessionId = UUID().uuidString.lowercased()
  }

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
    scheduleFlush(after: 0)
    await evaluateExperiences(
      context: ExperienceContextWire(
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
    )
  }

  public func screen(
    _ name: String,
    properties: [String: WtsValue] = [:]
  ) async throws {
    guard appKey != nil else { throw WtsSDKError.notConfigured }
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
    scheduleFlush(after: 0)
    await evaluateExperiences(
      context: ExperienceContextWire(
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
    )
  }

  public func setExperienceConsent(_ consent: WtsExperienceConsent) async throws
    -> WtsExperienceResult
  {
    guard options.experiences.enabled else { return .featureDisabled }
    if consent == .personalized, !profileConsentGranted {
      throw WtsSDKError.experienceProfileConsentRequired
    }
    experienceConsent = consent
    if consent == .pending || consent == .denied {
      experienceManifest = nil
      experienceCandidateVersionIds = []
      experienceManifestExpiresAt = nil
      experienceManifestRefreshAt = nil
      experienceQueue = []
      experienceGrants = [:]
      presentingExperience = nil
      #if canImport(UIKit)
        await MainActor.run {
          WtsExperiencePresenter.dismissCurrent(notify: false)
        }
      #endif
      try experienceInteractionStore.save([])
      return .accepted
    }
    try await refreshExperienceManifest()
    do {
      try await flushExperienceInteractions()
    } catch {
      scheduleRetry()
    }
    return .accepted
  }

  public func onExperienceAvailable(
    _ handler: (@Sendable (WtsExperience) -> Void)?
  ) {
    experienceHandler = handler
  }

  public func onExperienceAction(
    _ handler: (@Sendable (WtsExperience, WtsExperienceAction) -> Bool)?
  ) {
    experienceActionHandler = handler
  }

  public func presentNextExperience() async -> WtsExperience? {
    guard presentingExperience == nil, !experienceQueue.isEmpty,
      experienceSessionImpressions < 2
    else { return nil }
    let experience = experienceQueue.removeFirst()
    if options.experiences.renderMode == .manual {
      experienceHandler?(experience)
      return experience
    }
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
      enabled: options.experiences.enabled,
      consent: experienceConsent,
      queued: experienceQueue.count,
      presenting: presentingExperience != nil,
      testDeviceToken: experienceTestDeviceToken,
      lastErrorCode: experienceLastErrorCode
    )
  }

  public func flush() async {
    guard appKey != nil else { return }
    do {
      try await flushIdentity()
      do {
        try await flushExperienceInteractions()
      } catch {
        scheduleRetry()
      }
      let queue = try store.load()
      guard !queue.isEmpty else {
        retryAttempt = 0
        return
      }
      var batch = Array(queue.prefix(50))
      while batch.count > 1
        && encodedSize(EventBatchRequest(schemaVersion: 3, events: batch)) > 65_536
      {
        batch.removeLast()
      }
      let response: EventBatchResponse = try await post(
        path: "sdk/v3/events/batch",
        body: EventBatchRequest(schemaVersion: 3, events: batch),
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
    let response: ExperienceBootstrapResponse = try await postExperience(
      path: "experiences/v1/bootstrap",
      sourceKey: appKey,
      body: ExperienceBootstrapRequest(
        consent: experienceConsent,
        profileConsentGranted: profileConsentGranted,
        actorId: try identity.value(),
        sessionId: identitySessionId,
        metadata: .current,
        settings: experienceSettings,
        testDeviceToken: experienceTestDeviceToken
      )
    )
    guard response.expiresAt > Date(), response.manifest.expiresAt == response.expiresAt,
      !response.signature.isEmpty, !response.keyId.isEmpty
    else {
      throw WtsSDKError.invalidResponse(fallbackURL: nil)
    }
    experienceManifest = response.manifest
    experienceCandidateVersionIds = response.manifest.campaigns.map(\.campaignVersionId)
    experienceManifestExpiresAt = response.expiresAt
    experienceManifestRefreshAt = min(
      response.expiresAt,
      Date().addingTimeInterval(5 * 60)
    )
    experienceLastErrorCode = nil
  }

  private func evaluateExperiences(context: ExperienceContextWire) async {
    guard options.experiences.enabled,
      experienceConsent == .contextual || experienceConsent == .personalized
    else { return }
    do {
      if experienceManifestRefreshAt == nil || experienceManifestRefreshAt! <= Date() {
        try await refreshExperienceManifest()
      }
      let decisions: [ExperienceDecisionResponse.Decision]
      if experienceConsent == .contextual {
        guard let manifest = experienceManifest else { return }
        decisions = contextualExperienceDecisions(manifest: manifest, context: context)
      } else {
        try await flushIdentity()
        guard let appKey, !experienceCandidateVersionIds.isEmpty else { return }
        let response: ExperienceDecisionResponse = try await postExperience(
          path: "experiences/v1/decide",
          sourceKey: appKey,
          body: ExperienceDecisionRequest(
            consent: experienceConsent,
            profileConsentGranted: profileConsentGranted,
            actorId: try identity.value(),
            sessionId: identitySessionId,
            metadata: .current,
            settings: experienceSettings,
            testDeviceToken: experienceTestDeviceToken,
            candidateVersionIds: experienceCandidateVersionIds,
            context: context
          )
        )
        decisions = response.decisions
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
          })
        else { continue }
        experienceGrants[experience.assignmentId] = decision.grant
        experienceQueue.append(experience)
        experienceQueue.sort {
          $0.priority == $1.priority
            ? $0.campaignId < $1.campaignId
            : $0.priority > $1.priority
        }
        if experienceQueue.count > 5 { experienceQueue.removeLast() }
        for type in ["assigned_variant", "eligible", "queued"] {
          interactions.append(
            experienceInteraction(
              decision: decision,
              exposureId: experience.exposureId,
              type: type,
              triggerEventId: context.triggerEventId
            )
          )
        }
        if options.experiences.renderMode == .manual {
          experienceHandler?(experience)
        }
      }
      if !interactions.isEmpty {
        do {
          try await sendExperienceInteractions(interactions)
        } catch {
          scheduleRetry()
        }
      }
      if options.experiences.renderMode == .automatic {
        _ = await presentNextExperience()
      }
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
    guard experienceConsent == .contextual || experienceConsent == .personalized,
      let appKey
    else { return }
    let queue = try experienceInteractionStore.load()
    guard !queue.isEmpty else { return }
    let actorId = try identity.value()
    var batch = Array(queue.prefix(50))
    while batch.count > 1
      && encodedSize(
        ExperienceInteractionBatchRequest(
          consent: experienceConsent,
          profileConsentGranted: profileConsentGranted,
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
        path: "experiences/v1/interactions/batch",
        sourceKey: appKey,
        body: ExperienceInteractionBatchRequest(
          consent: experienceConsent,
          profileConsentGranted: profileConsentGranted,
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
    #if canImport(UIKit)
      let presented = await WtsExperiencePresenter.present(
        experience,
        onImpression: { [weak self] in
          Task { await self?.experienceDidImpress(experience) }
        },
        onAction: { [weak self] action in
          Task { await self?.handleExperienceAction(experience, action: action) }
        },
        onDismiss: { [weak self] in
          Task { await self?.experienceDidDismiss(experience) }
        }
      )
      if presented {
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
    experienceSessionImpressions += 1
    await recordExperience(experience, type: "impression")
  }

  private func experienceDidDismiss(_ experience: WtsExperience) async {
    guard presentingExperience?.exposureId == experience.exposureId else { return }
    presentingExperience = nil
    await recordExperience(experience, type: "dismissed")
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    _ = await presentNextExperience()
  }

  private func handleExperienceAction(
    _ experience: WtsExperience,
    action: WtsExperienceAction
  ) async {
    guard isExperienceActionAllowed(action) else {
      experienceLastErrorCode = "EXPERIENCE_ACTION_NOT_ALLOWED"
      return
    }
    let handled = experienceActionHandler?(experience, action) ?? false
    if !handled { await performSafeExperienceAction(action) }
    let content = experience.content.translations.values.first
    let primary = content?.primaryAction?.id == action.id
    await recordExperience(
      experience,
      type: primary ? "primary_action" : "secondary_action",
      actionId: action.id
    )
    if action.type == .openInternalRoute || action.type == .openDeepLink
      || action.type == .openWebURL
    {
      experienceQueue.removeAll()
    }
  }

  private func isExperienceActionAllowed(_ action: WtsExperienceAction) -> Bool {
    switch action.type {
    case .dismiss:
      return true
    case .copyCode:
      return action.target?.isEmpty == false
    case .openInternalRoute:
      return action.target.map(options.experiences.allowedInternalRoutes.contains) == true
    case .customCallback:
      return action.target.map(options.experiences.allowedCallbackKeys.contains) == true
    case .openWebURL:
      guard
        let target = action.target,
        let url = URL(string: target),
        url.scheme?.lowercased() == "https",
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let scheme = components.scheme,
        let host = components.host
      else { return false }
      let port = components.port.map { ":\($0)" } ?? ""
      return options.experiences.allowedWebOrigins.contains(
        "\(scheme)://\(host)\(port)".lowercased()
      )
    case .openDeepLink:
      guard
        let target = action.target,
        let url = URL(string: target),
        let scheme = url.scheme?.lowercased()
      else { return false }
      return options.experiences.allowedDeepLinkSchemes.contains(scheme)
        || (scheme == "https"
          && url.host.map {
            options.experiences.allowedDeepLinkHosts.contains($0.lowercased())
          } == true)
    }
  }

  private func performSafeExperienceAction(_ action: WtsExperienceAction) async {
    guard let target = action.target else { return }
    switch action.type {
    case .dismiss, .customCallback, .openInternalRoute:
      return
    case .copyCode:
      #if canImport(UIKit)
        await MainActor.run { UIPasteboard.general.string = target }
      #endif
    case .openWebURL:
      guard let url = URL(string: target), url.scheme == "https",
        let origin = URLComponents(url: url, resolvingAgainstBaseURL: false)
          .flatMap({ components -> String? in
            guard let scheme = components.scheme, let host = components.host else { return nil }
            let port = components.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)".lowercased()
          }),
        options.experiences.allowedWebOrigins.contains(origin)
      else { return }
      #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.open(url) }
      #endif
    case .openDeepLink:
      guard let url = URL(string: target),
        let scheme = url.scheme?.lowercased(),
        options.experiences.allowedDeepLinkSchemes.contains(scheme)
          || (scheme == "https"
            && url.host.map {
              options.experiences.allowedDeepLinkHosts.contains($0.lowercased())
            } == true)
      else { return }
      #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.open(url) }
      #endif
    }
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

  private var experienceSettings: ExperienceSettingsWire {
    ExperienceSettingsWire(
      allowedInternalRoutes: options.experiences.allowedInternalRoutes.sorted(),
      allowedCallbackKeys: options.experiences.allowedCallbackKeys.sorted(),
      allowedDeepLinkHosts: options.experiences.allowedDeepLinkHosts.sorted(),
      allowedDeepLinkSchemes: options.experiences.allowedDeepLinkSchemes.sorted(),
      allowedWebOrigins: options.experiences.allowedWebOrigins.sorted()
    )
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
    scheduleFlush(after: 0)
  }

  private func requireProfileConsent() throws {
    guard profileConsentGranted else { throw WtsSDKError.profileConsentRequired }
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

private struct RetryableBatchRejection: Error {}
