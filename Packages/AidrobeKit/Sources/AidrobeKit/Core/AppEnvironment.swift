import Foundation

/// Build-time configuration. Values come from the app's Info.plist, which the
/// xcconfig files fill per build configuration (Debug / Preview / Release).
public struct AppEnvironment: Sendable, Equatable {
    public enum Stage: String, Sendable {
        case development, staging, production
    }

    public var stage: Stage
    public var apiBaseURL: URL
    /// Only honoured outside production: requests without a token send it as `X-User-Id`.
    public var devUserID: String?
    public var flags: FeatureFlags

    public init(stage: Stage, apiBaseURL: URL, devUserID: String? = nil, flags: FeatureFlags = .init()) {
        self.stage = stage
        self.apiBaseURL = apiBaseURL
        self.devUserID = devUserID
        self.flags = flags
    }

    public var allowsDevLogin: Bool { stage != .production }

    /// Reads `AIDROBE_*` keys from an Info.plist dictionary.
    public init(infoDictionary info: [String: Any]) {
        func string(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func bool(_ key: String) -> Bool {
            guard let raw = string(key)?.lowercased() else { return false }
            return raw == "true" || raw == "yes" || raw == "1"
        }
        let stage = string("AIDROBE_APP_ENV").flatMap(Stage.init(rawValue:)) ?? .development
        let fallback = stage == .production ? "https://api.aidrobe.app" : "http://localhost:8000"
        self.init(
            stage: stage,
            apiBaseURL: URL(string: string("AIDROBE_API_BASE_URL") ?? fallback) ?? URL(string: fallback)!,
            devUserID: string("AIDROBE_DEV_USER_ID") ?? "00000000-0000-4000-8000-000000000001",
            flags: FeatureFlags(
                purchaseDecision: bool("AIDROBE_ENABLE_V3_PURCHASE_DECISION"),
                avatar: bool("AIDROBE_ENABLE_V3_AVATAR"),
                staticTryOn: bool("AIDROBE_ENABLE_V3_STATIC_TRYON"),
                analytics: bool("AIDROBE_ENABLE_V3_ANALYTICS")
            )
        )
    }

    public static var current: AppEnvironment {
        AppEnvironment(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }
}

/// Client-side twins of the backend `ENABLE_V3_*` flags. The backend answers 503
/// for a disabled surface; the client hides the entry instead of explaining it.
public struct FeatureFlags: Sendable, Equatable {
    public var purchaseDecision: Bool
    public var avatar: Bool
    public var staticTryOn: Bool
    public var analytics: Bool

    public init(purchaseDecision: Bool = false, avatar: Bool = false, staticTryOn: Bool = false, analytics: Bool = false) {
        self.purchaseDecision = purchaseDecision
        self.avatar = avatar
        self.staticTryOn = staticTryOn
        self.analytics = analytics
    }
}
