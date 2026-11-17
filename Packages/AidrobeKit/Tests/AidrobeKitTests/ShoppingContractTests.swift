import Foundation
import Testing
@testable import AidrobeKit

private enum ShoppingFixture {
    static let conversation = "10000000-0000-0000-0000-000000000001"
    static let candidate = "20000000-0000-0000-0000-000000000001"
    static let decision = "30000000-0000-0000-0000-000000000001"
    static let request = "40000000-0000-0000-0000-000000000001"
    static let nextRequest = "40000000-0000-0000-0000-000000000002"
    static let item = "50000000-0000-0000-0000-000000000001"
    static let objectKey = "purchase-candidates/example-shirt.jpg"

    static var constraints: String {
        """
        {"goal":"周末出去玩","target_style":"vivid","scene":"casual","exploration":true,
         "locked_item_ids":["\(item)"],"excluded_item_ids":[],"notes":["只想试试鲜艳一点"],
         "target_date":"2026-11-21"}
        """
    }

    static func result(revision: Int? = 3, choice: String? = nil, id: String = ShoppingFixture.decision) -> String {
        let context = revision.map {
            """
            ,"design_context":{"conversation_id":"\(conversation)","revision":\($0),
              "constraints":\(constraints),"captured_at":"2026-11-17T08:00:00.123456+00:00",
              "evaluated_dimensions":["owned_items","locked_items","scene_evidence"],
              "unverified_dimensions":["size_and_fit","candidate_style","target_date_weather"]}
            """
        } ?? ""
        let savedChoice = choice.map { ",\"choice\":\"\($0)\",\"choice_updated_at\":\"2026-11-17T08:02:00Z\"" } ?? ""
        return """
        {"id":"\(id)","candidate_id":"\(candidate)","decision":"consider_alternate",
         "decision_text":"先看看已有的衬衫","reasons":[{"kind":"compatibility","text":"已有黑裤子可搭"}],
         "closet_comparison":{"summary_text":"已有衣物可以覆盖这次场景","similar_items":[]},
         "uncertainty":"medium","visual_need":"none","boundary_note":"尚不能判断尺码和合身程度。",
         "next_actions":["style_with_existing"],"created_at":"2026-11-17T08:01:00Z"\(context)\(savedChoice)}
        """
    }

    static var conversationBody: String {
        """
        {"conversation_id":"\(conversation)","design_brief":{"revision":5,
          "constraints":\(constraints),"needs_outfit_update":true},"messages":[],
          "purchase_decisions":[\(result(revision: 1, choice: "skip")),
          \(result(revision: 4, choice: "later", id: "30000000-0000-0000-0000-000000000002"))]}
        """
    }
}

private func shoppingClient(_ handler: @escaping StubTransport.Handler) -> (APIClient, StubTransport) {
    let transport = StubTransport(handler)
    return (APIClient(
        environment: AppEnvironment(stage: .development, apiBaseURL: URL(string: "https://api.example.test")!, devUserID: "dev"),
        tokens: TokenStore(store: InMemorySecureStore()), transport: transport
    ), transport)
}

private func shoppingBody(_ request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any])
}

private actor LostShoppingResponse {
    private var count = 0
    func firstAttempt() -> Bool { count += 1; return count == 1 }
}

@Suite struct ShoppingContractTests {
    @Test func independentShoppingAndOldSnapshotsRemainReadable() throws {
        let endpoint = try Endpoints.decide(candidateID: ShoppingFixture.candidate, concern: .color)
        let body = try #require(JSONSerialization.jsonObject(with: #require(endpoint.body)) as? [String: Any])
        #expect(body["concern"] as? String == "color")
        #expect(body["conversation_id"] == nil)
        #expect(body["expected_revision"] == nil)
        #expect(body["request_id"] == nil)
        let old = try JSONCoding.decoder.decode(
            Wire.WardrobeDecisionResponse.self, from: Data(ShoppingFixture.result(revision: nil).utf8)
        )
        #expect(old.designContext == nil)
        #expect(old.choice == nil)
        #expect(old.candidateId == ShoppingFixture.candidate)
    }

    @Test func lostCandidateResponseReusesTheUploadedObjectAndCreationRequest() async throws {
        let attempts = LostShoppingResponse()
        let (client, transport) = shoppingClient { _ in
            if await attempts.firstAttempt() { throw URLError(.networkConnectionLost) }
            return (201, "{\"id\":\"\(ShoppingFixture.candidate)\",\"status\":\"parsed\"}")
        }
        let endpoint = try Endpoints.createPurchaseCandidate(
            objectKey: ShoppingFixture.objectKey, requestID: ShoppingFixture.request
        )
        await #expect(throws: APIError.network(.networkConnectionLost)) { try await client.send(endpoint) }
        let candidate = try await client.send(endpoint)
        #expect(candidate.id == ShoppingFixture.candidate)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].httpBody == transport.requests[1].httpBody)
        let body = try shoppingBody(transport.requests[1])
        #expect(body["source_asset_id"] as? String == ShoppingFixture.objectKey)
        #expect(body["source_type"] as? String == "screenshot")
        #expect(body["request_id"] as? String == ShoppingFixture.request)
    }

