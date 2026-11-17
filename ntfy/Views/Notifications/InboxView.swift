import CoreData
import SwiftUI

/// The first tab (DECISION change 9): the questions agents are blocked on, then everything the
/// agents said, newest first, across every topic that isn't muted.
struct InboxView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var waiting = WaitingObservable.shared
    @StateObject private var activity = NotificationsObservable(scope: .activity)
    @StateObject private var subscriptions = SubscriptionsObservable()
    @State private var opened: OpenedMessage?
    @State private var showAllWaiting = false
    @State private var showingAdd = false
    @State private var showCopied = false
    @ObservedObject private var fold = SectionFold.shared

    /// Three questions on iPhone keep Activity in reach; iPad has room for five (DECISION change 3).
    private var waitingCap: Int { sizeClass == .regular ? 5 : 3 }

    var body: some View {
        NavigationView {
            content
                .navigationTitle(String(localized: "Inbox"))
                .modifier(MessagePageLink(opened: $opened))
                .background(
                    NavigationLink(isActive: $showAllWaiting) {
                        WaitingAllView()
                    } label: { EmptyView() }
                    .hidden()
                )
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showingAdd) {
            SubscriptionAddView(isShowing: $showingAdd)
        }
    }

    @ViewBuilder private var content: some View {
        if waiting.notifications.isEmpty && activity.notifications.isEmpty {
            if subscriptions.subscriptions.isEmpty {
                InboxEmptyState(symbol: "tray",
                                title: String(localized: "No agents yet"),
                                message: String(localized: "Connect an agent and its messages and questions show up here."),
                                actionTitle: String(localized: "Connect your first agent"),
                                actionIdentifier: "inbox-connect-first") { showingAdd = true }
            } else {
                InboxEmptyState(symbol: "tray",
                                title: String(localized: "No messages yet"),
                                message: String(localized: "What your agents send shows up here, newest first."))
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !waiting.notifications.isEmpty {
                FoldHeader(fold: fold, id: SectionFold.waiting, title: String(localized: "Waiting on you"),
                           symbol: "hand.raised.fill", count: waiting.notifications.count, identifier: "waiting-header")
                    .modifier(ListHeaderRow())
                if !fold.isCollapsed(SectionFold.waiting) {
                    ForEach(waiting.notifications.prefix(waitingCap), id: \.objectID) { notification in
                        WaitingRow(notification: notification) { focus in
                            opened = OpenedMessage(notification: notification, focusReply: focus)
                        }
                        .modifier(CardRowInsets())
                        .modifier(NotNeededSwipe(notification: notification))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if waiting.notifications.count > waitingCap {
                        Button {
                            showAllWaiting = true
                        } label: {
                            HStack {
                                Text(String(localized: "Show all \(waiting.notifications.count)"))
                                    .foregroundColor(InboxColor.ink)
                                Spacer()
                                RowAccessoryGlyph()
                            }
                        }
                        .accessibilityIdentifier("waiting-show-all")
                    }
                }
            }
            if !activity.notifications.isEmpty {
                // Activity heads the days; folding it folds every day under it.
                FoldHeader(fold: fold, id: SectionFold.activity, title: String(localized: "Activity"),
                           identifier: "activity-header")
                    .modifier(ListHeaderRow(topSpace: waiting.notifications.isEmpty ? 0 : 16))
                if !fold.isCollapsed(SectionFold.activity) {
                    let days = Notification.groupedByDay(activity.notifications, date: { $0.date() })
                    ForEach(days, id: \.day) { group in
                        DayHeaderRow(day: group.day)
                        ForEach(group.items, id: \.objectID) { notification in
                            MessageCard(notification: notification, showsTopic: true, defersToWaiting: true,
                                        open: { focus in opened = OpenedMessage(notification: notification, focusReply: focus) },
                                        onCopy: copied)
                                .modifier(CardRowInsets())
                                .modifier(MessageRowActions(notification: notification, onCopy: copied))
                        }
                    }
                    if activity.hasOlder {
                        Button(NotificationHistoryStrings.loadOlder) { activity.loadOlder() }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        // One level of inset (operator, 2026-11-17): rows run edge to edge with hairlines between
        // them, as in Mail, instead of cards inside the screen's margins.
        .listStyle(.plain)
        .modifier(ReadableCardWidth())
        .animation(.default, value: waiting.notifications.map(\.objectID))
        .refreshable {
            await SubscriptionManager(store: store).pollAll(store.getSubscriptions() ?? [], manual: true)
        }
        .overlay(Group {
            if showCopied {
                CopiedToast()
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        })
    }

    private func copied() {
        withAnimation { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { showCopied = false } }
    }
}

/// "Not needed": the person's way to take a question out of Waiting when the agent got its
/// answer some other way (DIRECTIONS 1.6).
struct NotNeededSwipe: ViewModifier {
    let notification: Notification

    func body(content: Content) -> some View {
        content.swipeActions(edge: .trailing) {
            Button {
                withAnimation { WaitingObservable.shared.dismiss(notification) }
            } label: {
                Label(String(localized: "Not needed"), systemImage: "xmark")
            }
            .tint(.gray)
        }
    }
}

/// Every waiting question, past the Inbox's cap.
struct WaitingAllView: View {
    @ObservedObject private var waiting = WaitingObservable.shared
    @State private var opened: OpenedMessage?

    var body: some View {
        List {
            Section(header: WaitingHeader(count: waiting.notifications.count)) {
                ForEach(waiting.notifications, id: \.objectID) { notification in
                    WaitingRow(notification: notification) { focus in
                        opened = OpenedMessage(notification: notification, focusReply: focus)
                    }
                    .modifier(CardRowInsets())
                    .modifier(NotNeededSwipe(notification: notification))
                }
            }
        }
        .listStyle(.plain)
        .modifier(ReadableCardWidth())
        .animation(.default, value: waiting.notifications.map(\.objectID))
        .navigationTitle(String(localized: "Waiting on you"))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(MessagePageLink(opened: $opened))
    }
}
