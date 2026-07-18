import CryptoKit
import Foundation
import XCTest

@testable import WtsSDK

final class WtsSDKTests: XCTestCase {
  func testRevenueNormalizesCurrency() {
    XCTAssertEqual(WtsRevenue(amount: 12.50, currency: "try").currency, "TRY")
  }

  func testResolveDecodesContractAndUsesMemoryCache() async throws {
    let transport = MockTransport { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-WTS-App-Key"), "public-app-key")
      return (try Self.fixture("resolve-success.json"), 200)
    }
    let sdk = WtsSDK(
      transport: transport,
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: MemoryIdentityMutationStore()
    )
    try await sdk.configure(appKey: "public-app-key")
    let url = try XCTUnwrap(URL(string: "https://demo.links.wts.is/summer"))

    let first = try await sdk.handle(url: url)
    let second = try await sdk.handle(url: url)

    XCTAssertEqual(first.linkId, "link_example")
    XCTAssertEqual(first.path, "/products/123")
    XCTAssertEqual(second, first)
    let requestCount = await transport.requestCount
    XCTAssertEqual(requestCount, 1)
  }

  func testNoMatchPreservesOriginalFallbackURL() async throws {
    let sdk = WtsSDK(
      transport: MockTransport { _ in (Data(), 404) },
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: MemoryIdentityMutationStore()
    )
    try await sdk.configure(appKey: "public-app-key")
    let url = try XCTUnwrap(URL(string: "https://demo.links.wts.is/missing"))

    do {
      _ = try await sdk.handle(url: url)
      XCTFail("Expected noMatch")
    } catch let error as WtsSDKError {
      XCTAssertEqual(error, .noMatch(fallbackURL: url))
      XCTAssertEqual(error.fallbackURL, url)
    }
  }

  func testInvalidEventIsRejectedBeforePersistence() async throws {
    let store = MemoryEventStore()
    let sdk = WtsSDK(
      transport: MockTransport { _ in (Self.emptyBatchFixture, 202) },
      identity: StaticIdentity(),
      store: store,
      identityStore: MemoryIdentityMutationStore()
    )
    try await sdk.configure(appKey: "public-app-key")

    do {
      try await sdk.track(eventKey: "Purchase Event")
      XCTFail("Expected invalidEvent")
    } catch let error as WtsSDKError {
      guard case .invalidEvent = error else { return XCTFail("Unexpected error: \(error)") }
    }
    XCTAssertTrue(try store.load().isEmpty)
  }

  func testScreenUsesMobileProtocolV3AndCarriesSessionContext() async throws {
    let store = MemoryEventStore()
    let transport = MockTransport { request in
      XCTAssertEqual(request.url?.path, "/api/v1/sdk/v3/events/batch")
      let body = try XCTUnwrap(request.httpBody)
      let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )
      XCTAssertEqual(json["schemaVersion"] as? Int, 3)
      let events = try XCTUnwrap(json["events"] as? [[String: Any]])
      XCTAssertEqual(events.first?["type"] as? String, "screen_view")
      XCTAssertEqual(events.first?["screenName"] as? String, "checkout")
      XCTAssertNotNil(events.first?["sessionId"] as? String)
      let eventId = try XCTUnwrap(events.first?["clientEventId"] as? String)
      return (
        Data(
          """
          { "accepted": ["\(eventId)"], "duplicates": [], "rejected": [] }
          """.utf8), 202
      )
    }
    let sdk = WtsSDK(
      transport: transport,
      identity: StaticIdentity(),
      store: store,
      identityStore: MemoryIdentityMutationStore()
    )
    try await sdk.configure(appKey: "public-app-key")

    try await sdk.screen(
      "checkout",
      properties: ["item_count": .number(3)]
    )
    await sdk.flush()

