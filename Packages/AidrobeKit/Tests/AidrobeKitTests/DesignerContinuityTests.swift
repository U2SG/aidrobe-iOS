import Foundation
import Testing
@testable import AidrobeKit

private let conversationID = "aaaaaaaa-0000-0000-0000-000000000001"
private let outfitID = "bbbbbbbb-0000-0000-0000-000000000001"
private let requestID = "cccccccc-0000-0000-0000-000000000001"
private let referenceID = "dddddddd-0000-0000-0000-000000000001"

private func experienceJSON(_ kind: String, id: String, day: String? = nil, feedback: String? = nil) -> String {
    """
    {"experience_id":"\(id)","request_id":"\(requestID)","outfit_id":"\(outfitID)",
     "kind":"\(kind)","conversation_id":"\(conversationID)","revision":3,
     "worn_date":\(day.map { "\"\($0)\"" } ?? "null"),"feedback":\(feedback.map { "\"\($0)\"" } ?? "null"),
     "note":null,"occasion":null,"supersedes_id":null,"created_at":"2026-11-15T12:00:00Z"}
    """
}

@Suite struct DesignerContinuityTests {
    @Test func onlyAMatchingReceiptProvesTheConditionsWereUsed() throws {
        let expected = Wire.DesignContextRef(conversationId: conversationID.uppercased(), expectedRevision: 3)
        let saved = try JSONCoding.decoder.decode(Wire.DesignContextSnapshot.self, from: Data("""
        {"conversation_id":"\(conversationID)","revision":3,"outfit_id":null,"constraints":{"goal":"轻松一点"}}
        """.utf8))
        #expect(DesignContinuity.matches(expected, saved))
        #expect(!DesignContinuity.matches(expected, nil))
        #expect(!DesignContinuity.matches(.init(conversationId: conversationID, expectedRevision: 4), saved))
        #expect(!DesignContinuity.matches(.init(conversationId: outfitID, expectedRevision: 3), saved))
    }

    @Test func purchaseAndPackingRequestsCarryTheSameDesignRevision() throws {
        let context = Wire.DesignContextRef(conversationId: conversationID, expectedRevision: 3)
        let purchase = try Endpoints.decide(candidateID: "candidate", concern: .scene, designContext: context)
        let purchaseBody = try JSONCoding.decoder.decode(Wire.DecisionRequest.self, from: #require(purchase.body))
        #expect(purchaseBody.designContext?.conversationId == conversationID)
        #expect(purchaseBody.designContext?.expectedRevision == 3)
        var trip = Wire.CreatePackingListRequest(days: 3, scenes: ["casual"])
        trip.designContext = context
        trip.requestId = requestID
        let endpoint = try Endpoints.createPackingList(trip)
        let tripBody = try JSONCoding.decoder.decode(Wire.CreatePackingListRequest.self, from: #require(endpoint.body))
        #expect(tripBody.requestId == requestID)
        #expect(tripBody.designContext?.expectedRevision == 3)
        #expect(endpoint.timeout == Endpoint<Wire.PackingListResponse>.slowTimeout)
    }

    @Test func inspirationIsAnExplicitFirstQuestionCondition() throws {
        let endpoint = try Endpoints.ask(
            "想保留这种配色，用我自己的衣服搭一套", requestID: requestID, referenceInspirationID: referenceID
        )
        let body = try JSONCoding.decoder.decode(Wire.AskRequest.self, from: #require(endpoint.body))
        #expect(body.question == "想保留这种配色，用我自己的衣服搭一套")
        #expect(body.constraints?.referenceInspirationId == referenceID)
        #expect(body.conversationId == nil)
        #expect(body.baseOutfitId == nil)
        #expect(body.designMode == true)
    }

    @Test func linkedResultsRestoreWithoutInventingAQuestionOrAnOutfit() throws {
        let result = try JSONCoding.decoder.decode(Wire.AskConversationResponse.self, from: Data("""
        {"conversation_id":"\(conversationID)","messages":[{
          "id":"\(requestID)","role":"assistant","content":"排好了三天的行程","created_at":"2026-11-15T12:00:00Z",
          "linked_result":{"kind":"packing_list","resource_id":"\(referenceID)","source_revision":3,"summary":"排好了三天的行程"}
        }]}
        """.utf8))
        #expect(result.messages?.first?.linkedResult?.kind == .packing_list)
        #expect(result.messages?.first?.linkedResult?.resourceId == referenceID)
        #expect(result.messages?.first?.styling == nil)
        #expect(result.messages?.first?.askSessionId == nil)
    }

    @Test func appreciationAndIntentionNeverClaimAnActualWear() throws {
        let result = try JSONCoding.decoder.decode(Wire.StylingExperienceListResponse.self, from: Data("""
        {"items":[\(experienceJSON("appreciated", id: "a")),\(experienceJSON("want_to_try", id: "b"))],"latest_worn_date":null}
        """.utf8))
        let state = StylingExperienceState(result)
        #expect(state.appreciated != nil)
        #expect(state.wantToTry != nil)
        #expect(state.wornDate == nil)
        #expect(state.wearFeedback == nil)
        let endpoint = try Endpoints.recordStylingExperience(.init(requestId: requestID, outfitId: outfitID, kind: .appreciated))
        let body = try JSONCoding.decoder.decode(Wire.StylingExperienceRequest.self, from: #require(endpoint.body))
        #expect(body.wornDate == nil)
        #expect(body.feedback == nil)
    }

    @Test func reflectionBelongsToItsWornDayAndCanBeReplacedExplicitly() throws {
        let result = try JSONCoding.decoder.decode(Wire.StylingExperienceListResponse.self, from: Data("""
        {"items":[\(experienceJSON("wear_feedback", id: "old", day: "2026-11-14", feedback: "dislike")),
          \(experienceJSON("wear_feedback", id: "current", day: "2026-11-15", feedback: "like"))],"latest_worn_date":"2026-11-15"}
        """.utf8))
        #expect(StylingExperienceState(result).wearFeedback?.experienceId == "current")
        var replacement = Wire.StylingExperienceRequest(requestId: requestID, outfitId: outfitID, kind: .wear_feedback)
        replacement.wornDate = "2026-11-15"
        replacement.feedback = .neutral
        replacement.supersedesId = "current"
        let endpoint = try Endpoints.recordStylingExperience(replacement)
        let body = try JSONCoding.decoder.decode(Wire.StylingExperienceRequest.self, from: #require(endpoint.body))
        #expect(body.wornDate == "2026-11-15")
        #expect(body.supersedesId == "current")
        #expect(body.feedback == .neutral)
    }
}
