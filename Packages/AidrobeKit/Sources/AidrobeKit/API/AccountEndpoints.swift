import Foundation

extension Endpoints {
    // MARK: Sign in

    public static func loginWithApple(identityToken: String) throws -> Endpoint<AuthTokens> {
        try Endpoint(.post, "/v1/auth/login/apple", json: Wire.AppleLoginRequest(idToken: identityToken))
    }

    // MARK: First outfit

    /// Whether the wardrobe can already make one outfit, and what is missing if not.
    public static func firstOutfit() -> Endpoint<Wire.FirstOutfitGateResponse> {
        Endpoint(.get, "/v1/recommendations/first-outfit", timeout: Endpoint<Wire.FirstOutfitGateResponse>.slowTimeout)
    }

    // MARK: Learned memory

    public static func memory() -> Endpoint<Wire.MemoryListResponse> {
        Endpoint(.get, "/v1/profile/memory")
    }

    public static func forgetMemory(_ preferenceID: String) -> Endpoint<EmptyResponse> {
        Endpoint(.delete, "/v1/profile/memory/\(preferenceID)")
    }

    /// The preference stops counting and is not re-learned from the same evidence.
    public static func markMemoryWrong(_ preferenceID: String) -> Endpoint<EmptyResponse> {
        Endpoint(.post, "/v1/profile/memory/\(preferenceID)/mark-wrong")
    }

    public static func forgetAllMemory() -> Endpoint<EmptyResponse> {
        Endpoint(.delete, "/v1/profile/memory")
    }

    // MARK: Data and account

    public static func requestDataExport() -> Endpoint<Wire.DataExportResponse> {
        Endpoint(.post, "/v1/me/data-export")
    }

    /// `status`: queued | running | succeeded | failed | dead (`pending` right after the request).
    public static func dataExport(_ jobID: String) -> Endpoint<Wire.DataExportResponse> {
        Endpoint(.get, "/v1/me/data-export/\(jobID)")
    }

    /// Deletes garments, history and learned preferences; the account stays.
    public static func clearAllData() -> Endpoint<Wire.ClearDataResponse> {
        Endpoint(.delete, "/v1/profile/data")
    }

    /// Deactivates the account; the backend purges it after `grace_days`.
    public static func deactivateAccount() -> Endpoint<Wire.DeactivateResponse> {
        Endpoint(.delete, "/v1/me")
    }
}
