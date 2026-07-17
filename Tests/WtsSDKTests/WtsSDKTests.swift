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
      store: MemoryEventStore()
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
      store: MemoryEventStore()
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
      store: store
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
      store: store
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
      store: MemoryEventStore()
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
    let transport = MockTransport { request in
      switch request.url?.path {
      case "/experiences/v1/bootstrap":
        return (Self.contextualExperienceBootstrapFixture, 200)
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
      experienceInteractionStore: MemoryExperienceInteractionStore()
    )
    try await sdk.configure(
      appKey: "public-app-key",
      options: WtsOptions(
        experiences: WtsExperienceOptions(enabled: true, renderMode: .manual)
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

  private static let contextualExperienceBootstrapFixture = Data(
    """
    {
      "manifest": {
        "sourceId": "source_mobile",
        "sourceManifestVersion": 7,
        "environment": "production",
        "expiresAt": "2099-01-01T00:00:00Z",
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
                  "primaryAction": null,
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
      },
      "signature": "signed-manifest",
      "keyId": "experience-key-v1",
      "expiresAt": "2099-01-01T00:00:00Z"
    }
    """.utf8)
}

private actor MockTransport: HTTPTransport {
  typealias Handler = @Sendable (URLRequest) throws -> (Data, Int)
  private let handler: Handler
  private(set) var requestCount = 0
  private(set) var requestedPaths: [String] = []

  init(handler: @escaping Handler) { self.handler = handler }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requestCount += 1
    requestedPaths.append(request.url?.path ?? "")
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
