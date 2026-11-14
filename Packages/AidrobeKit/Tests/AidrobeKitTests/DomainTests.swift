@testable import AidrobeKit
import Testing

@Suite struct OutfitBoardLayoutTests {
    @Test func threePieceOutfitPutsTopAndShoesLeftAndTrousersRight() {
        let frames = OutfitBoardLayout.frames(for: ["top", "bottom", "shoes"])
        #expect(frames[0].x == 0 && frames[0].y == 0)
        #expect(frames[1].x > 0 && frames[1].height == 1)
        #expect(frames[2].x == 0 && frames[2].y == frames[0].height)
    }

    @Test(arguments: [["top"], ["dress", "shoes"], ["outer", "top", "bottom", "shoes"], ["outer", "top", "bottom", "shoes", "accessory"]])
    func columnsFillTheBoardWithoutOverlap(roles: [String]) {
        let frames = OutfitBoardLayout.frames(for: roles)
        #expect(frames.count == roles.count)
        for x in Set(frames.map(\.x)) {
            let column = frames.filter { $0.x == x }.sorted { $0.y < $1.y }
            #expect(abs(column.reduce(0) { $0 + $1.height } - 1) < 1e-9)
            for (upper, lower) in zip(column, column.dropFirst()) {
                #expect(abs(upper.y + upper.height - lower.y) < 1e-9)
            }
        }
        #expect(frames[0].x == 0)
    }
}

@Suite struct SettingsFormatTests {
    @Test func locationIsLongitudeFirstWithTwoDecimals() {
        #expect(SettingsFormat.location(latitude: 31.2304, longitude: 121.4737) == "121.47,31.23")
    }

    @Test func departureTimeRoundTrips() {
        #expect(SettingsFormat.departureTime(hour: 8, minute: 5) == "08:05:00")
        #expect(SettingsFormat.hourMinute(from: "08:05:00")?.hour == 8)
        #expect(SettingsFormat.hourMinute(from: "08:05:00")?.minute == 5)
        #expect(SettingsFormat.hourMinute(from: "25:00") == nil)
    }
}

@Suite struct WeatherVisualTests {
    private func visual(
        _ condition: String, icon: String? = nil, temp: Double = 18, hour: Double = 10,
        speed: Double? = nil, scale: String? = nil, direction: String? = nil
    ) -> WeatherVisual {
        WeatherVisual(
            condition: condition, icon: icon, temperatureC: temp,
            windSpeed: speed, windScale: scale, windDirection: direction, hour: hour
        )
    }

    @Test func clearDayIsOpenSkyWithNothingFalling() {
        let sky = visual("晴", icon: "100")
        #expect(sky.cloud < 0.1 && sky.rain == 0 && sky.snow == 0 && sky.fog == 0 && sky.dust == 0)
        #expect(sky.openSky > 0.95 && sky.night == 0)
    }

    @Test func rainGetsHeavierWithTheConditionAndClosesTheSky() {
        #expect(visual("毛毛雨").rain < visual("小雨").rain)
        #expect(visual("小雨").rain < visual("中雨").rain)
        #expect(visual("中雨").rain < visual("暴雨").rain)
        #expect(visual("中雨").openSky == 0)
        #expect(visual("雷阵雨").thunder == 1 && visual("雷阵雨").rain >= 0.7)
    }

    @Test func iconCodeIsEnoughWhenTheTextIsUnfamiliar() {
        #expect(visual("Regen", icon: "305").rain > 0)
        #expect(visual("Schnee", icon: "400").snow > 0)
        #expect(visual("Nebel", icon: "501").fog > 0)
        #expect(visual("Staub", icon: "504").dust > 0)
    }

    @Test func overcastIsCloudierThanCloudyThanPartlyCloudy() {
        #expect(visual("阴").cloud > visual("多云").cloud)
        #expect(visual("多云").cloud > visual("晴间多云").cloud)
    }

    @Test func dustIsNotFog() {
        let storm = visual("沙尘暴")
        #expect(storm.dust > 0.9 && storm.fog == 0 && storm.wind >= 0.6)
        #expect(visual("霾").dust > 0 && visual("雾").dust == 0 && visual("雾").fog > 0)
    }

    @Test func windComesFromSpeedThenScaleThenWords() {
        #expect(visual("晴", speed: 5).wind < visual("晴", speed: 40).wind)
        #expect(visual("晴", scale: "1-2").wind < visual("晴", scale: "6-7").wind)
        #expect(visual("大风").wind >= 0.75)
        #expect(visual("晴", direction: "东北风").windSide == -1)
        #expect(visual("晴", direction: "西风").windSide == 1)
    }

    @Test func theSunClimbsCrossesAndSets() {
        #expect(visual("晴", hour: 12).elevation > visual("晴", hour: 8).elevation)
        #expect(visual("晴", hour: 8).sunSide < 0 && visual("晴", hour: 16).sunSide > 0)
        #expect(visual("晴", hour: 22).night == 1)
        #expect(abs(visual("晴", hour: 18).night - 0.5) < 1e-9)
        #expect(visual("晴", hour: 12).night == 0)
        #expect(visual("晴", hour: 22).openSky == 0)
    }

    @Test func warmthIsClamped() {
        #expect(visual("晴", temp: -10).warmth == 0)
        #expect(visual("晴", temp: 40).warmth == 1)
    }
}
