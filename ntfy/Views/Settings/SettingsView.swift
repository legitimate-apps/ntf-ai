// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import Foundation
import SwiftUI
import StoreKit
import SafariServices

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @AppStorage(TopicServerAddressPolicy.preferenceKey) private var showServerAddresses = TopicServerAddressPolicy.defaultValue
    @AppStorage(InAppBrowser.preferenceKey) private var openWebLinksInApp = false
    @AppStorage(AgentAck.showKey, store: AgentAck.defaults) private var showAgentConfirmations = true
    @AppStorage(AgentReminder.settingKey, store: AgentAck.defaults) private var agentReminders = true
    @AppStorage(LockScreenButtons.key, store: LockScreenButtons.defaults) private var buttonsWithoutUnlocking = false
    @AppStorage(Config.ntfyShBridgeKey, store: NtfyShBridge.defaults) private var ntfyShBridge = true
    @State private var userDialog: UserDialog?
    
    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text(String(localized: "General")),
                    // Only the toggle needs explaining; Default server's value says what it is.
                    footer: Text(String(localized: "Topics with matching names always show their addresses."))
                ) {
                    Toggle(String(localized: "Open web links in app"), isOn: $openWebLinksInApp)
                    DefaultServerView()
                    TopicSortOrderView()
                    Toggle(String(localized: "Show server addresses"), isOn: $showServerAddresses)
                        .accessibilityHint(String(localized: "Topics with matching names always show their addresses."))
                }
                Section(
                    header: Text(String(localized: "Notifications")),
                    footer: Text(String(localized: "Automatically download attachments up to the selected size. Attachments larger than this limit must be downloaded manually."))
                ) {
                    NavigationLink(String(localized: "Quiet hours")) { QuietHoursView() }
                    AttachmentAutoDownloadView()
                }
                Section(footer: Text(NtfyShBridgeCopy.settingFooter)) {
                    Toggle(NtfyShBridgeCopy.settingTitle, isOn: $ntfyShBridge)
                        .accessibilityIdentifier("settings-ntfysh-bridge")
                        .onChange(of: ntfyShBridge) { on in
                            NtfyShBridge.shared.sync(reason: on ? "setting turned on" : "setting turned off", userInitiated: true)
                        }
                }
                // On a Mac every button opens the app, so there is nothing to allow.
                if !ProcessInfo.processInfo.isiOSAppOnMac {
                    Section(footer: Text(String(localized: "Buttons such as Approve work from the Lock Screen without Face ID, Touch ID or your passcode. Anyone holding your device could tap them."))) {
                        Toggle(String(localized: "Use buttons without unlocking"), isOn: $buttonsWithoutUnlocking)
                            .accessibilityIdentifier("settings-buttons-without-unlocking")
                            .onChange(of: buttonsWithoutUnlocking) { _ in LockScreenButtons.applyToRegisteredCategories() }
                    }
                }
                Section(footer: Text(String(localized: "Shows a receipt and the agent's note when an agent confirms your answer. Confirmations are always silent."))) {
                    Toggle(String(localized: "Show agent confirmations"), isOn: $showAgentConfirmations)
                        .accessibilityIdentifier("settings-agent-confirmations")
                }
                Section(footer: Text(String(localized: "An agent can remind you of a question you haven't answered: up to three times, at least five minutes apart. Off, reminders arrive silently."))) {
                    Toggle(String(localized: "Agent reminders"), isOn: $agentReminders)
                        .accessibilityIdentifier("settings-agent-reminders")
                }
                NotificationStatusView()
                RetentionSettingsView(store: store)
                UrgentAlertsSettingView()
                Section(
                    header: Text(String(localized: "Users")),
                    footer: Text(String(localized: "Add or edit a password or access token for read-protected topics. All topics for a server use the same login."))
                ) {
                    UserTableView(dialog: $userDialog)
                }
                Section(
                    header: Text(String(localized: "Server headers")),
                    footer: Text(String(localized: "Add credentials required by Cloudflare Access or another reverse proxy. Values are stored in the Keychain."))
                ) {
                    NavigationLink(String(localized: "Custom HTTP headers")) {
                        ServerHeadersView(defaultBaseUrl: store.getDefaultBaseUrl())
                    }
                }
                DirectWatchServersSection()
                FeedbackSettingsSection()
                Section(header: Text(String(localized: "About"))) {
                    AboutView()
                }
            }
            .navigationTitle(String(localized: "Settings"))
        }
        .sheet(item: $userDialog) { dialog in
            UserEditorView(
                selectedUser: dialog.user,
                onSave: { baseUrl, username, credential in
                    guard let credential else { return false }
                    let saved = store.saveUser(baseUrl: baseUrl, credential: credential)
                    NtfyShBridge.shared.sync(reason: "login changed")
                    if saved { userDialog = nil }
                    return saved
                },
                onDelete: { user in
                    let deleted = store.delete(user: user)
                    NtfyShBridge.shared.sync(reason: "login changed")
                    if deleted { userDialog = nil }
                    return deleted
                },
                onCancel: {
                    userDialog = nil
                }
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview // Store.previewEmpty
        SettingsView()
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}

struct InAppBrowser: UIViewControllerRepresentable {
    static let preferenceKey = "openWebLinksInApp"
    static func shouldOpen(_ url: URL, enabled: Bool) -> Bool {
        enabled && ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }
    @Binding var url: URL?
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { controller.dismiss(animated: true) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let url else { return }
        DispatchQueue.main.async {
            guard controller.view.window != nil, controller.presentedViewController == nil else { return }
            let safari = SFSafariViewController(url: url)
            safari.delegate = context.coordinator
            controller.present(safari, animated: true)
            self.url = nil
        }
    }
}
