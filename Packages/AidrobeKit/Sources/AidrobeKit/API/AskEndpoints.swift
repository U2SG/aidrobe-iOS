import Foundation

/// Ask and saved outfit revisions use plain (unwrapped) responses.
extension Endpoints {
    /// The answer is generated inline by the LLM, so it gets the slow timeout.
    /// Pass the previous answer's `conversationID` to continue the same thread.
    public static func ask(
        _ question: String,
        conversationID: String? = nil,
        requestID: String? = nil,
        expectedRevision: Int? = nil,
        baseOutfitID: String? = nil,
        inspirationID: String? = nil,
        inspirationOnly: Bool = false
    ) throws -> Endpoint<Wire.AskResponse> {
        var body = Wire.AskRequest(question: question)
        body.locale = "zh-CN"
        body.conversationId = conversationID
        body.designMode = requestID != nil
        body.requestId = requestID
        body.expectedRevision = expectedRevision
        body.baseOutfitId = baseOutfitID
        body.inspirationId = inspirationID
        if inspirationOnly { body.inspirationOnly = true }
        return try Endpoint(
            .post,
            "/v1/ask",
            json: body,
            timeout: Endpoint<Wire.AskResponse>.slowTimeout
        )
    }

    /// Newest first.
    public static func askHistory(limit: Int = 20) -> Endpoint<[Wire.AskHistoryItem]> {
        Endpoint(.get, "/v1/ask/history", query: [URLQueryItem(name: "limit", value: "\(limit)")])
    }

    public static func askConversation(_ conversationID: String) -> Endpoint<Wire.AskConversationResponse> {
        Endpoint(.get, "/v1/ask/conversations/\(conversationID)")
    }

    public static func reviseStylingConstraints(
        conversationID: String,
        revision: Int,
        lockedItemIDs: [String]? = nil,
        excludedItemIDs: [String]? = nil,
        requestID: String
    ) throws -> Endpoint<Wire.StylingResponse> {
        var body = Wire.CreateOutfitRevisionRequest(requestId: requestID, expectedRevision: revision)
        body.lockedItemIds = lockedItemIDs
        body.excludedItemIds = excludedItemIDs
        return try Endpoint(.post, "/v1/ask/conversations/\(conversationID)/outfit-revisions", json: body)
    }

    public static func adoptStyling(
        conversationID: String, revision: Int, requestID: String, date: String? = nil
    ) throws -> Endpoint<Wire.StylingResponse> {
        try Endpoint(
            .post,
            "/v1/ask/conversations/\(conversationID)/adopt",
            json: Wire.AdoptStylingRequest(requestId: requestID, expectedRevision: revision, date: date)
        )
    }

    public static func askFeedback(sessionID: String, type: FeedbackKind) throws -> Endpoint<EmptyResponse> {
        try Endpoint(
            .post,
            "/v1/ask/\(sessionID)/feedback",
            json: Wire.FeedbackRequest(feedbackType: type.rawValue)
        )
    }
}
