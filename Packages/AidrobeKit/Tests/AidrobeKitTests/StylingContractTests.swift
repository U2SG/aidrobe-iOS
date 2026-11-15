import Foundation
import Testing
@testable import AidrobeKit

private enum StylingFixture {
    static let conversation = "10000000-0000-0000-0000-000000000001"
    static let oldOutfit = "20000000-0000-0000-0000-000000000001"
    static let newOutfit = "20000000-0000-0000-0000-000000000002"
    static let oldItem = "30000000-0000-0000-0000-000000000001"
    static let newItem = "30000000-0000-0000-0000-000000000002"
    static let request = "40000000-0000-0000-0000-000000000001"
    static let session = "50000000-0000-0000-0000-000000000001"
    static let message = "60000000-0000-0000-0000-000000000001"

    static func styling(revision: Int = 2, adopted: Bool = true) -> String {
        """
        {"conversation_id":"\(conversation)","revision":\(revision),"status":"\(adopted ? "adopted" : "draft")",
         "outfit":{"outfit_id":"\(revision == 1 ? oldOutfit : newOutfit)","type":"safe","title":"今天这一套","reason":"保留上装，只换鞋",
           "items":[{"item_id":"\(revision == 1 ? oldItem : newItem)","title":"白色运动鞋","category":"shoes"}]},
         "constraints":{"locked_item_ids":[],"excluded_item_ids":["\(oldItem)"],"goal":"走很多路",
           "notes":["这次想舒服一点"],"exploration":true},
         "recommendation_date":\(adopted ? "\"2026-11-15\"" : "null")}
        """
    }

    static var conversationBody: String {
        """
        {"conversation_id":"\(conversation)","title":"周末出门","styling":\(styling()),"messages":[
          {"id":"70000000-0000-0000-0000-000000000001","role":"user","content":"周末穿什么？","created_at":"2026-11-15T08:00:00Z"},
          {"id":"\(message)","ask_session_id":"\(session)","role":"assistant","content":"先试试这一套。",
           "created_at":"2026-11-15T08:00:01.123456+00:00","styling":\(styling(revision: 1, adopted: false))}
        ]}
        """
    }
}

