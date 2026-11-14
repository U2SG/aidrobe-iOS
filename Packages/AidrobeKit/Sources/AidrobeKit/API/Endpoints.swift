import Foundation

/// Typed endpoints used by the main line. Payload shapes come from `Wire.*`.
public enum Endpoints {
    // MARK: Today

    public static func today() -> Endpoint<Wire.TodayRecommendationResponse> {
        Endpoint(.get, "/v1/recommendations/today", timeout: Endpoint<Wire.TodayRecommendationResponse>.slowTimeout)
    }

    public static func generateOutfitImage(_ outfitID: String) -> Endpoint<Wire.OutfitVisualAssetResponse> {
        Endpoint(.post, "/v1/outfits/\(outfitID)/share-asset", query: [
            URLQueryItem(name: "generate", value: "true"),
        ])
    }

    public static func generatedOutfitImage(_ outfitID: String) -> Endpoint<Wire.OutfitVisualAssetResponse> {
        Endpoint(.get, "/v1/outfits/\(outfitID)/share-asset")
    }

    public static func outfitVisual(_ assetID: String) -> Endpoint<Wire.OutfitVisualAssetResponse> {
        Endpoint(.get, "/v1/outfit-visual-assets/\(assetID)")
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
        reasonTags: [String] = []
    ) throws -> Endpoint<EmptyResponse> {
        try Endpoint(
            .post,
            "/v1/recommendations/outfits/\(outfitID)/feedback",
            json: Wire.FeedbackRequest(feedbackType: type.rawValue, reasonTags: reasonTags)
        )
    }

    public static func refreshToday(chipID: String? = nil) throws -> Endpoint<Wire.TodayRecommendationResponse> {
        let override = chipID.map { Wire.ContextOverrideRequest(source: "chip", chipId: $0) }
        return try Endpoint(
            .post,
            "/v1/recommendations/today/refresh",
            json: Wire.RefreshTodayRequest(contextOverride: override),
            timeout: Endpoint<Wire.TodayRecommendationResponse>.slowTimeout
        )
    }

    public static func replacements(outfitID: String, itemID: String) -> Endpoint<Wire.ReplacementCandidatesResponse> {
        Endpoint(.get, "/v1/recommendations/outfits/\(outfitID)/items/\(itemID)/replacements")
    }

    public static func setFavorite(_ favorite: Bool, outfitID: String) -> Endpoint<EmptyResponse> {
        Endpoint(favorite ? .post : .delete, "/v1/recommendations/outfits/\(outfitID)/favorite")
    }

    public static func feedbackTags() -> Endpoint<Wire.FeedbackTagsResponse> {
        Endpoint(.get, "/v1/recommendations/feedback-tags")
    }

    /// Plain (unwrapped) body. Newest first.
    public static func outfitHistory(page: Int = 1, pageSize: Int = 30) -> Endpoint<Wire.OutfitHistoryListResponse> {
        Endpoint(
            .get,
            "/v1/outfit-history",
            query: [URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "page_size", value: "\(pageSize)")]
        )
    }

    // MARK: Wardrobe

    public static func updateItem(
        _ itemID: String,
        _ changes: Wire.UpdateWardrobeItemRequest
    ) throws -> Endpoint<Wire.WardrobeItemResponse> {
        try Endpoint(.patch, "/v1/wardrobe-items/\(itemID)", json: changes)
    }

    public static func updateFit(_ itemID: String, status: Wire.FitStatus) throws -> Endpoint<Wire.WardrobeItemResponse> {
        try Endpoint(.patch, "/v1/wardrobe-items/\(itemID)/fit", json: Wire.UpdateFitRequest(fitStatus: status))
    }

    public static func markItemWorn(_ itemID: String) throws -> Endpoint<Wire.WardrobeItemResponse> {
        try Endpoint(.post, "/v1/wardrobe-items/\(itemID)/wears", json: Wire.MarkItemWornRequest())
    }

    public static func deleteItem(_ itemID: String) -> Endpoint<EmptyResponse> {
        Endpoint(.delete, "/v1/wardrobe-items/\(itemID)")
    }

    // MARK: Settings

    public static func settings() -> Endpoint<Wire.UserSettingsResponse> {
        Endpoint(.get, "/v1/user/settings")
    }

    public static func updateSettings(_ changes: Wire.UpdateUserSettingsRequest) throws -> Endpoint<Wire.UserSettingsResponse> {
        try Endpoint(.patch, "/v1/user/settings", json: changes)
    }

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
