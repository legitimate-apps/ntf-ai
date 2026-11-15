import SwiftUI
import CoreData
import FirebaseMessaging
import UserNotifications
import UIKit

struct SubscriptionListView: View {
    let tag = "SubscriptionList"
    var linkRoute: TopicLinkRoute? = nil
    /// With an `.open` route from a banner tap: the message whose page opens on top of the topic.
    var openMessageSequence: String? = nil
    
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    // @StateObject, not @ObservedObject: `SubscriptionsObservable()` is constructed here, and
    // @ObservedObject does not own what it is given — SwiftUI is free to rebuild this view's struct
    // and hand it a freshly constructed observable, throwing away the live NSFetchedResultsController
    // (and its delegate registration) mid-flight. @StateObject makes the view the owner, so exactly
    // one controller is created for the view's lifetime.
    @StateObject private var subscriptionsModel = SubscriptionsObservable()
    @ObservedObject private var waiting = WaitingObservable.shared
    @AppStorage(TopicServerAddressPolicy.preferenceKey) private var showServerAddresses = TopicServerAddressPolicy.defaultValue
    @State private var showingAddDialog = false
    @State private var handledTopicLink = false
    @State private var openedSubscription: Subscription?
    
    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }
    
    var body: some View {
        NavigationView {
            subscriptionList
                .refreshable {
                    await pollSubscriptions(manual: true)
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private var subscriptionList: some View {
        VStack(spacing: 0) {
            if NotificationHealth.showsBanner(for: delegate.notificationAuthorizationStatus) {
                NotificationPermissionBanner()
            }
            topicList
        }
    }

    /// The newest waiting question per topic, so a question never hides behind a later message.
    private var waitingByTopic: [NSManagedObjectID: Notification] {
        var result: [NSManagedObjectID: Notification] = [:]
        for notification in waiting.notifications {
            guard let id = notification.subscription?.objectID, result[id] == nil else { continue }
            result[id] = notification
        }
        return result
    }

    private var topicList: some View {
        let ambiguousNames = TopicServerAddressPolicy.ambiguousNames(in: subscriptionsModel.subscriptions)
        let waitingByTopic = waitingByTopic
        return List {
            ForEach(subscriptionsModel.subscriptions) { subscription in
                SubscriptionItemNavView(subscription: subscription,
                                        summary: subscriptionsModel.summaries[subscription.objectID],
                                        showServerAddress: TopicServerAddressPolicy.showsAddress(
                                            name: subscription.shortDisplayName(), showAddresses: showServerAddresses,
                                            ambiguousNames: ambiguousNames),
                                        waiting: waitingByTopic[subscription.objectID])
                    // A rule above the first row read as an underline on the large title.
                    .listRowSeparator(subscription == subscriptionsModel.subscriptions.first ? .hidden : .automatic, edges: .top)
                    // The unread dot sits in the leading gutter, as in Mail (DIRECTIONS A1).
                    .listRowInsets(EdgeInsets(top: 10, leading: 28, bottom: 10, trailing: 16))
            }
        }
        // This link lives outside the lazy List rows, so an external request can open any topic.
        .background(
            NavigationLink(isActive: Binding(
                get: { openedSubscription != nil },
                set: { if !$0 { openedSubscription = nil } }
            )) {
                if let subscription = openedSubscription {
                    NotificationListView(subscription: subscription, openMessageSequence: openMessageSequence)
                }
            } label: {
                EmptyView()
            }
            .hidden()
        )
        .listStyle(PlainListStyle())
        .modifier(ReadableCardWidth())
        .navigationTitle(String(localized: "Topics"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    self.showingAddDialog = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "Add topic"))
            }
        }
        .overlay(Group {
            if subscriptionsModel.subscriptions.isEmpty {
                InboxEmptyState(symbol: "tray.full",
                                title: String(localized: "No topics yet"),
                                message: String(localized: "Each agent sends to a topic. Add one and connect your agent to it."),
                                actionTitle: String(localized: "Connect your first agent"),
                                actionIdentifier: "empty-create-topic") { showingAddDialog = true }
            }
        })
        .sheet(isPresented: $showingAddDialog) {
            SubscriptionAddView(isShowing: $showingAddDialog, topicLink: addTopicLink)
        }
        .onAppear {
            if let linkRoute, !handledTopicLink {
                handledTopicLink = true
                switch linkRoute {
                case .add: showingAddDialog = true
                case .open(let url):
                    openedSubscription = (store.getSubscriptions() ?? []).first { $0.urlString() == url }
                }
            }
        }
    }

    private var addTopicLink: TopicLink? {
        if case .add(let link) = linkRoute { return link }
        return nil
    }

    @MainActor
    private func pollSubscriptions(manual: Bool) async {
        await subscriptionManager.pollAll(store.getSubscriptions() ?? [], manual: manual)
    }
}