    @Test func lostEvaluationResponsePreservesExactDesignAndRequestID() async throws {
        let attempts = LostShoppingResponse()
        let (client, transport) = shoppingClient { _ in
            if await attempts.firstAttempt() { throw URLError(.networkConnectionLost) }
            return (200, ShoppingFixture.result())
        }
        let endpoint = try Endpoints.decide(
            candidateID: ShoppingFixture.candidate, concern: .color,
            conversationID: ShoppingFixture.conversation, expectedRevision: 3, requestID: ShoppingFixture.request
        )
        await #expect(throws: APIError.network(.networkConnectionLost)) { try await client.send(endpoint) }
        let decision = try await client.send(endpoint)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].httpBody == transport.requests[1].httpBody)
        let body = try shoppingBody(transport.requests[1])
        #expect(body["conversation_id"] as? String == ShoppingFixture.conversation)
        #expect(body["expected_revision"] as? Int == 3)
        #expect(body["request_id"] as? String == ShoppingFixture.request)
        #expect(decision.designContext?.revision == 3)
        #expect(decision.designContext?.constraints.lockedItemIds == [ShoppingFixture.item])
        #expect(decision.designContext?.unverifiedDimensions?.contains("candidate_style") == true)
        #expect(endpoint.timeout == Endpoint<Wire.WardrobeDecisionResponse>.slowTimeout)
    }

    @Test func conflictIsNotAutomaticallyRetriedAndNewBriefGetsANewEvaluation() async throws {
        let (client, transport) = shoppingClient { request in
            if request.httpMethod == "GET" { return (200, ShoppingFixture.conversationBody) }
            let body = try shoppingBody(request)
            if body["request_id"] as? String == ShoppingFixture.request {
                return (409, #"{"detail":"Design brief has changed"}"#)
            }
            return (200, ShoppingFixture.result(revision: 5))
        }
        do {
            _ = try await client.send(Endpoints.decide(
                candidateID: ShoppingFixture.candidate, concern: .color,
                conversationID: ShoppingFixture.conversation, expectedRevision: 3, requestID: ShoppingFixture.request
            ))
            Issue.record("Expected a design revision conflict")
        } catch let error as APIError { #expect(error.status == 409) }
        #expect(transport.requests.count == 1)
        let latest = try await client.send(Endpoints.askConversation(ShoppingFixture.conversation))
        let brief = try #require(latest.designBrief)
        #expect(brief.needsOutfitUpdate == true)
        let next = try await client.send(Endpoints.decide(
            candidateID: ShoppingFixture.candidate, concern: .color,
            conversationID: ShoppingFixture.conversation, expectedRevision: brief.revision,
            requestID: ShoppingFixture.nextRequest
        ))
        #expect(next.designContext?.revision == 5)
        #expect(transport.requests.map(\.httpMethod) == ["POST", "GET", "POST"])
        #expect(transport.requests[0].url?.path() == transport.requests[2].url?.path())
        #expect(try shoppingBody(transport.requests[2])["request_id"] as? String == ShoppingFixture.nextRequest)
    }

    @Test func serverChoicesRoundTripAndClearingExplicitlyEncodesNull() async throws {
        let (client, transport) = shoppingClient { request in
            let body = try shoppingBody(request)
            let choice = body["choice"] as? String
            return (200, ShoppingFixture.result(choice: choice))
        }
        for value in ["buy", "skip", "later"] {
            let decision = try await client.send(Endpoints.setPurchaseChoice(
                .init(rawValue: value), decisionID: ShoppingFixture.decision
            ))
            #expect(decision.choice?.rawValue == value)
            #expect(decision.choiceUpdatedAt != nil)
            #expect(decision.designContext?.revision == 3)
            #expect(decision.candidateId == ShoppingFixture.candidate)
        }
        let cleared = try await client.send(Endpoints.setPurchaseChoice(nil, decisionID: ShoppingFixture.decision))
        #expect(cleared.choice == nil)
        let clear = try shoppingBody(#require(transport.requests.last))
        #expect(clear.keys.contains("choice"))
        #expect(clear["choice"] is NSNull)
        #expect(transport.requests.allSatisfy { $0.httpMethod == "PUT" })
        #expect(transport.requests.allSatisfy {
            $0.url?.path() == "/v1/wardrobe-decisions/\(ShoppingFixture.decision)/choice"
        })
    }

    @Test func conversationRestoresHistoricalPurchaseContextsWithoutReplacingPendingBrief() async throws {
        let (client, _) = shoppingClient { _ in (200, ShoppingFixture.conversationBody) }
        let conversation = try await client.send(Endpoints.askConversation(ShoppingFixture.conversation))
        let decisions = try #require(conversation.purchaseDecisions)
        #expect(decisions.map(\.designContext?.revision) == [1, 4])
        #expect(decisions.map(\.choice?.rawValue) == ["skip", "later"])
        #expect(conversation.designBrief?.revision == 5)
        #expect(conversation.designBrief?.needsOutfitUpdate == true)
        #expect(decisions.allSatisfy { $0.designContext?.conversationId == ShoppingFixture.conversation })
        let historical = Endpoints.wardrobeDecision(ShoppingFixture.decision)
        #expect(historical.method == .get)
        #expect(historical.path == "/v1/wardrobe-decisions/\(ShoppingFixture.decision)")
        #expect(historical.body == nil)
    }
}
