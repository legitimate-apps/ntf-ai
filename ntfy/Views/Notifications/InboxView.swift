// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import Combine
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
                           symbol: "hand.raised.fill", count: waiting.notifications.count, identifier: "waiting-header",
                           accessory: AnyView(ClearWaitingMoreButton()))
                    .modifier(ClearWaitingMenu())
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
        .modifier(ClearWaitingConfirm())
        .modifier(MessagePageLink(opened: $opened))
    }
}

/// "Clear all" on the Waiting on you header (operator, 2026-11-19): touch and hold the header (on a
/// Mac, right-click or click and hold), or the VoiceOver action. Questions approved elsewhere, by
/// code, or past their window pile up with nothing telling the app; this takes them all out at once,
/// after "Are you sure?" (`ClearWaitingAskBar`). Undo follows (`ClearedToast`).
struct ClearWaitingMenu: ViewModifier {
    @Environment(\.askClearWaiting) private var ask
    /// The header takes VoiceOver focus back when the question is cancelled.
    @AccessibilityFocusState private var headerFocused: Bool

    func body(content: Content) -> some View {
        content
            .contextMenu { ClearWaitingMenuItems() }
            .environment(\.foldHeaderAction, FoldHeaderAction(name: String(localized: "Clear all"),
                                                              run: { ask?.ask() }, focus: $headerFocused))
            .onReceive(ask?.$cancelled.dropFirst().eraseToAnyPublisher() ?? Empty<Int, Never>().eraseToAnyPublisher()) { _ in
                headerFocused = true
            }
    }
}

/// The menu's body: what clearing does, then the one destructive item, which asks before it clears.
/// No icon: the app tint would color it green beside the red title.
struct ClearWaitingMenuItems: View {
    @Environment(\.askClearWaiting) private var ask

    var body: some View {
        Section(header: Text(String(localized: "They leave Waiting on you on this device. The messages stay in Activity."))) {
            Button(String(localized: "Clear all"), role: .destructive) { ask?.ask() }
        }
    }
}

/// Show all's "Clear all": a view of its own so it reads the page's `askClearWaiting`.
struct ClearWaitingToolbarButton: View {
    @Environment(\.askClearWaiting) private var ask

    var body: some View {
        Button(String(localized: "Clear all")) { ask?.ask() }
            .accessibilityIdentifier("waiting-clear-all")
    }
}

/// The open "Are you sure?" of one screen. A class handed down the environment, so asking changes no
/// environment value: only the bar that shows the question redraws, never the list under it.
///
/// It used to be a SwiftUI `.alert` on the whole List. On a Mac that becomes an AppKit window-modal
/// sheet: a new window, a modal session, the main window resigning key (which redraws every row) and
/// AppKit's key-view-loop focus search; 0.2 s to open and 0.16 s to close on a fast Mac, and the
/// 2026-11-27 seven-second freeze on a loaded one began right there.
final class ClearWaitingAsk: ObservableObject {
    /// How many were waiting when asked, so the title doesn't change under the person's finger.
    /// Nil while no question is open.
    @Published private(set) var count: Int?
    /// Counts Cancels, so the header can take VoiceOver focus back.
    @Published private(set) var cancelled = 0
    private let waiting: WaitingObservable

    init(waiting: WaitingObservable = .shared) {
        self.waiting = waiting
    }

    /// Opens the question. Nothing happens while one is already open or nothing is waiting.
    func ask() {
        let waitingNow = waiting.notifications.count
        guard count == nil, waitingNow > 0 else { return }
        count = waitingNow
    }

    /// Clear all: every question now waiting leaves, and Undo is offered.
    func confirm() {
        guard count != nil else { return }
        count = nil
        waiting.clearAll()
    }

    func cancel() {
        guard count != nil else { return }
        count = nil
        cancelled += 1
    }

    /// Closes the question without a Cancel, when Waiting empties under it.
    func close() {
        count = nil
    }
}

/// Hands each screen's `ClearWaitingAsk` to its menus and buttons.
private struct AskClearWaitingKey: EnvironmentKey {
    static let defaultValue: ClearWaitingAsk? = nil
}

