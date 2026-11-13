import XCTest
import CoreFoundation
import Vision

final class NavigationPilotUITests: XCTestCase {
    lazy var app = XCUIApplication(bundleIdentifier: setting("NTFYTestAppID"))
    func setting(_ key: String) -> String {
        Bundle(for: Self.self).object(forInfoDictionaryKey: key) as! String
    }
    let target = "zz-nav-118-regression"
    let newTopic = "zz-nav-118-new"
    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-ntfyDebugLastSeenVersion", "1.25.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = setting("NTFYTestHarness")
    }
    func test00ResolveLaunchAlert() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 3) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 5))
    }
    func launchList() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 1) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.staticTexts[target].exists)
        XCTAssertFalse(app.navigationBars["What's new"].exists, "Ordinary navigation starts after the current release was seen")
        // 60 earlier rows make the target absent from the rendered viewport.
        XCTAssertFalse(app.staticTexts[target].firstMatch.exists && app.staticTexts[target].firstMatch.isHittable, "fixture target must start off screen")
    }
    func assertTarget() {
        XCTAssertTrue(app.navigationBars.staticTexts[target].waitForExistence(timeout: 8), "off-screen target must open without scrolling")
        // The title is the bar's own title and shows as the push starts; on iOS 26 the back button and
        // the trailing items fade in when it settles, about a second later. Wait for them instead of
        // reading them in the same instant. A target pushed on top of another topic would read that
        // topic's name here and still fail.
        XCTAssertTrue(app.navigationBars.buttons["Topics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Topic actions"].waitForExistence(timeout: 5))
    }
    func testURLNewCold() {
        app.terminate()
        app.open(URL(string: "https://ntfy-me.com/" + newTopic)!)
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.textFields["Topic name"].value as? String, newTopic)
        XCTAssertEqual(app.textFields["subscription-server-url"].value as? String, "https://ntf-ai.app")
    }
    func testNotificationWarmOffscreen() {
        launchList()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
    }
    func testNotificationColdOffscreen() {
        app.terminate()
        app.launchEnvironment["NTFY_NAV_COLD_RESPONSE"] = "1"
        app.launch()
        assertTarget()
    }
    func testURLFollowedColdOffscreen() {
        app.terminate()
        app.open(URL(string: "https://ntfy-me.com/" + target)!)
        assertTarget()
    }
    func testURLNewWarmRepeatedAndSheetReplacement() {
        launchList()
        for _ in 0..<2 {
            app.open(URL(string: "https://ntfy-me.com/" + newTopic)!)
            XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields["Topic name"].value as? String, newTopic)
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 5))
            // One tap leaves one sheet, with no second presentation after Cancel.
            Thread.sleep(forTimeInterval: 1)
            XCTAssertFalse(app.navigationBars["Add topic"].exists)
        }
        app.buttons["Add topic"].tap()
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
        app.open(URL(string: "https://ntfy-me.com/" + target)!)
        assertTarget()
    }
    func testNotificationFromSettingsAndSheet() {
        launchList()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
        app.navigationBars.buttons["Topics"].tap()
        app.buttons["Add topic"].tap()
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
    }
    func testNotificationWhileAnotherTopicIsOpen() {
        launchList()
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["aaa-nav-000"].waitForExistence(timeout: 5))
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
        // The target replaces the open topic: one Back returns to the list, not to aaa-nav-000.
        app.navigationBars.buttons["Topics"].tap()
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.staticTexts["aaa-nav-000"].exists)
    }
    func testVersion124UpdateSheet() {
        verifyVersion124UpdateSheet(app: app, german: false)
    }
    func testWhatsNewIsReplacedByURL() {
        app.launchArguments = ["-ntfyDebugLastSeenVersion", "1.17.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["What's new"].waitForExistence(timeout: 8))
        app.open(URL(string: "https://ntfy-me.com/" + newTopic)!)
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Topic name"].value as? String, newTopic)
    }
    func testReservedInvalidAndOtherHostDoNothing() {
        launchList()
        for url in ["https://ntfy-me.com/docs", "https://ntfy-me.com/a/b", "https://ntfy.sh/alerts"] {
            app.open(URL(string: url)!)
            XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.navigationBars["Add topic"].exists)
        }
    }
    func testBackAndScrollingDoNotReplaySelectionAndRowsStillOpen() {
        launchList()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true)
        assertTarget()
        app.navigationBars.buttons["Topics"].tap()
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 5))
        for _ in 0..<20 {
            if app.staticTexts[target].firstMatch.exists && app.staticTexts[target].firstMatch.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts[target].firstMatch.isHittable)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.navigationBars["Topics"].exists, "scrolling must not replay the consumed notification")
        app.staticTexts[target].firstMatch.tap()
        assertTarget()
    }
    func testURLFollowedOffscreen() {
        launchList()
        app.open(URL(string: "https://ntfy-me.com/" + target)!)
        assertTarget()
    }
    func testYSubscribeRequiresTapThenOpensTopic() {
        launchList()
        app.open(URL(string: "https://ntfy-me.com/" + newTopic)!)
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Topic name"].value as? String, newTopic)
        app.buttons["Subscribe"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts[newTopic].waitForExistence(timeout: 15))
        confirmUnsubscribe()
    }
    func confirmUnsubscribe() {
        app.buttons["Topic actions"].tap()
        app.buttons["Unsubscribe"].tap()
        // A confirmation dialog (an action sheet on iPhone), titled with the topic's name.
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        dialog.buttons["Unsubscribe"].tap()
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 5), "unsubscribing must dismiss its message list")
    }
    func testZUnsubscribeManuallyOpenedTopic() {
        launchList()
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["aaa-nav-000"].waitForExistence(timeout: 5))
        confirmUnsubscribe()
        XCTAssertFalse(app.staticTexts["aaa-nav-000"].exists)
    }
    func testZZUnsubscribeExternallyOpenedTopic() {
        app.terminate()
        app.open(URL(string: "https://ntfy-me.com/" + target)!)
        assertTarget()
        confirmUnsubscribe()
        XCTAssertFalse(app.staticTexts[target].exists)
    }

    func muteScreenshot(_ name: String) {
        captureAX(name)
    }
    func revealMuteChoice(_ title: String, scrollingUp: Bool = true) -> XCUIElement {
        let button = app.buttons[title]
        for _ in 0..<4 {
            if button.exists && button.isHittable { return button }
            if scrollingUp { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(button.exists && button.isHittable, "Mute choice must be reachable: \(title)")
        return button
    }
    func testTopicMuteMenusPersistenceSwipeAndResume() {
        launchList()
        let row = app.staticTexts["aaa-nav-000"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1)
        muteScreenshot("mute-topic-context-menu")
        app.buttons["Mute topic"].tap()
        XCTAssertTrue(app.navigationBars["Mute topic"].waitForExistence(timeout: 3))
        let largeText = app.buttons["30 minutes"].frame.height > 60
        muteScreenshot("mute-duration-picker")
        for choice in ["30 minutes", "1 hour", "2 hours", "8 hours", "Until tomorrow, 8:30 AM", "Until resumed"] {
            _ = revealMuteChoice(choice)
        }
        if largeText {
            app.swipeUp()
            muteScreenshot("mute-duration-picker-scrolled")
        }
        revealMuteChoice("30 minutes", scrollingUp: false).tap()
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Notifications muted until ")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        muteScreenshot("muted-topic-list")
        app.terminate(); app.launch()
        XCTAssertTrue(status.waitForExistence(timeout: 5), "mute must survive a restart")
        row.swipeLeft()
        muteScreenshot("mute-swipe-actions")
        app.buttons["Mute settings"].tap()
        app.buttons["Unmute"].tap()
        XCTAssertFalse(status.exists)
        row.tap()
        app.navigationBars.buttons["Topic actions"].tap()
        muteScreenshot("mute-topic-menu")
        app.buttons["Mute topic"].tap()
        revealMuteChoice("Until resumed").tap()
        XCTAssertTrue(app.staticTexts["Notifications muted until resumed"].waitForExistence(timeout: 3))
        muteScreenshot("muted-topic-history")
        app.navigationBars.buttons["Topic actions"].tap()
        app.buttons["Mute settings"].tap()
        app.buttons["Unmute"].tap()
        XCTAssertFalse(app.staticTexts["Notifications muted until resumed"].exists)
    }

    func captureAX(_ name: String) {
        print("AXTREE-BEGIN " + name + "\n" + app.debugDescription + "\nAXTREE-END " + name)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + ".txt"
        tree.lifetime = .keepAlways
        add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
    func tapEither(_ label: String, _ old: String) {
        let named = app.buttons[label].firstMatch
        if named.exists { named.tap() }
        else if label == "Attachment actions" { app.buttons.matching(identifier: old).element(boundBy: 2).tap() }
        else { app.buttons[old].firstMatch.tap() }
    }
    func testAccessibilityControlNames() {
        continueAfterFailure = true
        app.launch()
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 8))
        captureAX("regression-list")
        XCTAssertTrue(app.buttons["Add topic"].exists, "The primary action needs its spoken name")
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["aaa-nav-000"].waitForExistence(timeout: 5))
        captureAX("regression-topic")
        XCTAssertTrue(app.buttons["Topic actions"].exists)
        XCTAssertFalse(app.buttons["Message actions"].exists, "Message actions live in the long-press menu")
        XCTAssertTrue(app.images["High priority"].exists)
        XCTAssertFalse(app.images["priority-4"].exists)
        XCTAssertTrue(app.buttons["Attachment actions"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Open image"].exists)
    }
    // Run separately with --seed --empty-fixture, after the navigation suite.
    func testAccessibilityEmptyList() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 8))
        guard !app.staticTexts["aaa-nav-000"].exists else { throw XCTSkip("Run with --seed --empty-fixture") }
        captureAX("empty-topic-list")
        XCTAssertTrue(app.staticTexts["No topics yet"].exists)
    }
    func testCaptureSavedUserRow() {
        app.launch()
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 8))
        app.buttons["Settings"].tap()
        let user = app.buttons.matching(NSPredicate(format: "label CONTAINS 'accessibility-user'")).firstMatch
        for _ in 0..<16 { if user.exists && user.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(user.isHittable)
        captureAX("saved-user-row")
        user.tap()
        captureAX("edit-user")
        app.buttons["Cancel"].tap()
    }
    func testCaptureAccessibilityScreens() {
        app.launch()
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 8))
        captureAX("topic-list")
        tapEither("Add topic", "Add")
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
        captureAX("add-subscription")
        app.buttons["Cancel"].tap()
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["aaa-nav-000"].waitForExistence(timeout: 5))
        captureAX("topic-and-attachments")
        app.cells.firstMatch.press(forDuration: 1.0)
        captureAX("message-menu")
        app.tapCoordinateOutsideMenu()
        tapEither("Attachment actions", "More")
        captureAX("attachment-menu")
        app.tapCoordinateOutsideMenu()
        if app.buttons["Open image"].exists { app.buttons["Open image"].tap() }
        else { app.images.matching(NSPredicate(format: "label == ''")).firstMatch.tap() }
        captureAX("fullscreen-image")
        app.buttons["Close"].tap()
        tapEither("Topic actions", "More")
        captureAX("topic-menu")
        app.tapCoordinateOutsideMenu()
        app.navigationBars.buttons["Topics"].tap()
        app.buttons["Settings"].tap()
        captureAX("settings-top")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Default server'")).firstMatch.tap()
        captureAX("default-server")
        let field = app.textFields.firstMatch
        field.tap(); field.typeText("http://localhost:8080")
        captureAX("default-server-clear")
        // Default server is a pushed screen; going back discards the unsaved edit.
        app.navigationBars.buttons["Settings"].tap()
        for _ in 0..<16 { if app.buttons["Add user"].isHittable { break }; app.swipeUp() }
        captureAX("settings-users")
        app.buttons["Add user"].tap()
        captureAX("user-editor")
        XCTAssertTrue(app.buttons["Username and password"].isSelected)
        XCTAssertEqual(app.textFields["server-username"].label, "Username")
        XCTAssertEqual(app.secureTextFields["server-password"].label, "Password")
        app.buttons["Access token"].tap()
        XCTAssertTrue(app.buttons["Access token"].isSelected)
        XCTAssertEqual(app.secureTextFields["server-access-token"].label, "Access token")
        XCTAssertFalse(app.textFields["server-username"].exists)
        captureAX("user-editor-access-token")
        app.buttons["Cancel"].tap()
        for _ in 0..<16 { if app.buttons["Custom HTTP headers"].isHittable { break }; app.swipeUp() }
        app.buttons["Custom HTTP headers"].tap()
        captureAX("server-headers")
        app.navigationBars.buttons["Settings"].tap()
        app.terminate()
        app.launchArguments = ["-ntfyDebugLastSeenVersion", "1.17.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["What's new"].waitForExistence(timeout: 8))
        captureAX("whats-new")
    }

    func testTopicQRControlsHaveSpokenNames() {
        launchList()
        app.staticTexts["aaa-nav-000"].firstMatch.tap()
        app.buttons["Topic actions"].tap()
        app.buttons["Show QR code"].tap()
        XCTAssertTrue(app.navigationBars["QR code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["QR code for 127.0.0.1:1/aaa-nav-000"].exists)
        XCTAssertTrue(app.buttons["Share"].exists)
        // The sheet's close control: the system Close button on iOS 26, Done before it.
        let close = app.navigationBars["QR code"].buttons[app.navigationBars["QR code"].buttons["Close"].exists ? "Close" : "Done"]
        XCTAssertTrue(close.exists)
        captureAX("topic-qr-code")
        close.tap()
        app.navigationBars.buttons["Topics"].tap()
        app.buttons["Add topic"].tap()
        let scan = app.buttons["Scan QR code"]
        for _ in 0..<6 { if scan.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(scan.isHittable)
        captureAX("add-subscription-scan-entry")
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan QR code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This device has no camera. Type the topic and server in instead."].exists)
        XCTAssertFalse(app.images["camera"].exists)
        let cancelScan = app.navigationBars["Scan QR code"].buttons["Cancel"]
        XCTAssertTrue(cancelScan.exists)
        captureAX("topic-qr-scanner")
        cancelScan.tap()
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }

}

/// Before/after captures for the 1.26 nav-bar and small-element review (REVIEW-small.md). Runs
/// against either build: each step taps the first label that exists and screenshots regardless,
/// so a control missing from one build shows as an unchanged screen rather than a failure.
extension NavigationPilotUITests {
    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @discardableResult
    func tapFirst(_ labels: [String], in scope: XCUIElement? = nil, timeout: TimeInterval = 2) -> Bool {
        let root = scope ?? app
        for label in labels {
            let button = root.buttons[label].firstMatch
            if button.waitForExistence(timeout: timeout / Double(labels.count)) && button.isHittable { button.tap(); return true }
        }
        return false
    }
    func pause(_ seconds: Double = 0.8) { Thread.sleep(forTimeInterval: seconds) }
    /// Taps the topmost sheet's Close, Cancel or Done: the last such button in the bars, since a sheet
    /// presented over another lists after it.
    @discardableResult
    func tapTopmost(_ labels: [String]) -> Bool {
        let matches = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", labels))
        for index in stride(from: matches.count - 1, through: 0, by: -1) {
            let button = matches.element(boundBy: index)
            if button.isHittable { button.tap(); return true }
        }
        return false
    }
    func barIDs() -> Set<String> {
        Set(app.navigationBars.allElementsBoundByIndex.map(\.identifier))
    }
    /// Dismisses what opened since `before` was taken: its close control, then a drag down on any bar
    /// still showing. Without `before`, only the close control is tried.
    func closeSheet(since before: Set<String>? = nil) {
        tapTopmost(["Close", "Cancel", "Done"]); pause()
        guard let before else { return }
        for _ in 0..<2 {
            let left = barIDs().subtracting(before)
            guard let id = left.first else { return }
            let bar = app.navigationBars[id]
            if tapTopmost(["Close", "Cancel", "Done"]) == false || app.navigationBars[id].exists {
                if bar.exists {
                    bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                        .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
                }
            }
            pause()
        }
    }
    func openTopicMenu() -> Bool {
        let more = app.navigationBars.buttons["Topic actions"].firstMatch
        guard more.waitForExistence(timeout: 3) else { return false }
        more.tap(); pause(0.6); return true
    }
    func fromTopicMenu(_ item: String, _ name: String, settle: Double = 1.0) {
        guard openTopicMenu() else { return }
        let before = barIDs()
        if tapFirst([item]) { pause(settle); shot(name); closeSheet(since: before) } else { app.tapCoordinateOutsideMenu() }
    }
    /// A row swipe that starts mid-row, so a rightward one can't become the system back gesture.
    func swipeRow(_ cell: XCUIElement, right: Bool) {
        let from = cell.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.2 : 0.8, dy: 0.5))
        let to = cell.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.75 : 0.25, dy: 0.5))
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0.05)
    }
    /// Re-opens the seeded topic if a step left it.
    func ensureTopic() {
        if app.navigationBars.buttons["Topic actions"].exists { return }
        closeSheet()
        let topics = app.navigationBars.buttons["Topics"].firstMatch
        if topics.exists && topics.isHittable { topics.tap(); pause() }
        let row = app.staticTexts["aaa-nav-000"].firstMatch
        if row.waitForExistence(timeout: 2) && row.isHittable { row.tap(); pause(1.2) }
    }
    func scrollUntilHittable(_ element: XCUIElement, max: Int = 16) {
        for _ in 0..<max { if element.exists && element.isHittable { return }; app.swipeUp() }
    }

    func testSmallElementsCapture() {
        continueAfterFailure = true
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 2) { springboard.buttons["Allow"].tap() }
        // The fixture's last-seen version can trail the build, which opens What's new first.
        if app.navigationBars["What's new"].waitForExistence(timeout: 3) { app.buttons["Continue"].tap(); pause() }
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 8))
        pause(1.5)
        shot("topics")

        // Topic list: long-press menu, then the trailing and leading swipes on a row.
        let row = app.staticTexts["aaa-nav-002"].firstMatch
        row.press(forDuration: 1.0); pause(); shot("list-context-menu"); app.tapCoordinateOutsideMenu(); pause()
        let topicCell = app.cells.containing(.staticText, identifier: "aaa-nav-002").firstMatch
        swipeRow(topicCell, right: false); pause(); shot("list-swipe-trailing"); swipeRow(topicCell, right: true); pause()
        swipeRow(topicCell, right: true); pause(); shot("list-swipe-leading"); swipeRow(topicCell, right: false); pause()

        // Add sheet: empty, then with a topic typed so Subscribe enables, then the QR scanner.
        if tapFirst(["Add topic", "Add subscription", "Add"]) {
            pause(); shot("sheet-add-empty")
            let field = app.textFields["Topic name"].firstMatch
            if field.waitForExistence(timeout: 2) { field.tap(); field.typeText("build-alerts"); pause(0.5); shot("sheet-add-filled") }
            let scan = app.buttons["Scan QR code"].firstMatch
            scrollUntilHittable(scan, max: 6)
            if scan.exists && scan.isHittable { scan.tap(); pause(); shot("sheet-scanner"); tapTopmost(["Cancel", "Close"]); pause() }
            for _ in 0..<3 where app.navigationBars["Add topic"].exists || app.navigationBars["Add subscription"].exists {
                tapTopmost(["Cancel", "Close"]); pause()
            }
        }

        // A pushed topic with two titled messages (seeded), its More menu and the copied toast.
        app.staticTexts["aaa-nav-000"].firstMatch.tap(); pause(1.5)
        shot("topic-pushed")
        if openTopicMenu() { shot("topic-menu"); app.tapCoordinateOutsideMenu(); pause() }
        if openTopicMenu() {
            if tapFirst(["Copy publish URL"]) { pause(0.4); shot("toast-copied"); pause(2.5) } else { app.tapCoordinateOutsideMenu() }
        }

        // Message row: context menu, then both swipes.
        let titled = app.cells.containing(.staticText, identifier: "Deploy finished").firstMatch
        let message = titled.waitForExistence(timeout: 2) ? titled : app.cells.element(boundBy: 0)
        if message.exists {
            message.press(forDuration: 1.0); pause(); shot("message-context-menu"); app.tapCoordinateOutsideMenu(); pause()
            swipeRow(message, right: false); pause(); shot("message-swipe-trailing"); swipeRow(message, right: true); pause()
            swipeRow(message, right: true); pause(); shot("message-swipe-leading"); swipeRow(message, right: false); pause()
        }

        // Every sheet the topic menu opens.
        for (item, name) in [("Rename", "sheet-rename"), ("Topic details", "sheet-details"),
                             ("End-to-end encryption", "sheet-encryption"), ("Show QR code", "sheet-qr"),
                             ("Alert if quiet", "sheet-quiet"), ("Notification sound", "sheet-sound"),
                             ("Mute topic", "sheet-mute")] {
            ensureTopic(); fromTopicMenu(item, name)
        }

        // Select mode with none, then two rows selected, and the delete confirmation.
        ensureTopic()
        if openTopicMenu() {
            if tapFirst(["Select messages"]) {
                pause(); shot("select-0")
                let cells = app.cells
                if cells.count >= 2 { cells.element(boundBy: 0).tap(); cells.element(boundBy: 1).tap() }
                pause(0.5); shot("select-2")
                if tapFirst(["Delete"], in: app.navigationBars.firstMatch) { pause(); shot("select-delete-confirm"); tapFirst(["Cancel"]); pause() }
                tapFirst(["Done"], in: app.navigationBars.firstMatch); pause()
            } else { app.tapCoordinateOutsideMenu() }
        }

        // Search with no results.
        ensureTopic()
        var search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 1) { app.swipeDown(); search = app.searchFields.firstMatch }
        if search.waitForExistence(timeout: 2) {
            search.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { search.tap() }
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { app.typeText("zqxv no such message"); pause(); shot("search-empty") }
            tapFirst(["Cancel", "Close"]); pause()
        }

        // The two destructive confirmations, cancelled.
        ensureTopic()
        if openTopicMenu() { if tapFirst(["Unsubscribe"]) { pause(); shot("confirm-unsubscribe"); tapFirst(["Cancel"]); pause() } }
        if openTopicMenu() { if tapFirst(["Clear all notifications"]) { pause(); shot("confirm-clear"); tapFirst(["Cancel"]); pause() } }

        // A topic muted and holding an unencrypted message (seeded) shows its notices.
        let back = app.navigationBars.buttons["Topics"].firstMatch
        if back.exists && back.isHittable { back.tap(); pause() }
        let noticeTopic = app.staticTexts["aaa-nav-001"].firstMatch
        scrollUntilHittable(noticeTopic, max: 2)
        if noticeTopic.exists && noticeTopic.isHittable { noticeTopic.tap(); pause() }
        if openTopicMenu(), tapFirst(["Mute topic"]) { pause(); tapFirst(["1 hour"]); pause(1.2) }
        shot("topic-notices")
        let back2 = app.navigationBars.buttons["Topics"].firstMatch
        if back2.exists && back2.isHittable { back2.tap(); pause() }

        // Settings: top, the Download attachments choice open, Default server, Users, About, a license.
        guard tapFirst(["Settings"]) else { return }
        pause(); shot("settings-top")
        let download = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Download attachments'")).firstMatch
        scrollUntilHittable(download, max: 4)
        if download.exists { download.tap(); pause(); shot("download-picker"); if !tapFirst(["Cancel"], timeout: 1) { app.tapCoordinateOutsideMenu() }; pause() }
        let server = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Default server'")).firstMatch
        scrollUntilHittable(server, max: 4)
        if server.exists {
            server.tap(); pause(); shot("default-server")
            if !tapFirst(["Cancel"], timeout: 1) { app.navigationBars.buttons["Settings"].tap() }; pause()
        }
        let addUser = app.buttons["Add user"].firstMatch
        scrollUntilHittable(addUser)
        pause(0.5); shot("settings-users")
        if addUser.exists && addUser.isHittable { addUser.tap(); pause(); shot("sheet-user-editor"); tapTopmost(["Cancel", "Close"]); pause() }
        for _ in 0..<12 { app.swipeUp() }
        pause(0.5); shot("settings-about")
        let licenses = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Licenses'")).firstMatch
        if licenses.exists && licenses.isHittable {
            licenses.tap(); pause()
            app.cells.firstMatch.tap(); pause(); shot("licenses-detail")
            app.navigationBars.buttons.firstMatch.tap(); pause()
            app.navigationBars.buttons.firstMatch.tap(); pause()
        }
        app.navigationBars.buttons.firstMatch.tap(); pause()

        // What's new listing three versions, with Continue pinned.
        app.terminate()
        app.launchArguments = ["-ntfyDebugLastSeenVersion", "1.22.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        if app.navigationBars["What's new"].waitForExistence(timeout: 8) { pause(); shot("whats-new-3") }
    }
}

