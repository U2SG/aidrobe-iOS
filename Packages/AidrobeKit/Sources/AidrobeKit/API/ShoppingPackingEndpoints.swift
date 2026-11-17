import Foundation

/// V3 purchase decision (contract §5) and packing lists. Every body here is
/// plain (not enveloped); a 503 means the backend flag is off.
extension Endpoints {
    // MARK: Should I buy

    /// `objectKey` is the presign `object_key` of an uploaded screenshot or photo.
    public static func createPurchaseCandidate(
        objectKey: String, requestID: String? = nil
    ) throws -> Endpoint<Wire.PurchaseCandidateResponse> {
        try Endpoint(
            .post,
            "/v1/purchase-candidates",
            json: Wire.CreatePurchaseCandidateRequest(
                sourceType: .screenshot, sourceAssetId: objectKey, requestId: requestID
            )
        )
    }

    public static func purchaseCandidate(_ candidateID: String) -> Endpoint<Wire.PurchaseCandidateResponse> {
        Endpoint(.get, "/v1/purchase-candidates/\(candidateID)")
    }

    /// Contextual evaluations bind all three identifiers. A retry reuses the
    /// exact request ID and body; a changed brief is a separate evaluation.
    public static func decide(
        candidateID: String,
        concern: Wire.DecisionRequest.ConcernPayload = .none,
        conversationID: String? = nil,
        expectedRevision: Int? = nil,
        requestID: String? = nil
    ) throws -> Endpoint<Wire.WardrobeDecisionResponse> {
        try Endpoint(
            .post,
            "/v1/purchase-candidates/\(candidateID)/decision",
            json: Wire.DecisionRequest(
                concern: concern, conversationId: conversationID,
                expectedRevision: expectedRevision, requestId: requestID
            ),
            timeout: Endpoint<Wire.WardrobeDecisionResponse>.slowTimeout
        )
    }

    /// Replays a decision from its snapshot; the wording never changes.
    public static func wardrobeDecision(_ decisionID: String) -> Endpoint<Wire.WardrobeDecisionResponse> {
        Endpoint(.get, "/v1/wardrobe-decisions/\(decisionID)")
    }

    public static func setPurchaseChoice(
        _ choice: Wire.PurchaseChoiceRequest.ChoicePayload?, decisionID: String
    ) throws -> Endpoint<Wire.WardrobeDecisionResponse> {
        let path = "/v1/wardrobe-decisions/\(decisionID)/choice"
        // The generator normalizer makes nullable fields optional. Clearing
        // this required nullable field must still send an explicit JSON null.
        guard let choice else {
            return Endpoint(.put, path, body: Data(#"{"choice":null}"#.utf8))
        }
        return try Endpoint(.put, path, json: Wire.PurchaseChoiceRequest(choice: choice))
    }

    // MARK: Packing

    public static func packingLists() -> Endpoint<[Wire.PackingListResponse]> {
        Endpoint(.get, "/v1/packing-lists")
    }

    /// Generates the list inline from the wardrobe, so it can be slow.
    public static func createPackingList(_ request: Wire.CreatePackingListRequest) throws -> Endpoint<Wire.PackingListResponse> {
        try Endpoint(
            .post, "/v1/packing-lists", json: request, timeout: Endpoint<Wire.PackingListResponse>.slowTimeout
        )
    }

    public static func packingList(_ listID: String) -> Endpoint<Wire.PackingListResponse> {
        Endpoint(.get, "/v1/packing-lists/\(listID)")
    }

    /// `items` replaces the whole list (that is how a piece is ticked as packed).
    public static func updatePackingList(
        _ listID: String,
        items: [Wire.PackingItem]
    ) throws -> Endpoint<Wire.PackingListResponse> {
        try Endpoint(.patch, "/v1/packing-lists/\(listID)", json: Wire.UpdatePackingListRequest(items: items))
    }
}
