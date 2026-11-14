import CoreData
import Foundation
import Combine

/// Which question an answer belongs to: server, topic and sequence. A sequence update replaces its
/// row in place, so the key outlives an agent's edit of the question. `version` is the message id
/// the person saw: an answer applies only to that version, so a new question that reuses the
/// sequence waits again.
struct AnswerKey: Hashable {
    let baseUrl: String
    let topic: String
    let sequence: String
    var version: String?

    var id: String { "\(normalizeBaseUrl(baseUrl))|\(topic)|\(sequence)" }

    init(baseUrl: String, topic: String, sequence: String, version: String? = nil) {
        self.baseUrl = baseUrl
        self.topic = topic
        self.sequence = sequence
        self.version = version
    }

    init?(notification: Notification) {
        guard let subscription = notification.subscription, let baseUrl = subscription.baseUrl,
              let topic = subscription.topic, let id = notification.id else { return nil }
        let sequence = notification.sequenceID.flatMap { $0.isEmpty ? nil : $0 } ?? id
        self.init(baseUrl: baseUrl, topic: topic, sequence: sequence, version: id)
    }
}

/// What the person did with a question (DIRECTIONS 1.6): tapped an `http` answer, sent a typed
/// reply, or swiped it away as not needed. `ok` is false when the request didn't reach the agent.
struct AnswerEntry: Codable, Equatable {
    enum Kind: String, Codable { case tap, reply, dismissed }
    var kind: Kind
    var label: String
    var text: String?
    var at: Date
    var ok: Bool
    /// The message id answered. Nil in entries from before 1.26's fix round, which apply to any version.
    var messageId: String?

    func applies(to key: AnswerKey) -> Bool {
        messageId == nil || key.version == nil || messageId == key.version
    }
}

/// A small local record of answers, in the app group's defaults so a banner answer and an in-app
/// answer land in the same place. No Core Data entity, so no migration. Written on the main queue.
final class AnswerLog: ObservableObject {
    static let shared = AnswerLog(defaults: UserDefaults(suiteName: Store.appGroup) ?? .standard)
    static let defaultsKey = "answerLog.v1"

