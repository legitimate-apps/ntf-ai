import CoreData
import Foundation
import Combine

/// Which question an answer belongs to: server, topic and sequence. A sequence update replaces its
/// row in place, so the key outlives an agent's edit of the question.
struct AnswerKey: Hashable {
    let baseUrl: String
    let topic: String
    let sequence: String

    var id: String { "\(normalizeBaseUrl(baseUrl))|\(topic)|\(sequence)" }

    init(baseUrl: String, topic: String, sequence: String) {
        self.baseUrl = baseUrl
        self.topic = topic
        self.sequence = sequence
    }

    init?(notification: Notification) {
        guard let subscription = notification.subscription, let baseUrl = subscription.baseUrl,
              let topic = subscription.topic, let id = notification.id else { return nil }
        let sequence = notification.sequenceID.flatMap { $0.isEmpty ? nil : $0 } ?? id
        self.init(baseUrl: baseUrl, topic: topic, sequence: sequence)
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

    func entry(for key: AnswerKey?) -> AnswerEntry? {
        key.flatMap { entries[$0.id] }
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

    /// A failure never replaces an earlier success: the agent already has that answer.
    func record(_ key: AnswerKey, _ entry: AnswerEntry) {
        onMain {
            self.sending[key.id] = nil
            if let existing = self.entries[key.id], existing.ok, !entry.ok { return }
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
    /// "settled" update without actions takes the question out, and so does a clear.
    static func isWaiting(actions: [Action], time: Date, entry: AnswerEntry?, cleared: Bool, now: Date = Date()) -> Bool {
        guard hasAnswerAction(actions), !cleared else { return false }
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
    /// Sequence keys whose newest event is a clear: the agent withdrew those questions.
    func clearedSequenceKeys(_ keys: [String], in context: NSManagedObjectContext? = nil) -> Set<String> {
        guard !keys.isEmpty else { return [] }
        let request = NSFetchRequest<NSManagedObject>(entityName: "SequenceState")
        request.predicate = NSPredicate(format: "key IN %@ AND event == %@", keys, "message_clear")
        let rows = (try? (context ?? self.context).fetch(request)) ?? []
        return Set(rows.compactMap { $0.value(forKey: "key") as? String })
    }

    /// Every message waiting on the person, ordered for the Waiting on you queue.
    func waitingNotifications(log: AnswerLog = .shared, now: Date = Date()) -> [Notification] {
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "actions != nil AND actions != '' AND time >= %lld AND subscription != nil",
                                        Int64(now.addingTimeInterval(-WaitingRule.maxAge).timeIntervalSince1970))
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)]
        request.fetchLimit = 500
        let rows = ((try? context.fetch(request)) ?? []).filter { !$0.isDeleted }
        let cleared = clearedSequenceKeys(rows.compactMap(\.sequenceKey))
        return rows.filter { row in
            WaitingRule.isWaiting(actions: row.actionsList(), time: row.date(), entry: log.entry(for: AnswerKey(notification: row)),
                                  cleared: row.sequenceKey.map(cleared.contains) ?? false, now: now)
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
        // Questions age out after seven days even when nothing else changes.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private var pending = false
    private func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
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