struct SubscriptionItemNavView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var subscription: Subscription
    let summary: Store.SubscriptionSummary?
    var showServerAddress: Bool = false
    /// The topic's newest question waiting on you, shown in the preview instead of the newest message.
    var waiting: Notification? = nil
    @State private var unsubscribeAlert = false
    @State private var showMuteOptions = false
    @State private var showQuietOptions = false
    @State private var showSoundOptions = false
    
    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }
    
    var body: some View {
        if #available(iOS 15.0, *) {
            subscriptionRow
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    // Mirrors Messages: swipe right to toggle read state, and a full swipe commits
                    // it without waiting for a tap.
                    Button {
                        toggleRead()
                    } label: {
                        readLabel(swipe: true)
                    }
                    .tint(Color("BrandControlFill"))

                    Button {
                        togglePinned()
                    } label: {
                        pinLabel(swipe: true)
                    }
                    .tint(PinBadge.tint)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // Swipes take the filled symbols; indigo is Messages' hide-alerts colour, where
                    // grey read as a disabled action.
                    Button { showMuteOptions = true } label: {
                        Label(TopicMute.isMuted(until: subscription.mutedUntil) ? String(localized: "Mute settings") : String(localized: "Mute topic"),
                              systemImage: AppSymbol.mute(swipe: true))
                    }
                    .tint(.indigo)
                    // Named for what it does: the confirmation is "Unsubscribe", and a swipe that
                    // said "Delete" read as deleting messages, not leaving the topic.
                    Button(role: .destructive) {
                        self.unsubscribeAlert = true
                    } label: {
                        Label(String(localized: "Unsubscribe"), systemImage: AppSymbol.unsubscribe(swipe: true))
                    }
                    // The app-wide tint overrides the destructive role in swipe actions; keep it red.
                    .tint(.red)
                }
                // Long-press offers the same actions for anyone who never tries a swipe. A blind
                // setup test looked for pin here, found nothing and concluded the app had none.
                // Frequent first, then the topic's alert settings, then leaving it.
                .contextMenu {
                    Section {
                        Button {
                            toggleRead()
                        } label: {
                            readLabel(swipe: false)
                        }
                        Button {
                            togglePinned()
                        } label: {
                            pinLabel(swipe: false)
                        }
                    }
                    Section {
                        TopicMuteButton(subscription: subscription, showingOptions: $showMuteOptions)
                        QuietTopicButton(showingOptions: $showQuietOptions)
                        TopicSoundButton(showingOptions: $showSoundOptions)
                    }
                    Section {
                        Button(role: .destructive) {
                            self.unsubscribeAlert = true
                        } label: {
                            Label(String(localized: "Unsubscribe"), systemImage: AppSymbol.unsubscribe())
                        }
                    }
                }
        } else {
            subscriptionRow
        }
    }

    /// Flip the whole topic's read state, with the same light impact Messages gives when a full
    /// swipe commits. SwiftUI hands us one callback for both the tap and the full swipe, so the
    /// haptic fires for either — there is no API to distinguish them.
    private func toggleRead() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if subscription.hasUnread() {
            store.setRead(true, forSubscription: subscription)
        } else {
            // Only the newest message comes back unread — see Store.markMostRecentUnread.
            store.markMostRecentUnread(subscription: subscription)
        }
    }
    
    private func readLabel(swipe: Bool) -> some View {
        // From the summary, not `subscription.hasUnread()`. SwiftUI builds this label while
        // building the row, not when the user swipes or long-presses, and hasUnread() scans the
        // to-many relationship — which would fault every topic's whole history during list
        // rendering and undo the point of the aggregate. `toggleRead()` still asks the object
        // directly: by then the user has acted and a fresh authoritative read is worth one fault.
        let unread = (summary?.unread ?? subscription.unreadCount()) > 0
        return Label(unread ? String(localized: "Mark read") : String(localized: "Mark unread"),
                     systemImage: unread ? AppSymbol.markRead(swipe: swipe) : AppSymbol.markUnread(swipe: swipe))
    }

    private func pinLabel(swipe: Bool) -> some View {
        Label(subscription.pinned ? String(localized: "Unpin") : String(localized: "Pin"),
              systemImage: subscription.pinned ? AppSymbol.unpin(swipe: swipe) : AppSymbol.pin(swipe: swipe))
    }

    private func togglePinned() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.setPinned(!subscription.pinned, forSubscription: subscription)
    }

    private var subscriptionRow: some View {
        ZStack {
            NavigationLink(
                destination: LazyView(NotificationListView(subscription: subscription))
            ) {
                EmptyView()
            }
            .opacity(0.0)
            .buttonStyle(PlainButtonStyle())
            
            SubscriptionItemRowView(subscription: subscription, summary: summary, showServerAddress: showServerAddress,
                                    waiting: waiting)
        }
        .accessibilityElement(children: .combine)
        .sheet(isPresented: $showQuietOptions) { QuietTopicView(subscription: subscription) }
        .sheet(isPresented: $showSoundOptions) { TopicSoundView(subscription: subscription) }
        .sheet(isPresented: $showMuteOptions) {
            TopicMuteView(subscription: subscription)
        }
        .confirmationDialog(String(localized: "Unsubscribe from \(subscription.shortDisplayName())?"),
                            isPresented: $unsubscribeAlert, titleVisibility: .visible) {
            Button(String(localized: "Unsubscribe"), role: .destructive) {
                self.subscriptionManager.unsubscribe(subscription)
                self.unsubscribeAlert = false
            }
        } message: {
            Text(String(localized: "Its messages are deleted from this device."))
        }
    }
}

