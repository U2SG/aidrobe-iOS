@testable import AidrobeKit
import Foundation
import Testing

private enum FavoriteFixture {
    static let outfitID = "10000000-0000-0000-0000-000000000021"
    static let itemID = "20000000-0000-0000-0000-000000000021"
    static let page = """
    {"code":0,"message":"ok","data":{"items":[
      {"outfit_id":"\(outfitID)","type":"stylish","title":"收藏的周末搭配","reason":"保留这条深色裤子",
       "is_favorited":true,"items":[{"item_id":"\(itemID)","title":"深色裤子","category":"bottom"}]}],
      "limit":1,"offset":0,"has_more":true}}
    """
}

@Suite struct FavoriteOutfitsTests {
    @Test func savedOutfitIdentitySurvivesPagingAndContinuingDesign() async throws {
        let transport = StubTransport { request in
            if request.url?.query()?.contains("offset=1") == true {
                return (200, #"{"code":0,"message":"ok","data":{"items":[],"limit":1,"offset":1,"has_more":false}}"#)
            }
            return (200, FavoriteFixture.page)
        }
        let client = APIClient(
            environment: AppEnvironment(stage: .development, apiBaseURL: URL(string: "https://api.example.test")!, devUserID: "dev"),
            tokens: TokenStore(store: InMemorySecureStore()), transport: transport
        )
        let first = try await client.send(Endpoints.favoriteOutfits(limit: 1))
        let saved = try #require(first.items.first)
        #expect(first.hasMore)
        #expect(saved.outfitId == FavoriteFixture.outfitID)
        #expect(saved.items.map(\.itemId) == [FavoriteFixture.itemID])
        #expect(saved.isFavorited == true)

        let next = try await client.send(Endpoints.favoriteOutfits(limit: first.limit, offset: first.offset + first.items.count))
        #expect(next.items.isEmpty)
        #expect(!next.hasMore)
        #expect(transport.requests.map { $0.url?.path() } == [
            "/v1/recommendations/outfits/favorites", "/v1/recommendations/outfits/favorites",
        ])
        #expect(transport.requests[1].url?.query() == "limit=1&offset=1")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Cache-Control") == "no-cache")

        let nextDesign = try Endpoints.ask(
            "保留裤子，换一件上衣", requestID: UUID().uuidString, baseOutfitID: saved.outfitId
        )
        let body = try JSONCoding.decoder.decode(Wire.AskRequest.self, from: #require(nextDesign.body))
        #expect(body.baseOutfitId == FavoriteFixture.outfitID)
        #expect(body.conversationId == nil)
        #expect(body.designMode == true)
    }

    @Test func detailRefreshReadsTheExactOutfitAfterItLeavesTheFavoritesPage() async throws {
        let transport = StubTransport { _ in
            (200, """
            {"code":0,"message":"ok","data":{
              "outfit_id":"\(FavoriteFixture.outfitID)","type":"stylish","title":"保存的搭配","reason":"保留原方案",
              "is_favorited":false,"items":[{"item_id":"\(FavoriteFixture.itemID)","category":"bottom"}]}}
            """)
        }
        let client = APIClient(
            environment: AppEnvironment(stage: .development, apiBaseURL: URL(string: "https://api.example.test")!, devUserID: "dev"),
            tokens: TokenStore(store: InMemorySecureStore()), transport: transport
        )
        let current = try await client.send(Endpoints.outfit(FavoriteFixture.outfitID))
        #expect(current.outfitId == FavoriteFixture.outfitID)
        #expect(current.items.map(\.itemId) == [FavoriteFixture.itemID])
        #expect(current.isFavorited == false)
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url?.path() == "/v1/recommendations/outfits/\(FavoriteFixture.outfitID)")
        #expect(transport.requests[0].value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    }
}

@Suite struct StylingTextTests {
    @Test func combinedTagsAreReadableAndDoNotRepeat() {
        #expect(StylingText.styles(" vivid, casual, clean, soft, Casual ") == "鲜艳、休闲、利落、柔和")
        #expect(StylingText.styles("smart_casual，elegant；streetwear") == "日常通勤、优雅、街头")
    }

    @Test func freeTextAndUnknownTagsStayIntact() {
        #expect(StylingText.styles("稍微鲜艳一点、学院风") == "稍微鲜艳一点、学院风")
        #expect(StylingText.styles("experimental, ") == "experimental")
        #expect(StylingText.styles(" ,； ").isEmpty)
    }
}
