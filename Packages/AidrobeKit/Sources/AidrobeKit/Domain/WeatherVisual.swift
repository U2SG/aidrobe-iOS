import Foundation

/// Everything the page's light needs to know about the weather, as continuous
/// amounts rather than a list of scenes. Any report — windy and clear, light
/// rain at dusk, a dust storm — is one point in this space, and two reports of
/// the "same" weather differ wherever their numbers do.
public struct WeatherVisual: Sendable, Equatable {
    /// Share of the sky covered by cloud, 0…1.
    public var cloud: Double
    /// Rain intensity, 0 (none) … 1 (downpour).
    public var rain: Double
    public var snow: Double
    /// Water in the air that hides distance: fog and mist.
    public var fog: Double
    /// Dry matter in the air: sand, dust, smog. Warmer and dirtier than fog.
    public var dust: Double
    /// Lightning now and then.
    public var thunder: Double
    /// 0 calm … 1 gale.
    public var wind: Double
    /// −1 blowing right-to-left, +1 left-to-right (from the reported direction; east wind blows westward).
    public var windSide: Double
    /// 0 dry … 1 saturated. Softens shadows and beads the glass.
    public var humidity: Double
    /// 0 near freezing … 1 hot. Tints the light, nothing more.
    public var warmth: Double
    /// Sun height: 0 at the horizon, 1 overhead.
    public var elevation: Double
    /// −1 morning sun (from the east), +1 evening sun (from the west).
    public var sunSide: Double
    /// 0 day, 1 night; in between at dawn and dusk.
    public var night: Double

    /// - Parameters:
    ///   - condition: display text from the provider ("多云", "小雨", "Light rain").
    ///   - icon: QWeather icon code when present ("101", "305").
    ///   - windSpeed: km/h. `windScale` (Beaufort, "3" or "3-4") is used when speed is missing.
    ///   - windDirection: provider text ("东北风", "NE").
    ///   - hour: local time of day in hours, fractional (8.5 = 08:30).
    public init(
        condition: String,
        icon: String? = nil,
        temperatureC: Double,
        humidity: Int? = nil,
        windSpeed: Double? = nil,
        windScale: String? = nil,
        windDirection: String? = nil,
        hour: Double
    ) {
        let text = condition.lowercased()
        let code = icon.flatMap(Int.init) ?? 0
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

        // Precipitation is shown only when it is falling, never from a forecast probability.
        if has("暴雨", "大雨", "heavy rain", "downpour", "storm") {
            rain = 0.92
        } else if has("中雨", "moderate rain") {
            rain = 0.65
        } else if has("毛毛雨", "细雨", "drizzle") {
            rain = 0.22
        } else if has("小雨", "light rain") {
            rain = 0.38
        } else if has("雨", "rain", "shower") || (300...399).contains(code) {
            rain = 0.5
        } else {
            rain = 0
        }
        thunder = has("雷", "thunder") || (302...304).contains(code) ? 1 : 0
        if thunder > 0 { rain = max(rain, 0.7) }

        if has("暴雪", "大雪", "heavy snow", "blizzard") {
            snow = 0.9
        } else if has("中雪") {
            snow = 0.62
        } else if has("雪", "snow", "sleet") || (400...499).contains(code) {
            snow = 0.38
        } else {
            snow = 0
        }

        if has("沙尘暴", "强沙尘", "sandstorm") {
            dust = 0.95
        } else if has("扬沙", "沙", "dust", "sand") || (503...508).contains(code) {
            dust = 0.65
        } else if has("浮尘", "霾", "haze", "smog") || [502, 511, 512, 513].contains(code) {
            dust = 0.42
        } else {
            dust = 0
        }

        if has("大雾", "浓雾", "dense fog") {
            fog = 0.9
        } else if has("雾", "fog", "mist") || [500, 501, 509, 510, 514, 515].contains(code) {
            fog = 0.6
        } else {
            fog = 0
        }

        let relative = min(max(Double(humidity ?? 55) / 100, 0), 1)
        self.humidity = max(relative, rain > 0 ? 0.85 : 0, fog)

        if rain > 0 || snow > 0 {
            cloud = 0.82 + 0.16 * max(rain, snow)
        } else if has("阴", "overcast") || code == 104 {
            cloud = 0.92
        } else if has("少云", "晴间多云", "partly", "few clouds") || [102, 103, 152, 153].contains(code) {
            cloud = 0.28
        } else if has("多云", "cloud") || [101, 151].contains(code) {
            cloud = 0.58
        } else if has("晴", "sun", "clear") || [100, 150].contains(code) {
            cloud = 0.04
        } else {
            cloud = fog > 0 || dust > 0 ? 0.5 : 0.3
        }

        // Wind: measured speed, else the Beaufort scale, else what the condition says.
        var kmh = windSpeed
        if kmh == nil, let scale = windScale?.split(separator: "-").compactMap({ Double($0) }), !scale.isEmpty {
            let beaufort = scale.reduce(0, +) / Double(scale.count)
            kmh = 3.0 * pow(beaufort, 1.5)          // ≈ Beaufort mid-points in km/h
        }
        var gust = min(max((kmh ?? 8) / 55, 0), 1)
        if has("飓风", "台风", "狂风", "hurricane", "typhoon") {
            gust = max(gust, 1)
        } else if has("大风", "烈风", "强风", "gale", "windy") {
            gust = max(gust, 0.75)
        }
        if dust > 0.6 { gust = max(gust, 0.6) }
        wind = gust

        let direction = (windDirection ?? "").lowercased()
        if direction.contains("东") || direction.contains("e") && !direction.contains("w") {
            windSide = -1
        } else {
            windSide = 1
        }

        warmth = min(max((temperatureC - 5) / 25, 0), 1)

        // The sun runs a simple arc from 06:00 to 18:00.
        let height = sin(.pi * (hour - 6) / 12)
        elevation = max(0, height)
        sunSide = min(max((hour - 12) / 6, -1), 1)
        let dark = min(max((0.12 - height) / 0.24, 0), 1)
        night = (150...153).contains(code) ? 1 : dark
    }

    /// Direct sun the sky lets through before any single cloud passes: 0 under
    /// rain, snow, thick fog or dust, and at night.
    public var openSky: Double {
        let blocked = min(1, max(rain, snow) * 1.6) + fog * 0.9 + dust * 0.75
        return max(0, 1 - blocked) * (1 - night)
    }
}
