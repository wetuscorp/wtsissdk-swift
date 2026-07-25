import CryptoKit
import Foundation
import XCTest

@testable import WtsSDK

final class WtsSDKTests: XCTestCase {
  func testEmbeddedProductionRootIsCanonicalAndHasExpectedFingerprint() throws {
    let encoded = ExperienceTrust.rootPublicKey
    let der = try XCTUnwrap(Data(base64Encoded: encoded))
    XCTAssertEqual(der.base64EncodedString(), encoded)
    XCTAssertEqual(
      Array(der.prefix(12)),
      [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]
    )
    XCTAssertEqual(der.count, 44)
    let digest = Data(SHA256.hash(data: der)).base64URLEncodedString
    XCTAssertEqual(digest, "c_dZ_7kxZ_zrwwzdif7yziZCREvj6PTilcqkacX-ac4")
  }

  func testPendingUsesOnlyFunctionalResolveAndCreatesNoIdentity() async throws {
    let identity = StaticIdentity()
    let events = MemoryEventStore()
    let transport = MockTransport { request in
      XCTAssertEqual(request.url?.path, "/api/v1/sdk/v4/functional-resolve")
      let body = try XCTUnwrap(request.httpBody)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(json["schemaVersion"] as? Int, 4)
      XCTAssertNil(json["installId"])
      return (
        Data(
          #"{"matched":true,"destination":"https://example.com/fallback","path":"/offers","parameters":{"campaign":"summer"}}"#.utf8
        ),
        200,
        [:]
      )
    }
    let sdk = makeSDK(transport: transport, identity: identity, eventStore: events)
    try await sdk.configure(appKey: "public-app-key")

    try await sdk.track(eventKey: "checkout_started")
    let result = try await sdk.handle(url: XCTUnwrap(URL(string: "https://go.example/summer")))

    let consentState = await sdk.getConsentState()
    let requestCount = await transport.requestCount
    XCTAssertEqual(consentState, .pending)
    XCTAssertEqual(result.path, "/offers")
    XCTAssertNil(result.attributionId)
    XCTAssertEqual(identity.valueCalls, 0)
    XCTAssertTrue(try events.load().isEmpty)
    XCTAssertEqual(requestCount, 1)
  }

  func testGrantPersistsRestoresAndUsesMobileV4() async throws {
    let consent = MemoryConsentStore()
    let trust = try SignedExperienceFixture.make()
    let transport = experienceTransport(fixture: trust)
    let events = MemoryEventStore()
    let sdk = makeSDK(
      transport: transport,
      eventStore: events,
      consentStore: consent,
      rootPublicKey: trust.rootPublicKey
    )
    try await sdk.configure(appKey: "public-app-key")
    try await sdk.setConsent(.granted)
    try await sdk.screen("checkout")
    await sdk.flush()
    try await Task.sleep(nanoseconds: 100_000_000)

    let state = await sdk.getConsentState()
    let paths = await transport.requestedPaths
    XCTAssertEqual(state, .granted)
    XCTAssertTrue(paths.contains("/experiences/v2/bootstrap"))
    XCTAssertTrue(paths.contains("/experiences/v2/decide"))
    XCTAssertTrue(paths.contains("/api/v1/sdk/v4/events/batch"))

    let restored = makeSDK(
      transport: experienceTransport(fixture: trust),
      consentStore: consent,
      rootPublicKey: trust.rootPublicKey
    )
    try await restored.configure(appKey: "public-app-key")
    let restoredState = await restored.getConsentState()
    XCTAssertEqual(restoredState, .granted)
  }

  func testFirstConfigureClearsLegacyStateWithoutMigratingIt() async throws {
    let legacy = MemoryLegacyStateCleaner()
    let sdk = makeSDK(
      transport: MockTransport { _ in throw URLError(.notConnectedToInternet) },
      legacyStateCleaner: legacy
    )

    try await sdk.configure(appKey: "public-app-key")
    XCTAssertEqual(legacy.clearCalls, 1)

    try await sdk.setConsent(.denied)
    XCTAssertEqual(legacy.clearCalls, 1)
  }

