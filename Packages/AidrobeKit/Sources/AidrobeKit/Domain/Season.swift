import Foundation

/// Which garments suit the season now, mirroring the backend's
/// `app/common/season.py` (Northern Hemisphere, by calendar month).
public enum Season {
    /// About how many in-season pieces make the daily outfit work; the point
    /// where a new wardrobe stops needing more cataloguing.
    public static let starterCount = 15

    /// `spring` (Mar–May), `summer` (Jun–Aug), `autumn` (Sep–Nov) or `winter`.
    public static func current(on date: Date = .now, calendar: Calendar = .current) -> String {
        switch calendar.component(.month, from: date) {
        case 3...5: "spring"
        case 6...8: "summer"
        case 9...11: "autumn"
        default: "winter"
        }
    }

    /// True when a garment suits `season`; untagged garments always do.
    public static func contains(_ tags: [String]?, _ season: String) -> Bool {
        guard let tags, !tags.isEmpty else { return true }
        return tags.contains(season) || tags.contains("all_season")
    }
}
