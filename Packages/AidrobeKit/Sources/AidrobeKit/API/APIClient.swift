import Foundation

/// Sends a request and returns the raw response. URLSession in the app, a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Session-level outcomes the UI must react to (both return the user to Welcome).
public enum SessionEvent: Sendable, Equatable {
    case expired
    case deactivated
}

/// The single entry point to the Aidrobe backend.
///
/// - Unwraps the `{code, message, data}` envelope; passes plain bodies through.
/// - Sends `Authorization: Bearer` when signed in; otherwise, outside production,
///   `X-User-Id` with the dev user id.
/// - On 401 (non-auth endpoints, token sessions only) runs one shared refresh and
///   replays the request once.
public actor APIClient {
    private let environment: AppEnvironment
    private let tokens: TokenStore
    private let transport: any HTTPTransport
    private let onSessionEvent: @Sendable (SessionEvent) -> Void
    private var refreshTask: Task<TokenPair, any Error>?

    /// `X-Correlation-Id` for the active V3 decision flow, if any.
    public var correlationID: String?

    public init(
        environment: AppEnvironment,
        tokens: TokenStore,
        transport: any HTTPTransport = URLSessionTransport(),
        onSessionEvent: @escaping @Sendable (SessionEvent) -> Void = { _ in }
    ) {
        self.environment = environment
        self.tokens = tokens
        self.transport = transport
        self.onSessionEvent = onSessionEvent
    }

    public func setCorrelationID(_ id: String?) {
        correlationID = id
    }

    public func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        let session = tokens.tokens
        let (data, response) = try await perform(endpoint, accessToken: session?.accessToken)

        if response.statusCode == 401 {
            let message = Self.errorFields(in: data).message ?? ""
            if message.localizedCaseInsensitiveContains("deactivated") {
                tokens.clear()
                onSessionEvent(.deactivated)
                throw APIError.unauthorized(deactivated: true)
            }
            guard !endpoint.isAuthEndpoint, let session else {
                if session != nil { expireSession() }
                throw APIError.unauthorized(deactivated: false)
            }
            let refreshed: TokenPair
            do {
                refreshed = try await refreshTokens(from: session)
            } catch {
                expireSession()
                throw APIError.unauthorized(deactivated: false)
            }
            let (retryData, retryResponse) = try await perform(endpoint, accessToken: refreshed.accessToken)
            if retryResponse.statusCode == 401 {
                expireSession()
                throw APIError.unauthorized(deactivated: false)
            }
            return try Self.decode(Response.self, data: retryData, response: retryResponse)
        }
        return try Self.decode(Response.self, data: data, response: response)
    }

    // MARK: - Request

    private func perform<Response>(
        _ endpoint: Endpoint<Response>,
        accessToken: String?
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(
            url: environment.apiBaseURL.appending(path: endpoint.path),
            resolvingAgainstBaseURL: false
        )
        if !endpoint.query.isEmpty { components?.queryItems = endpoint.query }
        guard let url = components?.url else { throw APIError.decoding("invalid URL for \(endpoint.path)") }

        var request = URLRequest(url: url, timeoutInterval: endpoint.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        } else if environment.allowsDevLogin, let devUserID = environment.devUserID {
            request.setValue(devUserID, forHTTPHeaderField: "X-User-Id")
        }
        if let correlationID {
            request.setValue(correlationID, forHTTPHeaderField: "X-Correlation-Id")
        }

        do {
            return try await transport.send(request)
        } catch let error as URLError {
            throw APIError.network(error.code)
        }
    }

    // MARK: - Refresh

    private func refreshTokens(from session: TokenPair) async throws -> TokenPair {
        if let refreshTask { return try await refreshTask.value }
        guard let refreshToken = session.refreshToken else { throw APIError.unauthorized(deactivated: false) }

        let task = Task<TokenPair, any Error> {
            let endpoint = try Endpoint<AuthTokens>(.post, "/v1/auth/refresh", json: Wire.RefreshTokenRequest(refreshToken: refreshToken))
            let (data, response) = try await perform(endpoint, accessToken: nil)
            let tokens = try Self.decode(AuthTokens.self, data: data, response: response)
            return TokenPair(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        let pair = try await task.value
        tokens.save(pair)
        return pair
    }

    private func expireSession() {
        tokens.clear()
        onSessionEvent(.expired)
    }

    // MARK: - Decoding

    static func decode<Response: Decodable>(
        _ type: Response.Type,
        data: Data,
        response: HTTPURLResponse
    ) throws -> Response {
        guard (200..<300).contains(response.statusCode) else {
            let fields = errorFields(in: data)
            throw APIError.http(
                status: response.statusCode,
                code: fields.code,
                message: fields.message,
                reason: fields.reason
            )
        }

        var payload = data
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = object["code"] as? Int, object.keys.contains("data") {
            guard code == 0 || code == 200 else {
                throw APIError.business(code: code, message: object["message"] as? String ?? "")
            }
            let inner = object["data"] ?? NSNull()
            payload = (inner is NSNull)
                ? Data("null".utf8)
                : try JSONSerialization.data(withJSONObject: inner, options: [.fragmentsAllowed])
        }

        if Response.self == EmptyResponse.self, let empty = EmptyResponse() as? Response {
            return empty
        }
        do {
            return try JSONCoding.decoder.decode(Response.self, from: payload)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    static func errorFields(in data: Data) -> (code: Int?, message: String?, reason: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let message = (object["message"] as? String) ?? (object["detail"] as? String)
        let reason = (object["data"] as? [String: Any])?["reason"] as? String
        return (object["code"] as? Int, message, reason)
    }
}

/// `AuthTokenResponse` from `/v1/auth/*`.
public typealias AuthTokens = Wire.AuthTokenResponse
