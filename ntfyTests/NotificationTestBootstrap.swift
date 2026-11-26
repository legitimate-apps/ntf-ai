// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import XCTest
import UserNotifications

/// Simulator bootstatus does not wait for the notification daemon's first-boot source import.
/// Keep that infrastructure wait outside the individual tests' short callback deadlines.
@objc final class NotificationTestBootstrap: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
#if targetEnvironment(simulator)
        let started = Date()
        print("NOTIFICATION_TEST_READINESS waiting for settings, categories and delivered notifications")
        let center = UNUserNotificationCenter.current()
        let settings = XCTestExpectation(description: "notification daemon settings readiness")
        let categories = XCTestExpectation(description: "notification daemon categories readiness")
        let delivered = XCTestExpectation(description: "notification daemon delivered-list readiness")
        center.getNotificationSettings { _ in settings.fulfill() }
        center.getNotificationCategories { _ in categories.fulfill() }
        center.getDeliveredNotifications { _ in delivered.fulfill() }
        let result = XCTWaiter.wait(for: [settings, categories, delivered], timeout: 180)
        guard result == .completed else {
            // This is an unusable test destination, not a reason to skip notification tests.
            fatalError("Notification daemon did not become ready within 180 seconds; aborting the test run (\(result.rawValue)).")
        }
        print("NOTIFICATION_TEST_READINESS ready after \(Date().timeIntervalSince(started)) seconds")
#endif
    }
}