    XCTAssertTrue(try store.load().isEmpty)
  }

  func testExperienceDiagnosticsExposeASourceScopedTestDeviceToken() async throws {
    let sdk = WtsSDK(
      transport: MockTransport { _ in (Self.emptyBatchFixture, 202) },
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: MemoryIdentityMutationStore()
    )
    try await sdk.configure(appKey: "public-app-key")
    let first = await sdk.getExperienceDiagnostics().testDeviceToken
    XCTAssertNotNil(UUID(uuidString: first))

    try await sdk.configure(appKey: "second-public-app-key")
    let second = await sdk.getExperienceDiagnostics().testDeviceToken
    XCTAssertNotEqual(first, second)
    XCTAssertNotNil(UUID(uuidString: second))
  }

  func testContextualExperienceUsesSignedBootstrapGrantWithoutDecisionRoundTrip() async throws {
    let fixture = try Self.signedContextualExperienceFixture(
      rawManifest: ["untrusted": true]
    )
    let transport = MockTransport { request in
      switch request.url?.path {
      case "/experiences/v1/bootstrap":
        return (fixture.response, 200)
      case "/experiences/v1/interactions/batch":
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let interactions = try XCTUnwrap(json["interactions"] as? [[String: Any]])
        let accepted = interactions.compactMap { $0["clientInteractionId"] as? String }
        return (
          try JSONSerialization.data(
            withJSONObject: ["accepted": accepted, "duplicates": [], "rejected": []]
          ), 202
        )
      case "/api/v1/sdk/v3/events/batch":
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
          JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let accepted = events.compactMap { $0["clientEventId"] as? String }
        return (
          try JSONSerialization.data(
            withJSONObject: ["accepted": accepted, "duplicates": [], "rejected": []]
          ), 202
        )
      default:
        XCTFail("Unexpected Experience request: \(request.url?.path ?? "nil")")
        return (Data(), 404)
      }
    }
    let sdk = WtsSDK(
      transport: transport,
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: MemoryIdentityMutationStore(),
      experienceInteractionStore: MemoryExperienceInteractionStore()
    )
    try await sdk.configure(
      appKey: "public-app-key",
      options: WtsOptions(
        experiences: WtsExperienceOptions(
          enabled: true,
          renderMode: .manual,
          manifestVerificationKeys: fixture.verificationKeys
        )
      )
    )

    let consentResult = try await sdk.setExperienceConsent(.contextual)
    XCTAssertEqual(consentResult, .accepted)
    try await sdk.screen("checkout", properties: ["cart_total": .number(749.90)])

    let paths = await transport.requestedPaths
    let diagnostics = await sdk.getExperienceDiagnostics()
    XCTAssertEqual(paths.filter { $0 == "/experiences/v1/bootstrap" }.count, 1)
    XCTAssertFalse(paths.contains("/experiences/v1/decide"))
    XCTAssertEqual(diagnostics.queued, 1)
  }

  func testExperienceManifestFailsClosedForMissingKeyInvalidSignatureUnknownKeyAndExpiry() async throws {
    let validFixture = try Self.signedContextualExperienceFixture()
    let invalidSignatureFixture = try Self.signedContextualExperienceFixture(signatureTampered: true)
    let expiredFixture = try Self.signedContextualExperienceFixture(
      expiresAt: "2000-01-01T00:00:00.000Z"
    )

    for (fixture, keys) in [
      (validFixture, [String: String]()),
      (invalidSignatureFixture, invalidSignatureFixture.verificationKeys),
      (validFixture, ["unknown-kid": validFixture.verificationKeys["experience-key-v1"]!]),
      (expiredFixture, expiredFixture.verificationKeys),
    ] {
      let sdk = WtsSDK(
        transport: MockTransport { request in
          XCTAssertEqual(request.url?.path, "/experiences/v1/bootstrap")
          return (fixture.response, 200)
        },
        identity: StaticIdentity(),
        store: MemoryEventStore(),
        identityStore: MemoryIdentityMutationStore()
      )
      try await sdk.configure(
        appKey: "public-app-key",
        options: WtsOptions(
          experiences: WtsExperienceOptions(
            enabled: true,
            renderMode: .manual,
            manifestVerificationKeys: keys
          )
        )
      )

      let result = try await sdk.setExperienceConsent(.contextual)
      let diagnostics = await sdk.getExperienceDiagnostics()
      XCTAssertEqual(result, .manifestVerificationFailed)
      XCTAssertEqual(diagnostics.lastErrorCode, "EXPERIENCE_MANIFEST_VERIFICATION_FAILED")
    }
  }

  func testExperienceVerifierAcceptsBase64SPKIDERAndUsesSignedPayload() throws {
    let fixture = try Self.signedContextualExperienceFixture(rawManifest: ["untrusted": true])
    let response = try JSONDecoder.wts.decode(ExperienceBootstrapResponse.self, from: fixture.response)
    let payload = try XCTUnwrap(Data(base64URLEncoded: response.signedPayload))
    let signature = try XCTUnwrap(Data(base64URLEncoded: response.signature))
    let spki = try XCTUnwrap(Data(base64Encoded: fixture.verificationKeys[response.keyId]!))
    let raw = Data(spki.dropFirst(12))
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: raw)

    XCTAssertTrue(publicKey.isValidSignature(signature, for: payload))
    let manifest = try JSONDecoder.wts.decode(ExperienceBootstrapResponse.Manifest.self, from: payload)
    XCTAssertEqual(manifest.sourceId, "source_mobile")
    XCTAssertNotNil(
      ExperienceManifestVerifier.verify(
        response: response,
        verificationKeys: fixture.verificationKeys,
        decoder: .wts
      )
    )
  }

  func testManualExperienceLifecycleIsSingleDeliveryIdempotentAndRejectsStaleHandles() async throws {
    let fixture = try Self.signedContextualExperienceFixture()
    let recorder = ManualPresentationRecorder()
    let sdk = WtsSDK(
      transport: Self.experienceTransport(fixture: fixture),
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: MemoryIdentityMutationStore(),
      experienceInteractionStore: MemoryExperienceInteractionStore()
    )
    try await sdk.configure(
      appKey: "public-app-key",
      options: WtsOptions(
        experiences: WtsExperienceOptions(
          enabled: true,
          renderMode: .manual,
          manifestVerificationKeys: fixture.verificationKeys,
          allowedDeepLinkHosts: ["allowed.example"]
        )
      )
    )
    await sdk.onExperienceAvailable { recorder.append($0) }

    let consentResult = try await sdk.setExperienceConsent(.contextual)
    XCTAssertEqual(consentResult, .accepted)
    try await sdk.screen("checkout")

    let presentation = try XCTUnwrap(recorder.last)
    XCTAssertEqual(recorder.count, 1)
    let automaticPresentation = await sdk.presentNextExperience()
    let queuedDiagnostics = await sdk.getExperienceDiagnostics()
    XCTAssertNil(automaticPresentation)
    XCTAssertEqual(queuedDiagnostics.queued, 1)

    let forged = WtsExperiencePresentationHandle(exposureId: "forged")
    let forgedOutcome = await sdk.acknowledgeExperienceRender(forged)
    let renderOutcome = await sdk.acknowledgeExperienceRender(presentation.handle)
    let duplicateRenderOutcome = await sdk.acknowledgeExperienceRender(presentation.handle)
    let impressionOutcome = await sdk.acknowledgeExperienceImpression(presentation.handle)
    let duplicateImpressionOutcome = await sdk.acknowledgeExperienceImpression(presentation.handle)
    let actionOutcome = await sdk.reportExperienceAction(presentation.handle, actionId: "continue")
    let duplicateActionOutcome = await sdk.reportExperienceAction(
      presentation.handle,
      actionId: "continue"
    )
    let dismissalOutcome = await sdk.dismissExperience(presentation.handle)
    let duplicateDismissalOutcome = await sdk.dismissExperience(presentation.handle)
    let staleActionOutcome = await sdk.reportExperienceAction(
      presentation.handle,
      actionId: "continue"
    )
    XCTAssertEqual(forgedOutcome.code, "EXPERIENCE_PRESENTATION_NOT_FOUND")
    XCTAssertTrue(renderOutcome.accepted)
    XCTAssertTrue(duplicateRenderOutcome.idempotent)
    XCTAssertTrue(impressionOutcome.accepted)
    XCTAssertTrue(duplicateImpressionOutcome.idempotent)
    XCTAssertTrue(actionOutcome.accepted)
    XCTAssertTrue(duplicateActionOutcome.idempotent)
    XCTAssertTrue(dismissalOutcome.accepted)
    XCTAssertTrue(duplicateDismissalOutcome.idempotent)
    XCTAssertEqual(staleActionOutcome.code, "EXPERIENCE_PRESENTATION_NOT_CURRENT")
    XCTAssertEqual(recorder.count, 1)
  }

  func testHTTPSDeepLinkCannotBypassHostAllowlistWithSchemeAllowlist() async throws {
    let fixture = try Self.signedContextualExperienceFixture()
    let recorder = ManualPresentationRecorder()
    let sdk = WtsSDK(
      transport: Self.experienceTransport(fixture: fixture),
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: MemoryIdentityMutationStore(),
      experienceInteractionStore: MemoryExperienceInteractionStore()
    )
    try await sdk.configure(
      appKey: "public-app-key",
      options: WtsOptions(
        experiences: WtsExperienceOptions(
          enabled: true,
          renderMode: .manual,
          manifestVerificationKeys: fixture.verificationKeys,
          allowedDeepLinkSchemes: ["https"]
        )
      )
    )
    await sdk.onExperienceAvailable { recorder.append($0) }
    let consentResult = try await sdk.setExperienceConsent(.contextual)
    XCTAssertEqual(consentResult, .accepted)
    try await sdk.screen("checkout")

    let presentation = try XCTUnwrap(recorder.last)
    let renderOutcome = await sdk.acknowledgeExperienceRender(presentation.handle)
    XCTAssertTrue(renderOutcome.accepted)
    let outcome = await sdk.reportExperienceAction(presentation.handle, actionId: "continue")
    XCTAssertFalse(outcome.accepted)
    XCTAssertEqual(outcome.code, "EXPERIENCE_ACTION_NOT_ALLOWED")
  }

  func testPersonalizedExperienceStopsWhenProfileConsentIsDenied() async throws {
    let fixture = try Self.signedContextualExperienceFixture()
    let sdk = WtsSDK(
      transport: Self.experienceTransport(fixture: fixture),
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: MemoryIdentityMutationStore(),
      experienceInteractionStore: MemoryExperienceInteractionStore()
    )
    try await sdk.configure(
      appKey: "public-app-key",
      options: WtsOptions(
        experiences: WtsExperienceOptions(
          enabled: true,
          renderMode: .manual,
          manifestVerificationKeys: fixture.verificationKeys
        )
      )
    )
    try await sdk.setProfileConsent(.granted)
    let consentResult = try await sdk.setExperienceConsent(.personalized)
    XCTAssertEqual(consentResult, .accepted)
    try await sdk.setProfileConsent(.denied)

    let diagnostics = await sdk.getExperienceDiagnostics()
    XCTAssertEqual(diagnostics.consent, .pending)
    XCTAssertEqual(diagnostics.queued, 0)
    XCTAssertFalse(diagnostics.presenting)
  }

  func testCorruptedQueueIsQuarantinedAsEmpty() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("events.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: file)
    let store = FileEventStore(fileURL: file)

    XCTAssertEqual(try store.load(), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testCanonicalBatchFixtureDecodesStableRejectionFields() throws {
    let response = try JSONDecoder.wts.decode(
      EventBatchResponse.self,
      from: Self.fixture("event-batch-mixed.json")
    )

    XCTAssertEqual(response.accepted.count, 1)
    XCTAssertEqual(response.duplicates.count, 1)
    XCTAssertEqual(response.rejected.first?.code, "EVENT_NOT_REGISTERED")
    XCTAssertEqual(response.rejected.first?.retryable, false)
  }

  func testIdentityRequiresConsentBeforePersistentQueueing() async throws {
    let identityStore = MemoryIdentityMutationStore()
    let transport = MockTransport { request in
      XCTAssertEqual(request.url?.path, "/api/v1/sdk/v2/identity/mutations")
      return (
        Data(
          """
          {
            "accepted": [],
            "duplicates": [],
            "rejected": [{
              "clientMutationId": "00000000-0000-0000-0000-000000000000",
              "code": "PROFILE_SUPPRESSED",
              "message": "Suppressed",
              "retryable": false
            }]
          }
          """.utf8), 202
      )
    }
    let sdk = WtsSDK(
      transport: transport,
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: identityStore
    )
    try await sdk.configure(appKey: "public-app-key")

    do {
      try await sdk.identify("customer_1842")
      XCTFail("Expected profileConsentRequired")
    } catch let error as WtsSDKError {
      XCTAssertEqual(error, .profileConsentRequired)
    }

    try await sdk.setProfileConsent(.granted)
    try await sdk.identify("customer_1842", attributes: ["plan": .string("enterprise")])
    let queued = try identityStore.load()
    XCTAssertEqual(queued.count, 1)
  }

  func testOpaqueExternalUserIdIsPreservedAndConsentDenialQueuesReset() async throws {
    let identityStore = MemoryIdentityMutationStore()
    let sdk = WtsSDK(
      transport: MockTransport { _ in (Self.emptyBatchFixture, 202) },
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: identityStore
    )
    try await sdk.configure(appKey: "public-app-key")
    try await sdk.setProfileConsent(.granted)
    try await sdk.identify(" customer_1842 ")

    XCTAssertEqual(try identityStore.load().first?.externalUserId, " customer_1842 ")

    try await sdk.setProfileConsent(.denied)
    let queued = try identityStore.load()
    XCTAssertEqual(queued.count, 1)
    XCTAssertEqual(queued.first?.type, "reset_identity")
  }

  func testOversizedIdentityMutationIsRejectedBeforePersistence() async throws {
    let identityStore = MemoryIdentityMutationStore()
    let sdk = WtsSDK(
      transport: MockTransport { _ in (Self.emptyBatchFixture, 202) },
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: identityStore
    )
    try await sdk.configure(appKey: "public-app-key")
    try await sdk.setProfileConsent(.granted)
    let attributes = Dictionary(
      uniqueKeysWithValues: (0..<50).map {
        ("attribute_\($0)", WtsUserValue.string(String(repeating: "x", count: 2_048)))
      }
    )

    do {
      try await sdk.identify("customer_1842", attributes: attributes)
      XCTFail("Expected invalidProfile")
    } catch let error as WtsSDKError {
      guard case .invalidProfile = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertTrue(try identityStore.load().isEmpty)
  }

  func testErrorsExposeStableCodesAndFallbackURLs() {
    let fallbackURL = URL(string: "https://wts.is/fallback")!

    XCTAssertEqual(WtsSDKError.timeout(fallbackURL: fallbackURL).code, "TIMEOUT")
    XCTAssertEqual(
      WtsSDKError.timeout(fallbackURL: fallbackURL).fallbackURL,
      fallbackURL
    )
    XCTAssertEqual(
      WtsSDKError.profileConsentRequired.code,
      "PROFILE_CONSENT_REQUIRED"
    )
  }

  func testTestSessionIsOptInSanitizedAndUsesIsolatedExperienceDecision() async throws {
    let testStore = MemoryTestSessionStore()
    let transport = MockTransport { request in
      switch request.url?.path {
      case "/api/v1/sdk/test/v1/pair":
        return (
          Data(
            """
            {
              "session": { "id": "session_123", "status": "running", "expiresAt": "2099-01-01T00:00:00.000Z" },
              "participant": { "id": "participant_123", "sourceId": "source_123", "sourceType": "mobile_app", "status": "paired" },
              "sessionToken": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "testProfile": { "externalUserId": "test_profile_123" },
              "requiredSdkVersion": "0.3.0-alpha.1",
              "testPlan": {
                "profile": { "selected": true, "available": true, "allowedMethods": ["identify", "update_user", "set_once", "increment", "reported_attribution", "reset_identity"] },
                "events": [{ "eventKey": "checkout_started", "properties": [{ "key": "cart_total", "type": "number", "required": true }], "revenueEnabled": true }],
                "deepLink": { "selected": true, "available": true, "linkId": "link_123" },
                "experience": { "selected": true, "available": true, "campaignId": "campaign_123", "versionId": "version_123" },
                "screen": { "selected": true }
              }
            }
            """.utf8
          ), 200
        )
      case "/api/v1/sdk/test/v1/handshake":
        return (
          Data(
            """
            { "accepted": true, "compatible": true, "requiredSdkVersion": "0.3.0-alpha.1", "checks": [{ "key": "sdk_version", "status": "ready", "code": null, "message": "Ready" }], "testPlan": { "profile": { "selected": true, "available": true, "allowedMethods": ["identify", "update_user", "set_once", "increment", "reported_attribution", "reset_identity"] }, "events": [{ "eventKey": "checkout_started", "properties": [{ "key": "cart_total", "type": "number", "required": true }], "revenueEnabled": true }], "deepLink": { "selected": true, "available": true, "linkId": "link_123" }, "experience": { "selected": true, "available": true, "campaignId": "campaign_123", "versionId": "version_123" }, "screen": { "selected": true } } }
            """.utf8
          ), 200
        )
      case "/api/v1/sdk/test/v1/signals/batch":
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let signals = try XCTUnwrap(json["signals"] as? [[String: Any]])
        let identifiers = signals.compactMap { $0["clientSignalId"] as? String }
        return (
          try JSONSerialization.data(withJSONObject: [
            "accepted": identifiers,
            "duplicates": [],
            "rejected": [],
          ]), 202
        )
      case "/api/v1/sdk/test/v1/experiences/decide":
        return (
          Data(
            """
            {
              "outcome": "ready",
              "reason": null,
              "testGrant": { "fixtureId": "fixture_123", "expiresAt": "2099-01-01T00:00:00.000Z" },
              "decision": {
                "campaignId": "campaign_123",
                "campaignVersionId": "version_123",
                "placement": "modal",
                "defaultLocale": "en",
                "variant": { "id": "variant_123", "key": "control", "content": {}, "asset": null }
              }
            }
            """.utf8
          ), 200
        )
      case "/api/v1/sdk/test/v1/resolve":
        return (
          Data(
            """
            {
              "match": true,
              "status": "ready",
              "code": "RESOLVED",
              "originalUrl": "https://sample.wts.is/offer",
              "fallbackUrl": "https://example.com/offer",
              "link": { "id": "link_123", "path": "/offer", "parameters": {} }
            }
            """.utf8
          ), 200
        )
      case "/api/v1/sdk/test/v1/leave":
        return (Data("{ \"accepted\": true }".utf8), 200)
      case "/api/v1/sdk/v3/events/batch":
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let identifiers = (json["events"] as? [[String: Any]])?.compactMap {
          $0["clientEventId"] as? String
        } ?? []
        return (
          try JSONSerialization.data(withJSONObject: [
            "accepted": identifiers,
            "duplicates": [],
            "rejected": [],
          ]), 202
        )
      default:
        XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
        return (Data(), 404)
      }
    }
    let sdk = WtsSDK(
      transport: transport,
      identity: StaticIdentity(),
      store: MemoryEventStore(),
      identityStore: MemoryIdentityMutationStore(),
      testSessionStore: testStore
    )
    try await sdk.configure(
      appKey: "public-app-key",
      options: WtsOptions(experiences: WtsExperienceOptions(enabled: true, renderMode: .manual))
    )

    try await sdk.track(eventKey: "checkout_started", properties: ["cart_total": .number(749.9)])
    XCTAssertNil(try testStore.load())

    XCTAssertEqual(
      try WtsTestSessionPairing.parse("A2B3C4D5E6F7G8H9").pairingCode,
      "A2B3C4D5E6F7G8H9"
    )
    let pairing = try WtsTestSessionPairing.parse(
      "https://sample.wts.is/_wts/test/pair?pairing=" + String(repeating: "p", count: 32)
    )
    XCTAssertEqual(pairing.pairingToken, String(repeating: "p", count: 32))
    let joined = await sdk.joinTestSession(pairing)
    XCTAssertTrue(joined.accepted)
    XCTAssertTrue(joined.compatible)
    XCTAssertEqual(joined.testProfileExternalUserId, "test_profile_123")

    try await sdk.track(
      eventKey: "checkout_started",
      properties: ["cart_total": .number(749.9)],
      revenue: WtsRevenue(amount: "749.90", currency: "try")
    )
    let probe = try await sdk.probeTestSessionURL(
      XCTUnwrap(URL(string: "https://sample.wts.is/offer?secret=value"))
    )
    XCTAssertTrue(probe.match)
    let probes = try await sdk.runTestSessionProbes()
    XCTAssertTrue(probes.emitted.contains("identity"))
    XCTAssertTrue(probes.emitted.contains("event"))
    XCTAssertTrue(probes.emitted.contains("screen"))
    XCTAssertTrue(probes.emitted.contains("experiences"))
    XCTAssertEqual(probes.experienceDecision?.outcome, "ready")
    let reportedTestInteraction = await sdk.reportTestSessionExperienceInteraction(.action)
    XCTAssertTrue(reportedTestInteraction)
    await sdk.flush()
    let leftTestSession = await sdk.leaveTestSession()
    XCTAssertTrue(leftTestSession)

    let paths = await transport.requestedPaths
    XCTAssertTrue(paths.contains("/api/v1/sdk/test/v1/experiences/decide"))
    XCTAssertTrue(paths.contains("/api/v1/sdk/test/v1/resolve"))
    XCTAssertTrue(paths.contains("/api/v1/sdk/test/v1/leave"))
    XCTAssertFalse(paths.contains("/experiences/v1/interactions/batch"))
    let requests = await transport.requests
    let signalBodies = requests.filter { $0.url?.path == "/api/v1/sdk/test/v1/signals/batch" }
      .compactMap(\.httpBody)
    let signals = signalBodies.flatMap { body -> [[String: Any]] in
      let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
      return payload?["signals"] as? [[String: Any]] ?? []
    }
    let serialized = String(data: signalBodies.reduce(Data(), +), encoding: .utf8) ?? ""
    XCTAssertTrue(serialized.contains("checkout_started"))
    XCTAssertTrue(serialized.contains("cart_total"))
    for method in ["identify", "update_user", "set_once", "increment", "reported_attribution", "reset_identity"] {
      XCTAssertTrue(serialized.contains("\"method\":\"\(method)\""))
    }
    XCTAssertTrue(serialized.contains("sdk_test_increment"))
    XCTAssertTrue(signals.contains { signal in
      let revenue = signal["revenue"] as? [String: Any]
      return revenue?["present"] as? Bool == true && revenue?["currency"] as? String == "TRY"
    })
    XCTAssertTrue(signals.contains { signal in
      let revenue = signal["revenue"] as? [String: Any]
      return revenue?["present"] as? Bool == true && revenue?["currency"] as? String == "USD"
    })
    XCTAssertTrue(serialized.contains("experience_action"))
    XCTAssertFalse(serialized.contains("experience_decision"))
    XCTAssertFalse(serialized.contains("749.9"))
    XCTAssertFalse(serialized.contains("secret=value"))
    XCTAssertFalse(serialized.contains("test_profile_123"))
    let diagnostics = await sdk.getTestSessionDiagnostics()
    XCTAssertFalse(diagnostics.joined)
    XCTAssertNil(try testStore.load())
  }

  private static func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try Data(
      contentsOf: root.appendingPathComponent("contracts/mobile/v2/fixtures/\(name)")
    )
  }

  private static let emptyBatchFixture = Data(
    """
    { "accepted": [], "duplicates": [], "rejected": [] }
    """.utf8)

  private struct SignedExperienceFixture: Sendable {
    let response: Data
    let verificationKeys: [String: String]
  }

  private static func signedContextualExperienceFixture(
    rawManifest: [String: Any]? = nil,
    keyId: String = "experience-key-v1",
    expiresAt: String = "2099-01-01T00:00:00.000Z",
    signatureTampered: Bool = false
  ) throws -> SignedExperienceFixture {
    let payload = Data(
      """
      {
        "sourceId": "source_mobile",
        "sourceManifestVersion": 7,
        "environment": "production",
        "expiresAt": "\(expiresAt)",
        "campaigns": [{
          "campaignId": "campaign_checkout",
          "campaignVersionId": "campaign_version_7",
          "priority": 100,
          "placement": "modal",
          "trigger": {
            "type": "screen_view",
            "screenName": "checkout"
          },
          "targeting": {
            "kind": "condition",
            "field": "platform",
            "operator": "equals",
            "value": "ios"
          },
          "variants": [{
            "id": "variant_primary",
            "content": {
              "translations": {
                "tr": {
                  "title": "Siparişinizi tamamlayın",
                  "description": "Güvenli ödeme adımına devam edin.",
                  "primaryAction": {
                    "id": "continue",
                    "label": "Devam et",
                    "type": "OPEN_DEEP_LINK",
                    "target": "https://allowed.example/checkout"
                  },
                  "secondaryAction": null
                }
              },
              "closeable": true,
              "themePreset": "brand",
              "delaySeconds": 0,
              "autoCloseSeconds": null
            },
            "asset": null
          }],
          "requiresPersonalization": false,
          "grant": "signed-contextual-grant",
          "assignment": {
            "assignmentId": "assignment_checkout",
            "kind": "variant",
            "variantId": "variant_primary"
          }
        }]
      }
      """.utf8
    )
    let privateKey = Curve25519.Signing.PrivateKey()
    var signature = try privateKey.signature(for: payload)
    if signatureTampered {
      signature[signature.startIndex] ^= 0x01
    }
    let signedManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: payload))
    let manifest = rawManifest ?? signedManifest
    let response = try JSONSerialization.data(
      withJSONObject: [
        "manifest": manifest,
        "signedPayload": payload.base64URLEncodedString,
        "signature": signature.base64URLEncodedString,
        "keyId": keyId,
        "expiresAt": "untrusted-outer-expiry",
      ]
    )
    var publicKeySPKIDER = Data([
      0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
    ])
    publicKeySPKIDER.append(privateKey.publicKey.rawRepresentation)
    return SignedExperienceFixture(
      response: response,
      verificationKeys: [keyId: publicKeySPKIDER.base64EncodedString()]
    )
  }

  private static func experienceTransport(fixture: SignedExperienceFixture) -> MockTransport {
    MockTransport { request in
      switch request.url?.path {
      case "/experiences/v1/bootstrap":
        return (fixture.response, 200)
      case "/experiences/v1/interactions/batch", "/api/v1/sdk/v3/events/batch":
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let identifiers = ((json["interactions"] ?? json["events"]) as? [[String: Any]])?
          .compactMap { $0["clientInteractionId"] as? String ?? $0["clientEventId"] as? String }
          ?? []
        return (
          try JSONSerialization.data(withJSONObject: [
            "accepted": identifiers,
            "duplicates": [],
            "rejected": [],
          ]), 202
        )
      default:
        XCTFail("Unexpected Experience request: \(request.url?.path ?? "nil")")
        return (Data(), 404)
      }
    }
  }
}

