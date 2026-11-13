import Foundation

/// Every failure the API facade can surface. The backend uses two channels:
/// HTTP 2xx with a non-zero envelope `code`, and HTTP 4xx/5xx with an error
/// envelope whose `data.reason` refines V3 refusals (e.g. 409 `avatar_not_ready`).
public enum APIError: Error, Sendable, Equatable {
    /// HTTP 2xx but envelope `code` is not 0/200.
    case business(code: Int, message: String)
    /// HTTP status >= 400 (other than an unrecoverable 401).
    case http(status: Int, code: Int?, message: String?, reason: String?)
    /// 401 that refresh could not recover. `deactivated` mirrors the backend's
    /// "Account deactivated" message.
    case unauthorized(deactivated: Bool)
    case network(URLError.Code)
    case decoding(String)

    public var status: Int? {
        switch self {
        case let .http(status, _, _, _): status
        case .unauthorized: 401
        default: nil
        }
    }

    /// `data.reason` for V3 refusals; nil otherwise.
    public var reason: String? {
        if case let .http(_, _, _, reason) = self { return reason }
        return nil
    }

    /// 503 means the backend feature flag is off; optional surfaces hide silently.
    public var isFeatureDisabled: Bool { status == 503 }
}
