import Foundation

/// Ask: questions about the user's own wardrobe. All three bodies are plain (unwrapped).
extension Endpoints {
    /// The answer is generated inline by the LLM, so it gets the slow timeout.
    /// Pass the previous answer's `conversationID` to continue the same thread.
    public static func ask(_ question: String, conversationID: String? = nil) throws -> Endpoint<Wire.AskResponse> {
        try Endpoint(
            .post,
            "/v1/ask",
            json: Wire.AskRequest(question: question, locale: "zh-CN", conversationId: conversationID),
            timeout: Endpoint<Wire.AskResponse>.slowTimeout
        )
    }

    /// Newest first.
    public static func askHistory(limit: Int = 20) -> Endpoint<[Wire.AskHistoryItem]> {
        Endpoint(.get, "/v1/ask/history", query: [URLQueryItem(name: "limit", value: "\(limit)")])
    }

    public static func askFeedback(sessionID: String, type: FeedbackKind) throws -> Endpoint<EmptyResponse> {
        try Endpoint(
            .post,
            "/v1/ask/\(sessionID)/feedback",
            json: Wire.FeedbackRequest(feedbackType: type.rawValue)
        )
    }
}
