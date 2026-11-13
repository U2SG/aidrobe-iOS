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
    /// Generated wire models carry explicit snake_case `CodingKeys`, so no key
    /// conversion. Dates accept ISO 8601 with or without fractional seconds
    /// (Python emits microseconds).
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(raw)")
        }
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func parseDate(_ raw: String) -> Date? {
        var value = raw
        // Trim sub-millisecond digits ("…:00.123456+00:00" → "…:00.123+00:00").
        if let dot = value.firstIndex(of: ".") {
            let digitsEnd = value[value.index(after: dot)...].firstIndex { !$0.isNumber } ?? value.endIndex
            let digits = value[value.index(after: dot)..<digitsEnd]
            if digits.count > 3 {
                value.replaceSubrange(value.index(dot, offsetBy: 4)..<digitsEnd, with: "")
            }
        }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        return (try? withFraction.parse(value)) ?? (try? plain.parse(value))
    }
}

/// Generated wire models (from contracts/openapi.json).
public typealias Wire = Components.Schemas