    @Published private(set) var entries: [String: AnswerEntry] = [:]
    /// Answers on their way: key id to the action id in flight. Memory only, so a send cut short by
    /// the app ending never sticks as "sending".
    @Published private(set) var sending: [String: String] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: AnswerEntry].self, from: data) else { entries = [:]; return }
        entries = decoded
    }

    /// The answer made on this version of the question, if any.
    func entry(for key: AnswerKey?) -> AnswerEntry? {
        guard let key, let entry = entries[key.id], entry.applies(to: key) else { return nil }
        return entry
    }

    func isSending(_ key: AnswerKey?) -> Bool {
        key.map { sending[$0.id] != nil } ?? false
    }

    func sendingActionId(_ key: AnswerKey?) -> String? {
        key.flatMap { sending[$0.id] }
    }

    func begin(_ key: AnswerKey, actionId: String) {
        onMain { self.sending[key.id] = actionId }
    }

    /// A failure never replaces an earlier success on the same version: the agent already has that answer.
    func record(_ key: AnswerKey, _ entry: AnswerEntry) {
        var entry = entry
        if entry.messageId == nil { entry.messageId = key.version }
        onMain {
            self.sending[key.id] = nil
            if let existing = self.entries[key.id], existing.ok, !entry.ok, existing.applies(to: key) { return }
            self.entries[key.id] = entry
            self.save()
        }
    }

    func dismiss(_ key: AnswerKey, now: Date = Date()) {
        record(key, AnswerEntry(kind: .dismissed, label: "", text: nil, at: now, ok: true))
    }

    /// How long an answer is kept: 90 days.
    static let keepFor: TimeInterval = 90 * 24 * 3600

    /// Drops answers recorded before `cutoff`.
    func prune(before cutoff: Date) {
        onMain {
            let kept = self.entries.filter { $0.value.at >= cutoff }
            guard kept.count != self.entries.count else { return }
            self.entries = kept
            self.save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// "Waiting on you" (DIRECTIONS 1.6): a question an agent is blocked on.
enum WaitingRule {
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// `http` actions post back to the agent and the reply action carries typed text; `view` and
    /// `copy` actions are links and utilities, not answers.
    static func isAnswer(_ action: Action) -> Bool {
        action.action == "http" || BannerReply.destination(for: action) != nil
    }

    static func hasAnswerAction(_ actions: [Action]) -> Bool {
        actions.contains(where: isAnswer)
    }

    /// The row judged is the newest of its sequence (an update replaces it in place), so an agent's
    /// "settled" update without actions takes the question out, and a delete removes the row.
    /// A `message_clear` does not: in ntfy it means "read and dismissed", and this app sends one
    /// whenever a message is read here or on another device, so it can't tell an agent's withdrawal
    /// from the person having looked at the question.
    static func isWaiting(actions: [Action], time: Date, entry: AnswerEntry?, now: Date = Date()) -> Bool {
        guard hasAnswerAction(actions) else { return false }
        if entry?.ok == true { return false }
        let age = now.timeIntervalSince(time)
        return age < maxAge
    }

    /// Urgent first, then high, then everything else; newest first within each.
    static func precedes(priority lp: Int, time lt: Date, _ rp: Int, _ rt: Date) -> Bool {
        let rank: (Int) -> Int = { $0 >= 5 ? 0 : $0 == 4 ? 1 : 2 }
        return rank(lp) != rank(rp) ? rank(lp) < rank(rp) : lt > rt
    }
}

/// How long an agent has waited, the measure that matters when it is blocked: "12 min", "2 hr",
/// "3 days". The system formatter localizes the units in every language the app ships.
enum WaitedTime {
    static func text(since start: Date, now: Date = Date(), locale: Locale = .current, style: DateComponentsFormatter.UnitsStyle = .short) -> String {
        let seconds = max(60, now.timeIntervalSince(start))
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = style
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = seconds < 3600 ? [.minute] : seconds < 86_400 ? [.hour] : [.day]
        return formatter.string(from: seconds) ?? ""
    }
}

extension Store {
    /// Every message waiting on the person, ordered for the Waiting on you queue. No fetch limit:
    /// the rule filters after the fetch, so a cap would let a busy bot push real questions out.
    /// The predicate keeps the set to rows with actions from the last seven days.
    func waitingNotifications(log: AnswerLog = .shared, now: Date = Date()) -> [Notification] {
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "actions != nil AND actions != '' AND actions != '[]' AND time >= %lld AND subscription != nil",
                                        Int64(now.addingTimeInterval(-WaitingRule.maxAge).timeIntervalSince1970))
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)]
        let rows = ((try? context.fetch(request)) ?? []).filter { !$0.isDeleted }
        return rows.filter { row in
            WaitingRule.isWaiting(actions: row.actionsList(), time: row.date(), entry: log.entry(for: AnswerKey(notification: row)), now: now)
        }
        .sorted { WaitingRule.precedes(priority: Int($0.priority), time: $0.date(), Int($1.priority), $1.date()) }
    }
}

/// The Waiting on you queue, kept current as messages arrive or change and as answers are logged.
final class WaitingObservable: ObservableObject {
    static let shared = WaitingObservable()
    @Published private(set) var notifications: [Notification] = []
    /// The same rows as a set, for "is this card waiting" checks while drawing a list.
    private(set) var ids: Set<NSManagedObjectID> = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private let store: Store
    private let log: AnswerLog

    init(store: Store = .shared, log: AnswerLog = .shared) {
        self.store = store
        self.log = log
        refresh()
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange, object: store.context, queue: .main
        ) { [weak self] _ in self?.scheduleRefresh() })
        observers.append(NotificationCenter.default.addObserver(
            forName: Store.didResetHistory, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() })
        // An answered row shows its receipt for two seconds before it leaves the queue (C1).
        // "Not needed" refreshes at once through `dismiss`.
        log.$entries.dropFirst().debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // Questions age out after seven days even when nothing else changes, and the minutes
        // waited move on: redraw every minute even when the queue is the same.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.refresh()
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var pending = false
    /// Every poll, read and extension merge changes the context; coalesce a burst into one fetch.
    private func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pending = false
            self?.refresh()
        }
    }

    func refresh() {
        let next = store.waitingNotifications(log: log)
        if next.map(\.objectID) != notifications.map(\.objectID) {
            ids = Set(next.map(\.objectID))
            notifications = next
        }
    }

    func contains(_ notification: Notification) -> Bool { ids.contains(notification.objectID) }

    /// "Not needed": the question leaves the queue now, with no receipt to show first.
    func dismiss(_ notification: Notification) {
        guard let key = AnswerKey(notification: notification) else { return }
        log.dismiss(key)
        refresh()
    }
}
