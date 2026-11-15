@testable import AidrobeKit
import Foundation
import Testing

@Test func magazineReferencesCanOmitAnImage() throws {
    let response = try JSONCoding.decoder.decode(Wire.InspirationListResponse.self, from: Data("""
    {"items":[{
      "id":"d988e59d-8957-4413-b62d-20d18b85aff2","image_url":null,
      "source_url":"https://example.com/magazine.pdf","source_type":"pdf_magazine",
      "learn_status":"queued","created_at":"2026-11-15T08:30:00Z"
    }],"limit":30,"offset":0}
    """.utf8))
    let magazine = try #require(response.items.first)
    #expect(magazine.imageUrl == nil)
    #expect(magazine.sourceUrl == "https://example.com/magazine.pdf")
}
