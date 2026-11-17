import SwiftUI

struct TopicMuteButton: View {
    @ObservedObject var subscription: Subscription
    @Binding var showingOptions: Bool

    var body: some View {
        Button { showingOptions = true } label: {
            Label(TopicMute.isMuted(until: subscription.mutedUntil) ? String(localized: "Mute settings") : String(localized: "Mute topic"), systemImage: AppSymbol.mute())
        }
    }
}

struct TopicMuteView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject var subscription: Subscription
    @State private var saveFailed = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text(subscription.shortDisplayName()), footer: Text(String(localized: "Messages will still arrive and stay in your history. Notifications will appear quietly in Notification Center, with no sound or banner. Unread counts and the app badge will still update."))) {
                    if TopicMute.isMuted(until: subscription.mutedUntil) {
                        TopicMuteStatus(subscription: subscription)
                        Button(String(localized: "Unmute")) { save(nil) }
                            .foregroundColor(.primary)
                    }
                    ForEach(TopicMuteDuration.allCases) { duration in
                        Button(duration.title) { save(duration.deadline()) }
                            .foregroundColor(.primary)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(String(localized: "topic.mute.title", defaultValue: "Mute topic"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: SheetCloseButton.placement) {
                    SheetCloseButton { presentationMode.wrappedValue.dismiss() }
                }
            }
            .alert(isPresented: $saveFailed) {
                Alert(title: Text(String(localized: "Couldn't save mute setting")), message: Text(String(localized: "Please try again.")), dismissButton: .default(Text("OK")))
            }
        }
    }

    private func save(_ until: Date?) {
        do {
            try store.setTopicMute(until: until, subscription: subscription)
            presentationMode.wrappedValue.dismiss()
        } catch { saveFailed = true }
    }
}

struct TopicMuteStatus: View {
    @ObservedObject var subscription: Subscription
    /// In a topic's notice bar it takes the shared notice style; in rows it stays a quiet line.
    var asNotice = false
    var body: some View {
        // Refresh at the deadline even if this screen stays open. Delivery does not depend on this.
        TimelineView(MuteExpirySchedule(until: subscription.mutedUntil)) { context in
            if let status = TopicMute.status(until: subscription.mutedUntil, now: context.date) {
                if asNotice {
                    InlineNotice(symbol: AppSymbol.mute(swipe: true), text: status)
                } else {
                    Label(status, systemImage: AppSymbol.mute(swipe: true))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Include the initial instant as well as the deadline. There is no recurring timer.
private struct MuteExpirySchedule: TimelineSchedule {
    let until: Date?
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        guard let until, until != .distantFuture, until > startDate else { return [startDate] }
        return [startDate, until]
    }
}
