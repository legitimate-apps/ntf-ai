import SwiftUI
import UIKit
import StoreKit
import UserNotifications

struct ReleaseNotes: Identifiable, Equatable {
    let version: String
    let bullets: [String]
    var id: String { version }

    /// The App Store "What's New" text per release (CHANGELOG.md, drafts/whats-new-*.md). Add the new
    /// version's entry when cutting a release; a version without an entry shows no card.
    static let shipped: [ReleaseNotes] = [
        ReleaseNotes(version: "1.30.0", bullets: [
            String(localized: "ntfy.sh topics get instant banners even with an ntfy.sh login saved. A topic that needs that login says so, and its messages show when you open the app."),
            String(localized: "Topics added as http://ntfy.sh or www.ntfy.sh get instant banners too."),
            String(localized: "Notification status lists each topic that won't get instant banners and why, including a self-hosted server that isn't set up for them."),
            String(localized: "Instant banners keep working even if you rarely open the app.")
        ]),
        ReleaseNotes(version: "1.29.0", bullets: [
            String(localized: "Topics on ntfy.sh now get instant banners: ntfy-me.com watches them and wakes your device when a message arrives."),
            String(localized: "Your own ntfy server gets instant banners with its usual setting, upstream-base-url: https://ntfy.sh, so the official ntfy app keeps working too."),
            String(localized: "You can turn this off anytime in Settings.")
        ]),
        ReleaseNotes(version: "1.28.0", bullets: [
            String(localized: "Clear all empties Waiting on you at once: touch and hold its header. Undo brings it back."),
            String(localized: "Only questions from agents wait on you. Messages with plain buttons, like a smart-home alert, stay in Activity."),
            String(localized: "Waiting on you lists the newest question first."),
            String(localized: "Plain buttons can be tapped again, and an answered question shows the answer you chose."),
            String(localized: "Share a topic, a message or a file, or copy a topic's curl or ntf command."),
            String(localized: "Send feedback from Settings, or shake your device to open the form."),
            String(localized: "New setting: Use buttons without unlocking lets you answer from the lock screen.")
        ]),
        ReleaseNotes(version: "1.27.0", bullets: [
            String(localized: "Agents can ask for a choice, a number, a date, some text or a short form, and you answer right in the app."),
            String(localized: "See which agent is asking, with its name and picture in the app and in notifications."),
            String(localized: "Questions with a deadline show the time left, and an agent can withdraw a question it no longer needs."),
            String(localized: "Agent reminders: an unanswered question can alert you again, or remind you silently."),
            String(localized: "Answer buttons are easier to read in light and dark mode.")
        ]),
        ReleaseNotes(version: "1.26.0", bullets: [
            String(localized: "Inbox lists the questions agents ask you under Waiting on you, and everything else under Activity."),
            String(localized: "Answer an agent from the notification with a button or a typed reply. A blue tick shows the agent got it."),
            String(localized: "Connect an agent shows how to link an agent or a script to a topic."),
            String(localized: "Denser message lists: long messages fold to six lines, and row actions are in the long-press menu."),
            String(localized: "A new emerald look and app icon.")
        ]),
        ReleaseNotes(version: "1.25.0", bullets: [
            String(localized: "NTF-AI. Same app, same topics, same settings.")
        ]),
        ReleaseNotes(version: "1.24.0", bullets: [
            String(localized: "The next poll fetches messages missed by dropped pushes, while they remain in the server cache."),
            String(localized: "Use Read messages in Shortcuts to read stored messages from a topic."),
            String(localized: "Choose Topics saved in account when adding a subscription on a server you are signed in to."),
            String(localized: "Notification status now shows iOS settings that hide or delay alerts."),
            String(localized: "See when you subscribed in Topic details. Older subscriptions show Unknown."),
            String(localized: "Long message links work in full, words wrap normally, and Markdown code follows text size changes.")
        ]),
        ReleaseNotes(version: "1.23.0", bullets: [
            String(localized: "Schedule Quiet hours, with exceptions for priority 5 and chosen topics."),
            String(localized: "Run HTTP notification buttons without opening the app. Unlocking is still required."),
            String(localized: "Send messages from Shortcuts and Siri."),
            String(localized: "Use Alert if quiet to be notified when a topic receives no messages."),
            String(localized: "Read code blocks in monospace and choose to open web links in app."),
            String(localized: "Fix silent fallback notifications when a message cannot be fetched.")
        ]),
        ReleaseNotes(version: "1.22.0", bullets: [
            String(localized: "Choose a notification sound for each topic, or import one from Files."),
            String(localized: "Removed topics stop sending notifications, even if the first unsubscribe attempt fails."),
            String(localized: "View and share diagnostic reports from Settings > About. Reports stay on your phone.")
        ]),
        ReleaseNotes(version: "1.21.0", bullets: [
            String(localized: "Send messages with an optional title, priority, tags and an attachment from a topic screen."),
            String(localized: "Share links, text, photos and files to your subscribed topics from other apps."),
            String(localized: "Messages that already alerted you no longer alert again when received a second time."),
            String(localized: "See when a server refuses sign-in, with a button in the topic screen to check the server user.")
        ]),
        ReleaseNotes(version: "1.20.0", bullets: [
            String(localized: "Message images no longer disappear from the app after appearing in a notification."),
            String(localized: "The app and its notifications now support Spanish, Italian, Polish, Dutch and French, following your phone's language.")
        ]),
        ReleaseNotes(version: "1.19.0", bullets: [
            String(localized: "The app and its notifications now follow your phone's language when it is German."),
            String(localized: "Sign in to a server with an access token instead of a username and password."),
            String(localized: "Mute a topic for a while or until you turn it back on. Messages stay in history and arrive quietly in Notification Center."),
            String(localized: "Show a topic's QR code to share its address, or scan a code from Add subscription to subscribe."),
            String(localized: "Base64-encoded text messages now show their decoded text. Binary messages show a short explanation."),
            String(localized: "VoiceOver gives controls, priorities and attachments clearer names.")
        ]),
        ReleaseNotes(version: "1.18.0", bullets: [
            String(localized: "Open ntfy-me.com topic links in the app. A topic you already follow opens its messages; a new topic has its server and name filled in, ready for you to tap Subscribe."),
            String(localized: "Marking a topic read can update your other devices with fewer requests on ntfy-me.com and self-hosted servers that support it."),
            String(localized: "A server limit on sending no longer pauses message refreshes."),
            String(localized: "For self-hosted HTTPS topics, Settings → Notification status can check whether ntfy-me.com receives forwarded wake-ups. It asks before sending one visible test message. This checks forwarding, not delivery to your phone.")
        ]),
        ReleaseNotes(version: "1.17.0", bullets: [
            String(localized: "If notifications are turned off for the app, or a topic can't refresh, the app now says why and how to fix it. Settings → Notification status checks that this phone is set up for push and can repair it."),
            String(localized: "Priority 4 and 5 messages can now break through Focus and the Notification Summary when Time Sensitive notifications are allowed in iOS and Focus settings."),
            String(localized: "Swipe a message to mark it read or unread. Long-press a topic to pin it, mark it read or unsubscribe."),
            String(localized: "Settings → Notification history sets how long notifications are kept on this phone. Until you choose a limit, everything is kept. Long topics open on their newest messages, and you can search a topic's whole history."),
            String(localized: "Notification buttons can copy text, such as a code, to the clipboard."),
            String(localized: "A new topic has a \"Send a test notification\" button, so you can see a notification arrive without a computer.")
        ]),
        ReleaseNotes(version: "1.16.0", bullets: [
            String(localized: "On a Mac, notification buttons such as Approve now work right from the banner."),
            String(localized: "Tapping an action button twice sends it once, and a busy server is retried instead of showing a false failure."),
            String(localized: "Clearer server hints: topics on ntfy.sh explain that they get no instant banners in this app, adding a topic reminds you where your scripts must send, and the self-hosting and migration guides are one tap away."),
            String(localized: "Reading or dismissing notifications on a self-hosted topic now helps clear them on your other devices."),
            String(localized: "Settings → About → Licenses lists the open-source software the app is built on.")
        ])
    ]
}

