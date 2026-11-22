import SwiftUI
import UIKit

struct NotificationPermissionBanner: View {
    @EnvironmentObject private var delegate: AppDelegate

    var body: some View {
        InlineNotice(symbol: AppSymbol.mute(), text: DeliveryHealthCopy.notificationsOff,
                     actionTitle: DeliveryHealthCopy.openSettings,
                     action: { delegate.openNotificationSettings() })
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemBackground))
    }
}

/// Value trailing, as in the rest of Settings.
struct NotificationStatusRow: View {
    let title: String
    let value: String

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                LabeledContent(title, value: value)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                    Spacer(minLength: 8)
                    Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NotificationStatusView: View {
    @EnvironmentObject private var delegate: AppDelegate
    @StateObject private var subscriptions = SubscriptionsObservable()
    @Environment(\.scenePhase) private var scenePhase
    @State private var repairing = false
    @State private var result: String?
    @State private var repairID = UUID()

    private var pendingCount: Int { subscriptions.subscriptions.filter { !$0.fcmSubscribed }.count }

    var body: some View {
        Section(header: Text(DeliveryHealthCopy.status)) {
            NotificationStatusRow(title: DeliveryHealthCopy.permission, value:
                      DeliveryHealthCopy.permissionLabel(delegate.notificationAuthorizationStatus))
            NotificationStatusRow(title: DeliveryHealthCopy.phoneRegistration, value:
                      delegate.hasPhoneRegistration ? DeliveryHealthCopy.registered : DeliveryHealthCopy.waiting)
            NotificationStatusRow(title: DeliveryHealthCopy.pushRegistration, value:
                      delegate.hasPushRegistration ? DeliveryHealthCopy.registered : DeliveryHealthCopy.waiting)
            NotificationStatusRow(title: DeliveryHealthCopy.pendingTopics, value: String(pendingCount))
            NtfyShBridgeStatusRows(bridge: NtfyShBridge.shared, subscriptionCount: subscriptions.subscriptions.count)
            ForEach(delegate.notificationSwitches.warnings(), id: \.self, content: warningRow)
            if delegate.notificationAuthorizationStatus == .notDetermined {
                Button(DeliveryHealthCopy.allowNotifications) {
                    delegate.requestStandardNotificationAuthorization { result = nil }
                }
            } else {
                Button(DeliveryHealthCopy.openSettings) { delegate.openNotificationSettings() }
            }
            Button(repairing ? DeliveryHealthCopy.repairing : DeliveryHealthCopy.repair, action: repair)
                .disabled(repairing)
            ForEach(selfHostedSubscriptions, id: \.objectID) { subscription in
                NavigationLink(destination: RelayTopicCheckView(subscription: subscription)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Check self-hosted wake-ups"))
                        Text(subscription.displayName()).font(.subheadline).foregroundColor(.secondary)
                    }
                }
            }
            if let result {
                Text(result)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { delegate.refreshNotificationSettings() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                result = nil
                delegate.refreshNotificationSettings()
            }
        }
        // Low Power Mode and Background App Refresh can change from Control Center or Settings while this screen is open.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in delegate.refreshNotificationSettings() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in delegate.refreshNotificationSettings() }
    }

    private var selfHostedSubscriptions: [Subscription] {
        subscriptions.subscriptions.filter {
            Self.offersWakeupCheck(baseUrl: $0.baseUrl ?? "")
        }
    }

    static func offersWakeupCheck(baseUrl: String) -> Bool {
        guard RelayCheck.isSecureBase(baseUrl), let hostname = URL(string: baseUrl)?.host?.lowercased() else { return false }
        let host = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let appHost = URL(string: Config.appBaseUrl)?.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host != appHost && host != "ntfy-me.com" && host != "ntfy.sh"
    }

    private func warningRow(_ warning: NotificationWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(warning.title)
                Text(warning.detail).font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status-warning-\(warning.rawValue)")
    }

    private func repair() {
        repairing = true
        result = nil
        let id = UUID()
        repairID = id
        UIApplication.shared.registerForRemoteNotifications()
        RegistrationRepair.wait(isReady: { delegate.hasPhoneRegistration && delegate.hasPushRegistration }) {
            guard repairID == id, repairing else { return }
            FcmSubscriptionReconciler.shared.reconcile(reason: "user requested repair") {
                DispatchQueue.main.async {
                    guard repairID == id else { return }
                    delegate.refreshNotificationSettings {
                        guard repairID == id else { return }
                        repairing = false
                        let registered = delegate.hasPhoneRegistration && delegate.hasPushRegistration
                        result = NotificationHealth.repairResult(permission: delegate.notificationAuthorizationStatus,
                            registered: registered, bindingsComplete: FcmSubscriptionReconciler.shared.isPushSetupComplete)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard repairID == id, repairing else { return }
            repairing = false
            result = DeliveryHealthCopy.repairTimeout
            repairID = UUID() // A late callback must not overwrite the timeout or a later attempt.
        }
    }
}


/// What the ntfy.sh bridge watches for this device and whether it is live, so a user (or a
/// feedback report's reader) can see why ntfy.sh and upstream-ntfy.sh banners do or don't come.
struct NtfyShBridgeStatusRows: View {
    @ObservedObject var bridge: NtfyShBridge
    /// Re-reads the watch set when topics are added or removed while the screen is open.
    let subscriptionCount: Int
    @AppStorage(Config.ntfyShBridgeKey, store: NtfyShBridge.defaults) private var enabled = true
    @State private var status: NtfyShBridge.Status?
    @State private var checked = false
    /// Bumped when the bridge, the access cache or a wake check changes in any process.
    @State private var revision = 0
    @State private var expanded = Set<String>()
    @State private var armed = Set<String>()

    var body: some View {
        let _ = revision
        let set = bridge.subscribedSet()
        let report = bridge.report()
        NotificationStatusRow(title: NtfyShBridgeCopy.settingTitle, value: enabled ? NtfyShBridgeCopy.on : NtfyShBridgeCopy.off)
            .onReceive(NotificationCenter.default.publisher(for: .ntfyShBridgeStateChanged)) { _ in
                bridge.reload(); revision += 1
            }
        // Per server: how many topics are watched, then each topic that won't get banners and why.
        ForEach(report.groups, id: \.server) { group in
            let selfHosted = group.server != NtfyShAddress.canonical
            NotificationStatusRow(title: Self.serverLabel(group.server),
                                  value: enabled ? NtfyShBridgeCopy.watching(group.watching) : NtfyShBridgeCopy.off)
            if let hold = group.serverWide {
                heldRow(server: group.server, topic: nil, hold: hold, selfHosted: selfHosted)
                    .accessibilityIdentifier("bridge-held-server-\(Self.serverLabel(group.server))")
            }
            let held = group.topicHeld
            let shown = expanded.contains(group.server) ? held : Array(held.prefix(Self.maxHeldRows))
            ForEach(shown, id: \.topic) { row in
                heldRow(server: group.server, topic: row.topic, hold: row.hold, selfHosted: selfHosted)
                    .accessibilityIdentifier("bridge-held-\(row.topic)")
            }
            if held.count > shown.count {
                Button(NtfyShBridgeCopy.showMore(held.count - shown.count)) { expanded.insert(group.server) }
                    .accessibilityIdentifier("bridge-show-more-\(Self.serverLabel(group.server))")
            }
        }
        if enabled {
            NotificationStatusRow(title: NtfyShBridgeCopy.lastRegistration, value: NtfyShBridgeCopy.lastRegistration(bridge.record))
            if !set.isEmpty {
                NotificationStatusRow(title: NtfyShBridgeCopy.connection,
                                      value: status.map(NtfyShBridgeCopy.status) ?? NtfyShBridgeCopy.checking)
                    .onAppear(perform: check)
            }
            Text(NtfyShBridgeCopy.renewalNote).font(.footnote).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bridge-renewal-note")
        }
    }

    static let maxHeldRows = 20

    static func serverLabel(_ server: String) -> String {
        server.replacingOccurrences(of: "https://", with: "")
    }

    /// One topic and its reason, or (topic nil) a reason that holds for every topic on the server.
    @ViewBuilder
    private func heldRow(server: String, topic: String?, hold: NtfyShBridge.TopicHold, selfHosted: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hold.isPending ? "clock" : "exclamationmark.triangle.fill")
                .foregroundColor(hold.isPending ? .secondary : .orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let topic { Text(topic) }
                Text(NtfyShBridgeCopy.reason(hold, selfHosted: selfHosted)).font(topic == nil ? .body : .subheadline)
                    .foregroundColor(topic == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        if let topic, hold.offersCheckAgain {
            let hash = topicHash(baseUrl: server, topic: topic)
            if armed.contains(hash) || SelfHostedWakeCheck.shared.isArmed(hash: hash) {
                Text(NtfyShBridgeCopy.checkArmed).font(.footnote).foregroundColor(.secondary)
            } else {
                Button(NtfyShBridgeCopy.checkAgain) {
                    armed.insert(hash)
                    NtfyShBridgeCheckAgain.run(hash: hash, bridge: bridge) { status = $0 }
                }
                .accessibilityIdentifier("bridge-check-again-\(topic)")
            }
        }
    }

    private func check() {
        guard !checked else { return }
        checked = true
        bridge.sync(reason: "status screen opened") {
            bridge.fetchStatus { status = $0 }
        }
    }
}

/// "Check again" on a self-hosted topic: check its next message whatever the throttles say, and
/// refresh the bridge's connection evidence the diagnosis rests on.
enum NtfyShBridgeCheckAgain {
    static func run(hash: String, bridge: NtfyShBridge = .shared, wakes: SelfHostedWakeCheck = .shared,
                    status: ((NtfyShBridge.Status) -> Void)? = nil) {
        wakes.arm(hash: hash)
        bridge.fetchStatus { status?($0) }
    }
}

/// Consent is local to a selected topic. The relay API never sees this message or its credentials.
struct RelayTopicCheckView: View {
    @Environment(\.scenePhase) private var scenePhase
    let subscription: Subscription
    @StateObject private var check = RelayCheck()

    var body: some View {
        RelayCheckContentView(topicName: subscription.displayName(), baseUrl: subscription.baseUrl ?? "",
            state: check.state,
            prepare: { check.prepare(baseUrl: subscription.baseUrl ?? "", topic: subscription.topic ?? "") },
            approve: sendTest, cancel: check.cancel)
            .onDisappear { check.cancel() }
            .onChange(of: scenePhase) { if $0 != .active { check.cancel() } }
    }

    private func sendTest() {
        let keyState = Store.shared.topicKeyState(for: subscription)
        check.approve { completion in
            guard keyState != .unavailable else {
                completion(String(localized: "The encryption key is unavailable. Nothing was sent."))
                return
            }
            ApiService.shared.publish(subscription: subscription,
                user: Store.shared.getBasicUser(baseUrl: subscription.baseUrl ?? ""),
                message: String(localized: "This is a test notification from NTF-AI (wake-up forwarding check)."), title: String(localized: "Wake-up forwarding test"),
                encryptionKey: keyState.key,
                completionHandler: { completion(nil) }, failureHandler: { completion($0.userMessage) })
        }
    }
}


/// Pure presentation shared by the live flow and the simulator visual checks.
struct RelayCheckContentView: View {
    let topicName: String
    let baseUrl: String
    let state: RelayCheck.State
    let prepare: () -> Void
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        Form {
            Section(header: Text(String(localized: "Self-hosted wake-ups"))) {
                Text(topicName).fixedSize(horizontal: false, vertical: true)
                Text(baseUrl).font(.footnote).foregroundColor(.secondary)
                // The relay is the app's own server (RelayCheck's relayBaseUrl), named as the rest of the UI names it.
                Text(String(localized: "Check whether \(shortUrl(url: normalizeBaseUrl(Config.appBaseUrl))) receives forwarded wake-ups for this topic. This cannot prove delivery to your device."))
                    .fixedSize(horizontal: false, vertical: true)
                if state != .consent {
                    Button(String(localized: "Check relay support")) {
                        prepare()
                    }.disabled(state.isBusy)
                }
            }
            if state == .consent {
                Section(header: Text(String(localized: "Send a visible test?"))) {
                    Text(String(localized: "This sends one ordinary test message to this topic, visible to everyone subscribed. It uses your topic server's credentials and encryption settings. The relay receives only the topic hash, without your message or credentials."))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Send one test message"), action: approve)
                    Button(String(localized: "Cancel"), action: cancel)
                }
            }
            if let message = state.message {
                Section(header: Text(String(localized: "Check result"))) {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("relay-check-result")
                    if state.isBusy {
                        Button(String(localized: "Cancel check"), action: cancel)
                    }
                }
            }
            Section(header: Text(String(localized: "Server setup"))) {
                Text(String(localized: "Your server's upstream-base-url must be https://ntfy.sh, with instant banners on in Settings, or \(normalizeBaseUrl(Config.appBaseUrl)). Its configured base-url must exactly match the server address used for this subscription, including scheme, port, path and spelling. The relay keeps only recent acceptance times (up to 2 minutes); it does not report device delivery."))
                    .font(.footnote).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle(String(localized: "Wake-up check"))
        .navigationBarTitleDisplayMode(.inline)
    }

}
