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
        // Ask reopens the latest conversation; start fresh so the starter prompts show.
        let fresh = app.buttons["新对话"].firstMatch
        if fresh.exists, scrollIntoOpenArea(fresh) {
            fresh.tap()
            settle(2)
        }
        shot("40-ask")
        app.buttons["周五面试穿什么"].tap()
        // With an answer model the page shows the answer and its garments; without one, a quiet note.
        let answered = app.buttons["有帮助"].waitForExistence(timeout: 45)
        settle(2)
        shot(answered ? "40a-ask-answer" : "40a-ask-unavailable")
        app.buttons["新对话"].firstMatch.tap()
        settle(3)
        shot("40c-ask-new")
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
        push("收藏穿搭", shot: "45b-favorites")
        app.swipeUp()
        shot("44-profile-links")
        push("衣橱洞察", shot: "46-insights", scrollShot: "46b-insights-more")
        push("记住的偏好", shot: "47-memory")
        push("数据与隐私", shot: "48-privacy")
    }

    /// Runs the real shopping pipeline with the existing synthetic DEBUG photo.
    /// It checks continuity and persistence, not recognition or styling quality.
    func testShoppingContinuesTheDesignAndReplaysSavedChoice() {
        launch(onboarded: true, extra: ["-aidrobe.display.appearance", "light", "-AidrobeShoppingDemo"])
        guard app.tabBars.buttons["问问"].waitForExistence(timeout: 60) else { return XCTFail("Ask tab unavailable") }
        app.tabBars.buttons["问问"].tap()
        settle(3)
        let newConversation = app.buttons["新对话"]
        if newConversation.exists {
            guard reveal(newConversation, towardTop: true) else { return XCTFail("Cannot start a fresh design") }
            newConversation.tap()
            settle(2)
        }
        sendDesignMessage("周末出去玩，想鲜艳一点，保留衣橱里的黑裤子。")
        let shopping = app.buttons["ask.shopping"]
        guard shopping.waitForExistence(timeout: 90), waitUntilEnabled(shopping), reveal(shopping) else {
            return XCTFail("The design did not expose its shopping entry")
        }
        shot("70-shopping-design")
        shopping.tap()

        let result = app.staticTexts["shopping.result"]
        guard result.waitForExistence(timeout: 90) else { return XCTFail("Shopping evaluation did not finish") }
        let frozenText = result.label
        XCTAssert(app.descendants(matching: .any)["shopping.designContext"].exists)
        shot("71-shopping-result")
        let later = app.buttons["shopping.choice.later"]
        guard reveal(later) else { return XCTFail("Purchase choice is not reachable") }
        later.tap()
        let saved = app.staticTexts["shopping.choice.saved"]
        guard saved.waitForExistence(timeout: 20) else { return XCTFail("Purchase choice was not saved") }
        XCTAssert(saved.label.contains("再想想"))
        shot("72-shopping-choice-saved")

        let resume = app.buttons["shopping.continue"]
        guard reveal(resume) else { return XCTFail("Cannot return to the design") }
        resume.tap()
        settle(2)
        let purchase = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ask.purchaseDecision.'")).firstMatch
        guard purchase.waitForExistence(timeout: 20), waitUntilHittable(purchase) else {
            return XCTFail("Returning did not reveal the purchase result in the original conversation")
        }
        let purchaseIdentifier = purchase.identifier
        XCTAssert(purchase.label.contains("再想想"))
        shot("73-shopping-in-conversation")
        sendDesignMessage("那先不买了，继续用已有衣服搭，保持刚才想尝试的风格。")
        guard waitUntilEnabled(app.buttons["新对话"], timeout: 90) else { return XCTFail("Continuation did not finish") }
        let updatedChoice = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "这次不买"), object: purchase
        )
        guard XCTWaiter.wait(for: [updatedChoice], timeout: 20) == .completed else {
            return XCTFail("The conversation did not refresh the natural-language purchase choice")
        }
        shot("74-shopping-continue-design")

        app.terminate()
        launch(onboarded: true)
        guard app.tabBars.buttons["问问"].waitForExistence(timeout: 60) else { return XCTFail("Ask tab unavailable after restart") }
        app.tabBars.buttons["问问"].tap()
        let restored = app.buttons[purchaseIdentifier]
        guard restored.waitForExistence(timeout: 30), reveal(restored, towardTop: true) else {
            return XCTFail("Saved purchase is missing after restarting")
        }
        XCTAssert(restored.label.contains("这次不买"))
        restored.tap()
        guard result.waitForExistence(timeout: 30) else { return XCTFail("Historical decision did not replay") }
        XCTAssertEqual(result.label, frozenText)
        guard reveal(saved) else { return XCTFail("Saved choice is missing from historical decision") }
        XCTAssert(saved.label.contains("这次不买"))
        shot("75-shopping-replayed")

        let reassess = app.buttons["shopping.reassess"]
        guard reveal(reassess) else { return XCTFail("The saved candidate cannot be reassessed") }
        reassess.tap()
        let evaluate = app.buttons["shopping.evaluateLatest"]
        guard evaluate.waitForExistence(timeout: 30), reveal(evaluate) else {
            return XCTFail("Latest design conditions were not presented for confirmation")
        }
        XCTAssertFalse(app.buttons["shopping.pickPhoto"].exists)
        shot("76-shopping-review-new-conditions")
        evaluate.tap()
        guard result.waitForExistence(timeout: 90), reveal(resume) else {
            return XCTFail("The saved candidate was not reassessed without another photo")
        }
        resume.tap()
        let assessments = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'ask.purchaseDecision.'"))
        let appended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: assessments)
        guard XCTWaiter.wait(for: [appended], timeout: 20) == .completed else {
            return XCTFail("Reassessment replaced the original purchase record")
        }
        let latest = assessments.allElementsBoundByIndex.first { $0.identifier != purchaseIdentifier }
        guard let latest, waitUntilHittable(latest) else { return XCTFail("The new assessment was not revealed") }
        shot("77-shopping-both-assessments")
        guard reveal(restored, towardTop: true) else { return XCTFail("Original assessment disappeared") }
        restored.tap()
        guard result.waitForExistence(timeout: 30) else { return XCTFail("Original assessment is no longer readable") }
        XCTAssertEqual(result.label, frozenText)
        guard reveal(saved) else { return XCTFail("Original purchase choice disappeared") }
        XCTAssert(saved.label.contains("这次不买"))
    }

    private func sendDesignMessage(_ text: String) {
        let input = app.descendants(matching: .any)["ask.message"]
        guard input.waitForExistence(timeout: 15) else { return XCTFail("Design input unavailable") }
        input.tap()
        input.typeText(text)
        let send = app.buttons["ask.send"]
        guard waitUntilEnabled(send) else { return XCTFail("Design message cannot be sent") }
        send.tap()
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        return XCTWaiter.wait(for: [visible], timeout: timeout) == .completed
    }

    private func reveal(_ element: XCUIElement, towardTop: Bool = false) -> Bool {
        for _ in 0..<10 {
            if element.exists, element.isHittable { return true }
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
        return element.exists && element.isHittable
    }

    private func scrollIntoOpenArea(_ element: XCUIElement) -> Bool {
        let bar = app.navigationBars.firstMatch
        let tabs = app.tabBars.firstMatch
        for _ in 0..<6 {
            let top = bar.exists ? bar.frame.maxY : app.frame.minY
            let bottom = tabs.exists ? tabs.frame.minY : app.frame.maxY
            if element.frame.minY >= top, element.frame.maxY <= bottom { return element.isHittable }
            if element.frame.minY < top { app.swipeDown() } else { app.swipeUp() }
            settle(1)
        }
        return false
    }

    /// Opens a row, screenshots the page (and optionally one scroll down), and comes back.
    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        settle(1)
    }

    private func push(_ label: String, shot name: String, scrollShot: String? = nil, stay: Bool = false) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch
        guard row.waitForExistence(timeout: 5) else { return XCTFail("no row \(label)") }
        // A row scrolled under the navigation or tab bar still counts as hittable, but a tap lands on the bar.
        guard scrollIntoOpenArea(row) else { return XCTFail("row \(label) is not reachable") }
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

    /// Opens a saved conversation with several questions through the
    /// last-conversation bookmark. Set `TEST_RUNNER_ASK_RAIL_CONVERSATION` to
    /// such a conversation of the dev user; without it the test is skipped.
    func testAskProgressRail() throws {
        guard let conversation = ProcessInfo.processInfo.environment["ASK_RAIL_CONVERSATION"] else {
            throw XCTSkip("Set TEST_RUNNER_ASK_RAIL_CONVERSATION to a dev-user conversation with several questions")
        }
        let bookmark = "-aidrobe.ask.last-conversation.http://localhost:8000|00000000-0000-4000-8000-000000000001"
        launch(onboarded: true, extra: ["-aidrobe.display.appearance", "light", bookmark, conversation])
        guard app.tabBars.buttons["问问"].waitForExistence(timeout: 60) else { return XCTFail("Ask tab unavailable") }
        app.tabBars.buttons["问问"].tap()
        let rail = app.descendants(matching: .any)["ask.progressRail"]
        guard rail.waitForExistence(timeout: 30) else { return XCTFail("Progress rail missing") }
        settle(2)
        shot("44-ask-rail")
        let newConversation = app.buttons["新对话"].firstMatch
        XCTAssert(newConversation.isHittable, "New conversation should stay pinned on screen")
        let atEnd = rail.value as? String

        // A quick swipe that starts on the rail scrolls the page instead of scrubbing.
        let middle = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 140)))
        settle(2)
        XCTAssertNotEqual(rail.value as? String, atEnd, "Swiping on the rail should scroll the page")

        // Tapping the first tick jumps to the first question.
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 10)).tap()
        settle(2)
        shot("44a-ask-rail-first")
        XCTAssert((rail.value as? String)?.hasPrefix("第1问") == true, "Tapping the first tick should show the first question")

        // Holding, then dragging to the last tick jumps to the last question.
        let last = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: -10))
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 10))
            .press(forDuration: 0.4, thenDragTo: last)
        settle(2)
        XCTAssertEqual(rail.value as? String, atEnd, "Dragging to the last tick should show the last question")
        XCTAssert(newConversation.isHittable)
    }

    func testMainLine() {
        launch(onboarded: true)
        XCTAssert(app.buttons["today.markWorn"].waitForExistence(timeout: 60) || app.buttons["说说穿着感受"].exists)
        settle()
        shot("02-today")
        app.swipeUp()
        let reasons = app.buttons["today.reasons"]
        if reasons.isHittable { reasons.tap() }
        shot("03-today-reasons")
        app.swipeDown()

        app.buttons["今天的情况"].tap()
        settle()
        shot("04-today-context")
        app.swipeDown(velocity: .fast)

        let pieces = app.buttons["today.pieces"]
        for _ in 0..<3 {
            if pieces.isHittable { break }
            app.swipeUp()
        }
        XCTAssert(pieces.isHittable)
        pieces.tap()
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

    /// A quick look at direct sun only, for tuning window light and leaf shade.
    func testWeatherSun() {
        stage("晴,24,10,6,40", "50-clear-morning", appearance: "light")
        stage("晴,22,16,30,45", "52b-clear-afternoon-breezy", appearance: "light")
        stage("晴,24,10,6,40", "70-dark-clear", appearance: "dark")
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
        guard app.buttons["today.markWorn"].waitForExistence(timeout: 60) else { return }
        app.buttons["today.markWorn"].tap()
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

