import Foundation
import Testing
@testable import AidrobeKit

final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, String)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let (status, body) = try await handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SessionEvent] = []
    var events: [SessionEvent] { lock.withLock { _events } }
    func record(_ event: SessionEvent) { lock.withLock { _events.append(event) } }
}

/// Deterministic ordering for account switches while a response is in flight.
private actor ResponseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

struct Item: Decodable, Sendable, Equatable {
    var itemId: String
    enum CodingKeys: String, CodingKey { case itemId = "item_id" }
}

private let env = AppEnvironment(stage: .development, apiBaseURL: URL(string: "http://api.test")!, devUserID: "dev-1")

private func makeClient(
    tokens: TokenPair? = nil,
    stage: AppEnvironment.Stage = .development,
    events: EventRecorder = EventRecorder(),
    handler: @escaping StubTransport.Handler
) -> (APIClient, StubTransport, TokenStore) {
    let store = TokenStore(store: InMemorySecureStore())
    if let tokens { store.save(tokens) }
    let transport = StubTransport(handler)
    var environment = env
    environment.stage = stage
    let client = APIClient(environment: environment, tokens: store, transport: transport) { events.record($0) }
    return (client, transport, store)
}

@Suite struct EnvelopeTests {
    @Test func unwrapsEnvelopeData() async throws {
        let (client, _, _) = makeClient { _ in (200, #"{"code":0,"message":"ok","data":{"item_id":"a"}}"#) }
        let item = try await client.send(Endpoint<Item>(.get, "/v1/x"))
        #expect(item == Item(itemId: "a"))
    }

    @Test func passesPlainBodyThrough() async throws {
        let (client, _, _) = makeClient { _ in (201, #"{"item_id":"plain"}"#) }
        let item = try await client.send(Endpoint<Item>(.post, "/v1/purchase-candidates"))
        #expect(item == Item(itemId: "plain"))
    }

    @Test func nonZeroEnvelopeCodeIsBusinessError() async {
        let (client, _, _) = makeClient { _ in (200, #"{"code":4091,"message":"conflict","data":null}"#) }
        await #expect(throws: APIError.business(code: 4091, message: "conflict")) {
            try await client.send(Endpoint<Item>(.get, "/v1/x"))
        }
    }

    @Test func httpErrorCarriesReason() async {
        let (client, _, _) = makeClient { _ in
            (409, #"{"code":4091,"message":"not ready","data":{"reason":"avatar_not_ready"}}"#)
        }
        do {
            _ = try await client.send(Endpoint<Item>(.post, "/v1/wardrobe-decisions/1/visual-preview"))
            Issue.record("expected error")
        } catch let error as APIError {
            #expect(error.status == 409)
            #expect(error.reason == "avatar_not_ready")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func emptyResponseIgnoresPayload() async throws {
        let (client, _, _) = makeClient { _ in (200, #"{"code":0,"message":"ok","data":null}"#) }
        let value = try await client.send(Endpoint<EmptyResponse>(.delete, "/v1/x"))
        #expect(value == EmptyResponse())
    }
}

@Suite struct AuthHeaderTests {
    @Test func devUserHeaderWithoutToken() async throws {
        let (client, transport, _) = makeClient { _ in (200, #"{"code":0,"message":"","data":null}"#) }
        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/v1/x"))
        #expect(transport.requests.first?.value(forHTTPHeaderField: "X-User-Id") == "dev-1")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func noDevHeaderInProduction() async throws {
        let (client, transport, _) = makeClient(stage: .production) { _ in (200, #"{"code":0,"message":"","data":null}"#) }
        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/v1/x"))
        #expect(transport.requests.first?.value(forHTTPHeaderField: "X-User-Id") == nil)
    }

    @Test func bearerAndCorrelationHeaders() async throws {
        let (client, transport, _) = makeClient(tokens: TokenPair(accessToken: "A", refreshToken: "R")) { _ in
            (200, #"{"code":0,"message":"","data":null}"#)
        }
        await client.setCorrelationID("flow-1")
        _ = try await client.send(Endpoint<EmptyResponse>(.get, "/v1/x"))
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer A")
        #expect(request.value(forHTTPHeaderField: "X-Correlation-Id") == "flow-1")
        #expect(request.value(forHTTPHeaderField: "X-User-Id") == nil)
    }
}

@Suite struct RefreshTests {
    private static let tokensBody = #"{"code":0,"message":"ok","data":{"user_id":"u","access_token":"A2","refresh_token":"R2","token_type":"bearer","expires_in":3600}}"#

    @Test func refreshesOnceAndReplays() async throws {
        let (client, transport, store) = makeClient(tokens: TokenPair(accessToken: "A1", refreshToken: "R1")) { request in
            if request.url?.path() == "/v1/auth/refresh" { return (200, Self.tokensBody) }
            let auth = request.value(forHTTPHeaderField: "Authorization")
            return auth == "Bearer A2"
                ? (200, #"{"code":0,"message":"","data":{"item_id":"ok"}}"#)
                : (401, #"{"code":4001,"message":"Token expired","data":null}"#)
        }
        let item = try await client.send(Endpoint<Item>(.get, "/v1/x"))
        #expect(item.itemId == "ok")
        #expect(store.tokens == TokenPair(accessToken: "A2", refreshToken: "R2"))
        #expect(transport.requests.map { $0.url!.path() } == ["/v1/x", "/v1/auth/refresh", "/v1/x"])
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let (client, transport, _) = makeClient(tokens: TokenPair(accessToken: "A1", refreshToken: "R1")) { request in
            if request.url?.path() == "/v1/auth/refresh" {
                try await Task.sleep(for: .milliseconds(50))
                return (200, Self.tokensBody)
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer A2"
                ? (200, #"{"code":0,"message":"","data":{"item_id":"ok"}}"#)
                : (401, #"{"code":4001,"message":"expired","data":null}"#)
        }
        async let first = client.send(Endpoint<Item>(.get, "/v1/a"))
        async let second = client.send(Endpoint<Item>(.get, "/v1/b"))
        _ = try await (first, second)
        #expect(transport.requests.filter { $0.url!.path() == "/v1/auth/refresh" }.count == 1)
    }

    @Test func failedRefreshExpiresSession() async {
        let events = EventRecorder()
        let (client, _, store) = makeClient(tokens: TokenPair(accessToken: "A1", refreshToken: "R1"), events: events) { _ in
            (401, #"{"code":4001,"message":"expired","data":null}"#)
        }
        await #expect(throws: APIError.unauthorized(deactivated: false)) {
            try await client.send(Endpoint<Item>(.get, "/v1/x"))
        }
        #expect(store.tokens == nil)
        #expect(events.events == [.expired])
    }

    @Test func deactivatedAccountSkipsRefresh() async {
        let events = EventRecorder()
        let (client, transport, store) = makeClient(tokens: TokenPair(accessToken: "A1", refreshToken: "R1"), events: events) { _ in
            (401, #"{"code":4001,"message":"Account deactivated","data":null}"#)
        }
        await #expect(throws: APIError.unauthorized(deactivated: true)) {
            try await client.send(Endpoint<Item>(.get, "/v1/x"))
        }
        #expect(transport.requests.count == 1)
        #expect(store.tokens == nil)
        #expect(events.events == [.deactivated])
    }

    @Test func authEndpointsNeverRefresh() async {
        let (client, transport, _) = makeClient(tokens: TokenPair(accessToken: "A1", refreshToken: "R1")) { _ in
            (401, #"{"code":4001,"message":"bad id token","data":null}"#)
        }
        await #expect(throws: APIError.unauthorized(deactivated: false)) {
            try await client.send(Endpoint<Item>(.post, "/v1/auth/login/apple"))
        }
        #expect(transport.requests.count == 1)
    }

    @Test func devSessionDoesNotRefresh() async {
        let (client, transport, _) = makeClient { _ in (401, #"{"code":4001,"message":"no","data":null}"#) }
        await #expect(throws: APIError.unauthorized(deactivated: false)) {
            try await client.send(Endpoint<Item>(.get, "/v1/x"))
        }
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func oldUnauthorizedResponseCannotExpireNewAccount(deactivated: Bool) async throws {
        let arrived = ResponseGate()
        let release = ResponseGate()
        let events = EventRecorder()
        let (client, transport, store) = makeClient(
            tokens: TokenPair(accessToken: "A1", refreshToken: "R1"), events: events
        ) { _ in
            await arrived.open()
            await release.wait()
            return (401, deactivated
                ? #"{"code":4001,"message":"Account deactivated","data":null}"#
                : #"{"code":4001,"message":"Token expired","data":null}"#)
        }
        let pending = Task { try await client.send(Endpoint<Item>(.get, "/v1/old-account")) }
        await arrived.wait()
        store.clear()
        let next = TokenPair(accessToken: "B1", refreshToken: "BR1")
        store.save(next)
        await release.open()

        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(store.tokens == next)
        #expect(events.events.isEmpty)
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func oldRefreshCannotOverwriteOrExpireNewAccount(succeeds: Bool) async throws {
        let arrived = ResponseGate()
        let release = ResponseGate()
        let events = EventRecorder()
        let (client, transport, store) = makeClient(
            tokens: TokenPair(accessToken: "A1", refreshToken: "R1"), events: events
        ) { request in
            if request.url?.path() == "/v1/auth/refresh" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                if body?["refresh_token"] as? String == "BR1" {
                    return (200, #"{"user_id":"b","access_token":"B2","refresh_token":"BR2","token_type":"bearer","expires_in":3600}"#)
                }
                await arrived.open()
                await release.wait()
                return succeeds ? (200, Self.tokensBody) : (401, #"{"message":"expired"}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer B2" {
                return (200, #"{"item_id":"new-account"}"#)
            }
            return (401, #"{"message":"expired"}"#)
        }
        let pending = Task { try await client.send(Endpoint<Item>(.get, "/v1/old-account")) }
        await arrived.wait()
        store.clear()
        let next = TokenPair(accessToken: "B1", refreshToken: "BR1")
        store.save(next)
        // A broken cross-account single-flight should fail rather than hang
        // waiting forever on the old account's deliberately held response.
        let fallbackRelease = Task {
            try? await Task.sleep(for: .milliseconds(100))
            await release.open()
        }
        defer { fallbackRelease.cancel() }
        let current = try await client.send(Endpoint<Item>(.get, "/v1/new-account"))
        await release.open()
        fallbackRelease.cancel()
        await fallbackRelease.value

        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(current.itemId == "new-account")
        #expect(store.tokens == TokenPair(accessToken: "B2", refreshToken: "BR2"))
        #expect(events.events.isEmpty)
        #expect(transport.requests.map { $0.url!.path() } == [
            "/v1/old-account", "/v1/auth/refresh", "/v1/new-account", "/v1/auth/refresh", "/v1/new-account",
        ])
    }

    @Test func oldSuccessIsDiscardedAfterLogout() async throws {
        let arrived = ResponseGate()
        let release = ResponseGate()
        let (client, _, store) = makeClient(tokens: TokenPair(accessToken: "A1", refreshToken: "R1")) { _ in
            await arrived.open()
            await release.wait()
            return (200, #"{"item_id":"private-old-account-data"}"#)
        }
        let pending = Task { try await client.send(Endpoint<Item>(.get, "/v1/wardrobe")) }
        await arrived.wait()
        store.clear()
        await release.open()

        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(store.tokens == nil)
    }

    @Test func late401ReusesAlreadyRefreshedTokensWithinTheSameSession() async throws {
        let arrived = ResponseGate()
        let release = ResponseGate()
        let (client, transport, _) = makeClient(tokens: TokenPair(accessToken: "A1", refreshToken: "R1")) { request in
            if request.url?.path() == "/v1/auth/refresh" { return (200, Self.tokensBody) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer A2" {
                return (200, #"{"item_id":"ok"}"#)
            }
            if request.url?.path() == "/v1/slow" {
                await arrived.open()
                await release.wait()
            }
            return (401, #"{"message":"expired"}"#)
        }
        let delayed = Task { try await client.send(Endpoint<Item>(.get, "/v1/slow")) }
        await arrived.wait()
        _ = try await client.send(Endpoint<Item>(.get, "/v1/fast"))
        await release.open()
        let result = try await delayed.value

        #expect(result.itemId == "ok")
        #expect(transport.requests.filter { $0.url?.path() == "/v1/auth/refresh" }.count == 1)
    }

    @Test func oldTokenSnapshotCannotChangeAReplacementLoginEvenWithIdenticalTokens() {
        let store = TokenStore(store: InMemorySecureStore())
        let original = TokenPair(accessToken: "A1", refreshToken: "R1")
        store.save(original)
        let oldSession = store.snapshot
        store.clear()
        store.save(original)

        #expect(store.rotate(TokenPair(accessToken: "A2", refreshToken: "R2"), ifCurrent: oldSession) == nil)
        #expect(!store.clear(ifCurrent: oldSession))
        #expect(store.tokens == original)
        #expect(store.generation != oldSession.generation)
    }
}

@Suite struct WireDecodingTests {
    @Test func decodesGeneratedModelThroughEnvelope() async throws {
        let body = #"{"code":0,"message":"ok","data":{"user_id":"u","access_token":"A","refresh_token":"R","token_type":"bearer","expires_in":60}}"#
        let (client, _, _) = makeClient { _ in (200, body) }
        let tokens = try await client.send(Endpoint<AuthTokens>(.post, "/v1/auth/login/apple"))
        #expect(tokens.accessToken == "A")
        #expect(tokens.expiresIn == 60)
    }

    @Test(arguments: [
        "2026-11-13T10:00:00Z",
        "2026-11-13T10:00:00.123Z",
        "2026-11-13T10:00:00.123456+00:00",
        "2026-11-13T18:00:00+08:00",
    ])
    func parsesBackendDates(raw: String) throws {
        let date = try #require(JSONCoding.parseDate(raw))
        #expect(abs(date.timeIntervalSince1970 - 1_794_564_000) < 1)
    }
}
