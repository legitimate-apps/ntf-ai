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
                HStack(spacing: 10) {
                    FoldHeader(fold: fold, id: SectionFold.waiting, title: String(localized: "Waiting on you"),
                               symbol: "hand.raised.fill", count: waiting.notifications.count, identifier: "waiting-header")
                        .modifier(ClearWaitingMenu())
                    ClearWaitingMoreButton()
                }
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
        .modifier(ClearWaitingUndo())
        .modifier(ClearWaitingConfirm())
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
            Section(header: WaitingHeader(count: waiting.notifications.count).modifier(ClearWaitingMenu())) {
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !waiting.notifications.isEmpty {
                    ClearWaitingToolbarButton()
                }
            }
        }
        .modifier(ClearWaitingUndo())
        .modifier(ClearWaitingConfirm())
        .modifier(MessagePageLink(opened: $opened))
    }
}

/// "Clear all" on the Waiting on you header (operator, 2026-11-19): touch and hold the header (on a
/// Mac, right-click or click and hold), or the VoiceOver action. Questions approved elsewhere, by
/// code, or past their window pile up with nothing telling the app; this takes them all out at once,
/// after "Are you sure?" (`ClearWaitingConfirm`). Undo follows (`ClearWaitingUndo`).
struct ClearWaitingMenu: ViewModifier {
    @Environment(\.askClearWaiting) private var askClear

    func body(content: Content) -> some View {
        content
            .contextMenu { ClearWaitingMenuItems() }
            .accessibilityAction(named: Text(String(localized: "Clear all"))) { askClear() }
    }
}

/// The menu's body: what clearing does, then the one destructive item, which asks before it clears.
/// No icon: the app tint would color it green beside the red title.
struct ClearWaitingMenuItems: View {
    @Environment(\.askClearWaiting) private var askClear

    var body: some View {
        Section(header: Text(String(localized: "They leave Waiting on you on this device. The messages stay in Activity."))) {
            Button(String(localized: "Clear all"), role: .destructive) { askClear() }
        }
    }
}

/// Show all's "Clear all": a view of its own so it reads the page's `askClearWaiting`.
struct ClearWaitingToolbarButton: View {
    @Environment(\.askClearWaiting) private var askClear

    var body: some View {
        Button(String(localized: "Clear all")) { askClear() }
            .accessibilityIdentifier("waiting-clear-all")
    }
}

/// Opens the "Are you sure?" for Clear all on the screen that shows it (`ClearWaitingConfirm`).
private struct AskClearWaitingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var askClearWaiting: () -> Void {
        get { self[AskClearWaitingKey.self] }
        set { self[AskClearWaitingKey.self] = newValue }
    }
}

/// The question every Clear all goes through (operator, 2026-11-24: "a confirmation are you sure you
/// want to clear all"): how many leave, what clearing does, a red Clear all and Cancel. Each screen
/// that offers Clear all (Inbox, Show all) holds its own, so a pushed page never asks twice.
struct ClearWaitingConfirm: ViewModifier {
    @ObservedObject private var waiting = WaitingObservable.shared
    @State private var asking = false
    /// The count when asked, so the title doesn't change under the person's finger.
    @State private var count = 0

    func body(content: Content) -> some View {
        content
            .environment(\.askClearWaiting) {
                count = waiting.notifications.count
                if count > 0 { asking = true }
            }
            .alert(ClearWaitingPrompt.title(count: count), isPresented: $asking) {
                Button(String(localized: "Clear all"), role: .destructive) {
                    withAnimation { waiting.clearAll() }
                }
                .accessibilityIdentifier("waiting-clear-confirm")
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "They leave Waiting on you on this device. The messages stay in Activity."))
            }
    }
}

enum ClearWaitingPrompt {
    static func title(count: Int) -> String {
        String(localized: "Clear all \(count) questions from Waiting on you?",
               comment: "Clear all confirmation title. The number is how many questions leave Waiting on you.")
    }
}

/// The visible way in: a "…" beside the header's chevron opens the same menu as touch and hold.
struct ClearWaitingMoreButton: View {
    var body: some View {
        Menu { ClearWaitingMenuItems() } label: {
            Image(systemName: "ellipsis.circle")
                .font(.headline)
                .foregroundColor(.secondary)
                .frame(minWidth: 44, minHeight: FoldHeaderAccessibility.minimumHitHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "More for Waiting on you"))
        .accessibilityIdentifier("waiting-more")
    }
}

/// The Undo bar after "Clear all": what happened and one button, for a few seconds.
struct ClearWaitingUndo: ViewModifier {
    @ObservedObject private var waiting = WaitingObservable.shared

    func body(content: Content) -> some View {
        content.overlay(Group {
            if let cleared = waiting.lastClear {
                ClearedToast { withAnimation { waiting.undoClear() } }
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        })
        .animation(.default, value: waiting.lastClear)
    }
}

/// "Questions cleared | Undo", in the same brand capsule as "Copied", said aloud to VoiceOver.
struct ClearedToast: View {
    let undo: () -> Void

    private var text: String { String(localized: "Questions cleared") }

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
            Rectangle().fill(Color("Ink").opacity(0.35)).frame(width: 1, height: 16).accessibilityHidden(true)
            Button(action: undo) {
                Text(String(localized: "Undo")).fontWeight(.bold).foregroundColor(Color("Ink"))
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("waiting-undo-clear")
        }
        .foregroundColor(Color("Ink"))
        .font(.subheadline.weight(.semibold))
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color("BrandFill")).padding(.vertical, 2))
        .accessibilityElement(children: .contain)
        .onAppear { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}
