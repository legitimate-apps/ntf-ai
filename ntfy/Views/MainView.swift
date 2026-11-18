import Foundation
import SwiftUI
import UIKit

/// The app's four places (DECISION change 9): Inbox, Topics, Settings and Search.
enum MainTab: Hashable {
    case inbox, topics, settings, search
}

struct MainView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @ObservedObject private var waiting = WaitingObservable.shared
    @State private var linkRequest: LinkRequest?
    /// Outside the `.id`-rebuilt tab view, so a link can choose the tab it lands on.
    @State private var tab: MainTab = .inbox
    @ObservedObject private var launchExperience = LaunchExperience.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Topics `RetiredDefaultServerMigration` moved to ntf-ai.app that the user hasn't been told about.
    @State private var movedTopicsNotice: [String] = []
    private let appGroupDefaults = UserDefaults(suiteName: Store.appGroup) ?? .standard

    private struct LinkRequest: Identifiable {
        let id = UUID()
        let route: TopicLinkRoute
        /// The tapped message's sequence: its page opens on top of the topic.
        var messageSequence: String? = nil
    }

    var body: some View {
        tabs
            // A new link returns to Topics and discards navigation and sheet state belonging
            // to the previous destination, including sheets presented from Settings or a message.
            .id(linkRequest?.id)
            .modifier(MinimizesTabBarOnScroll())
            // SwiftUI delivers Universal Links as URLs, including on a cold launch.
            .onOpenURL(perform: openTopicLink)
            .onChange(of: delegate.selectedBaseUrl) { _ in openSelectedTopic() }
            .onAppear(perform: openSelectedTopic)
            // The launch moments live here, not on a tab: Inbox opens first, so the topic list
            // may never appear in a session.
            .sheet(isPresented: $launchExperience.showingWhatsNew,
                   onDismiss: launchExperience.dismissWhatsNew) {
                WhatsNewView(entries: launchExperience.entries) {
                    launchExperience.showingWhatsNew = false
                }
            }
            .onAppear {
                if linkRequest == nil, delegate.selectedBaseUrl == nil {
                    movedTopicsNotice = RetiredDefaultServerMigration.pendingNoticeTopics(defaults: appGroupDefaults)
                }
            }
            .alert(isPresented: Binding(
                get: { !movedTopicsNotice.isEmpty },
                set: { if !$0 { dismissMovedTopicsNotice() } }
            )) {
                Alert(
                    title: Text(movedTopicsNotice.count == 1 ? String(localized: "Your topic moved to ntf-ai.app") : String(localized: "Your topics moved to ntf-ai.app")),
                    message: Text(RetiredDefaultServerMigration.noticeMessage(topics: movedTopicsNotice)),
                    dismissButton: .default(Text("OK")) { dismissMovedTopicsNotice() }
                )
            }
            .task(id: scenePhase) {
                guard scenePhase == .active, linkRequest == nil else { return }
                launchExperience.prepare(hasSubscriptions: !(store.getSubscriptions() ?? []).isEmpty)
                do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
                guard movedTopicsNotice.isEmpty, !isPresenting, !launchExperience.presentWhatsNew() else { return }
                // The review request waits for a quiet moment on the Inbox, never over a sheet.
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                guard tab == .inbox, linkRequest == nil, !isPresenting else { return }
                await launchExperience.requestReview(store: store)
            }
    }

    private var rootController: UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    }

    /// A sheet (Add topic, Compose, Connect) is up.
    private var isPresenting: Bool { rootController?.presentedViewController != nil }

    private func dismissMovedTopicsNotice() {
        RetiredDefaultServerMigration.dismissNotice(defaults: appGroupDefaults)
        movedTopicsNotice = []
    }

    /// The tab badge counts questions waiting on you; the app icon badge stays unread (DECISION
    /// change 5), so people whose messages carry no actions keep theirs.
    private var waitingBadge: Int { waiting.notifications.count }

    @ViewBuilder private var tabs: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: $tab) {
                Tab(String(localized: "Inbox"), systemImage: "tray", value: MainTab.inbox) { inbox }
                    .badge(waitingBadge)
                Tab(String(localized: "Topics"), systemImage: "tray.full", value: MainTab.topics) { topics }
                Tab(String(localized: "Settings"), systemImage: "gearshape", value: MainTab.settings) { SettingsView() }
                Tab(value: MainTab.search, role: .search) { SearchView() }
            }
        } else {
            TabView(selection: $tab) {
                inbox
                    .tabItem { Label(String(localized: "Inbox"), systemImage: "tray") }
                    .badge(waitingBadge)
                    .tag(MainTab.inbox)
                topics
                    .tabItem { Label(String(localized: "Topics"), systemImage: "tray.full") }
                    .tag(MainTab.topics)
                SettingsView()
                    .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
                    .tag(MainTab.settings)
                SearchView()
                    .tabItem { Label(String(localized: "Search"), systemImage: "magnifyingglass") }
                    .tag(MainTab.search)
            }
        }
    }

    private var inbox: some View { InboxView() }

    private var topics: some View {
        SubscriptionListView(linkRoute: linkRequest?.route, openMessageSequence: linkRequest?.messageSequence)
    }

    private func openTopicLink(_ url: URL) {
        guard let route = TopicLinkRoute.resolve(url, subscriptionURLs: (store.getSubscriptions() ?? []).map { $0.urlString() }) else { return }
        present(route)
    }

    private func openSelectedTopic() {
        guard let url = delegate.selectedBaseUrl else { return }
        let sequence = delegate.selectedMessageSequence
        // Consume the request even if its subscription was removed. Nothing should fire later
        // when a row appears, and another tap on the same topic must be a new request.
        delegate.selectedBaseUrl = nil
        delegate.selectedMessageSequence = nil
        guard (store.getSubscriptions() ?? []).contains(where: { $0.urlString() == url }) else { return }
        present(.open(url), messageSequence: sequence)
    }

    private func present(_ route: TopicLinkRoute, messageSequence: String? = nil) {
        let request = LinkRequest(route: route, messageSequence: messageSequence)
        let present = {
            delegate.selectedBaseUrl = nil
            LaunchExperience.shared.showingWhatsNew = false
            tab = .topics
            linkRequest = request
        }
        // SwiftUI cannot present Add while a previous sheet is still dismissing. Wait for the
        // actual dismissal completion instead of guessing an animation delay, on cold or warm launch.
        if let root = rootController, root.presentedViewController != nil {
            root.dismiss(animated: true, completion: present)
        } else {
            present()
        }
    }
}

/// On iOS 26 the tab bar steps out of the way of long messages while scrolling down.
private struct MinimizesTabBarOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview // Store.previewEmpty
        MainView()
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}