  func testDenialClearsAllDataAndStopsFutureNetwork() async throws {
    let consent = MemoryConsentStore(initial: .granted)
    let identity = StaticIdentity()
    let events = MemoryEventStore(events: [EventRequest(
      installId: "install-test-123",
      sessionId: "session-test-123",
      metadata: .current,
      type: "custom",
      eventKey: "checkout_started",
      properties: [:]
    )])
    let identityMutations = MemoryIdentityMutationStore()
    let interactions = MemoryExperienceInteractionStore()
    let testSessions = MemoryTestSessionStore()
    let transport = MockTransport { _ in throw URLError(.notConnectedToInternet) }
    let sdk = WtsSDK(
      transport: transport,
      identity: identity,
      store: events,
      identityStore: identityMutations,
      identityBindingStore: MemoryIdentityBindingStore(),
      experienceInteractionStore: interactions,
      testSessionStore: testSessions,
      consentStore: consent,
      legacyStateCleaner: MemoryLegacyStateCleaner(),
      experienceManifestCacheStore: MemoryManifestCacheStore()
    )
    try await sdk.configure(appKey: "public-app-key")
    try await sdk.setConsent(.denied)
    let countAfterDenial = await transport.requestCount
    try await sdk.track(eventKey: "checkout_started")
    await sdk.flush()

    let state = await sdk.getConsentState()
    let finalRequestCount = await transport.requestCount
    XCTAssertEqual(state, .denied)
    XCTAssertEqual(consent.state, .denied)
    XCTAssertTrue(try events.load().isEmpty)
    XCTAssertTrue(try identityMutations.load().isEmpty)
    XCTAssertTrue(try interactions.load().isEmpty)
    XCTAssertEqual(identity.clearCalls, 1)
    XCTAssertEqual(finalRequestCount, countAfterDenial)
  }

  func testRootSignedKeysetAllowsLeafRotationWithoutSDKKeyChange() throws {
    let first = try SignedExperienceFixture.make(keyId: "leaf-1")
    let second = try SignedExperienceFixture.make(
      keyId: "leaf-2",
      rootPrivateKey: first.rootPrivateKey
    )
    let decoder = JSONDecoder.wts

    XCTAssertNotNil(ExperienceManifestVerifier.verify(
      response: try decoder.decode(ExperienceBootstrapResponse.self, from: first.response),
      rootPublicKey: first.rootPublicKey,
      expectedSourceKey: "public-app-key",
      now: Date(),
      decoder: decoder
    ))
    XCTAssertNotNil(ExperienceManifestVerifier.verify(
      response: try decoder.decode(ExperienceBootstrapResponse.self, from: second.response),
      rootPublicKey: first.rootPublicKey,
      expectedSourceKey: "public-app-key",
      now: Date(),
      decoder: decoder
    ))
  }

  func testManifestTrustRejectsTamperSourceReplayUnknownKeyAndExpiry() throws {
    let valid = try SignedExperienceFixture.make()
    let decoder = JSONDecoder.wts
    let response = try decoder.decode(ExperienceBootstrapResponse.self, from: valid.response)
    XCTAssertNil(ExperienceManifestVerifier.verify(
      response: response,
      rootPublicKey: valid.rootPublicKey,
      expectedSourceKey: "another-source",
      now: Date(),
      decoder: decoder
    ))

    var tampered = try XCTUnwrap(JSONSerialization.jsonObject(with: valid.response) as? [String: Any])
    tampered["signature"] = Data(repeating: 7, count: 64).base64URLEncodedString
    XCTAssertNil(ExperienceManifestVerifier.verify(
      response: try decoder.decode(
        ExperienceBootstrapResponse.self,
        from: JSONSerialization.data(withJSONObject: tampered)
      ),
      rootPublicKey: valid.rootPublicKey,
      expectedSourceKey: "public-app-key",
      now: Date(),
      decoder: decoder
    ))

    XCTAssertNil(ExperienceManifestVerifier.verify(
      response: response,
      rootPublicKey: valid.rootPublicKey,
      expectedSourceKey: "public-app-key",
      now: Date(timeIntervalSinceNow: 3_600),
      decoder: decoder
    ))
  }

  func testUnsafeExperienceSchemesAreRejected() {
    for scheme in ["http", "about", "data", "file", "javascript"] {
      XCTAssertTrue(isUnsafeExperienceSchemeForTest(scheme))
    }
  }