private extension Data {
  var base64URLEncodedString: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  init?(base64URLEncoded value: String) {
    var normalized = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
    self.init(base64Encoded: normalized)
  }
}

private final class ManualPresentationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var presentations: [WtsExperienceManualPresentation] = []

  func append(_ presentation: WtsExperienceManualPresentation) {
    lock.lock()
    presentations.append(presentation)
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return presentations.count
  }

  var last: WtsExperienceManualPresentation? {
    lock.lock()
    defer { lock.unlock() }
    return presentations.last
  }
}

private actor MockTransport: HTTPTransport {
  typealias Handler = @Sendable (URLRequest) throws -> (Data, Int)
  private let handler: Handler
  private(set) var requestCount = 0
  private(set) var requestedPaths: [String] = []
  private(set) var requests: [URLRequest] = []

  init(handler: @escaping Handler) { self.handler = handler }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requestCount += 1
    requestedPaths.append(request.url?.path ?? "")
    requests.append(request)
    let (data, status) = try handler(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    return (data, response)
  }
}

private struct StaticIdentity: InstallIdentityProviding {
  func value() throws -> String { "install-test-123" }
}

private final class MemoryEventStore: EventStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [EventRequest] = []

  func load() throws -> [EventRequest] { lock.withLock { events } }
  func save(_ events: [EventRequest]) throws { lock.withLock { self.events = events } }
}

private final class MemoryIdentityMutationStore: IdentityMutationStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var mutations: [IdentityMutationRequest] = []

  func load() throws -> [IdentityMutationRequest] { lock.withLock { mutations } }
  func save(_ mutations: [IdentityMutationRequest]) throws {
    lock.withLock { self.mutations = mutations }
  }
}

private final class MemoryExperienceInteractionStore: ExperienceInteractionStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var interactions: [ExperienceInteractionRequest] = []

  func load() throws -> [ExperienceInteractionRequest] { lock.withLock { interactions } }
  func save(_ interactions: [ExperienceInteractionRequest]) throws {
    lock.withLock { self.interactions = interactions }
  }
}

private final class MemoryTestSessionStore: TestSessionStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var session: PersistedTestSession?

  func load() throws -> PersistedTestSession? { lock.withLock { session } }
  func save(_ session: PersistedTestSession) throws { lock.withLock { self.session = session } }
  func clear() throws { lock.withLock { session = nil } }
}
