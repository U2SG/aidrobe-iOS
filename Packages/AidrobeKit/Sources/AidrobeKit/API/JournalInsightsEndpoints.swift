import Foundation

/// Wear journal and wardrobe insights. Everything here except `outfit` answers
/// with a plain (unwrapped) body.
extension Endpoints {
    // MARK: Journal

    /// Dates (`yyyy-MM-dd`) in the month that have a recorded outfit.
    public static func outfitCalendar(year: Int, month: Int) -> Endpoint<Wire.OutfitCalendarResponse> {
        Endpoint(
            .get,
            "/v1/outfit-history/calendar",
            query: [URLQueryItem(name: "year", value: "\(year)"), URLQueryItem(name: "month", value: "\(month)")]
        )
    }

    /// The record for one day; 404 when nothing was recorded.
    public static func outfitRecord(wornDate: String) -> Endpoint<Wire.OutfitHistoryEntry> {
        Endpoint(.get, "/v1/outfit-history/\(wornDate)")
    }

    /// A recommended outfit with its pieces. History entries carry an empty
    /// `items` list, so the journal reads the pieces from here.
    public static func outfit(_ outfitID: String) -> Endpoint<Wire.OutfitResponse> {
        Endpoint(.get, "/v1/recommendations/outfits/\(outfitID)")
    }

    // MARK: Insights

    public static func insightsSummary() -> Endpoint<Wire.InsightsSummaryResponse> {
        Endpoint(.get, "/v1/insights/summary")
    }

    public static func topItems(limit: Int = 10) -> Endpoint<[Wire.TopItemResponse]> {
        Endpoint(.get, "/v1/insights/top-items", query: [URLQueryItem(name: "limit", value: "\(limit)")])
    }

    public static func idleItems() -> Endpoint<[Wire.IdleItemResponse]> {
        Endpoint(.get, "/v1/insights/idle-items")
    }

    public static func colorPalette() -> Endpoint<Wire.ColorPaletteResponse> {
        Endpoint(.get, "/v1/insights/color-palette")
    }

    public static func costPerWear() -> Endpoint<[Wire.CostPerWearItem]> {
        Endpoint(.get, "/v1/insights/cost-per-wear")
    }

    public static func wardrobeHealth() -> Endpoint<Wire.WardrobeHealthResponse> {
        Endpoint(.get, "/v1/insights/wardrobe-health")
    }
}