  private func makeSDK(
    transport: MockTransport,
    identity: StaticIdentity = StaticIdentity(),
    eventStore: MemoryEventStore = MemoryEventStore(),
    consentStore: MemoryConsentStore = MemoryConsentStore(),
    legacyStateCleaner: MemoryLegacyStateCleaner = MemoryLegacyStateCleaner(),
    rootPublicKey: String = ExperienceTrust.rootPublicKey
  ) -> WtsSDK {
    WtsSDK(
      transport: transport,
      identity: identity,
      store: eventStore,
      identityStore: MemoryIdentityMutationStore(),
      identityBindingStore: MemoryIdentityBindingStore(),
      experienceInteractionStore: MemoryExperienceInteractionStore(),
      testSessionStore: MemoryTestSessionStore(),
      consentStore: consentStore,
      legacyStateCleaner: legacyStateCleaner,
      experienceManifestCacheStore: MemoryManifestCacheStore(),
      experienceRootPublicKey: rootPublicKey
    )
  }

  private func experienceTransport(fixture: SignedExperienceFixture) -> MockTransport {
    MockTransport { request in
      switch request.url?.path {
      case "/experiences/v2/bootstrap":
        return (fixture.response, 200, ["ETag": "\"manifest-7\""])
      case "/experiences/v2/decide":
        return (fixture.decisionResponse, 200, [:])
      case "/experiences/v2/interactions/batch", "/api/v1/sdk/v4/events/batch",
        "/api/v1/sdk/v2/identity/mutations":
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let values = (json["interactions"] ?? json["events"] ?? json["mutations"])
          as? [[String: Any]] ?? []
        let ids = values.compactMap {
          $0["clientInteractionId"] as? String
            ?? $0["clientEventId"] as? String
            ?? $0["clientMutationId"] as? String
        }
        return (
          try JSONSerialization.data(withJSONObject: [
            "accepted": ids, "duplicates": [], "rejected": [],
          ]),
          202,
          [:]
        )
      default:
        return (Data(), 404, [:])
      }
    }
  }
}

private struct SignedExperienceFixture {
  let response: Data
  let decisionResponse: Data
  let rootPublicKey: String
  let rootPrivateKey: Curve25519.Signing.PrivateKey

  static func make(
    keyId: String = "leaf-1",
    rootPrivateKey: Curve25519.Signing.PrivateKey = .init()
  ) throws -> SignedExperienceFixture {
    let leaf = Curve25519.Signing.PrivateKey()
    let now = Date()
    let issuedAt = iso(now.addingTimeInterval(-60))
    let expiresAt = iso(now.addingTimeInterval(600))
    let keysetExpiresAt = iso(now.addingTimeInterval(1_800))
    let leafPublicKey = spki(leaf.publicKey.rawRepresentation).base64EncodedString()
    let keyset: [String: Any] = [
      "version": 1,
      "issuedAt": issuedAt,
      "expiresAt": keysetExpiresAt,
      "keys": [[
        "keyId": keyId,
        "algorithm": "Ed25519",
        "publicKey": leafPublicKey,
        "notBefore": issuedAt,
        "expiresAt": keysetExpiresAt,
      ]],
    ]
    let keysetPayload = try JSONSerialization.data(withJSONObject: keyset, options: [.sortedKeys])
    let manifest: [String: Any] = [
      "schemaVersion": 2,
      "sourceId": "source-mobile",
      "sourceKey": "public-app-key",
      "manifestVersion": 7,
      "environment": "production",
      "generatedAt": issuedAt,
      "issuedAt": issuedAt,
      "expiresAt": expiresAt,
      "campaigns": [[
        "campaignId": "campaign-checkout",
        "campaignVersionId": "version-7",
        "priority": 100,
        "placement": "modal",
        "trigger": ["type": "screen_view", "screenName": "checkout"],
        "targeting": [
          "kind": "condition", "field": "platform", "operator": "equals", "value": "ios",
        ],
        "variants": [],
        "requiresPersonalization": false,
        "grant": NSNull(),
        "assignment": NSNull(),
      ]],
    ]
    let manifestPayload = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    let response = try JSONSerialization.data(withJSONObject: [
      "onlineKeyset": keyset.merging([
        "signedPayload": keysetPayload.base64URLEncodedString,
        "rootSignature": try rootPrivateKey.signature(for: keysetPayload).base64URLEncodedString,
      ]) { _, new in new },
      "manifest": manifest,
      "signedPayload": manifestPayload.base64URLEncodedString,
      "signature": try leaf.signature(for: manifestPayload).base64URLEncodedString,
      "keyId": keyId,
      "expiresAt": expiresAt,
    ])
    let decision = try JSONSerialization.data(withJSONObject: [
      "mode": "contextual",
      "decisions": [],
      "serverTime": iso(now),
    ])
    return SignedExperienceFixture(
      response: response,
      decisionResponse: decision,
      rootPublicKey: spki(rootPrivateKey.publicKey.rawRepresentation).base64EncodedString(),
      rootPrivateKey: rootPrivateKey
    )
  }