private extension XCUIApplication {
    func tapCoordinateOutsideMenu() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.50)).tap()
    }
}

/// These assertions launch the actual app in German, with server content kept verbatim.
/// Run separately from the unchanged English navigation suite using run.py --german.
final class GermanLocalizationUITests: XCTestCase {
    lazy var app = XCUIApplication(bundleIdentifier: Bundle(for: Self.self).object(forInfoDictionaryKey: "NTFYTestAppID") as! String)
    let firstTopic = "aaa-nav-000"
    let language = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = language + ["-ntfyDebugLastSeenVersion", "1.24.0", "-notificationPermissionPrimerOffered", "YES"]
    }
    func capture(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "de-" + name + ".txt"; tree.lifetime = .keepAlways; add(tree)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "de-" + name; shot.lifetime = .keepAlways; add(shot)
    }
    func reveal(_ element: XCUIElement, up: Bool = true, attempts: Int = 40) {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return }
            // Small steps keep short controls from being skipped on SE at accessibility sizes.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.70 : 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.45 : 0.70))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, "Expected a reachable German control: \(element)")
    }
    func launch() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Erlauben", "Allow"] {
            if springboard.buttons[label].waitForExistence(timeout: 1) { springboard.buttons[label].tap() }
        }
        capture("launch")
        XCTAssertTrue(app.navigationBars["Abonnierte Themen"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Add topic"].exists)
        XCTAssertTrue(app.buttons["Neues Abo"].exists)
    }
    func testVersion124UpdateSheet() {
        verifyVersion124UpdateSheet(app: app, german: true)
    }
    func testGermanMainScreens() {
        launch()
        capture("topic-list")
        app.staticTexts[firstTopic].firstMatch.tap()
        XCTAssertTrue(app.buttons["Themenaktionen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Nachrichtenaktionen"].firstMatch.exists)
        XCTAssertTrue(app.images["Hohe Priorität"].exists)
        XCTAssertTrue(app.buttons["Anhangaktionen"].firstMatch.exists)
        capture("topic-attachments")
        app.buttons["Nachrichtenaktionen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Nachricht kopieren"].exists)
        capture("message-menu")
        app.tapCoordinateOutsideMenu()
        app.buttons["Anhangaktionen"].firstMatch.tap()
        capture("attachment-menu")
        app.tapCoordinateOutsideMenu()
        app.buttons["Themenaktionen"].tap()
        XCTAssertTrue(app.buttons["Thema stummschalten"].exists)
        capture("topic-menu")
        app.buttons["Thema stummschalten"].tap()
        XCTAssertTrue(app.navigationBars["Stummschalten"].waitForExistence(timeout: 4))
        capture("mute-top")
        for name in ["30 Minuten", "1 Stunde", "2 Stunden", "8 Stunden", "Bis zur Reaktivierung"] {
            reveal(app.buttons[name])
            XCTAssertTrue(app.buttons[name].exists)
        }
        capture("mute-bottom")
        app.buttons["Bis zur Reaktivierung"].tap()
        XCTAssertTrue(app.staticTexts["Benachrichtigungen bis zur Reaktivierung stumm"].waitForExistence(timeout: 4))
        capture("muted-topic")
        app.buttons["Themenaktionen"].tap()
        reveal(app.buttons["QR-Code anzeigen"])
        app.buttons["QR-Code anzeigen"].tap()
        XCTAssertTrue(app.navigationBars["QR-Code"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.images["QR-Code für 127.0.0.1:1/aaa-nav-000"].exists)
        XCTAssertTrue(app.buttons["Teilen"].exists)
        capture("qr-show")
        app.swipeUp(); capture("qr-show-bottom")
        app.buttons["Fertig"].tap()
        app.navigationBars.buttons["Abonnierte Themen"].tap()
        capture("muted-list")
        app.buttons["Neues Abo"].tap()
        XCTAssertTrue(app.navigationBars["Abo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Zufälliger Themenname"].exists)
        capture("add-top")
        reveal(app.buttons["QR-Code scannen"])
        capture("add-bottom")
        app.buttons["QR-Code scannen"].tap()
        XCTAssertTrue(app.navigationBars["Scannen"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Dieses Gerät hat keine Kamera. Gib Thema und Server von Hand ein."].exists)
        capture("qr-scan-no-camera")
        app.navigationBars["Scannen"].buttons["Abbrechen"].tap()
        app.navigationBars["Abo"].buttons["Abbrechen"].tap()
        app.buttons["Einstellungen"].tap()
        XCTAssertTrue(app.navigationBars["Einstellungen"].waitForExistence(timeout: 4))
        capture("settings-top")
        app.swipeUp(); capture("settings-status")
        reveal(app.buttons["Neues Konto"])
        capture("settings-users")
        app.buttons["Neues Konto"].tap()
        XCTAssertTrue(app.buttons["Benutzername und Passwort"].isSelected)
        XCTAssertEqual(app.textFields["server-username"].label, "Benutzername")
        XCTAssertEqual(app.secureTextFields["server-password"].label, "Passwort")
        capture("account-password")
        reveal(app.secureTextFields["server-password"])
        capture("account-password-bottom")
        reveal(app.buttons["Zugriffstoken"], up: false)
        app.buttons["Zugriffstoken"].tap()
        XCTAssertTrue(app.buttons["Zugriffstoken"].isSelected)
        XCTAssertEqual(app.secureTextFields["server-access-token"].label, "Zugriffstoken")
        capture("account-token")
        reveal(app.secureTextFields["server-access-token"])
        capture("account-token-bottom")
        app.buttons["Abbrechen"].tap()
        let savedUser = app.buttons.matching(NSPredicate(format: "label CONTAINS 'accessibility-user'")).firstMatch
        reveal(savedUser, up: false)
        savedUser.tap()
        XCTAssertTrue(app.navigationBars["Konto"].waitForExistence(timeout: 4))
        capture("account-editor")
        app.buttons["Abbrechen"].tap()
        reveal(app.buttons["Eigene HTTP-Header"])
        app.buttons["Eigene HTTP-Header"].tap()
        capture("server-headers")
        app.terminate()
        app.launchArguments = language + ["-ntfyDebugLastSeenVersion", "1.17.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Neuigkeiten"].waitForExistence(timeout: 8))
        capture("whats-new-top")
        app.swipeUp(); capture("whats-new-middle")
        reveal(app.buttons["Weiter"])
        capture("whats-new-bottom")
        app.buttons["Weiter"].tap()
    }
    func testGermanEmptyList() {
        launch()
        XCTAssertTrue(app.staticTexts["Du hast noch keine Themen abonniert"].exists)
        capture("empty-list")
    }
    /// Requires the task-local HTTP fixture on loopback: it refuses /auth with 401.
    func testGermanAddLoginChoices() {
        app.launchEnvironment["NTFY_SIMULATED_QR_SCAN"] = "http://127.0.0.1:18091/zz-german-auth"
        defer { app.launchEnvironment.removeValue(forKey: "NTFY_SIMULATED_QR_SCAN") }
        launch()
        app.buttons["Neues Abo"].tap()
        reveal(app.buttons["QR-Code scannen"])
        app.buttons["QR-Code scannen"].tap()
        XCTAssertTrue(app.navigationBars["Abo"].waitForExistence(timeout: 8))
        let server = app.textFields["subscription-server-url"]
        reveal(server, up: false)
        XCTAssertEqual(server.value as? String, "http://127.0.0.1:18091")
        capture("add-server-filled")
        app.navigationBars.buttons["Abonnieren"].tap()
        XCTAssertTrue(app.navigationBars["Login"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Benutzername und Passwort"].exists)
        capture("add-login-password")
        app.buttons["Zugriffstoken"].tap()
        XCTAssertEqual(app.secureTextFields["server-access-token"].label, "Zugriffstoken")
        capture("add-login-token")
    }
    func testGermanLicenseScreens() {
        launch()
        app.buttons["Einstellungen"].tap()
        // Settings spans about fifteen screens at AX5; keep small, non-skipping scroll steps.
        reveal(app.buttons["Lizenzen"], attempts: 80)
        app.buttons["Lizenzen"].tap()
        XCTAssertTrue(app.navigationBars["Lizenzen"].waitForExistence(timeout: 4))
        capture("licenses-list")
        app.staticTexts["ntfy for iOS"].tap()
        let text = app.textViews["licenseText"]
        XCTAssertTrue(text.waitForExistence(timeout: 4))
        XCTAssertTrue((text.value as? String)?.contains("Permission is hereby granted") == true)
        XCTAssertFalse((text.value as? String)?.contains("Hiermit wird jeder Person") == true)
        // The file wraps "copy" and "of" onto separate lines; on a phone the paragraph is shown reflowed.
        XCTAssertTrue((text.value as? String)?.contains("obtaining a copy of this software") == true)
        capture("license-mit-top")
        text.swipeUp(); capture("license-mit-bottom")
        app.navigationBars.buttons["Lizenzen"].tap()
        app.staticTexts["Firebase"].tap()
        XCTAssertTrue(text.waitForExistence(timeout: 4))
        XCTAssertTrue((text.value as? String)?.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION") == true)
        capture("license-apache-top")
        text.swipeUp(); capture("license-apache-middle")
    }

    func testGermanCompactHeaders() {
        launch()
        app.buttons["Neues Abo"].tap()
        XCTAssertTrue(app.navigationBars["Abo"].waitForExistence(timeout: 4))
        capture("compact-add")
        reveal(app.buttons["QR-Code scannen"])
        app.buttons["QR-Code scannen"].tap()
        XCTAssertTrue(app.navigationBars["Scannen"].waitForExistence(timeout: 4))
        capture("compact-scanner")
        app.navigationBars["Scannen"].buttons["Abbrechen"].tap()
        app.navigationBars["Abo"].buttons["Abbrechen"].tap()
        app.buttons["Einstellungen"].tap()
        reveal(app.buttons["Neues Konto"])
        app.buttons["Neues Konto"].tap()
        XCTAssertTrue(app.navigationBars["Konto"].waitForExistence(timeout: 4))
        capture("compact-account")
        app.buttons["Abbrechen"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS 'accessibility-user'")).firstMatch
        reveal(saved, up: false); saved.tap()
        XCTAssertTrue(app.navigationBars["Konto"].waitForExistence(timeout: 4))
        capture("compact-edit")
        app.terminate()
        testGermanAddLoginChoices()
    }

}

private extension XCTestCase {
    /// Exercise the automatic update path with the subscribed run.py fixture, not a manual sheet.
    func verifyVersion124UpdateSheet(app: XCUIApplication, german: Bool) {
        let language = german ? ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
                              : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + ["-ntfyDebugLastSeenVersion", "1.23.0",
                                         "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Erlauben"] {
            if springboard.buttons[label].waitForExistence(timeout: 1) { springboard.buttons[label].tap() }
        }
        XCTAssertTrue(app.navigationBars[german ? "Neuigkeiten" : "What's new"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["1.24.0"].exists)
        XCTAssertFalse(app.staticTexts["1.23.0"].exists, "only the unseen release should be shown")
        let bullets: [String] = german ? [
            "Beim nächsten Abruf werden durch ausgebliebene Pushs verpasste Nachrichten aus dem Servercache geladen.",
            "Lies gespeicherte Nachrichten eines Themas mit „Nachrichten lesen“ in der App „Kurzbefehle“.",
            "Abonniere „Im Konto gespeicherte Themen“, wenn du beim Server angemeldet bist.",
            "Der Benachrichtigungsstatus zeigt jetzt iOS-Einstellungen, die Hinweise ausblenden oder verzögern.",
            "Die Themendetails zeigen, wann du ein Thema abonniert hast. Bei älteren Abos steht „Unbekannt“.",
            "Lange Links funktionieren vollständig. Text wird normal umbrochen und Markdown-Code folgt der Textgröße."
        ] : [
            "The next poll fetches messages missed by dropped pushes, while they remain in the server cache.",
            "Use Read messages in Shortcuts to read stored messages from a topic.",
            "Choose Topics saved in account when adding a subscription on a server you are signed in to.",
            "Notification status now shows iOS settings that hide or delay alerts.",
            "See when you subscribed in Topic details. Older subscriptions show Unknown.",
            "Long message links work in full, words wrap normally, and Markdown code follows text size changes."
        ]
        var renderedGerman = ""
        func capture(_ page: Int, suffix: String? = nil) {
            let name = (german ? "de" : "en") + "-whats-new-1.24-" + (suffix ?? "page-\(page)")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + ".txt"; tree.lifetime = .keepAlways; add(tree)
            let screenshot = app.screenshot()
            if german {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["de-DE"]
                XCTAssertNoThrow(try VNImageRequestHandler(data: screenshot.pngRepresentation, options: [:]).perform([request]))
                renderedGerman += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") + " "
            }
            let shot = XCTAttachment(screenshot: screenshot)
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        var seen = Set<String>()
        let next = app.buttons[german ? "Weiter" : "Continue"]
        for page in 0..<20 {
            // Identifier shorthand rejects strings over 128 characters, common in release notes.
            for bullet in bullets where app.staticTexts.matching(NSPredicate(format: "label == %@", bullet)).firstMatch.exists {
                seen.insert(bullet)
            }
            capture(page)
            if next.isHittable && app.frame.contains(next.frame) { break }
            // Keep enough overlap that OCR sees each ending phrase within one captured viewport.
            let scroll = app.scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        XCTAssertEqual(seen, Set(bullets), "all six release bullets must resolve in the selected language")
        if german {
            // AX retains the complete label even when SwiftUI draws an ellipsis. Inspect pixels too.
            let words = renderedGerman.lowercased().components(separatedBy: CharacterSet.letters.inverted).joined()
            for ending in ["servercachegeladen", "derappkurzbefehle", "angemeldetbist", "ausblendenoderverzögern", "unbekannt", "folgtdertextgröße"] {
                XCTAssertTrue(words.contains(ending), "Each German bullet must render its final word (\(ending)): \(renderedGerman)")
            }
        }
        XCTAssertTrue(next.isHittable)
        XCTAssertTrue(app.frame.contains(next.frame), "The complete Continue button must be visible")
        next.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars[german ? "Neuigkeiten" : "What's new"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "Continue must dismiss the release sheet, not just reveal its underlying navigation bar")
        XCTAssertTrue(app.navigationBars[german ? "Abonnierte Themen" : "Topics"].waitForExistence(timeout: 5))
        capture(0, suffix: "dismissed")
    }
}

/// After-only captures for the small-elements fix round (VERDICT-small.md): the destructive dialogs
/// anchored to what opened them, Remove password, select mode, the copied toast, What's new and the
/// message-row swipes and menu. Screenshots regardless of outcome; each state is tried once.
extension NavigationPilotUITests {
    /// Dismisses a confirmation: its Cancel button as an action sheet, or a tap outside as a popover.
    func dismissDialog() {
        if !tapFirst(["Cancel"], timeout: 1) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        }
        pause()
    }
    /// Scrolls an open menu until `label` can be tapped: a drag inside the menu, from its lower
    /// half up, so the scrolled-off destructive section comes into view.
    func revealMenuItem(_ label: String) -> Bool {
        let item = app.buttons[label].firstMatch
        for _ in 0..<4 {
            if item.exists && item.isHittable { return true }
            guard let anchor = ["Topic details", "End-to-end encryption", "Rename", "Notification sound",
                                "Alert if quiet", "Mute topic", "Show QR code"]
                .map({ app.buttons[$0].firstMatch }).first(where: { $0.exists && $0.isHittable }) else { break }
            anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -4)))
            pause(0.4)
        }
        return item.exists && item.isHittable
    }
    /// A message row by its title. The row's text is one combined element, so match by label
    /// rather than an exact static-text identifier.
    func messageRow(_ title: String) -> XCUIElement {
        let contains = NSPredicate(format: "label CONTAINS %@", title)
        let cell = app.cells.matching(contains).firstMatch
        if cell.waitForExistence(timeout: 1.5) { return cell }
        return app.staticTexts.matching(contains).firstMatch
    }
    /// A horizontal drag across the screen at `row`'s height, for the row's swipe actions.
    func swipeAcross(_ row: XCUIElement, right: Bool) {
        let window = app.windows.firstMatch.frame
        let y = row.frame.midY
        let x0 = row.frame.minX, x1 = min(row.frame.maxX, window.maxX)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: right ? x0 + 40 : x1 - 40, dy: y))
        let to = origin.withOffset(CGVector(dx: right ? x0 + (x1 - x0) * 0.7 : x0 + (x1 - x0) * 0.3, dy: y))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0.1)
    }
    func tapCenter(_ element: XCUIElement) {
        guard element.exists else { return }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: element.frame.midX, dy: element.frame.midY)).tap()
    }
    func testSmallFixCapture() {
        continueAfterFailure = true
        app.launchArguments = ["-ntfyDebugLastSeenVersion", "1.22.0", "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 2) { springboard.buttons["Allow"].tap() }
        if app.navigationBars["What's new"].waitForExistence(timeout: 8) {
            pause(); shot("whats-new-3"); app.buttons["Continue"].firstMatch.tap(); pause()
        }
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 8))
        pause(1.2)

        ensureTopic()
        shot("topic-pushed")

        // The More menu, top and scrolled to its destructive section.
        if openTopicMenu() {
            shot("topic-menu")
            if revealMenuItem("Unsubscribe") { shot("topic-menu-destructive") }
            app.tapCoordinateOutsideMenu(); pause()
        }
        // Clear all and Unsubscribe, each anchored to More.
        for (item, name) in [("Clear all notifications", "confirm-clear"), ("Unsubscribe", "confirm-unsubscribe")] {
            ensureTopic()
            if openTopicMenu() {
                if revealMenuItem(item) { app.buttons[item].firstMatch.tap(); pause(); shot(name); dismissDialog() }
                else { app.tapCoordinateOutsideMenu(); pause() }
            }
        }

        // The copied toast, in three frames across its 1.5 s.
        ensureTopic()
        if openTopicMenu() {
            if tapFirst(["Copy publish URL"]) {
                pause(0.15); shot("toast-copied-a"); pause(0.35); shot("toast-copied-b"); pause(0.5); shot("toast-copied-c"); pause(1.5)
            } else { app.tapCoordinateOutsideMenu() }
        }

        // A message row: its context menu, then the system swipes.
        ensureTopic()
        let message = messageRow("Deploy finished")
        if message.waitForExistence(timeout: 2) {
            message.press(forDuration: 1.0); pause(); shot("message-context-menu"); app.tapCoordinateOutsideMenu(); pause()
            swipeAcross(message, right: false); pause(); shot("message-swipe-trailing"); swipeAcross(message, right: true); pause()
            swipeAcross(message, right: true); pause(); shot("message-swipe-leading"); swipeAcross(message, right: false); pause()
        } else { shot("message-row-not-found") }

        // Select mode: one, then two rows by title, then the delete confirmation anchored to Delete.
        ensureTopic()
        if openTopicMenu() {
            if tapFirst(["Select messages"]) {
                pause()
                tapCenter(messageRow("Deploy finished"))
                pause(0.5); shot("select-1")
                tapCenter(messageRow("Nightly report"))
                pause(0.5); shot("select-2")
                let delete = app.buttons["select-delete"].firstMatch
                if delete.exists && delete.isHittable { delete.tap(); pause(); shot("select-delete-confirm"); dismissDialog() }
                tapFirst(["Done"]); pause()
            } else { app.tapCoordinateOutsideMenu() }
        }

        // Encryption: set a generated password, then ask to remove it.
        ensureTopic()
        if openTopicMenu() {
            let before = barIDs()
            if tapFirst(["End-to-end encryption"]) {
                pause()
                if tapFirst(["Generate strong password"]) { pause(0.4) }
                let save = app.buttons["Save password"].firstMatch
                scrollUntilHittable(save, max: 3)
                if save.exists && save.isHittable { save.tap(); pause() }
                let remove = app.buttons["Remove password"].firstMatch
                scrollUntilHittable(remove, max: 3)
                if remove.exists && remove.isHittable { remove.tap(); pause(); shot("confirm-remove-password"); dismissDialog() }
                closeSheet(since: before)
            } else { app.tapCoordinateOutsideMenu() }
        }
    }
}
