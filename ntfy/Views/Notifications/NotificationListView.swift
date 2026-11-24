import CoreData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Errors only. Destructive actions confirm with a confirmation dialog.
enum ActiveAlert {
    case encryptionUnavailable, publishFailed
}


struct NotificationListView: View {
    private let tag = "NotificationListView"
    
    @Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var store: Store
    @Environment(\.scenePhase) private var scenePhase
    
    @ObservedObject private var deliveryHealth = DeliveryHealthMonitor.shared
    @ObservedObject var subscription: Subscription
    // @StateObject, not @ObservedObject: this view constructs the observable in its own
    // initializer, and @ObservedObject does not own what it is handed. Every rebuild of the view
    // struct — which LazyView makes more likely, since it re-runs its autoclosure whenever its body
    // is re-evaluated — would construct a fresh observable and re-run its per-topic fetch, throwing
    // away the live NSFetchedResultsController. Same ownership bug fixed for SubscriptionsObservable
    // in #36; this is its sibling.
    @StateObject var notificationsModel: NotificationsObservable
    
    @AppStorage(TopicServerAddressPolicy.preferenceKey) private var showServerAddresses = TopicServerAddressPolicy.defaultValue
    /// Names shared by topics on different servers, read once on appear for the subtitle rule.
    @State private var ambiguousNames = Set<String>()
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<Notification>()
    @State private var heldUnread = HeldUnreadMarkers<NSManagedObjectID>()
    
