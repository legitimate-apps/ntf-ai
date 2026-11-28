// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import UIKit
import XCTest
@testable import ntfy

final class NetworkCatchUpTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var jobs: [(TimeInterval, () -> Void)] = []
    private var unreachable = true
    private var polls: [Bool] = []
    private var completions: [() -> Void] = []
    private lazy var policy = NetworkCatchUp(hasUnreachable: { self.unreachable }, poll: { recovery, done in
        self.polls.append(recovery); self.completions.append(done)
    }, now: { self.clock }, schedule: { self.jobs.append((self.clock + $0, $1)) })
    private func advance(_ seconds: TimeInterval) {
        let end = clock + seconds
        while let index = jobs.indices.filter({ jobs[$0].0 <= end }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let job = jobs.remove(at: index); clock = job.0; job.1()
        }
        clock = end
    }
    private func completeFirst() {
        guard !completions.isEmpty else { XCTFail("Expected an in-flight batch"); return }
        completions.removeFirst()()
    }
    private func activate(path: String? = "wifi") {
        policy.pathChanged(path); policy.activate()
        XCTAssertEqual(polls, [false]); completeFirst()
    }
    func testUnavailableToUsableDebouncesAndDeduplicatesUpdates() {
        activate(path: nil)
        policy.pathChanged("wifi"); policy.pathChanged("wifi")
        advance(0.49); XCTAssertEqual(polls, [false])
        advance(0.011); XCTAssertEqual(polls, [false, true])
        policy.pathChanged("wifi"); advance(60)
        XCTAssertEqual(polls, [false, true])
    }
    func testInterfaceChangeCountsButInitialAndDuplicateSnapshotsDoNot() {
        policy.activate(); completeFirst()
        policy.pathChanged("cellular"); advance(1); XCTAssertEqual(polls, [false])
        policy.pathChanged("wifi"); advance(0.5); XCTAssertEqual(polls, [false, true])
    }
    func testHealthyPathChangesDoNotPollAndHealthIsRecheckedAtExecution() {
        activate(); unreachable = false
        policy.pathChanged("cellular"); advance(1); XCTAssertEqual(polls, [false])
        unreachable = true; policy.pathChanged("wifi")
        unreachable = false; advance(1); XCTAssertEqual(polls, [false])
    }
    func testRecoveryDuringForegroundPollWaitsForLateFailure() {
        policy.pathChanged(nil); policy.activate()
        policy.pathChanged("wifi"); advance(10); XCTAssertEqual(polls, [false])
        completeFirst(); advance(0.5)
        XCTAssertEqual(polls, [false, true])
    }
    func testRecoveryInFlightAndFlappingHaveOneTrailingRetryAfterThirtySeconds() {
        activate(path: nil); policy.pathChanged("wifi"); advance(0.5)
        XCTAssertEqual(polls, [false, true])
        policy.pathChanged(nil); policy.pathChanged("cellular"); advance(1)
        XCTAssertEqual(polls, [false, true])
        completeFirst(); advance(28.9)
        XCTAssertEqual(polls, [false, true])
        advance(0.11); XCTAssertEqual(polls, [false, true, true])
    }
    func testLatestPathMustStayUsableForDebounce() {
        activate(path: nil); policy.pathChanged("wifi"); advance(0.3)
        policy.pathChanged(nil); advance(1); XCTAssertEqual(polls, [false])
        policy.pathChanged("wifi"); advance(0.3); policy.pathChanged("cellular")
        advance(0.3); XCTAssertEqual(polls, [false])
        advance(0.21); XCTAssertEqual(polls, [false, true])
    }
    func testBackgroundCancelsPendingRecoveryAndResumeDoesOrdinaryCatchUp() {
        activate(path: nil); policy.pathChanged("wifi"); policy.deactivate()
        advance(1); policy.pathChanged("cellular"); advance(60)
        XCTAssertEqual(polls, [false])
        policy.activate(); XCTAssertEqual(polls, [false, false])
        completeFirst(); advance(60); XCTAssertEqual(polls, [false, false])
    }
    func testPersistentFailureDoesNotBecomeARetryTimer() {
        activate(path: nil); policy.pathChanged("wifi"); advance(0.5)
        XCTAssertEqual(polls, [false, true]); completeFirst()
        advance(600); XCTAssertEqual(polls, [false, true])
    }
    func testBackgroundWhileFetchCompletesDropsPendingPath() {
        policy.pathChanged(nil); policy.activate(); policy.pathChanged("wifi")
        policy.deactivate(); completeFirst(); advance(60)
        XCTAssertEqual(polls, [false])
    }
    func testForegroundTransitionsNeverOverlapAndDoNotLoseResume() {
        policy.pathChanged("wifi"); policy.activate(); policy.deactivate(); policy.activate()
        XCTAssertEqual(polls, [false]); completeFirst()
        XCTAssertEqual(polls, [false, false])
    }
}