  private static func spki(_ raw: Data) -> Data {
    var result = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    result.append(raw)
    return result
  }

  private static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

private actor MockTransport: HTTPTransport {
  typealias Handler = @Sendable (URLRequest) throws -> (Data, Int, [String: String])
  private let handler: Handler
  private(set) var requestCount = 0
  private(set) var requestedPaths: [String] = []

  init(handler: @escaping Handler) { self.handler = handler }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requestCount += 1
    requestedPaths.append(request.url?.path ?? "")
    let (data, status, headers) = try handler(request)
    return (
      data,
      HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )!
    )
  }
}

private final class StaticIdentity: InstallIdentityProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var values = 0
  private var clears = 0
  var valueCalls: Int { lock.withLock { values } }
  var clearCalls: Int { lock.withLock { clears } }
  func value() throws -> String { lock.withLock { values += 1 }; return "install-test-123" }
  func clear() throws { lock.withLock { clears += 1 } }
}

private final class MemoryConsentStore: ConsentStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: WtsConsentState
  init(initial: WtsConsentState = .pending) { value = initial }
  var state: WtsConsentState { lock.withLock { value } }
  func load(sourceKey: String) throws -> WtsConsentState { state }
  func save(_ state: WtsConsentState, sourceKey: String) throws {
    lock.withLock { value = state }
  }
}

private final class MemoryLegacyStateCleaner: LegacyStateCleaning, @unchecked Sendable {
  private let lock = NSLock()
  private var clears = 0
  var clearCalls: Int { lock.withLock { clears } }
  func clear() throws { lock.withLock { clears += 1 } }
}

private final class MemoryEventStore: EventStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [EventRequest]
  init(events: [EventRequest] = []) { self.events = events }
  func load() throws -> [EventRequest] { lock.withLock { events } }
  func save(_ events: [EventRequest]) throws { lock.withLock { self.events = events } }
}

private final class MemoryIdentityMutationStore: IdentityMutationStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [IdentityMutationRequest] = []
  func load() throws -> [IdentityMutationRequest] { lock.withLock { values } }
  func save(_ values: [IdentityMutationRequest]) throws { lock.withLock { self.values = values } }
}

private final class MemoryIdentityBindingStore: IdentityBindingStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: PersistedIdentityBinding?
  func load() throws -> PersistedIdentityBinding? { lock.withLock { value } }
  func save(_ value: PersistedIdentityBinding) throws { lock.withLock { self.value = value } }
  func clear() throws { lock.withLock { value = nil } }
}

private final class MemoryExperienceInteractionStore: ExperienceInteractionStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var values: [ExperienceInteractionRequest] = []
  func load() throws -> [ExperienceInteractionRequest] { lock.withLock { values } }
  func save(_ values: [ExperienceInteractionRequest]) throws { lock.withLock { self.values = values } }
}

private final class MemoryTestSessionStore: TestSessionStoring, @unchecked Sendable {
  func load() throws -> PersistedTestSession? { nil }
  func save(_ session: PersistedTestSession) throws {}
  func clear() throws {}
}

private final class MemoryManifestCacheStore: ExperienceManifestCacheStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: CachedExperienceManifestEnvelope?
  func load() throws -> CachedExperienceManifestEnvelope? { lock.withLock { value } }
  func save(_ value: CachedExperienceManifestEnvelope) throws { lock.withLock { self.value = value } }
  func clear() throws { lock.withLock { value = nil } }
}

private extension Data {
  var base64URLEncodedString: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private func isUnsafeExperienceSchemeForTest(_ scheme: String) -> Bool {
  ["about", "blob", "data", "file", "filesystem", "http", "javascript", "vbscript"]
    .contains(scheme)
}