private func stylingClient(_ handler: @escaping StubTransport.Handler) -> (APIClient, StubTransport) {
    let transport = StubTransport(handler)
    return (APIClient(
        environment: AppEnvironment(stage: .development, apiBaseURL: URL(string: "https://api.example.test")!, devUserID: "dev"),
        tokens: TokenStore(store: InMemorySecureStore()), transport: transport
    ), transport)
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private actor LostStylingResponse {
    private var count = 0
    func firstAttempt() -> Bool { count += 1; return count == 1 }
}

@Suite struct StylingContractTests {
    @Test func replacementReturnsTheVersionUsedForImageFavoriteAndWear() async throws {
        let (client, transport) = stylingClient { request in
            if request.url?.path().hasSuffix("/revisions") == true { return (200, StylingFixture.styling()) }
            if request.url?.path().hasSuffix("/share-asset") == true {
                return (200, #"{"asset_id":"80000000-0000-0000-0000-000000000001","generation_status":"completed","image_url":"https://images.example.test/new.jpg"}"#)
            }
            return (204, "")
        }
        let version = try await client.send(Endpoints.reviseOutfit(
            outfitID: StylingFixture.oldOutfit, itemID: StylingFixture.oldItem,
            replacementItemID: StylingFixture.newItem, requestID: StylingFixture.request
        ))
        #expect(version.outfit.outfitId == StylingFixture.newOutfit)
        #expect(version.status == .adopted)
        #expect(version.recommendationDate == "2026-11-15")
        _ = try await client.send(Endpoints.generateOutfitImage(version.outfit.outfitId))
        _ = try await client.send(Endpoints.setFavorite(true, outfitID: version.outfit.outfitId))
        _ = try await client.send(Endpoints.markWorn(outfitID: version.outfit.outfitId))

        let body = try requestBody(#require(transport.requests.first))
        #expect(body["item_id"] as? String == StylingFixture.oldItem)
        #expect(body["replacement_item_id"] as? String == StylingFixture.newItem)
        #expect(body["request_id"] as? String == StylingFixture.request)

        let adopt = try Endpoints.adoptStyling(
            conversationID: StylingFixture.conversation, revision: 2,
            requestID: StylingFixture.request, date: "2026-11-16"
        )
        let adoption = try JSONCoding.decoder.decode(Wire.AdoptStylingRequest.self, from: #require(adopt.body))
        #expect(adoption.date == "2026-11-16")
        #expect(adoption.expectedRevision == 2)
        #expect(transport.requests.map { $0.url!.path() } == [
            "/v1/recommendations/outfits/\(StylingFixture.oldOutfit)/revisions",
            "/v1/outfits/\(StylingFixture.newOutfit)/share-asset",
            "/v1/recommendations/outfits/\(StylingFixture.newOutfit)/favorite",
            "/v1/recommendations/outfits/\(StylingFixture.newOutfit)/wear",
        ])
        #expect(transport.requests[1].url?.query() == "generate=true")
    }

    @Test func lostResponseCanRetryTheExactMutationWithTheSameRequestID() async throws {
        let attempts = LostStylingResponse()
        let (client, transport) = stylingClient { _ in
            if await attempts.firstAttempt() { throw URLError(.networkConnectionLost) }
            return (200, StylingFixture.styling())
        }
        let endpoint = try Endpoints.reviseOutfit(
            outfitID: StylingFixture.oldOutfit, itemID: StylingFixture.oldItem,
            replacementItemID: StylingFixture.newItem, requestID: StylingFixture.request
        )
        await #expect(throws: APIError.network(.networkConnectionLost)) { try await client.send(endpoint) }
        let result = try await client.send(endpoint)

        #expect(result.revision == 2)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].httpBody == transport.requests[1].httpBody)
        #expect(try requestBody(transport.requests[1])["request_id"] as? String == StylingFixture.request)
    }

    @Test func conflictDoesNotReplayAndConversationReadKeepsHistorySeparateFromLatest() async throws {
        let (client, transport) = stylingClient { request in
            if request.httpMethod == "POST" {
                return (409, #"{"detail":"A newer outfit version is available"}"#)
            }
            return (200, StylingFixture.conversationBody)
        }
        do {
            _ = try await client.send(Endpoints.adoptStyling(
                conversationID: StylingFixture.conversation, revision: 1, requestID: StylingFixture.request
            ))
            Issue.record("Expected a version conflict")
        } catch let error as APIError { #expect(error.status == 409) }
        let restored = try await client.send(Endpoints.askConversation(StylingFixture.conversation))
        let latest = try #require(restored.styling)
        let historical = try #require(restored.messages?.last)

        #expect(latest.revision == 2)
        #expect(latest.outfit.outfitId == StylingFixture.newOutfit)
        #expect(historical.styling?.revision == 1)
        #expect(historical.styling?.outfit.outfitId == StylingFixture.oldOutfit)
        #expect(historical.id == StylingFixture.message)
        #expect(historical.askSessionId == StylingFixture.session)
        #expect(transport.requests.map(\.httpMethod) == ["POST", "GET"])
    }

    @Test func designRequestIncludesVersionAndPartialConstraintsPreserveOmittedValues() throws {
        let ask = try Endpoints.ask(
            "只换鞋，保留上装", conversationID: StylingFixture.conversation,
            requestID: StylingFixture.request, expectedRevision: 2, baseOutfitID: StylingFixture.newOutfit
        )
        let question = try JSONCoding.decoder.decode(Wire.AskRequest.self, from: #require(ask.body))
        #expect(question.designMode == true)
        #expect(question.requestId == StylingFixture.request)
        #expect(question.expectedRevision == 2)
        #expect(question.conversationId == StylingFixture.conversation)
        #expect(question.baseOutfitId == StylingFixture.newOutfit)
        #expect(ask.timeout == Endpoint<Wire.AskResponse>.slowTimeout)

        let change = try Endpoints.reviseStylingConstraints(
            conversationID: StylingFixture.conversation, revision: 2,
            excludedItemIDs: [], requestID: StylingFixture.request
        )
        let changeData = try #require(change.body)
        let body = try #require(JSONSerialization.jsonObject(with: changeData) as? [String: Any])
        #expect(body["locked_item_ids"] == nil)
        #expect(body["excluded_item_ids"] as? [String] == [])
        #expect(body["expected_revision"] as? Int == 2)
        #expect(body["request_id"] as? String == StylingFixture.request)
    }

    @Test func oldAskResponseStillDecodesWhenDesignerIsDisabled() throws {
        let response = try JSONCoding.decoder.decode(Wire.AskResponse.self, from: Data("""
        {"ask_session_id":"\(StylingFixture.session)","answer":"可以配白色鞋子。","item_refs":[],"tokens_used":20}
        """.utf8))
        #expect(response.styling == nil)
        #expect(response.designBrief == nil)
        #expect(response.answer == "可以配白色鞋子。")
        let continuation = try Endpoints.ask(
            "那鞋子呢？", conversationID: StylingFixture.conversation, requestID: StylingFixture.request
        )
        let data = try #require(continuation.body)
        let question = try JSONCoding.decoder.decode(Wire.AskRequest.self, from: data)
        #expect(question.expectedRevision == nil)
        #expect(question.conversationId == StylingFixture.conversation)
    }

    @Test func conversationRestoresOrdinaryReferencesTripIntentAndConditionsWithoutAnOutfit() async throws {
        let body = """
        {"conversation_id":"\(StylingFixture.conversation)","styling":null,
         "design_brief":{"revision":3,"constraints":{"locked_item_ids":["\(StylingFixture.oldItem)"],
           "goal":"试试新风格","exploration":true},"needs_outfit_update":true},
         "messages":[{"id":"\(StylingFixture.message)","ask_session_id":"\(StylingFixture.session)",
           "role":"assistant","content":"带上这件衬衫。","created_at":"2026-11-15T08:00:00Z",
           "item_refs":["\(StylingFixture.oldItem)"],
           "item_ref_snapshots":[{"item_id":"\(StylingFixture.oldItem)","name":"亚麻衬衫",
             "category":"top","color_main":"white","thumbnail_url":"https://images.example.test/shirt?signature=fresh"}],
           "trip_intent":{"is_trip":true,"duration_days":3}}]}
        """
        let (client, _) = stylingClient { _ in (200, body) }
        let restored = try await client.send(Endpoints.askConversation(StylingFixture.conversation))
        let brief = try #require(restored.designBrief)
        let answer = try #require(restored.messages?.first)

        #expect(restored.styling == nil)
        #expect(brief.revision == 3)
        #expect(brief.needsOutfitUpdate)
        #expect(brief.constraints.lockedItemIds == [StylingFixture.oldItem])
        #expect(brief.constraints.goal == "试试新风格")
        #expect(answer.itemRefs == [StylingFixture.oldItem])
        #expect(answer.itemRefSnapshots?.first?.name == "亚麻衬衫")
        #expect(answer.itemRefSnapshots?.first?.thumbnailUrl == "https://images.example.test/shirt?signature=fresh")
        #expect(answer.tripIntent?.isTrip == true)
        #expect(answer.tripIntent?.durationDays == 3)

        let continuation = try Endpoints.ask(
            "保留这件，继续搭配", conversationID: restored.conversationId,
            requestID: StylingFixture.request, expectedRevision: brief.revision
        )
        let data = try #require(continuation.body)
        let question = try JSONCoding.decoder.decode(Wire.AskRequest.self, from: data)
        #expect(question.expectedRevision == 3)
    }

    @Test func scopedMemoryKeepsServerCopyAndExpiryAndAcceptsOldPayloads() throws {
        let base = """
        "id":"90000000-0000-0000-0000-000000000001","type":"style","label":"简约",
        "display_text":"工作日更喜欢简约","polarity":"like","source":"explicit","confidence":"high","created_at":"2026-11-15T08:00:00Z"
        """
        let scoped = try JSONCoding.decoder.decode(Wire.MemoryItemResponse.self, from: Data("""
        {\(base),"scope":{"scene":"commute","day_type":"weekday"},"scope_text":"通勤 · 工作日","expires_at":"2026-12-15T08:00:00Z"}
        """.utf8))
        #expect(scoped.scopeText == "通勤 · 工作日")
        #expect(scoped.expiresAt == JSONCoding.parseDate("2026-12-15T08:00:00Z"))
        let legacy = try JSONCoding.decoder.decode(Wire.MemoryItemResponse.self, from: Data("{\(base)}".utf8))
        #expect(legacy.scopeText == nil)
        #expect(legacy.expiresAt == nil)
    }
}
