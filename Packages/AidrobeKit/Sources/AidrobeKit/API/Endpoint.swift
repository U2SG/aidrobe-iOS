import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
}

/// A typed request description. `Response` is the decoded payload: the envelope's
/// `data` for wrapped endpoints, or the whole body for plain (V3) endpoints.
public struct Endpoint<Response: Decodable & Sendable>: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var timeout: TimeInterval

    public init(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval = Endpoint.defaultTimeout
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.timeout = timeout
    }

    /// JSON-encodes `payload` with snake_case keys.
    public init(
        _ method: HTTPMethod,
        _ path: String,
        json payload: some Encodable,
        query: [URLQueryItem] = [],
        timeout: TimeInterval = Endpoint.defaultTimeout
    ) throws {
        self.init(method, path, query: query, body: try JSONCoding.encoder.encode(payload), timeout: timeout)
    }

    public static var defaultTimeout: TimeInterval { 15 }
    /// Today / refresh / first-outfit run recommendation generation inline.
    public static var slowTimeout: TimeInterval { 60 }

    /// Auth endpoints never trigger a token refresh (prevents refresh loops).
    var isAuthEndpoint: Bool { path.hasPrefix("/v1/auth/") }
}

/// For endpoints whose payload the caller ignores.
public struct EmptyResponse: Decodable, Sendable, Equatable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}

public enum JSONCoding {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