/// A topic in the list (DIRECTIONS A1): who (avatar and name), when, and what it last said, with
/// an unread dot in the leading gutter and the hand when a question is waiting.
struct SubscriptionItemRowView: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @ObservedObject private var deliveryHealth = DeliveryHealthMonitor.shared
    @ObservedObject var subscription: Subscription
    let summary: Store.SubscriptionSummary?
    let showServerAddress: Bool
    var waiting: Notification? = nil

    init(subscription: Subscription, summary: Store.SubscriptionSummary?, showServerAddress: Bool = false,
         waiting: Notification? = nil) {
        self.subscription = subscription
        self.summary = summary
        self.showServerAddress = showServerAddress
        self.waiting = waiting
    }

    var body: some View {
        // From one aggregate for the whole list. The fallbacks keep previews and any caller
        // without a summary working; they are the old per-row faulting path and should stay unused
        // in the list itself.
        let unread = summary?.unread ?? subscription.unreadCount()
        let lastNotification = summary.map { $0.lastNotification } ?? subscription.lastNotification()
        // A waiting question leads the preview, so it never hides behind a later "build passed".
        let shown = waiting ?? lastNotification
        let lastTime = summary.map { $0.lastTime } ?? subscription.lastNotification().map { $0.time }
        let lastDateTime = lastTime.map { Notification.topicListTime(for: Date(timeIntervalSince1970: TimeInterval($0))) }
        HStack(alignment: .top, spacing: 12) {
            TopicAvatar(name: subscription.shortDisplayName(), iconUrl: lastNotification?.iconUrl())
            VStack(alignment: .leading, spacing: 2) {
                if sizeCategory.isAccessibilityCategory {
                    // At accessibility sizes the name gets its own lines and the time the next.
                    nameLine.lineLimit(3)
                    if let lastDateTime { timeText(lastDateTime, unread: unread > 0) }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        nameLine.lineLimit(1)
                        Spacer(minLength: 8)
                        if let lastDateTime { timeText(lastDateTime, unread: unread > 0) }
                        RowAccessoryGlyph()
                    }
                }
                if showServerAddress {
                    // Only when two topics share a name (or the user asked for addresses).
                    Text(subscription.shortUrlString())
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text(String(localized: "on \(subscription.serverHost())")))
                }
                if let shown {
                    preview(shown, waiting: waiting != nil, unread: unread > 0)
                        .font(.subheadline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("topic-row-preview")
                }
                if let health = deliveryHealth.topics[subscription.objectID.uriRepresentation().absoluteString], let label = health.label {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if health.needsAttention {
                            Image(systemName: "exclamationmark.triangle")
                                .accessibilityHidden(true)
                        }
                        Text(label).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
            }
            .modifier(SeparatorUnderText())
        }
        .overlay(alignment: .topLeading) {
            if unread > 0 {
                Circle().fill(InboxColor.ink).frame(width: 10, height: 10)
                    .offset(x: -23, y: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(unread > 0 ? String(localized: "\(unread) unread") : "")
    }

    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(subscription.shortDisplayName()).font(.headline)
            if subscription.pinned {
                Image(systemName: "pin.fill").font(.footnote).foregroundColor(.secondary)
                    .accessibilityLabel(Text(String(localized: "Pinned")))
            }
            if TopicMute.isMuted(until: subscription.mutedUntil) {
                Image(systemName: "bell.slash.fill").font(.footnote).foregroundColor(.secondary)
                    .accessibilityLabel(Text(String(localized: "Muted")))
            }
        }
    }

    private func timeText(_ value: String, unread: Bool) -> some View {
        Text(value)
            .font(.subheadline)
            .foregroundColor(unread ? InboxColor.ink : .secondary)
            .lineLimit(1)
            // The timestamp keeps its full width and the topic name yields instead (ntfy#1205): a
            // name reads fine truncated, a clipped clock does not.
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    /// Title, a dash, then the body, led by the waiting hand, a priority mark, or the orange
    /// "Not encrypted" mark when the message came without the topic's password.
    private func preview(_ notification: Notification, waiting: Bool, unread: Bool) -> Text {
        var text = Text("")
        if waiting {
            text = text + Text(Image(systemName: "hand.raised.fill")).foregroundColor(InboxColor.ink) + Text(" ")
        }
        if notification.priority == 5 {
            text = text + Text(Image(systemName: "exclamationmark.2")).foregroundColor(.red) + Text(" ")
        } else if notification.priority == 4 {
            text = text + Text(Image(systemName: "exclamationmark")).foregroundColor(.orange) + Text(" ")
        }
        if notification.previewIsMarkedNotEncrypted {
            text = text + Text(Image(systemName: "lock.open")).foregroundColor(.orange)
                + Text(" " + String(localized: "Not encrypted") + " · ").foregroundColor(.orange)
        }
        if notification.encryptionState == .locked {
            return text + Text(notification.formatMessage()).foregroundColor(.secondary)
        }
        let display = notification.display
        let plainBody = String(renderMessageBody(display.body, contentType: display.markdown ? "text/markdown" : nil).characters)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let words = [display.title, plainBody.isEmpty ? nil : plainBody].compactMap { $0 }.joined(separator: " – ")
        return text + Text(words).foregroundColor(unread ? .primary : .secondary)
    }
}

/// The row's separator starts under the name, past the avatar, as in Messages.
private struct SeparatorUnderText: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } else {
            content
        }
    }
}

