import Foundation

public actor WtsSDK {
    public static let shared = WtsSDK()
    public static let version = "0.2.0-alpha.1"

    private let transport: HTTPTransport
    private let identity: InstallIdentityProviding
    private let store: EventStoring
    private let identityStore: IdentityMutationStoring
    private let encoder = JSONEncoder.wts
    private let decoder = JSONDecoder.wts
    private var appKey: String?
    private var options = WtsOptions()
    private var cache = ResolveCache()
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?
    private var profileConsentGranted = false
    private var identitySessionId = UUID().uuidString.lowercased()

    public init() {
        transport = URLSessionTransport()
        identity = KeychainInstallIdentity()
        store = FileEventStore()
        identityStore = FileIdentityMutationStore()
    }

    init(
        transport: HTTPTransport,
        identity: InstallIdentityProviding,
        store: EventStoring,
        identityStore: IdentityMutationStoring = FileIdentityMutationStore()
    ) {
        self.transport = transport
        self.identity = identity
        self.store = store
        self.identityStore = identityStore
    }

    public func configure(appKey: String, options: WtsOptions = WtsOptions()) throws {
        let normalized = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 8 else { throw WtsSDKError.invalidAppKey }
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
            schemaVersion: 2,
            clientEventId: UUID().uuidString.lowercased(),
            installId: try identity.value(),
            occurredAt: Date(),
            metadata: .current,
            url: cacheKey
        )
        let response: ResolveResponse = try await post(
            path: "sdk/v2/resolve",
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
              attribution.source.count <= 120 else {
            throw WtsSDKError.invalidProfile(reason: "Attribution source must contain 1 to 120 characters.")
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
        queue.append(EventRequest(
            schemaVersion: 2,
            clientEventId: UUID().uuidString.lowercased(),
            installId: try identity.value(),
            occurredAt: Date(),
            metadata: .current,
            eventKey: eventKey,
            properties: properties,
            revenue: revenue,
            linkId: linkId
        ))
        trim(&queue)
        try store.save(queue)
        scheduleFlush(after: 0)
    }

    public func flush() async {
        guard appKey != nil else { return }
        do {
            try await flushIdentity()
            let queue = try store.load()
            guard !queue.isEmpty else { retryAttempt = 0; return }
            var batch = Array(queue.prefix(50))
            while batch.count > 1 && encodedSize(EventBatchRequest(schemaVersion: 2, events: batch)) > 65_536 {
                batch.removeLast()
            }
            let response: EventBatchResponse = try await post(
                path: "sdk/v2/events/batch",
                body: EventBatchRequest(schemaVersion: 2, events: batch),
                fallbackURL: nil
            )
            let terminal = Set(response.accepted + response.duplicates + response.rejected.filter { !$0.retryable }.map(\.clientEventId))
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
        while batch.count > 1 &&
            encodedSize(IdentityMutationBatchRequest(schemaVersion: 1, mutations: batch)) > 65_536 {
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
               status != 429 {
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
                if response.statusCode == 404, let fallbackURL { throw WtsSDKError.noMatch(fallbackURL: fallbackURL) }
                throw WtsSDKError.server(statusCode: response.statusCode, fallbackURL: fallbackURL)
            }
            do { return try decoder.decode(Response.self, from: data) }
            catch { throw WtsSDKError.invalidResponse(fallbackURL: fallbackURL) }
        } catch let error as WtsSDKError { throw error }
        catch let error as URLError where error.code == .timedOut { throw WtsSDKError.timeout(fallbackURL: fallbackURL) }
        catch { throw WtsSDKError.network(fallbackURL: fallbackURL) }
    }

    private func unwrap(_ url: URL) throws -> URL {
        if url.scheme == "http" || url.scheme == "https" { return url }
        guard url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let wrapped = URL(string: raw),
              wrapped.scheme == "https" else { throw WtsSDKError.invalidURL(fallbackURL: nil) }
        return wrapped
    }

    private func validate(eventKey: String, properties: [String: WtsValue], revenue: WtsRevenue?) throws {
        guard eventKey.range(of: "^[a-z][a-z0-9_]{1,63}$", options: .regularExpression) != nil else {
            throw WtsSDKError.invalidEvent(reason: "eventKey must use lowercase snake_case.")
        }
        guard properties.count <= 20 else { throw WtsSDKError.invalidEvent(reason: "Events support at most 20 properties.") }
        for value in properties.values {
            if case .string(let string) = value, string.count > 512 {
                throw WtsSDKError.invalidEvent(reason: "String event properties cannot exceed 512 characters.")
            }
        }
        if let revenue {
            guard revenue.amount.range(of: "^-?\\d{1,12}(?:\\.\\d{1,6})?$", options: .regularExpression) != nil,
                  revenue.currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
                throw WtsSDKError.invalidEvent(reason: "Revenue requires a decimal amount and ISO-4217 currency.")
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
        guard encodedSize(
            IdentityMutationBatchRequest(schemaVersion: 1, mutations: [mutation])
        ) <= 65_536 else {
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
                    throw WtsSDKError.invalidProfile(reason: "String attributes cannot exceed 2048 characters.")
                }
            case .date(let item):
                guard ISO8601DateFormatter().date(from: item) != nil else {
                    throw WtsSDKError.invalidProfile(reason: "Date attributes must use ISO-8601.")
                }
            case .stringArray(let items):
                guard items.count <= 50, items.allSatisfy({ $0.count <= 512 }) else {
                    throw WtsSDKError.invalidProfile(reason: "String-array attributes support 50 values of at most 512 characters.")
                }
            case .number, .boolean:
                break
            }
        }
    }

    private func validate(update: WtsUserUpdate) throws {
        let keys = Array(update.set.keys) + Array(update.setOnce.keys) +
            update.unset + Array(update.increment.keys)
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
        guard key.range(
            of: "^[a-z][a-z0-9_]{0,63}$",
            options: .regularExpression
        ) != nil else {
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

private struct RetryableBatchRejection: Error {}