enum LaunchExperiencePolicy {
    /// Treat omitted trailing components as zero (1.17 and 1.17.0 are the same).
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    struct Update: Equatable {
        let entries: [ReleaseNotes]
        let recordNow: Bool
    }

    static func update(current: String, lastSeen: String?, hasSubscriptions: Bool,
                       entries: [ReleaseNotes] = ReleaseNotes.shipped) -> Update {
        if let lastSeen, !isNewer(current, than: lastSeen) {
            return Update(entries: [], recordNow: false)
        }
        let eligible = entries.filter { entry in
            guard !isNewer(entry.version, than: current) else { return false }
            if let lastSeen { return isNewer(entry.version, than: lastSeen) }
            // Updating from a release before this card existed: the user never saw any of these notes.
            return hasSubscriptions
        }.sorted { isNewer($0.version, than: $1.version) }
        let selected = Array(eligible.prefix(2))
        return Update(entries: selected, recordNow: selected.isEmpty)
    }

    static let minimumInstallAge: TimeInterval = 3 * 24 * 60 * 60
}

/// One process session owns notice suppression, even after returning from a topic or switching tabs.
final class LaunchExperience: ObservableObject {
    static let shared = LaunchExperience()
    static let seenKey = "whatsNewLastSeenVersion"
    static let reviewKey = "reviewLastPromptedVersion"
    static let firstLaunchKey = "reviewFirstLaunchDate"
    let current: String
    @Published var showingWhatsNew = false
    private(set) var entries: [ReleaseNotes] = []
    private var prepared = false
    /// Seam for per-topic delivery health (feat/delivery-health): false while any topic is failing.
    static var topicsHealthy: () -> Bool = {
        let keys = (Store.shared.getSubscriptions() ?? []).map { $0.objectID.uriRepresentation().absoluteString }
        return FcmSubscriptionReconciler.shared.isPushSetupComplete && DeliveryHealthMonitor.shared.healthy(keys: keys)
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         current: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") {
        self.defaults = defaults
        self.current = current
        #if DEBUG
        // Simulator evidence can seed an update and elapsed install age without changing Info.plist.
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-ntfyDebugLastSeenVersion"), i + 1 < arguments.count {
            defaults.set(arguments[i + 1], forKey: Self.seenKey)
        }
        if let i = arguments.firstIndex(of: "-ntfyDebugFirstLaunchDays"), i + 1 < arguments.count,
           let days = Double(arguments[i + 1]) {
            defaults.set(Date().addingTimeInterval(-days * 86400), forKey: Self.firstLaunchKey)
        }
        #endif
    }

    func prepare(hasSubscriptions: Bool, now: Date = Date()) {
        guard !prepared else { return }
        prepared = true
        if defaults.object(forKey: Self.firstLaunchKey) == nil {
            // Existing users should not have to wait another three days for this new feature.
            defaults.set(hasSubscriptions ? now.addingTimeInterval(-LaunchExperiencePolicy.minimumInstallAge) : now,
                         forKey: Self.firstLaunchKey)
        }
        let update = LaunchExperiencePolicy.update(current: current,
            lastSeen: defaults.string(forKey: Self.seenKey), hasSubscriptions: hasSubscriptions)
        entries = update.entries
        if update.recordNow { defaults.set(current, forKey: Self.seenKey) }
    }

    /// True when the card is shown, so the caller leaves this foreground to it alone.
    @discardableResult
    func presentWhatsNew() -> Bool {
        guard !entries.isEmpty else { return false }
        showingWhatsNew = true
        return true
    }

    func dismissWhatsNew() {
        defaults.set(current, forKey: Self.seenKey)
        entries = []
    }
}

struct WhatsNewView: View {
    let entries: [ReleaseNotes]
    let onContinue: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.version)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(entry.bullets, id: \.self) { bullet in
                                Text(bullet).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            // Pinned below the notes, so Continue never scrolls out of reach.
            .modifier(BottomBar {
                Button(action: onContinue) {
                    Text(String(localized: "Continue")).frame(maxWidth: .infinity)
                }
                .brandProminentButton()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            })
            .navigationTitle(String(localized: "What's new"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

/// A control pinned to the bottom edge: iOS 26's safe-area bar, which joins the scroll-edge effect,
/// or a safe-area inset on the bar material before it.
struct BottomBar<Bar: View>: ViewModifier {
    let bar: Bar

    init(@ViewBuilder _ bar: () -> Bar) { self.bar = bar() }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) { bar }
        } else {
            content.safeAreaInset(edge: .bottom) { bar.padding(.top, 8).background(.bar) }
        }
    }
}