/// Count pill for unread messages. Capsule rather than a strict circle so three-digit
/// counts stay legible instead of squashing, matching how iOS badges grow.
struct UnreadBadge: View {
    let count: Int

    // Ink count text is 9.78:1 on the top and 8.63:1 on the bottom stop, in either appearance.
    private static let top = Color("UnreadBadgeTop")
    private static let bottom = Color("UnreadBadgeBottom")

    private var label: String { count > 99 ? String(localized: "99+") : count.formatted(.number) }

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold))
            .foregroundColor(Color("Ink"))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 24)
            .background(
                Capsule().fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Self.top, Self.bottom]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .accessibilityLabel(Text(String(localized: "\(count) unread")))
    }
}

/// Marks a pinned topic ahead of its name: a tilted pin in a warm gradient, the colour iOS uses for
/// pins in Messages and Mail, so it reads as "pinned" at a glance alongside the emerald
/// unread badge. Sized from the headline font so it scales with Dynamic Type alongside the name.
struct PinBadge: View {
    static let tint = Color(red: 0.96, green: 0.55, blue: 0.13)
    private static let top = Color(red: 1.0, green: 0.74, blue: 0.25)

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.subheadline.weight(.semibold))
            .rotationEffect(.degrees(45))
            .foregroundColor(Self.tint)
            .overlay(
                LinearGradient(gradient: Gradient(colors: [Self.top, Self.tint]),
                               startPoint: .top, endPoint: .bottom)
                    .mask(
                        Image(systemName: "pin.fill")
                            .font(.subheadline.weight(.semibold))
                            .rotationEffect(.degrees(45))
                    )
            )
            .accessibilityLabel(Text(String(localized: "Pinned")))
    }
}

struct SubscriptionListView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview // Store.previewEmpty
        SubscriptionListView()
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}

enum TopicServerAddressPolicy {
    static let preferenceKey = "showTopicServerAddresses"
    /// Off: every row carried the same host. Shown only where two topics share a name (A1).
    static let defaultValue = false

    static func ambiguousNames(in subscriptions: [Subscription]) -> Set<String> {
        let groups = Dictionary(grouping: subscriptions) { $0.shortDisplayName().lowercased() }
        return Set(groups.compactMap { name, topics in
            Set(topics.map { $0.urlString() }).count > 1 ? name : nil
        })
    }

    static func showsAddress(name: String, showAddresses: Bool = defaultValue, ambiguousNames: Set<String>) -> Bool {
        showAddresses || ambiguousNames.contains(name.lowercased())
    }
}
