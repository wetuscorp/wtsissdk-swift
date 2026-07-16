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
            return (Data("""
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
            """.utf8), 202)
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

    private static func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(
            contentsOf: root.appendingPathComponent("contracts/mobile/v2/fixtures/\(name)")
        )
    }

    private static let emptyBatchFixture = Data("""
    { "accepted": [], "duplicates": [], "rejected": [] }
    """.utf8)
}

private actor MockTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, Int)
    private let handler: Handler
    private(set) var requestCount = 0

    init(handler: @escaping Handler) { self.handler = handler }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
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
