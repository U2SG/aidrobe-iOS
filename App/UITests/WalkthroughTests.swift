import XCTest

/// Walks the main line against the local dev stack and saves a screenshot of
/// every screen, in light and dark. Not part of CI (needs the backend from
/// aidrobe-BE `scripts/dev-up.sh` and `scripts/dev-seed-wardrobe.py`):
///
///     TEST_RUNNER_WALKTHROUGH_DIR=/tmp/aidrobe-shots xcodebuild test \
///       -project Aidrobe.xcodeproj -scheme Walkthrough \
///       -destination 'platform=iOS Simulator,name=iPhone Air' -skipPackagePluginValidation
@MainActor
final class WalkthroughTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
    }

    func testWelcomeAndOnboarding() {
        launch(onboarded: false)
        let enter = app.buttons["开发版本：以测试账号进入"]
        XCTAssert(enter.waitForExistence(timeout: 10))
        shot("01-welcome")
        enter.tap()
        for step in 1...3 {
            settle(step == 3 ? 6 : 2.5)
            shot("01\(["a", "b", "c"][step - 1])-onboarding-\(step)")
            let skip = app.buttons["跳过"]
            guard skip.exists else { break }
            skip.tap()
        }
    }

    /// Every page beyond the main line; read-only.
    func testMorePages() {
        launch(onboarded: true)
        XCTAssert(app.tabBars.buttons["问问"].waitForExistence(timeout: 60))
        app.tabBars.buttons["问问"].tap()
        settle(3)
        shot("40-ask")
        push("该不该买", shot: "41-should-i-buy")
        push("出行打包", shot: "42-packing", stay: true)
        let trip = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '杭州'")).firstMatch
        if trip.waitForExistence(timeout: 3) {
            trip.tap()
            settle(3)
            shot("43-packing-detail")
            back()
        }
        back()

        app.tabBars.buttons["我的"].tap()
        settle(2)
        push("全部记录", shot: "45-journal")
        app.swipeUp()
        shot("44-profile-links")
        push("衣橱洞察", shot: "46-insights", scrollShot: "46b-insights-more")
        push("记住的偏好", shot: "47-memory")
        push("数据与隐私", shot: "48-privacy")
    }

    /// Opens a row, screenshots the page (and optionally one scroll down), and comes back.
    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        settle(1)
    }

    private func push(_ label: String, shot name: String, scrollShot: String? = nil, stay: Bool = false) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        guard row.waitForExistence(timeout: 5) else { return XCTFail("no row \(label)") }
        row.tap()
        settle(4)
        shot(name)
        if let scrollShot {
            app.swipeUp()
            settle()
            shot(scrollShot)
        }
        if !stay { back() }
    }

    func testMainLine() {
        launch(onboarded: true)
        XCTAssert(app.buttons["就穿这套"].waitForExistence(timeout: 60) || app.buttons["说说穿着感受"].exists)
        settle()
        shot("02-today")
        app.swipeUp()
        shot("03-today-reasons")
        app.swipeDown()

        app.buttons["今天的情况"].tap()
        settle()
        shot("04-today-context")
        app.swipeDown(velocity: .fast)

        app.buttons.matching(NSPredicate(format: "label CONTAINS '换一件'")).firstMatch.tap()
        settle(3)
        shot("05-today-swap")
        app.swipeDown(velocity: .fast)

        if app.buttons["这套不合适"].exists {
            app.buttons["这套不合适"].tap()
            settle()
            shot("06-today-feedback")
            app.swipeDown(velocity: .fast)
        }

        app.tabBars.buttons["衣橱"].tap()
        settle(3)
        shot("07-wardrobe")
        app.buttons.matching(NSPredicate(format: "label CONTAINS '打底'")).firstMatch.tap()
        settle(3)
        shot("08-item")
        app.buttons["更多"].tap()
        app.buttons["修改"].tap()
        settle()
        shot("08a-item-edit")
        app.buttons["取消"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["添加衣物"].tap()
        settle()
        shot("08b-import")
        app.buttons["完成"].tap()

        app.tabBars.buttons["我的"].tap()
        settle(3)
        shot("09-profile")
    }

    func testDarkAppearance() {
        launch(onboarded: true, extra: ["-aidrobe.display.appearance", "dark"])
        XCTAssert(app.tabBars.buttons["我的"].waitForExistence(timeout: 60))
        settle(4)
        shot("20-today-dark")
        app.tabBars.buttons["衣橱"].tap()
        settle(3)
        shot("21-wardrobe-dark")
        app.buttons.matching(NSPredicate(format: "label CONTAINS '打底'")).firstMatch.tap()
        settle(3)
        shot("22-item-dark")
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["我的"].tap()
        settle(3)
        shot("23-profile-dark")
    }

    /// The light on Today across the weather space, staged through the debug argument
    /// (condition, °C, hour, wind km/h, humidity %, wind direction). Pairs show the
    /// same weather under different numbers.
    func testWeatherSkies() {
        let light: [(String, String)] = [
            ("晴,24,10,6,40", "50-clear-morning"), ("晴,27,13,6,40", "51-clear-noon"), ("晴,22,17,10,45", "52-clear-evening"),
            ("多云,18,10,8,55", "53-cloudy-calm"), ("多云,18,15,38,55,西风", "54-cloudy-windy"),
            ("阴,14,10,10,70", "55-overcast"),
            ("小雨,13,10,8,90", "56-rain-light"), ("暴雨,12,10,40,95,东风", "57-rain-heavy-wind"), ("雷阵雨,20,15,25,90", "58-thunder"),
            ("小雪,-1,10,6,80", "59-snow-light"), ("大雪,-4,10,35,85,西风", "60-snow-heavy-wind"),
            ("雾,9,8,3,95", "61-fog"), ("霾,11,10,5,60", "62-haze"), ("沙尘暴,16,14,50,20,西北风", "63-sandstorm"),
            ("大风,15,11,60,35", "64-gale-clear"), ("晴,16,22,6,50", "65-night"),
        ]
        for (staged, name) in light { stage(staged, name, appearance: "light") }
        let dark: [(String, String)] = [
            ("晴,24,10,6,40", "70-dark-clear"), ("多云,18,15,38,55,西风", "71-dark-cloudy-windy"), ("阴,14,10,10,70", "72-dark-overcast"),
            ("暴雨,12,10,40,95,东风", "73-dark-rain-heavy"), ("大雪,-4,10,35,85,西风", "74-dark-snow"),
            ("沙尘暴,16,14,50,20,西北风", "75-dark-sandstorm"), ("晴,16,22,6,50", "76-dark-night"),
        ]
        for (staged, name) in dark { stage(staged, name, appearance: "dark") }
    }

    private func stage(_ weather: String, _ name: String, appearance: String) {
        launch(onboarded: true, extra: ["-aidrobe.debug.weather", weather, "-aidrobe.display.appearance", appearance])
        XCTAssert(app.tabBars.buttons["我的"].waitForExistence(timeout: 60))
        settle(4)
        shot(name)
    }

    /// Stores a weather location (dev data). Set one first:
    /// `xcrun simctl location <device> set 31.23,121.47`.
    func testUseCurrentLocation() {
        launch(onboarded: true)
        app.tabBars.buttons["我的"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS '所在城市'")).firstMatch.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["使用App时允许"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        settle(6)
        shot("30-profile-location")
        app.tabBars.buttons["今日"].tap()
        settle(5)
        shot("31-today-weather")
    }

    /// Records a wear, so it changes dev data; kept apart from the read-only walk.
    func testWearToday() {
        launch(onboarded: true)
        guard app.buttons["就穿这套"].waitForExistence(timeout: 60) else { return }
        app.buttons["就穿这套"].tap()
        XCTAssert(app.buttons["说说穿着感受"].waitForExistence(timeout: 15))
        settle()
        shot("13-today-worn")
        app.buttons["说说穿着感受"].tap()
        settle()
        shot("14-today-worn-feedback")
    }

    private func launch(onboarded: Bool, extra: [String] = []) {
        // The argument domain overrides stored defaults for this launch only.
        app.launchArguments = ["-aidrobe.onboarding.completed", onboarded ? "YES" : "NO"]
            + (extra.isEmpty ? ["-aidrobe.display.appearance", "light"] : extra)
        app.launch()
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["WALKTHROUGH_DIR"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
        }
    }
}
