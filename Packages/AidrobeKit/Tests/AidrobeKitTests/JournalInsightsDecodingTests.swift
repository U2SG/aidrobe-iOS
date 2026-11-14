@testable import AidrobeKit
import Foundation
import Testing

/// Bodies captured from the local stack: these endpoints answer unwrapped, and
/// the health metrics mix numbers with nested objects.
@Suite struct JournalInsightsDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(json.utf8))
    }

    @Test func wardrobeHealthWithNestedMetrics() throws {
        let health = try decode(Wire.WardrobeHealthResponse.self, """
        {"score":44,"level":"low","insights":[
          {"type":"wear_coverage","severity":"high","metrics":{"coverage_ratio":0.25,"window_days":90}},
          {"type":"category_balance","severity":"low","metrics":{"dominant_ratio":0.3125,"counts":{"bottom":4,"top":5}}}]}
        """)
        #expect(health.score == 44)
        #expect(health.insights.map(\._type) == ["wear_coverage", "category_balance"])
    }

    @Test func colorPaletteCounts() throws {
        let palette = try decode(Wire.ColorPaletteResponse.self, #"{"palette":{"black":4,"navy":2}}"#)
        #expect(palette.palette.additionalProperties == ["black": 4, "navy": 2])
    }

    @Test func historyEntryWithEmptyItemsAndMicroseconds() throws {
        let page = try decode(Wire.OutfitHistoryListResponse.self, """
        {"items":[{"wear_history_id":"d988e59d-8957-4413-b62d-20d18b85aff2","worn_date":"2026-11-13",
          "outfit":{"outfit_id":"c2e5e07b","outfit_type":"safe","title":"最稳妥","reason_text":"r","outfit_board_url":null,"items":[]},
          "feedback_type":null,"reason_tags":[],"ootd_image_url":null,"selected_at":"2026-11-13T12:29:55.043873Z"}],
          "page":1,"page_size":5,"total":1}
        """)
        #expect(page.items.first?.wornDate == "2026-11-13")
        #expect(page.items.first?.outfit?.title == "最稳妥")
    }

    @Test func topAndIdleItems() throws {
        let top = try decode([Wire.TopItemResponse].self, #"[{"item_id":"a","title":"白色运动鞋","category":"shoes","cover_image_url":null,"wear_count":1}]"#)
        #expect(top.first?.wearCount == 1)
        #expect(try decode([Wire.IdleItemResponse].self, "[]").isEmpty)
    }
}
