// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import Foundation
import UIKit
import StoreKit
import UserNotifications

/// When to ask "Enjoying NTF-AI?" (operator, 2026-11-19). Yes asks the system for the App Store
/// review sheet, which iOS may silently not show (three times a year at most, never in TestFlight).
/// Not really opens the feedback form instead.
enum ReviewPromptPolicy {
    static let minimumInstallAge: TimeInterval = 7 * 24 * 60 * 60
    static let minimumLaunches = 5
    static let dislikeQuietPeriod: TimeInterval = 120 * 24 * 60 * 60

    struct Inputs {
        var current: String
        var lastPrompted: String?
        var lastDislike: Date?
        var firstLaunch: Date?
        var launchCount: Int
        /// A notification arrived or an agent question was answered in this app session.
        var goodMomentThisSession: Bool
        var crashSinceLastLaunch: Bool
        var questionWaiting: Bool
        var notificationsAuthorized: Bool
        var topicsHealthy: Bool
        var now: Date
    }

    static func shouldAsk(_ i: Inputs) -> Bool {
        guard let firstLaunch = i.firstLaunch, i.now.timeIntervalSince(firstLaunch) >= minimumInstallAge else { return false }
        if let lastDislike = i.lastDislike, i.now.timeIntervalSince(lastDislike) < dislikeQuietPeriod { return false }
        return i.launchCount >= minimumLaunches && i.lastPrompted != i.current && i.goodMomentThisSession
            && !i.crashSinceLastLaunch && !i.questionWaiting && i.notificationsAuthorized && i.topicsHealthy
    }
}

final class ReviewPrompt: ObservableObject {
    static let shared = ReviewPrompt()
    static let launchCountKey = "reviewLaunchCount"
    static let launchStartKey = "reviewLastLaunchStart"
    static let dislikeKey = "reviewLastDislikeDate"
    /// Shared with the review request this replaces, so a version that already asked never asks again.
    static let promptedKey = LaunchExperience.reviewKey

    @Published var asking = false
    private(set) var goodMoment = false
    private var previousLaunchStart: Date?
    private var launched = false
    private let defaults: UserDefaults
    private let current: String

    init(defaults: UserDefaults = .standard,
         current: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") {
        self.defaults = defaults
        self.current = current
    }

    /// Once per process.
    func recordLaunch(now: Date = Date()) {
        guard !launched else { return }
        launched = true
        previousLaunchStart = defaults.object(forKey: Self.launchStartKey) as? Date
        defaults.set(now, forKey: Self.launchStartKey)
        defaults.set(defaults.integer(forKey: Self.launchCountKey) + 1, forKey: Self.launchCountKey)
    }

    /// A notification arrived or an agent's question was answered. Ask a moment later, if at all.
    func noteGoodMoment() {
        DispatchQueue.main.async {
            self.goodMoment = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.considerAsking() }
        }
    }

    func inputs(now: Date, crashArrival: Date?, questionWaiting: Bool,
                notificationsAuthorized: Bool, topicsHealthy: Bool) -> ReviewPromptPolicy.Inputs {
        let crashed = crashArrival.map { crash in previousLaunchStart.map { crash >= $0 } ?? true } ?? false
        return .init(current: current, lastPrompted: defaults.string(forKey: Self.promptedKey),
                     lastDislike: defaults.object(forKey: Self.dislikeKey) as? Date,
                     firstLaunch: defaults.object(forKey: LaunchExperience.firstLaunchKey) as? Date,
                     launchCount: defaults.integer(forKey: Self.launchCountKey),
                     goodMomentThisSession: goodMoment, crashSinceLastLaunch: crashed,
                     questionWaiting: questionWaiting, notificationsAuthorized: notificationsAuthorized,
                     topicsHealthy: topicsHealthy, now: now)
    }

    /// Asks only while the app is in front with nothing else on screen.
    func considerAsking() {
        guard goodMoment, !asking, UIApplication.shared.applicationState == .active,
              defaults.string(forKey: Self.promptedKey) != current else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                let inputs = self.inputs(now: Date(), crashArrival: DiagnosticReportStore.shared.latestCrashArrival(),
                                         questionWaiting: !WaitingObservable.shared.notifications.isEmpty,
                                         notificationsAuthorized: settings.authorizationStatus == .authorized,
                                         topicsHealthy: LaunchExperience.topicsHealthy())
                guard ReviewPromptPolicy.shouldAsk(inputs), !FeedbackCenter.screenBusy() else { return }
                self.defaults.set(self.current, forKey: Self.promptedKey)
                Log.d("ReviewPrompt", "Asking whether the app is enjoyed, version \(self.current)")
                self.asking = true
            }
        }
    }

    func answeredYes() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        Task { @MainActor in
            if #available(iOS 16.0, *) { AppStore.requestReview(in: scene) }
            else { SKStoreReviewController.requestReview(in: scene) }
        }
    }

    func answeredNotReally(now: Date = Date()) {
        defaults.set(now, forKey: Self.dislikeKey)
        FeedbackCenter.shared.present(kind: .dislike, source: .reviewPrompt)
    }
}

extension DiagnosticReportStore {
    /// When the newest crash report reached this device (its file's creation), if any is kept.
    func latestCrashArrival() -> Date? {
        guard let reports = try? reports() else { return nil }
        return reports.filter { $0.kind == .crash }.compactMap { report in
            (try? file(for: report)).flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
        }.max()
    }
}
