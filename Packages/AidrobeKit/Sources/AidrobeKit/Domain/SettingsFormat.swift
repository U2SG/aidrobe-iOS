import Foundation

/// Wire formats for user settings that are easy to get wrong.
public enum SettingsFormat {
    /// `"lon,lat"`, longitude first, two decimals.
    public static func location(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), longitude, latitude)
    }

    /// `HH:MM:00`.
    public static func departureTime(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d:00", hour, minute)
    }

    /// Hour and minute from `HH:MM[:SS]`; nil when malformed.
    public static func hourMinute(from departureTime: String) -> (hour: Int, minute: Int)? {
        let parts = departureTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }
}