/// The Mac (the iPad app on Apple Silicon) posts `didBecomeActive` once, at launch, and never on
/// focus (OBSERVED 2026-11-28), so it never caught up. `AppActivation` is registered at launch and,
/// on the Mac, also follows AppKit's activation and scene activation and catches up every five minutes.
final class AppActivationTests: XCTestCase {
    private var clock: TimeInterval = 100
    private var jobs: [(TimeInterval, () -> Void)] = []
    private var actives = 0, resigns = 0, ticks = 0
    private let center = NotificationCenter()

    private func make(onMac: Bool) -> AppActivation {
        AppActivation(center: center, onMac: onMac, now: { self.clock }, schedule: { self.jobs.append((self.clock + $0, $1)) },
                      onActive: { self.actives += 1 }, onResign: { self.resigns += 1 }, onTick: { self.ticks += 1 })
    }

    private func advance(_ seconds: TimeInterval) {
        let end = clock + seconds
        while let index = jobs.indices.filter({ jobs[$0].0 <= end }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
            let job = jobs.remove(at: index); clock = job.0; job.1()
        }
        clock = end
    }

    private func post(_ name: Foundation.Notification.Name) {
        center.post(name: name, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    func testTheLaunchActivationIsSeenOnEveryDevice() {
        for onMac in [false, true] {
            actives = 0
            let activation = make(onMac: onMac)
            activation.start()
            post(UIApplication.didBecomeActiveNotification)
            XCTAssertEqual(actives, 1, onMac ? "Mac" : "iPhone")
            post(UIApplication.willResignActiveNotification)
            clock += 10
            withExtendedLifetime(activation) {}
        }
        XCTAssertEqual(resigns, 2)
    }

    func testTheMacCatchesUpOnFocusAndEveryFiveMinutes() {
        let activation = make(onMac: true)
        activation.start()
        post(Foundation.Notification.Name("NSApplicationDidBecomeActiveNotification"))
        XCTAssertEqual(actives, 1, "AppKit's activation")
        post(UIScene.didActivateNotification)
        XCTAssertEqual(actives, 1, "within two seconds it counts once")
        clock += 3
        post(UIScene.didActivateNotification)
        XCTAssertEqual(actives, 2, "a scene activating")
        advance(AppActivation.macInterval - 4) // Three seconds have gone already.
        XCTAssertEqual(ticks, 0)
        advance(1)
        XCTAssertEqual(ticks, 1)
        advance(AppActivation.macInterval)
        XCTAssertEqual(ticks, 2, "and again")
        withExtendedLifetime(activation) {}
    }

    func testAnIPhoneFollowsOnlyItsOwnLifecycle() {
        let activation = make(onMac: false)
        activation.start()
        post(Foundation.Notification.Name("NSApplicationDidBecomeActiveNotification"))
        post(UIScene.didActivateNotification)
        XCTAssertEqual(actives, 0)
        XCTAssertTrue(jobs.isEmpty, "no timer: iOS suspends it anyway")
        withExtendedLifetime(activation) {}
    }
}
