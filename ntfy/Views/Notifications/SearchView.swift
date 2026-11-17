import SwiftUI

/// The Search tab: every topic's messages, matched on title and text. Replaces the per-topic
/// field that floated over the last message (DIRECTIONS 1.7).
struct SearchView: View {
    @StateObject private var results = NotificationsObservable(scope: .search)
    @State private var query = ""
    @State private var opened: OpenedMessage?

    var body: some View {
        NavigationView {
            list
                .navigationTitle(String(localized: "Search"))
                .modifier(MessagePageLink(opened: $opened))
                .searchable(text: $query, prompt: NotificationHistoryStrings.search)
                .onChange(of: query) { results.scheduleSearch($0) }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder private var list: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            InboxEmptyState(symbol: "magnifyingglass",
                            title: NotificationHistoryStrings.search,
                            message: String(localized: "Find a message from any topic by its title or text."))
        } else if results.notifications.isEmpty {
            InboxEmptyState(symbol: "magnifyingglass",
                            title: NotificationHistoryStrings.noMatches,
                            message: String(localized: "Check the spelling or try another word."))
        } else {
            List {
                let days = Notification.groupedByDay(results.notifications, date: { $0.date() })
                ForEach(days, id: \.day) { group in
                    Section(header: DayHeader(title: Notification.daySectionTitle(for: group.day))) {
                        ForEach(group.items, id: \.objectID) { notification in
                            MessageCard(notification: notification, showsTopic: true,
                                        open: { focus in opened = OpenedMessage(notification: notification, focusReply: focus) })
                                .listRowInsets(CardSpacing.rowInsets)
                                .modifier(MessageRowActions(notification: notification))
                        }
                    }
                }
                if results.hasOlder {
                    Button(NotificationHistoryStrings.loadOlder) { results.loadOlder() }
                        .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.insetGrouped)
            .modifier(ReadableCardWidth())
        }
    }
}
