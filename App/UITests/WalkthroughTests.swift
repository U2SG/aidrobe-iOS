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

    func testWelcome() {
        launch(onboarded: false)
        XCTAssert(app.buttons["开始"].waitForExistence(timeout: 10))
        shot("01-welcome")
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
        app.launchArguments = ["-aidrobe.onboarding.completed", onboarded ? "YES" : "NO"] + extra
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
