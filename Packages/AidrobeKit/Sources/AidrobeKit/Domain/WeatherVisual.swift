import Foundation

/// How the sky should feel behind Today, as continuous amounts (0…1) rather
/// than a fixed set of scenes: light rain under heavy cloud and a clear cold
/// night are both just points in this space.
public struct WeatherVisual: Sendable, Equatable {
    public var rain: Double
    public var snow: Double
    public var cloud: Double
    public var fog: Double
    /// 0 = near freezing, 1 = hot. Tints the light, nothing more.
    public var warmth: Double
    public var wind: Double
    /// 0 = day, 0.5 = dawn or dusk, 1 = night.
    public var night: Double

    /// - Parameters:
    ///   - condition: display text from the weather provider ("多云", "小雨", "Light rain").
    ///   - icon: QWeather icon code when present ("101", "305").
    ///   - hour: local hour of day, 0…23.
    public init(condition: String, icon: String?, temperatureC: Double, windSpeed: Double?, hour: Int) {
        let text = condition.lowercased()
        let code = icon.flatMap(Int.init) ?? 0
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

        // Precipitation is drawn only when it is actually falling, never from a forecast probability.
        if has("暴雨", "大雨", "storm", "heavy rain") {
            rain = 0.9
        } else if has("雷") {
            rain = 0.8
        } else if has("中雨", "moderate rain") {
            rain = 0.68
        } else if has("雨", "rain", "shower", "drizzle") || (300...399).contains(code) {
            rain = 0.48
        } else {
            rain = 0
        }

        if has("暴雪", "大雪", "heavy snow") {
            snow = 0.9
        } else if has("中雪") {
            snow = 0.65
        } else if has("雪", "snow", "sleet") || (400...499).contains(code) {
            snow = 0.45
        } else {
            snow = 0
        }

        fog = has("雾", "霾", "沙", "尘", "fog", "haze", "mist", "dust") || (500...515).contains(code) ? 0.65 : 0

        if rain > 0 || snow > 0 {
            cloud = 0.8
        } else if has("阴", "overcast") || code == 104 {
            cloud = 0.85
        } else if has("少云", "晴间多云", "partly", "few clouds") || [102, 103, 152, 153].contains(code) {
            cloud = 0.3
        } else if has("多云", "cloud") || [101, 151].contains(code) {
            cloud = 0.55
        } else if has("晴", "sun", "clear") || [100, 150].contains(code) {
            cloud = 0.05
        } else {
            cloud = fog > 0 ? 0.5 : 0.3
        }

        warmth = min(max((temperatureC - 5) / 25, 0), 1)
        wind = min(max((windSpeed ?? 6) / 40, 0), 1)

        switch hour {
        case 7...17: night = (150...153).contains(code) ? 1 : 0
        case 6, 18: night = 0.5
        default: night = 1
        }
    }
}
