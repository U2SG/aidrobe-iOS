import Foundation

/// Typed endpoints used by the main line. Payload shapes come from `Wire.*`.
public enum Endpoints {
    // MARK: Today

    public static func today() -> Endpoint<Wire.TodayRecommendationResponse> {
        Endpoint(.get, "/v1/recommendations/today", timeout: Endpoint<Wire.TodayRecommendationResponse>.slowTimeout)
    }

    public static func markWorn(outfitID: String, wornDate: String? = nil) throws -> Endpoint<EmptyResponse> {
        try Endpoint(
            .post,
            "/v1/recommendations/outfits/\(outfitID)/wear",
            json: Wire.WearOutfitRequest(wornDate: wornDate)
        )
    }

    public static func feedback(
        outfitID: String,
        type: FeedbackKind,
        reasons: [FeedbackReason] = []
    ) throws -> Endpoint<EmptyResponse> {
        try Endpoint(
            .post,
            "/v1/recommendations/outfits/\(outfitID)/feedback",
            json: Wire.FeedbackRequest(feedbackType: type.rawValue, reasonTags: reasons.map(\.rawValue))
        )
    }

    // MARK: Wardrobe

    public static func wardrobeItems(limit: Int = 100, offset: Int = 0) -> Endpoint<Wire.WardrobeListResponse> {
        Endpoint(
            .get,
            "/v1/wardrobe-items",
            query: [URLQueryItem(name: "limit", value: "\(limit)"), URLQueryItem(name: "offset", value: "\(offset)")]
        )
    }
}

/// Backend `FeedbackType` (`^(love|like|neutral|dislike)$`).
public enum FeedbackKind: String, Sendable, CaseIterable {
    case love, like, neutral, dislike
}

/// Reason tags the backend understands. Contextual ones (`tooWarm`, `tooCold`)
/// describe the day; the rest feed durable preference learning.
public enum FeedbackReason: String, Sendable, CaseIterable, Identifiable {
    case tooWarm = "too_warm"
    case tooCold = "too_cold"
    case tooFormal = "too_formal"
    case tooCasual = "too_casual"
    case wrongFit = "wrong_fit"
    case notMyStyle = "not_my_style"

    public var id: String { rawValue }
}