    @State private var showAlert = false
    @State private var activeAlert: ActiveAlert = .publishFailed
    @State private var confirmClear = false
    @State private var confirmUnsubscribe = false
    @State private var confirmDeleteSelected = false
    @State private var showCopiedConfirmation = false
    @State private var showDetails = false
    @State private var showRenameSheet = false
    @State private var showEncryptionSheet = false
    @State private var showMuteOptions = false
    @State private var showQuietOptions = false
    @State private var showSoundOptions = false
    @State private var showQRCodeSheet = false
    @State private var shareRequest: ShareRequest?
    @State private var showComposeSheet = false
    @State private var showUserEditor = false
    @State private var sendingTest = false
    @State private var publishError = ""
    @State private var draftDisplayName = ""
    @State private var showConnectSheet = false
    /// The message whose page is pushed on top of this topic.
    @State private var opened: OpenedMessage?
    /// A notification tap's message, opened once on arrival so Back lands on its topic.
    let openMessageSequence: String?
    @State private var didOpenRequested = false
    
    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }

    init(subscription: Subscription, openMessageSequence: String? = nil) {
        self.subscription = subscription
        self.openMessageSequence = openMessageSequence
        // StateObject's wrappedValue is an autoclosure, so this is evaluated once for the view's
        // lifetime rather than on every struct rebuild.
        _notificationsModel = StateObject(wrappedValue: NotificationsObservable(subscriptionID: subscription.objectID))
    }

    var body: some View {
        notificationList
            // Search is its own tab now (DECISION change 9), across every topic.
            .modifier(MessagePageLink(opened: $opened))
            .refreshable {
                _ = await pollOnce()
            }
            .onAppear {
                // Opening the topic counts as reading it, so the badge clears immediately rather
                // than lingering behind the user. Anything the live poll below pulls in afterwards
                // stays unread, which is what you want — it hadn't arrived when you opened. The rows
                // that were unread keep their marker until the user leaves, so they can see what was new.
                heldUnread.hold(store.setRead(true, forSubscription: subscription))
                ambiguousNames = TopicServerAddressPolicy.ambiguousNames(in: store.getSubscriptions() ?? [])
                openRequestedMessage()
            }
            .onDisappear {
                heldUnread.clear()
            }
            // While this topic is on screen and the app is active, check for new messages: once right
            // away (opening a topic, or coming back to the app), then every 10 s, each check starting
            // only after the previous one ended, backing off while the server fails. A push normally
            // brings messages in live, but there is none when notifications are off ("Not now" or
            // denied), on a self-hosted server without `upstream-base-url`, or in the simulator; a
            // message sent while the topic was open then stayed invisible until the user left and came
            // back. SwiftUI cancels this task when the view goes away or the scene phase changes.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                var failures = 0
                while !Task.isCancelled {
                    failures = LivePollSchedule.failures(after: await pollOutcome(skipIfInFlight: true), previous: failures)
                    let delay = LivePollSchedule.delay(afterConsecutiveFailures: failures)
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        return
                    }
                }
            }
    }

    /// One poll; true unless it failed. The live loop skips while its previous poll is still out
    /// (see `PollGuard`); pull to refresh always polls.
    private func pollOnce(skipIfInFlight: Bool = false) async -> Bool {
        await pollOutcome(skipIfInFlight: skipIfInFlight).succeeded
    }

    private func pollOutcome(skipIfInFlight: Bool) async -> PollOutcome {
        await withCheckedContinuation { continuation in
            subscriptionManager.pollWithOutcome(subscription, skipIfInFlight: skipIfInFlight, manual: !skipIfInFlight) {
                continuation.resume(returning: $0)
            }
        }
    }
    
    /// A notification tap opens that message's page (DECISION change 7), pushed on this topic so
    /// one Back returns to it. Looked up by sequence, so an updated message opens as it is now.
    private func openRequestedMessage(tries: Int = 10) {
        guard !didOpenRequested, let sequence = openMessageSequence, !sequence.isEmpty else { return }
        didOpenRequested = true
        let request = Notification.fetchRequest() as NSFetchRequest<Notification>
        request.predicate = NSPredicate(format: "subscription == %@ AND (sequenceID == %@ OR id == %@)",
                                        subscription, sequence, sequence)
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)]
        request.fetchLimit = 1
        guard let notification = try? store.context.fetch(request).first else {
            // A tap on a banner can beat the extension's or the poll's save of that message: look
            // again every half second for five seconds before giving up.
            guard tries > 0 else { return }
            didOpenRequested = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openRequestedMessage(tries: tries - 1) }
            return
        }
        // Only once the topic's own push has finished: a second programmatic push started during
        // that transition shows the page and then SwiftUI pops it again.
        NavigationSettle.after {
            opened = OpenedMessage(notification: notification)
        }
    }

    private var signInFailed: Bool {
        deliveryHealth.topics[subscription.objectID.uriRepresentation().absoluteString]?.failure == .unauthorized
    }

    private var hasUnencryptedMessages: Bool {
        notificationsModel.notifications.contains { $0.encryptionState == .unencrypted }
    }

    private var showsTopNotice: Bool {
        signInFailed || hasUnencryptedMessages || TopicMute.status(until: subscription.mutedUntil, now: Date()) != nil
    }

    private var notificationList: some View {
        Group {
            if editMode == .active {
                List(selection: $selection) {
                    notificationRows
                }
            } else {
                List {
                    notificationRows
                }
            }
        }
        // Installed only when there is something to say. An always-present opaque inset clipped
        // the list's top edge hard instead of letting the scroll-edge effect fade it.
        .topNoticeBar {
            if showsTopNotice {
                VStack(alignment: .leading, spacing: 6) {
                    if signInFailed {
                        InlineNotice(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                     text: String(localized: "The server refused the sign-in."),
                                     actionTitle: String(localized: "Check server user"),
                                     action: { showUserEditor = true })
                            .accessibilityIdentifier("topic-sign-in-notice")
                    }
                    TopicMuteStatus(subscription: subscription, asNotice: true)
                    if hasUnencryptedMessages {
                        // Said once for the topic; each such row keeps its orange "Not encrypted" label.
                        InlineNotice(symbol: "lock.open", tint: .orange,
                                     text: String(localized: "Messages marked Not encrypted were sent without this topic's password. Anyone who knows the topic name could have sent them."))
                            .accessibilityIdentifier("topic-unencrypted-notice")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showUserEditor) {
            UserEditorView(selectedUser: store.getUser(baseUrl: subscription.baseUrl ?? ""),
                defaultBaseUrl: subscription.baseUrl ?? "",
                onSave: { baseUrl, _, credential in
                    guard let credential, store.saveUser(baseUrl: baseUrl, credential: credential) else { return false }
                    showUserEditor = false
                    NtfyShBridge.shared.sync(reason: "login changed")
                    Task { _ = await pollOnce() }
                    return true
                }, onDelete: { user in
                    let deleted = store.delete(user: user)
                    NtfyShBridge.shared.sync(reason: "login changed")
                    if deleted { showUserEditor = false }
                    return deleted
                }, onCancel: { showUserEditor = false })
        }
        .sheet(isPresented: $showDetails) { TopicDetailsView(subscription: subscription) }
        .sheet(isPresented: $showQuietOptions) { QuietTopicView(subscription: subscription) }
        .sheet(isPresented: $showSoundOptions) { TopicSoundView(subscription: subscription) }
        .sheet(isPresented: $showMuteOptions) { TopicMuteView(subscription: subscription) }
        .sheet(isPresented: $showConnectSheet) {
            ConnectAgentSheet(baseUrl: subscription.baseUrl ?? "", topic: subscription.topicName(),
                              isShowing: $showConnectSheet)
                .environmentObject(store)
        }
        // One level of inset, as in the Inbox (operator, 2026-11-17): rows edge to edge with
        // hairlines between them, not cards inside the screen's margins.
        .listStyle(.plain)
        .modifier(ReadableCardWidth())
        .modifier(CompactDayBreaks())
        .navigationTitle(subscription.shortDisplayName())
        .navigationBarTitleDisplayMode(.inline)
        .modifier(TopicAddressSubtitle(address: showsAddress ? TopicSubtitle.address(for: subscription) : nil))
        .navigationBarBackButtonHidden(MessageSelectionChrome.hidesBackButton(editing: editMode == .active))
        .environment(\.editMode, self.$editMode)
        .sheet(isPresented: $showComposeSheet) {
            ComposeSheetView(subscription: subscription).environmentObject(store)
        }
        .toolbar {
            // Fixed items with conditional content: the toolbar builder's if/else needs iOS 16.
            // In select mode the bar holds only Delete and Done; Compose and More step aside.
            ToolbarItem(placement: .cancellationAction) {
                if editMode == .active {
                    Button(role: .destructive) {
                        confirmDeleteSelected = true
                    } label: {
                        Text(String(localized: "Delete"))
                    }
                    .disabled(!MessageSelectionChrome.deleteEnabled(selectionCount: selection.count))
                    // The app-wide tint overrides the destructive role here too; red when enabled.
                    .tint(.red)
                    .accessibilityIdentifier("select-delete")
                    // Anchored to Delete, so the iOS 26 popover points at the button that opened it.
                    .confirmationDialog(String(localized: "Delete"), isPresented: $confirmDeleteSelected,
                                        titleVisibility: .hidden) {
                        Button(String(localized: "Delete \(selection.count) messages"), role: .destructive,
                               action: deleteSelected)
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if editMode == .active {
                    Button(String(localized: "Done")) {
                        editMode = .inactive
                        selection = Set<Notification>()
                    }
                    .accessibilityIdentifier("select-done")
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if MessageSelectionChrome.showsCompose(editing: editMode == .active) {
                    Button { showComposeSheet = true } label: {
                        Image(systemName: AppSymbol.compose)
                    }
                    .accessibilityLabel(String(localized: "New message"))
                    .accessibilityIdentifier("compose-open")
                    topicMenu
                }
            }
        }
        .alert(isPresented: $showAlert) {
            switch activeAlert {
            case .publishFailed:
                return Alert(title: Text(String(localized: "Test notification not sent")), message: Text(publishError))
            case .encryptionUnavailable:
                return Alert(
                    title: Text(String(localized: "Not sent")),
                    message: Text(String(localized: "This topic is end-to-end encrypted, but its password can't be read right now, so the test message would go out unencrypted. Try again after unlocking your device, or set the password again."))
                )
            }
        }
        .overlay(Group {
            if showCopiedConfirmation {
                CopiedToast()
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        })
        .onAppear {
            cancelSubscriptionNotifications()
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(isPresented: $showEncryptionSheet) {
            TopicEncryptionView(subscription: subscription)
                .environmentObject(store)
        }
        .sheet(isPresented: $showQRCodeSheet) {
            TopicQRCodeView(baseUrl: subscription.baseUrl ?? "", topic: subscription.topicName(),
                            isShowing: $showQRCodeSheet,
                            topicShare: .topic(subscription, store: store, onCopied: showCopyConfirmation))
        }
    }
    
    /// The saved login and custom headers for this topic's server, so the copied commands ask for
    /// them instead of publishing anonymously and failing. Names only: no secret leaves the Keychain.
    private func publishAuth(baseUrl: String) -> PublishCommand.Auth {
        PublishCommand.Auth(
            username: store.getBasicUser(baseUrl: baseUrl).flatMap { $0.isAccessToken ? nil : $0.username },
            accessToken: store.getBasicUser(baseUrl: baseUrl)?.isAccessToken ?? false,
            headerNames: KeychainCredentialStore.shared.httpHeaders(baseUrl: baseUrl).keys.sorted()
        )
    }

    @ViewBuilder
    private var notificationRows: some View {
        // The empty state is a row of the list, not an overlay on top of it. As an overlay it sat over
        // the (empty) list and swallowed the drag, so pull-to-refresh did nothing on a new topic, and on
        // a small phone its text ran off the screen with no way to scroll to the copy buttons.
        if notificationsModel.notifications.isEmpty && editMode == .inactive && !signInFailed, let baseUrl = subscription.baseUrl {
            TopicPublishHelpView(
                baseUrl: baseUrl,
                topic: subscription.topicName(),
                encrypted: subscription.encrypted,
                auth: publishAuth(baseUrl: baseUrl),
                sendingTest: sendingTest,
                onTest: { sendTestNotification(firstRun: true) },
                onCopy: showCopyConfirmation
            )
            .listRowSeparator(.hidden)
        }
        // One header per day, so each row shows only its time.
        ForEach(Notification.groupedByDay(notificationsModel.notifications, date: { $0.date() }), id: \.day) { group in
            // The day is a row, not a pinned section header, so scrolled rows never show through it.
            DayHeaderRow(day: group.day)
            ForEach(group.items, id: \.self) { notification in
                let held = heldUnread.ids.contains(notification.objectID)
                MessageCard(notification: notification, heldUnread: held,
                            open: { focus in opened = OpenedMessage(notification: notification, focusReply: focus) },
                            onCopy: showCopyConfirmation)
                    .modifier(CardRowInsets())
                    .modifier(MessageRowActions(notification: notification, heldUnread: held,
                                                onReleaseHeldUnread: { heldUnread.release(notification.objectID) },
                                                onCopy: showCopyConfirmation))
            }
        }
        if notificationsModel.hasOlder {
            Button(NotificationHistoryStrings.loadOlder) { notificationsModel.loadOlder() }
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        }
    }
    
    private var renameSheet: some View {
        NavigationView {
            Form {
                Section(footer: Text(String(localized: "Set a custom name for this topic. Leave empty to use the topic name."))) {
                    TextField(subscription.topicName(), text: $draftDisplayName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle(String(localized: "Display name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        showRenameSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        store.updateSubscription(subscription: subscription, displayName: draftDisplayName)
                        showRenameSheet = false
                    }
                }
            }
        }
    }

    /// More: frequent actions first, each group divided, destructive ones last (System fixes A, C, D).
    private var topicMenu: some View {
        Menu {
            Section {
                Button { sendTestNotification() } label: {
                    Label(String(localized: "Send test"), systemImage: AppSymbol.test)
                }
                // Step 2 of Add topic, again whenever another agent should use this topic.
                Button { showConnectSheet = true } label: {
                    Label(String(localized: "Connect an agent"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .accessibilityIdentifier("topic-connect-agent")
                // Sharing, together: the link with its commands, the code, the bare publish URL.
                Button(action: shareTopic) {
                    Label(String(localized: "Share topic"), systemImage: AppSymbol.share)
                }
                .accessibilityIdentifier("topic-share")
                Button { showQRCodeSheet = true } label: {
                    Label(String(localized: "Show QR code"), systemImage: AppSymbol.qrCode)
                }
                // The publish URL is what every script needs. Once a topic has messages the
                // empty-state copy buttons are gone, so keep it one tap away here.
                Button {
                    if let baseUrl = subscription.baseUrl {
                        UIPasteboard.general.string = PublishCommand.publishUrl(
                            baseUrl: baseUrl, topic: subscription.topicName())
                        showCopyConfirmation()
                    }
                } label: {
                    Label(String(localized: "Copy publish URL"), systemImage: AppSymbol.copyLink)
                }
            }
            Section {
                TopicMuteButton(subscription: subscription, showingOptions: $showMuteOptions)
                QuietTopicButton(showingOptions: $showQuietOptions)
                TopicSoundButton(showingOptions: $showSoundOptions)
            }
            Section {
                // Pin lives on the topic list's swipe and long-press too; here it is
                // where people look for a topic's settings.
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.setPinned(!subscription.pinned, forSubscription: subscription)
                } label: {
                    Label(subscription.pinned ? String(localized: "Unpin topic") : String(localized: "Pin topic"),
                          systemImage: subscription.pinned ? AppSymbol.unpin() : AppSymbol.pin())
                }
                Button {
                    draftDisplayName = subscription.customDisplayName ?? ""
                    showRenameSheet = true
                } label: {
                    Label(String(localized: "Rename"), systemImage: AppSymbol.rename)
                }
                Button { showEncryptionSheet = true } label: {
                    Label(String(localized: "End-to-end encryption"), systemImage: AppSymbol.encryption)
                }
                Button { showDetails = true } label: {
                    Label(String(localized: "Topic details"), systemImage: AppSymbol.details)
                }
            }
            if notificationsModel.notifications.count > 0 {
                Section {
                    Button {
                        editMode = .active
                        selection = Set<Notification>()
                    } label: {
                        Label(String(localized: "Select messages"), systemImage: AppSymbol.select)
                    }
                }
            }
            Section {
                if notificationsModel.notifications.count > 0 {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label(String(localized: "Clear all notifications"), systemImage: AppSymbol.delete())
                    }
                }
                Button(role: .destructive) { confirmUnsubscribe = true } label: {
                    Label(String(localized: "Unsubscribe"), systemImage: AppSymbol.unsubscribe())
                }
            }
        } label: {
            Image(systemName: AppSymbol.more)
        }
        .accessibilityLabel(String(localized: "Topic actions"))
        .accessibilityIdentifier("topic-actions")
        .shareSheet($shareRequest)
        // Anchored to More, where both were chosen, so the iOS 26 popover points at the ellipsis
        // rather than the title (attached to the list it anchored to the whole screen).
        .confirmationDialog(String(localized: "Delete all messages in \(subscription.shortDisplayName())?"),
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive, action: deleteAll)
        } message: {
            Text(String(localized: "This can't be undone."))
        }
        .confirmationDialog(String(localized: "Unsubscribe from \(subscription.shortDisplayName())?"),
                            isPresented: $confirmUnsubscribe, titleVisibility: .visible) {
            Button(String(localized: "Unsubscribe"), role: .destructive, action: unsubscribe)
        } message: {
            Text(String(localized: "Its messages are deleted from this device."))
        }
    }

    private var showsAddress: Bool {
        TopicServerAddressPolicy.showsAddress(name: subscription.shortDisplayName(),
                                              showAddresses: showServerAddresses,
                                              ambiguousNames: ambiguousNames)
    }

    private func shareTopic() {
        shareRequest = .topic(subscription, store: store, onCopied: showCopyConfirmation)
    }

    private func sendTestNotification(firstRun: Bool = false) {
        guard !sendingTest else { return }
        guard let baseUrl = subscription.baseUrl else {
            Log.w(tag, "Cannot send test notification: subscription base URL is missing")
            return
        }

        let possibleTags: Array<String> = ["warning", "skull", "success", "triangular_flag_on_post", "de", "us", "dog", "cat", "rotating_light", "bike", "backup", "rsync", "this-s-a-tag", "ios"]
        let priority = firstRun ? FirstTopicTest.priority : Int.random(in: 1..<6)
        let tags = firstRun ? [] : Array(possibleTags.shuffled().prefix(Int.random(in: 0..<4)))

        // Never fall back to plaintext on an encrypted topic whose key can't be read right now.
        let keyState = store.topicKeyState(for: subscription)
        if keyState == .unavailable {
            activeAlert = .encryptionUnavailable
            showAlert = true
            return
        }
        let user = store.getBasicUser(baseUrl: baseUrl)
        sendingTest = true
        ApiService.shared.publish(
            subscription: subscription,
            user: user,
            message: firstRun ? FirstTopicTest.body : String(localized: "This is a test notification from NTF-AI. It has a priority of \(priority). If you send another one, it may look different."),
            title: firstRun ? FirstTopicTest.title : String(localized: "Test: You can set a title if you like"),
            priority: priority,
            tags: tags,
            // A topic with a password gets an encrypted test message, so this button also proves the
            // password round-trips through the server.
            encryptionKey: keyState.key,
            completionHandler: {
                DispatchQueue.main.async {
                    sendingTest = false
                    subscriptionManager.pollWithOutcome(subscription, manual: true) { _ in }
                }
            },
            failureHandler: { error in
                DispatchQueue.main.async {
                    sendingTest = false
                    publishError = error.userMessage
                    activeAlert = .publishFailed
                    showAlert = true
                }
            }
        )
    }
    
    private func unsubscribe() {
        subscriptionManager.unsubscribe(subscription)
        presentationMode.wrappedValue.dismiss()
    }
    
    private func deleteAll() {
        store.delete(allNotificationsFor: subscription)
    }
    
    private func deleteSelected() {
        store.delete(notifications: selection)
        selection = Set<Notification>()
        editMode = .inactive
    }
    
    private func cancelSubscriptionNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        // Notification Center calls back off-main. Snapshot values before leaving the view's queue.
        let subscriptionBaseUrl = normalizeBaseUrl(subscription.baseUrl ?? "")
        let subscriptionTopic = subscription.topicName()
        notificationCenter.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { notification in
                    let userInfo = notification.request.content.userInfo
                    if let baseUrl = userInfo["base_url"] as? String, let topic = userInfo["topic"] as? String {
                        // `matches` normalizes both sides. Comparing the payload's raw base URL
                        // against the normalized stored one meant a self-hosted server configured
                        // with a trailing slash never matched, so opening the topic left its banners
                        // sitting in Notification Center until the user cleared them by hand.
                        return normalizeBaseUrl(baseUrl) == subscriptionBaseUrl && topic == subscriptionTopic
                    }
                    return false
                }
                .map { notification in
                    notification.request.identifier
                }
            if !ids.isEmpty {
                Log.d(tag, "Cancelling \(ids.count) notification(s) from notification center")
                notificationCenter.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }
    
    private func showCopyConfirmation() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showCopiedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                showCopiedConfirmation = false
            }
        }
    }
    
}

/// What a new, empty topic shows: ready-to-run publish commands with the full https:// URL, each
/// copyable with one tap, plus where to learn more. See `PublishCommand` for why the scheme matters.
struct TopicPublishHelpView: View {
    let baseUrl: String
    let topic: String
    let encrypted: Bool
    var auth: PublishCommand.Auth = .none
    var sendingTest = false
    var onTest: () -> Void = {}
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "No messages yet"))
                .font(.title3.bold())
            Button(action: onTest) {
                Text(String(localized: "Send a test notification"))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .brandProminentButton()
            .disabled(sendingTest)
            Text(String(localized: "Send a message to this topic from any computer, server or script. Copy a command and run it in a terminal:"))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            copyBlock(title: String(localized: "Send a message"),
                      text: PublishCommand.simple(baseUrl: baseUrl, topic: topic, auth: auth))
            copyBlock(title: String(localized: "With a title and high priority"),
                      text: PublishCommand.titled(baseUrl: baseUrl, topic: topic, auth: auth))
            copyBlock(title: String(localized: "Publish URL"),
                      text: PublishCommand.publishUrl(baseUrl: baseUrl, topic: topic))
            if !auth.isEmpty {
                Text(authNote)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if encrypted {
                Text(String(localized: "These commands send unencrypted messages. For encrypted ones, open End-to-end encryption in the ••• menu."))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let help = URL(string: Config.helpUrl) {
                Link(String(localized: "Quick start and more examples"), destination: help)
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 24)
    }

    private var authNote: String {
        var lines: [String] = []
        if let username = auth.username {
            lines.append(String(localized: "This server uses your login (\(username)). curl asks for the password, so it is never in the copied text."))
        }
        if !auth.headerNames.isEmpty {
            lines.append(String(localized: "Replace \(PublishCommand.headerValuePlaceholder) with the value of \(auth.headerNames.joined(separator: ", ")) from Settings."))
        }
        lines.append(String(localized: "Sending needs write access to this topic; read access alone isn't enough."))
        return lines.joined(separator: " ")
    }

    private func copyBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Button {
                UIPasteboard.general.string = text
                onCopy()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    // Wrap, never truncate: a command with an ellipsis in it is worse than none.
                    Text(verbatim: text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.accentColor)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(UIColor.secondarySystemFill)))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Copy: \(title)"))
            .accessibilityValue(text)
        }
    }
}

struct TopicDetailsView: View {
    @ObservedObject var subscription: Subscription
    @ObservedObject private var bridge = NtfyShBridge.shared
    @Environment(\.dismiss) private var dismiss
    /// Bumped when the bridge, the access cache or a wake check changes in any process.
    @State private var revision = 0

    private var subscribedValue: String {
        guard let date = subscription.subscribedAt else {
            return String(localized: "Subscription date unknown", defaultValue: "Unknown")
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }

    /// Whether this topic gets instant banners, and why not (NtfyShBridge.topicState).
    private var bannerState: NtfyShBridge.TopicState? {
        guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return nil }
        _ = revision
        return bridge.topicState(baseUrl: baseUrl, topic: topic, fcmBound: subscription.fcmSubscribed)
    }

    private var selfHosted: Bool {
        guard let baseUrl = subscription.baseUrl else { return false }
        return !NtfyShAddress.isNtfySh(baseUrl)
    }

    private var bannerHold: NtfyShBridge.TopicHold? {
        if case .held(let hold)? = bannerState { return hold }
        return nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Topic URL"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Text(HostedServer.publicURL(subscription.urlString()))
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    NotificationStatusRow(title: String(localized: "Subscribed"), value: subscribedValue)
                        .accessibilityIdentifier("topic-subscribed-date")
                } header: {
                    Text(String(localized: "About this topic"))
                } footer: {
                    if subscription.subscribedAt == nil {
                        Text(String(localized: "The subscription date was not recorded for this topic."))
                    }
                }
                if let state = bannerState {
                    Section {
                        NotificationStatusRow(title: NtfyShBridgeCopy.instantBanners,
                                              value: bannerHold == nil ? NtfyShBridgeCopy.on
                                                : (bannerHold?.isPending == true ? NtfyShBridgeCopy.pending : NtfyShBridgeCopy.off))
                            .accessibilityIdentifier("topic-instant-banners")
                        if let hold = bannerHold, hold.offersCheckAgain, let baseUrl = subscription.baseUrl, let topic = subscription.topic {
                            let hash = topicHash(baseUrl: baseUrl, topic: topic)
                            // Driven by the stored check (review-130b #8): it clears when the check
                            // completes, the topic is removed, or the arm times out.
                            if SelfHostedWakeCheck.shared.isArmed(hash: hash) {
                                Text(NtfyShBridgeCopy.checkArmed).font(.footnote).foregroundColor(.secondary)
                            } else {
                                Button(NtfyShBridgeCopy.checkAgain) {
                                    NtfyShBridgeCheckAgain.run(hash: hash, bridge: bridge)
                                }
                                .accessibilityIdentifier("topic-check-again")
                            }
                        }
                    } footer: {
                        if let hold = bannerHold { Text(NtfyShBridgeCopy.reason(hold, selfHosted: selfHosted)) }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ntfyShBridgeStateChanged)) { _ in
                bridge.reload(); revision += 1
            }
            .navigationTitle(String(localized: "Topic details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: SheetCloseButton.placement) {
                    SheetCloseButton { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct NotificationListView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview
        Group {
            let subscriptionWithNotifications = store.makeSubscription(store.context, "stats", Store.sampleMessages["stats"]!)
            let subscriptionWithoutNotifications = store.makeSubscription(store.context, "announcements", Store.sampleMessages["announcements"]!)
            NotificationListView(subscription: subscriptionWithNotifications)
                .environment(\.managedObjectContext, store.context)
                .environmentObject(store)
            NotificationListView(subscription: subscriptionWithoutNotifications)
                .environment(\.managedObjectContext, store.context)
                .environmentObject(store)
        }
    }
}

/// A first notification should use the default priority, so it does not arrive silently.
enum FirstTopicTest {
    static let priority = 3
    static let title = String(localized: "NTF-AI test")
    static let body = String(localized: "This is a test notification from NTF-AI. Your topic is ready.")
}

/// Day headers sit close to the rows around them instead of opening a wide gap at each day.
private struct CompactDayBreaks: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content
                .listSectionSpacing(.compact)
                .environment(\.defaultMinListHeaderHeight, 0)
        } else {
            content
        }
    }
}

/// What goes under a topic's title. The title already names the topic, so the subtitle names only
/// its server; a renamed topic keeps the full address, since its title no longer says the topic.
enum TopicSubtitle {
    static func address(for subscription: Subscription) -> String {
        address(server: subscription.serverHost(), fullAddress: subscription.shortUrlString(),
                renamed: subscription.shortDisplayName() != subscription.topicName())
    }

    static func address(server: String, fullAddress: String, renamed: Bool) -> String {
        renamed ? fullAddress : server
    }
}

/// The topic's address under its title, iOS 26's navigation subtitle, when the topic list shows it too.
private struct TopicAddressSubtitle: ViewModifier {
    let address: String?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let address {
            content.navigationSubtitle(address)
        } else {
            content
        }
    }
}

private extension View {
    /// The topic's notices above the list. On iOS 26 a safe-area bar, so the list fades under it
    /// with the scroll-edge effect; earlier versions put the bar material behind it.
    @ViewBuilder
    func topNoticeBar<Notice: View>(@ViewBuilder _ notice: () -> Notice) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: notice)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { notice().background(.bar) }
        }
    }
}

/// "Copied", in a brand capsule with no shadow, and said aloud to VoiceOver.
struct CopiedToast: View {
    var body: some View {
        Text(String(localized: "Copied"))
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Color("Ink"))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color("BrandFill")))
            .onAppear {
                UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
            }
    }
}