extension EnvironmentValues {
    var askClearWaiting: ClearWaitingAsk? {
        get { self[AskClearWaitingKey.self] }
        set { self[AskClearWaitingKey.self] = newValue }
    }
}

/// The question every Clear all goes through (operator, 2026-11-24: "a confirmation are you sure you
/// want to clear all"): how many leave, what clearing does, a red Clear all and Cancel. Each screen
/// that offers Clear all (Inbox, Show all) holds its own, so a pushed page never asks twice. The
/// question and the Undo after it share one place at the bottom of the screen, so they never overlap.
struct ClearWaitingConfirm: ViewModifier {
    /// In `@State`, not `@StateObject`: this modifier wraps the whole List and must not redraw with it.
    @State private var ask = ClearWaitingAsk()

    func body(content: Content) -> some View {
        content
            .environment(\.askClearWaiting, ask)
            .overlay(ClearWaitingSlot(ask: ask))
    }
}

/// The bottom of the screen during a Clear all: the question while it's open, then the Undo.
private struct ClearWaitingSlot: View {
    @ObservedObject var ask: ClearWaitingAsk
    @ObservedObject private var waiting = WaitingObservable.shared

    var body: some View {
        Group {
            if let count = ask.count {
                ClearWaitingAskBar(count: count, confirm: { withAnimation { ask.confirm() } },
                                   cancel: { withAnimation { ask.cancel() } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if waiting.lastClear != nil {
                ClearedToast { withAnimation { waiting.undoClear() } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.default, value: ask.count)
        .animation(.default, value: waiting.lastClear)
        .onChange(of: waiting.notifications.isEmpty) { empty in
            if empty { ask.close() }
        }
    }
}

/// "Clear all 9 questions from Waiting on you?" with what clearing does, Cancel and a red Clear all.
/// VoiceOver lands on it when it opens and stays in it; Escape (or the two-finger scrub) cancels.
/// Return does nothing: no default button, since Clear all is the destructive one.
struct ClearWaitingAskBar: View {
    let count: Int
    let confirm: () -> Void
    let cancel: () -> Void
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ClearWaitingPrompt.title(count: count))
                    .font(.headline)
                Text(String(localized: "They leave Waiting on you on this device. The messages stay in Activity."))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityFocused($focused)
            HStack(spacing: 12) {
                Button(action: cancel) {
                    Text(String(localized: "Cancel")).frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("waiting-clear-cancel")
                Button(role: .destructive, action: confirm) {
                    Text(String(localized: "Clear all")).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("waiting-clear-confirm")
            }
        }
        .padding(16)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, cancel)
        .accessibilityIdentifier("waiting-clear-ask")
        .background(EscapeKey(action: cancel).frame(width: 0, height: 0).accessibilityHidden(true))
        .onAppear {
            // After the menu's own focus change settles, or VoiceOver stays on the header.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
    }
}

/// Escape on a hardware keyboard (iPad, Mac). `.keyboardShortcut(.cancelAction)` alone missed it on
/// iPadOS 26/27 when nothing had keyboard focus, as after a menu or a toolbar tap; this view takes first
/// responder while the question is open and answers only Escape, so Return still does nothing.
private struct EscapeKey: UIViewRepresentable {
    let action: () -> Void

    final class KeyView: UIView {
        var action: () -> Void = {}
        override var canBecomeFirstResponder: Bool { true }
        override var keyCommands: [UIKeyCommand]? {
            let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
            escape.wantsPriorityOverSystemBehavior = true
            return [escape]
        }
        @objc private func escape() { action() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() } }
        }
    }

    func makeUIView(context: Context) -> KeyView { KeyView() }
    func updateUIView(_ view: KeyView, context: Context) { view.action = action }
}

enum ClearWaitingPrompt {
    static func title(count: Int) -> String {
        String(localized: "Clear all \(count) questions from Waiting on you?",
               comment: "Clear all confirmation title. The number is how many questions leave Waiting on you.")
    }
}

/// The visible way in: a "…" just left of the header's count opens the same menu as touch and hold.
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
