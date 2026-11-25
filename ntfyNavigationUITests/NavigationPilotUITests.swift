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
        openTopics()
    }
    /// The app opens on Inbox (1.26); the topic list is the second tab.
    func openTopics() {
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8), "the app shows a screen")
        if app.navigationBars["Topics"].exists { return }
        tab("Topics")
        // Tapping the selected tab returns its stack to the root.
        if !app.navigationBars["Topics"].waitForExistence(timeout: 2) { tab("Topics") }
        XCTAssertTrue(app.navigationBars["Topics"].waitForExistence(timeout: 5))
    }
    func launchList() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 1) { springboard.buttons["Allow"].tap() }
        openTopics()
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
        // 1.26 (A1): a muted row carries the bell.slash mark, spoken "Muted"; the duration lives on the topic's page.
        // Scoped to this row: earlier tests can leave another topic muted.
        let status = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "aaa-nav-000", "Muted")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        muteScreenshot("muted-topic-list")
        app.terminate(); app.launch()
        openTopics() // 1.26: the app opens on Inbox
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
        openTopics()
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
        openTopics()
        guard !app.staticTexts["aaa-nav-000"].exists else { throw XCTSkip("Run with --seed --empty-fixture") }
        captureAX("empty-topic-list")
        XCTAssertTrue(app.staticTexts["No topics yet"].exists)
    }
    /// Settings, "Use buttons without unlocking": off by default, and one tap turns it on.
    func testCaptureLockScreenButtonsSetting() {
        launchList()
        tab("Settings")
        let toggle = app.switches["settings-buttons-without-unlocking"]
        for _ in 0..<8 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "0")
        captureAX("lockscreen-buttons-off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        captureAX("lockscreen-buttons-on")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
    /// The ntfy.sh bridge: its Settings toggle and disclosure, its Notification status rows, and the
    /// add-topic footers for ntfy.sh and for a self-hosted server.
    func testCaptureNtfyShBridge() {
        launchList()
        tab("Settings")
        let toggle = app.switches["settings-ntfysh-bridge"]
        for _ in 0..<8 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        app.swipeUp(velocity: .slow)
        if !toggle.isHittable { app.swipeDown(velocity: .slow) }
        captureAX("bridge-setting")
        let watched = app.staticTexts["ntfy.sh"].firstMatch
        for _ in 0..<8 { if watched.exists && watched.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(watched.exists)
        captureAX("bridge-status")
        tab("Topics")
        tapEither("Add topic", "Add")
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
        let other = app.switches["Use another server"].firstMatch
        for _ in 0..<4 where !other.exists || !other.isHittable { app.collectionViews.firstMatch.swipeUp() }
        other.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let server = app.textFields["subscription-server-url"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 3))
        server.tap()
        app.typeText("https://ntfy.sh")
        app.navigationBars["Add topic"].tap()
        captureAX("add-footer-ntfysh")
        server.tap()
        server.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        app.typeText("https://ntfy.example.com")
        app.navigationBars["Add topic"].tap()
        captureAX("add-footer-selfhosted")
        app.buttons["Cancel"].tap()
    }
    /// 1.30: Notification status per server, each topic without banners and why, and the same
    /// reason in Topic details. Needs `seed130.py`'s fixture (no live bridge or ntfy.sh calls).
    /// `NTFY_130_VARIANT=off|full` names the captures for the other fixtures.
    func testCaptureBridgeStates130() {
        let variant = ProcessInfo.processInfo.environment["NTFY_130_VARIANT"] ?? "main"
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 1) { springboard.buttons["Allow"].tap() }
        openTopics()
        tab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let first = app.staticTexts["ntfy.sh"].firstMatch
        for _ in 0..<10 { if first.exists && first.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(first.exists, "the ntfy.sh group row")
        captureAX("b130-status-\(variant)")
        let last = app.otherElements["bridge-held-garage"].firstMatch
        if !(last.exists && last.isHittable) { app.swipeUp(velocity: .slow); captureAX("b130-status-\(variant)-more") }
        guard variant == "main" else { return }
        for topic in ["family-private-q7x", "garage"] {
            // A fresh launch for each topic; the sheet's close control differs between iPhone and iPad.
            app.terminate(); app.launch()
            openTopics()
            let row = app.staticTexts[topic].firstMatch
            for _ in 0..<6 { if row.exists && row.isHittable { break }; app.swipeUp() }
            row.tap()
            app.navigationBars.buttons["Topic actions"].tap()
            app.buttons["Topic details"].tap()
            XCTAssertTrue(app.staticTexts["Instant banners"].waitForExistence(timeout: 5))
            captureAX("b130-details-\(topic)")
        }
    }
    /// 1.31 direct server watch, from the fixture `DirectWatchCaptureSeed` writes: the offer under a
    /// server sending no wake-ups, then servers watched directly (connected with a topic that needs a
    /// login, unreachable, connecting), then a server's Advanced switch. NTFY_131_LANG picks a language.
    func testCaptureDirectWatch131() {
        let lang = ProcessInfo.processInfo.environment["NTFY_131_LANG"] ?? "en"
        app.launchArguments = ["-AppleLanguages", "(\(lang))", "-ntfyDebugLastSeenVersion", "1.30.0",
                               "-notificationPermissionPrimerOffered", "YES"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 1) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15), "the app shows a screen")
        let settings = lang == "de" ? "Einstellungen" : "Settings"
        tab(settings)
        // Under heavy load the first tap can land before the tab bar answers (fix round 3 captures).
        if !app.navigationBars[settings].waitForExistence(timeout: 5) { tab(settings) }
        XCTAssertTrue(app.navigationBars[settings].waitForExistence(timeout: 10))
        let anchor = app.descendants(matching: .any)["bridge-held-alerts"].firstMatch
        for _ in 0..<14 { if anchor.exists && anchor.isHittable { break }; app.swipeUp(velocity: .slow) }
        // Half-screen steps from the first held topic down to the Servers section, one capture each.
        let server = app.descendants(matching: .any)["settings-server-nas.example.org"].firstMatch
        let window = app.windows.firstMatch
        for step in 0..<16 {
            captureAX("d131-\(lang)-step\(step)")
            if server.exists && server.isHittable { break }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.33)))
            pause(0.6)
        }
        server.tap()
        XCTAssertTrue(app.switches["server-direct-watch"].waitForExistence(timeout: 5))
        captureAX("d131-\(lang)-advanced")
    }
    func testCaptureSavedUserRow() {
        app.launch()
        openTopics()
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
        openTopics()
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
    /// Taps an item low in the open topic menu, scrolling the menu when the item is below its fold
    /// (on iPad the menu is shorter than its items and the destructive section starts hidden).
    func tapMenuItem(_ label: String) -> Bool {
        let item = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        guard item.waitForExistence(timeout: 3) else { return false }
        let menu = app.collectionViews.containing(NSPredicate(format: "label == 'Send test'")).firstMatch
        for _ in 0..<3 where !item.isHittable && menu.exists {
            menu.swipeUp(velocity: .slow); pause(0.5)
        }
        XCTContext.runActivity(named: "MENUITEM \(label) frame \(item.frame) hittable \(item.isHittable)") { _ in }
        item.tap(); pause(0.8)
        return true
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
        openTopics()
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
        closeSheet()
        if !app.navigationBars["Topics"].exists { openTopics() }
        let noticeTopic = app.staticTexts["aaa-nav-001"].firstMatch
        scrollUntilHittable(noticeTopic, max: 2)
        if noticeTopic.exists && noticeTopic.isHittable { noticeTopic.tap(); pause() }
        // Mute only aaa-nav-001: a mute left on aaa-nav-000 breaks the mute-menu test that follows.
        if app.navigationBars.staticTexts["aaa-nav-001"].waitForExistence(timeout: 3),
           openTopicMenu(), tapFirst(["Mute topic"]) { pause(); tapFirst(["1 hour"]); pause(1.2) }
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
        XCTAssertTrue(app.navigationBars[german ? "Eingang" : "Inbox"].waitForExistence(timeout: 5), "1.26 opens on Inbox")
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
        openTopics()
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

/// 1.26 Inbox captures and the notification-to-message route, run on the inbox-seed.py fixture
/// (agent topics, waiting questions whose answers go to a local hook on port 8765).
extension NavigationPilotUITests {
    func launchInbox() {
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 2) { springboard.buttons["Allow"].tap() }
        if app.navigationBars["What's new"].waitForExistence(timeout: 3) { app.buttons["Continue"].firstMatch.tap(); pause() }
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 8))
        pause(1.5)
    }
    func tab(_ name: String) {
        let label = NSPredicate(format: "label == %@", name)
        var button = app.tabBars.buttons.matching(label).firstMatch
        if !button.exists && app.tabBars.buttons.firstMatch.exists {
            // Scrolling down minimizes the iOS 26 tab bar to the selected tab; a tap expands it.
            app.tabBars.buttons.firstMatch.tap(); pause(0.8)
            button = app.tabBars.buttons.matching(label).firstMatch
        }
        // On iPad the tabs sit in the top bar, outside any tab bar element; Search shows as an image.
        if !button.exists { button = app.buttons.matching(label).firstMatch }
        if !button.exists { button = app.images.matching(label).firstMatch }
        button.tap()
        pause(1)
    }
    func navButton(_ label: String) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    /// Scrolls the visible list back to its top (small screens and AX sizes scroll a lot).
    func toTop() {
        for _ in 0..<6 { app.swipeDown() }
        pause(0.5)
    }
    /// Scrolls until a button with this label can be tapped, then taps it.
    @discardableResult func tapScrolling(_ label: String) -> Bool {
        let button = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        if !(button.exists && button.isHittable) { toTop() }
        scrollUntilHittable(button, max: 10)
        guard button.exists && button.isHittable else { return false }
        button.tap(); return true
    }
    func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
    }
    func openText(_ text: String) {
        let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if !(element.exists && element.isHittable) { toTop() }
        scrollUntilHittable(element, max: 10)
        // A row under the translucent bar still reports hittable, but the tap lands on the bar.
        let bar = app.navigationBars.firstMatch
        for _ in 0..<3 where bar.exists && element.exists && element.frame.minY < bar.frame.maxY + 8 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)))
            pause(0.6)
        }
        element.tap()
        pause(1.2)
    }

    func testInboxCapture() {
        continueAfterFailure = true
        launchInbox()
        captureAX("inbox")
        XCTAssertTrue(app.otherElements["waiting-header"].exists || app.staticTexts["Waiting on you"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Muted topic'")).firstMatch.exists,
                       "a muted topic stays out of Activity")
        app.swipeUp(); pause(); shot("inbox-activity")
        app.swipeUp(); pause(); shot("inbox-activity-2")
        app.swipeDown(); app.swipeDown(); app.swipeDown(); pause()

        let showAll = app.buttons["waiting-show-all"].firstMatch
        if showAll.waitForExistence(timeout: 2) { showAll.tap(); pause(1.2); shot("waiting-all"); back() }

        // Receipts: a request that can't connect, one the hook holds, one it answers.
        if tapScrolling("Retry") { pause(0.3); shot("receipt-failed-sending") }
        XCTAssertTrue(app.staticTexts["Didn't reach the agent. Try again."].waitForExistence(timeout: 5), "a failure says so, never a check")
        pause(0.5); shot("receipt-failed")
        if tapScrolling("Roll back") { pause(0.3); shot("receipt-sending") }
        if tapScrolling("Approve") { pause(0.7); shot("receipt-answered") }
        pause(3); shot("inbox-after-answers")

        // The page: a long report from its card's Show more, then a question with its answer bar.
        let more = app.buttons["card-show-more"].firstMatch
        scrollUntilHittable(more, max: 8)
        if more.exists { more.tap(); pause(1.2); captureAX("page-report"); app.swipeUp(); pause(); shot("page-report-2"); back() }
        app.swipeDown(); app.swipeDown(); pause()
        openText("Front door is unlocked"); captureAX("page-question"); back()
        openText("Which branch should I release from?")
        let field = app.textFields["reply-field"].firstMatch.exists ? app.textFields["reply-field"].firstMatch : app.textViews["reply-field"].firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap(); app.typeText("release/1.26"); pause(); shot("page-reply-typing")
            app.buttons["reply-send"].firstMatch.tap(); pause(1.5); shot("receipt-replied")
        }
        back()

        tab("Topics"); captureAX("topics")
        openText("claude-code"); shot("topic-claude-code")
        app.swipeUp(); pause(); shot("topic-claude-code-2")
        if openTopicMenu() {
            shot("topic-menu")
            if tapFirst(["Connect an agent"]) {
                pause(1.2); captureAX("connect-sheet")
                app.swipeUp(); pause(); shot("connect-sheet-2")
                app.buttons["connect-done"].firstMatch.tap(); pause()
            } else { app.tapCoordinateOutsideMenu() }
        }
        back()
        openText("deploys"); app.swipeUp(); pause(); shot("topic-image"); back()

        // Add topic, two steps.
        tapFirst(["Add topic", "Add"])
        XCTAssertTrue(app.navigationBars["Add topic"].waitForExistence(timeout: 5))
        shot("add-step1")
        // The fixture's default server is unreachable; the local hook answers as an open server.
        // The server goes in first, before any keyboard is up: at large sizes on a small screen
        // the keyboard covers the switch and the form builds its rows lazily.
        let other = app.switches["Use another server"].firstMatch
        for _ in 0..<4 where !other.exists || !other.isHittable { app.collectionViews.firstMatch.swipeUp(); pause(0.4) }
        if other.exists {
            other.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); pause(0.5)
            let server = app.textFields["subscription-server-url"].firstMatch
            // At accessibility sizes the label wraps and the switch no longer sits at the row's
            // right middle: tap the switch control itself.
            if !server.waitForExistence(timeout: 1), (other.value as? String) != "1" {
                let knob = other.switches.firstMatch
                if knob.exists { knob.tap() } else { other.tap() }
                pause(0.5)
            }
            // The new row is built lazily too: below the fold at large sizes it isn't there until scrolled to.
            for _ in 0..<4 where !server.exists { app.collectionViews.firstMatch.swipeUp(); pause(0.4) }
            if server.waitForExistence(timeout: 2) {
                server.tap(); pause(0.3)
                app.typeText("http://127.0.0.1:8765"); pause(0.5)
                XCTAssertEqual(server.value as? String, "http://127.0.0.1:8765", "the server URL lands in the server field")
            }
        }
        let name = app.textFields["Topic name"].firstMatch
        for _ in 0..<4 where !name.isHittable { app.collectionViews.firstMatch.swipeDown(); pause(0.4) }
        name.tap(); app.typeText("my-agent"); pause(); shot("add-step1-filled")
        tapFirst(["Subscribe"])
        if app.buttons["Not now"].waitForExistence(timeout: 4) { shot("add-primer"); app.buttons["Not now"].tap() }
        let reachedStep2 = app.staticTexts["connect-instructions"].waitForExistence(timeout: 8) || app.otherElements["connect-instructions"].exists
        if reachedStep2 {
            pause(); captureAX("add-step2")
            app.swipeUp(); pause(); shot("add-step2-bottom")
            app.buttons["connect-done"].firstMatch.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["my-agent"].waitForExistence(timeout: 8), "Done opens the new topic")
            pause(1.2); shot("add-new-topic")
        } else {
            // Named for what it shows: step 1 still up, so no step-2 picture comes from it.
            shot("add-step1-not-reached-step2")
            XCTFail("Subscribe didn't reach step 2")
            tapFirst(["Cancel"]); pause()
        }

        tab("Search"); shot("search-prompt")
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap(); app.typeText("migration"); pause(1.5); shot("search-results")
        }
    }

    /// Run on the inbox fixture seeded with --empty.
    /// The waiting count in the header, "Waiting on you, 12".
    func waitingCount() -> Int {
        let header = app.descendants(matching: .any)["waiting-header"].firstMatch
        guard header.waitForExistence(timeout: 2) else { return -1 }
        return Int(header.label.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.last ?? "") ?? -1
    }

    /// Taps a point in the top probe question's row and says what happened: "opened" (the page),
    /// "answered" (the question left Waiting), both, or "nothing".
    func probeTap(_ name: String, at point: (_ body: CGRect, _ approve: CGRect, _ reject: CGRect) -> CGPoint) -> String {
        toTop()
        let body = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Probe body'")).firstMatch
        guard body.waitForExistence(timeout: 3) else { return "no-probe-left" }
        let below = { [self] (label: String) -> XCUIElement? in
            app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
                .filter { $0.frame.minY > body.frame.maxY - 1 }.min { $0.frame.minY < $1.frame.minY }
        }
        guard let approve = below("Approve"), let reject = below("Reject") else { return "no-buttons" }
        let before = waitingCount()
        let p = point(body.frame, approve.frame, reject.frame)
        print("TAPPROBE \(name) body=\(body.frame) approve=\(approve.frame) reject=\(reject.frame) tap=\(p)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
        pause(1.0)
        let opened = app.buttons["message-actions"].exists
        if opened { back() }
        pause(3)
        let answered = waitingCount() < before
        let result = opened && answered ? "opened+answered" : opened ? "opened" : answered ? "answered" : "nothing"
        print("TAPPROBE \(name) -> \(result)")
        XCTContext.runActivity(named: "TAPPROBE \(name) -> \(result)") { _ in }
        return result
    }

    /// The iPad check of build 45: a tap on a waiting question's text answered it. Only a deliberate
    /// tap on an answer button may answer an agent; everywhere else in the row opens the page.
    func testWaitingRowOnlyTheButtonAnswers() {
        continueAfterFailure = true
        launchInbox()
        let off: [(String, (CGRect, CGRect, CGRect) -> CGPoint)] = [
            ("body-centre", { b, _, _ in CGPoint(x: b.midX, y: b.midY) }),
            ("16pt-above-bar", { _, a, _ in CGPoint(x: a.midX, y: a.minY - 16) }),
            ("8pt-above-bar", { _, a, _ in CGPoint(x: a.midX, y: a.minY - 8) }),
            ("4pt-above-bar", { _, a, _ in CGPoint(x: a.midX, y: a.minY - 4) }),
            ("gap-between-buttons", { _, a, r in CGPoint(x: (a.maxX + r.minX) / 2, y: a.midY) }),
            ("4pt-below-bar", { _, a, _ in CGPoint(x: a.midX, y: a.maxY + 4) }),
        ]
        for (name, point) in off {
            let result = probeTap(name, at: point)
            XCTAssertEqual(result, "opened", "a tap at \(name) must open the page, never answer")
        }
        XCTAssertEqual(probeTap("approve-centre") { _, a, _ in CGPoint(x: a.midX, y: a.midY) }, "answered",
                       "a tap on the button itself answers")
    }

    /// Clear all on Waiting on you (operator, 2026-11-24: "tap and hold on waiting on you to bring up the
    /// menu that has clear all ... and then it has a confirmation"). Touch and hold the header, the "…"
    /// and Show all's Clear all each open the same "Are you sure?"; Cancel keeps every question, Clear
    /// all empties Waiting and offers Undo. Needs inbox_seed.py --tapprobe (more than three waiting).
    func testClearWaitingTouchAndHoldAsksFirst() {
        continueAfterFailure = false
        launchInbox()
        let header = app.buttons["waiting-header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 8), "the fixture has questions waiting")
        // The fold is kept across launches; start with the section open.
        if (header.value as? String) == "Collapsed" { header.tap(); pause() }
        let alert = app.alerts.firstMatch
        let asks = NSPredicate(format: "label BEGINSWITH 'Clear all' AND label ENDSWITH 'from Waiting on you?'")
        func menuClearAll() {
            let item = app.buttons.matching(NSPredicate(format: "label == 'Clear all'")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 4), "the menu offers Clear all")
            item.tap()
        }
        func cancel() {
            XCTAssertTrue(alert.buttons["Cancel"].waitForExistence(timeout: 2))
            alert.buttons["Cancel"].tap(); pause()
            XCTAssertFalse(alert.exists)
            XCTAssertTrue(header.exists, "Cancel keeps every question")
        }

        // 1. Touch and hold the header: menu, then the question.
        header.press(forDuration: 1.3)
        pause(0.6); shot("clear-waiting-1-menu")
        menuClearAll()
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Clear all asks first")
        XCTAssertTrue(alert.staticTexts.matching(asks).firstMatch.exists, "the question names the count and the section")
        shot("clear-waiting-2-confirm")
        cancel()

        // 2. Show all's Clear all asks the same.
        let showAll = app.buttons["waiting-show-all"].firstMatch
        XCTAssertTrue(showAll.waitForExistence(timeout: 3), "more than three are waiting")
        showAll.tap()
        let pageClear = app.buttons["waiting-clear-all"].firstMatch
        XCTAssertTrue(pageClear.waitForExistence(timeout: 5))
        pageClear.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Show all's Clear all asks first")
        alert.buttons["Cancel"].tap(); pause()
        XCTAssertTrue(pageClear.exists, "Cancel keeps Show all's questions")
        app.navigationBars.buttons.firstMatch.tap(); pause()

        // 3. The "…" opens the same menu; confirm this time.
        let more = app.buttons["waiting-more"].firstMatch
        XCTAssertTrue(app.navigationBars["Inbox"].waitForExistence(timeout: 5))
        // Back from Show all can leave the Inbox scrolled past its header; scroll up as a person would.
        for _ in 0..<4 where !(more.exists && more.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            pause(0.8)
        }
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        // The "…" sits left of the count and chevron (operator, 2026-11-25), not at the row's end:
        // the title ends where it starts, and the count (2 digits) and chevron still follow it.
        let headerButton = app.buttons["waiting-header"].firstMatch
        XCTAssertLessThanOrEqual(headerButton.frame.maxX, more.frame.minX + 1, "the title comes before the …")
        XCTAssertLessThan(more.frame.maxX, app.windows.firstMatch.frame.maxX - 40, "the count and chevron come after the …")
        more.tap()
        menuClearAll()
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "the … route asks first")
        alert.buttons["waiting-clear-confirm"].firstMatch.tap()
        let undo = app.buttons["waiting-undo-clear"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "Undo follows the clear")
        XCTAssertFalse(header.exists, "Waiting on you is empty")
        shot("clear-waiting-3-cleared")
        undo.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5), "Undo brings the questions back")
    }

    /// The iPad check of build 45: Topic actions > Unsubscribe closed the menu and no confirmation
    /// came. Both destructive items of the topic menu must ask first, on iPad and iPhone.
    func testTopicMenuConfirmationsShow() {
        continueAfterFailure = true
        launchInbox()
        tab("Topics")
        openText("nightly-ci")
        XCTAssertTrue(app.navigationBars.buttons["Topic actions"].waitForExistence(timeout: 5))

        XCTAssertTrue(openTopicMenu())
        XCTAssertTrue(tapMenuItem("Clear all notifications"), "Clear all is in the menu")
        let clearTitle = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Delete all messages in'")).firstMatch
        XCTAssertTrue(clearTitle.waitForExistence(timeout: 3), "Clear all asks first")
        shot("clear-all-confirm")
        // Dismiss without deleting: Cancel on iPhone, a tap outside the popover on iPad.
        if !tapFirst(["Cancel"]) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap() }
        pause()

        XCTAssertTrue(openTopicMenu())
        XCTAssertTrue(tapMenuItem("Unsubscribe"), "Unsubscribe is in the menu")
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Unsubscribe from'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3), "Unsubscribe asks first")
        shot("unsubscribe-confirm")
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Unsubscribe'")).allElementsBoundByIndex.last
        confirm?.tap(); pause(1.5)
        XCTAssertFalse(app.staticTexts["nightly-ci"].exists && app.navigationBars.buttons["Topic actions"].exists,
                       "the topic page closes after unsubscribing")
        shot("after-unsubscribe")
    }

    /// The same check on a topic's message cards.
    func testTopicCardOnlyTheButtonAnswers() {
        continueAfterFailure = true
        launchInbox()
        tab("Topics")
        openText("deploys")
        let receipts = NSPredicate(format: "label BEGINSWITH 'You tapped'")
        let cases: [(String, (CGRect, CGRect) -> CGPoint, String)] = [
            ("card-body-centre", { b, _ in CGPoint(x: b.midX, y: b.midY) }, "opened"),
            ("card-8pt-above-bar", { _, a in CGPoint(x: a.midX, y: a.minY - 8) }, "opened"),
            ("card-approve-centre", { _, a in CGPoint(x: a.midX, y: a.midY) }, "answered"),
        ]
        for (index, (name, point, expected)) in cases.enumerated() {
            toTop()
            let body = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Probe body \(index):")).firstMatch
            scrollUntilHittable(body, max: 6)
            guard body.exists else { XCTFail("no probe card \(index)"); continue }
            let approve = app.buttons.matching(NSPredicate(format: "label == 'Approve'")).allElementsBoundByIndex
                .filter { $0.frame.minY > body.frame.maxY - 1 }.min { $0.frame.minY < $1.frame.minY }
            guard let approve else { XCTFail("no Approve under probe card \(index)"); continue }
            let before = app.staticTexts.matching(receipts).count
            let p = point(body.frame, approve.frame)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
            pause(1.0)
            let opened = app.buttons["message-actions"].exists
            if opened { back() }
            pause(1.0)
            let answered = app.staticTexts.matching(receipts).count > before
            let result = opened && answered ? "opened+answered" : opened ? "opened" : answered ? "answered" : "nothing"
            XCTContext.runActivity(named: "TAPPROBE \(name) -> \(result)") { _ in }
            XCTAssertEqual(result, expected, "\(name)")
        }
    }

    /// An agent question with http answers only (no reply link) still takes a written answer:
    /// the page offers the reply field, and sending it shows the replied receipt.
    func testAgentReplyCapture() {
        continueAfterFailure = true
        launchInbox()
        openText("Front door is unlocked")
        let field = app.textFields["reply-field"].firstMatch.exists ? app.textFields["reply-field"].firstMatch : app.textViews["reply-field"].firstMatch
        if !field.exists { app.swipeUp(); pause() }
        let reply = app.textFields["reply-field"].firstMatch.exists ? app.textFields["reply-field"].firstMatch : app.textViews["reply-field"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 3), "an agent question offers the reply field")
        scrollUntilHittable(reply, max: 4)
        shot("agent-reply-field")
        guard reply.exists else { return }
        reply.tap(); app.typeText("Locked it from the app, thanks"); pause(); shot("agent-reply-typing")
        app.buttons["reply-send"].firstMatch.tap()
        let receipt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Reply sent'")).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 5), "the typed answer is recorded as a reply")
        pause(0.5); shot("agent-reply-sent")
    }

    /// `ntf ask --no-reply` and a typed reply (`re-<sequence>`): no reply field on the first, the second
    /// is not a question, and neither protocol tag shows anywhere.
    func testProtocolTagsCapture() {
        continueAfterFailure = true
        launchInbox()
        let hidden = NSPredicate(format: "label CONTAINS 're-q-door' OR label CONTAINS[c] 'no-reply'")
        XCTAssertTrue(app.staticTexts["Restart the router?"].firstMatch.waitForExistence(timeout: 3),
                      "a no-reply question still waits on its buttons")
        shot("protocol-inbox")
        XCTAssertFalse(app.staticTexts.matching(hidden).firstMatch.exists, "no protocol tag in Activity")
        tab("Topics"); openText("Home")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Locked it from the app'")).firstMatch
                        .waitForExistence(timeout: 3), "the reply shows on its topic")
        shot("protocol-topic-home")
        XCTAssertFalse(app.staticTexts.matching(hidden).firstMatch.exists, "no protocol tag on the topic's rows")
        openText("Restart the router?")
        XCTAssertTrue(app.buttons["Restart"].firstMatch.waitForExistence(timeout: 3), "the buttons still show")
        XCTAssertFalse(app.textFields["reply-field"].exists || app.textViews["reply-field"].exists,
                       "a no-reply question has no reply field")
        XCTAssertFalse(app.staticTexts.matching(hidden).firstMatch.exists, "no protocol tag on the page")
        shot("protocol-noreply-page")
    }

    /// Build 48, agent confirmations: the receipt on each kind of question, the list after the acks,
    /// and the same with "Show agent confirmations" off. q-live's ack comes from the hook's poll.
    func testAgentAckCapture() {
        continueAfterFailure = true
        launchInbox()
        let any = app.descendants(matching: .any)
        let hidden = NSPredicate(format: "label == 'ack' OR label CONTAINS 'Got it'")
        shot("ack-inbox")
        tab("Topics"); openText("Home")
        // The poll at launch may not have run yet: pull to refresh brings q-live's ack in.
        toTop(); pause(2)
        XCTAssertTrue(any["card-agent-got"].firstMatch.waitForExistence(timeout: 5), "the card shows the agent got it")
        shot("ack-home-list")
        app.swipeUp(); pause(0.6); shot("ack-home-list-2")
        XCTAssertFalse(app.staticTexts.matching(hidden).firstMatch.exists, "no ack tag or default body shows")
        let pages: [(String, String)] = [
            ("Front door is unlocked", "ack-page-button-acked-note"),
            ("Turn the heating down?", "ack-page-reply-acked-no-note"),
            ("Restart the media server?", "ack-page-acked-answered-elsewhere"),
            ("Garage door is open", "ack-page-button-not-acked"),
            ("Which Wi-Fi name", "ack-page-reply-not-acked"),
            ("Delete the old backups?", "ack-page-long-note"),
            ("Deploy the hotfix now?", "ack-page-failed-then-acked"),
            ("Publish the 2.4 release notes?", "ack-page-long-links"),
            ("Skip today's watering?", "ack-page-moved-on"),
            ("Porch lights are still on", "ack-page-old-settle"),
        ]
        for (title, name) in pages {
            openText(title)
            pause(1)
            shot(name)
            let receipt = any.matching(NSPredicate(format: "identifier BEGINSWITH 'receipt-'")).firstMatch
            // At accessibility sizes the receipt follows the text, under the tab bar: scroll to it.
            if receipt.exists && (!receipt.isHittable || receipt.frame.maxY > app.frame.height * 0.8) {
                for _ in 0..<4 where !receipt.isHittable || receipt.frame.maxY > app.frame.height * 0.8 {
                    app.swipeUp(); pause(0.8)
                }
                shot(name + "-end")
            }
            back()
        }
        XCTAssertTrue(any["card-agent-moved-on"].firstMatch.exists || any["card-agent-got"].firstMatch.exists)
        // Off: acks still close the question, but no receipt line or note shows.
        tab("Settings")
        let toggle = app.switches["settings-agent-confirmations"].firstMatch
        scrollUntilHittable(toggle, max: 10)
        shot("ack-settings-on")
        if toggle.exists { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        pause(0.8)
        XCTAssertEqual(toggle.value as? String, "0", "the toggle turned off")
        shot("ack-settings-off")
        tab("Topics"); pause(0.6)
        if !app.staticTexts["Front door is unlocked"].firstMatch.exists { openText("Home") }
        toTop()
        XCTAssertFalse(any["card-agent-got"].firstMatch.exists, "no receipt line with confirmations off")
        shot("ack-home-list-off")
        openText("Front door is unlocked"); pause(1)
        XCTAssertFalse(any["receipt-agent"].firstMatch.exists, "no agent line on the page")
        XCTAssertFalse(app.buttons["Lock"].firstMatch.exists, "the answered question takes no more answers")
        shot("ack-page-off")
        back()
        openText("Restart the media server?"); pause(1)
        XCTAssertFalse(app.buttons["Restart"].firstMatch.exists, "an acked question shows no buttons even unanswered here")
        XCTAssertTrue(any["receipt-closed"].firstMatch.exists, "with confirmations off it says Closed, not nothing")
        shot("ack-page-answered-elsewhere-off")
        back()
        openText("Deploy the hotfix now?"); pause(1)
        shot("ack-page-failed-then-acked-off")
        back()
        tab("Inbox"); pause(1)
        shot("ack-inbox-off")
    }

    func testInboxEmptyCapture() {
        launchInbox()
        captureAX("inbox-empty")
        XCTAssertTrue(app.buttons["Connect your first agent"].exists)
        tab("Topics"); captureAX("topics-empty")
        XCTAssertTrue(app.buttons["Connect your first agent"].exists)
    }

    /// A card tapped inside a topic opens its page, and the page stays until Back.
    func testTopicCardOpensAndStays() {
        launchInbox()
        tab("Topics"); openText("claude-code")
        openText("Run the database migration?")
        XCTAssertTrue(navButton("claude-code").waitForExistence(timeout: 5), "the page is pushed on its topic")
        pause(4)
        XCTAssertTrue(navButton("claude-code").exists, "the page stays open on its own")
        shot("topic-card-page")
    }
    /// A notification tap opens that message's page, one Back from its topic (DECISION change 7).
    func testNotificationOpensMessagePage() {
        app.launchEnvironment["NTFY_NAV_TOPIC"] = "claude-code"
        app.launchEnvironment["NTFY_NAV_MESSAGE_ID"] = "m-report"
        app.launchEnvironment["NTFY_NAV_BASE_URL"] = "http://127.0.0.1:1"
        launchInbox()
        let post = { CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("ntfy.navigation.fixture.response" as CFString), nil, nil, true) }
        post()
        // The Darwin post can be lost before the harness registers (seen at large text sizes:
        // no NAV_FIXTURE_RESPONSE_COMPLETED at all). Each post is a fresh notification id, so one repost is safe.
        // Only the message page has this menu; "What I found" alone can be an Inbox card (iPad shows it).
        let page = app.buttons["message-actions"].firstMatch
        if !page.waitForExistence(timeout: 6) { post() }
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the tapped message's page opens")
        XCTAssertTrue(app.staticTexts["What I found"].firstMatch.exists)
        XCTAssertTrue(navButton("claude-code").waitForExistence(timeout: 5), "Back leads to its topic")
        pause(4)
        XCTAssertTrue(page.exists, "the page stays open on its own")
        shot("notification-page")
        navButton("claude-code").tap()
        XCTAssertTrue(app.navigationBars.staticTexts["claude-code"].waitForExistence(timeout: 5))
        XCTAssertTrue(navButton("Topics").waitForExistence(timeout: 5))
        shot("notification-topic")
    }
}
