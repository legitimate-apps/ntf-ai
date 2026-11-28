// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import CoreData
import Foundation
import Combine
import UserNotifications

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

extension Notification {
    /// The buttons to offer. None when the row's topic can't be named (its subscription is gone): such
    /// an orphan must never send an answer to an agent, nor wait on the person.
    func answerableActions() -> [Action] { AnswerKey(notification: self) == nil ? [] : actionsList() }
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
    /// Not made here: an answer seen on the question's topic, which this install can't attribute to
    /// the person. Shown as "Answered", never "You answered".
    var seen: Bool? = nil

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
        #if DEBUG
        // Screenshot runs start every question unanswered (`-ntfyDebugResetAnswers YES`).
        if UserDefaults.standard.bool(forKey: "ntfyDebugResetAnswers") { defaults.removeObject(forKey: Self.defaultsKey) }
        #endif
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

    /// On an agent's question a failure never replaces an earlier success on the same version: the
    /// agent already has that answer. A `repeatable` button (any message that isn't an agent's
    /// question: "Toggle light", "Restart service") runs every time it is pressed, so its latest
    /// press is the one that counts, failed or not.
    func record(_ key: AnswerKey, _ entry: AnswerEntry, repeatable: Bool = false) {
        var entry = entry
        if entry.messageId == nil { entry.messageId = key.version }
        onMain {
            self.sending[key.id] = nil
            if !repeatable, let existing = self.entries[key.id], existing.ok, !entry.ok, existing.applies(to: key) { return }
            self.entries[key.id] = entry
            self.save()
            // An answered agent question is one of the moments the review question may follow.
            if !repeatable && entry.ok && entry.kind != .dismissed { ReviewPrompt.shared.noteGoodMoment() }
            // The button shows its check for a moment; then the views redraw: to the answered state
            // on a question, back to the buttons on any other message.
            if entry.ok && entry.kind != .dismissed {
                DispatchQueue.main.asyncAfter(deadline: .now() + AnswerState.hold(locks: !repeatable) + 0.05) { [weak self] in
                    self?.objectWillChange.send()
                }
            }
        }
    }

    func dismiss(_ key: AnswerKey, now: Date = Date()) {
        record(key, AnswerEntry(kind: .dismissed, label: "", text: nil, at: now, ok: true))
    }

    /// "Clear all" in Waiting on you: every listed question is marked "Not needed" at once, on this
    /// device. Returns what each key held before, so Undo can put it back. Main thread only.
    @discardableResult
    func dismissAll(_ keys: [AnswerKey], now: Date = Date()) -> AnswerLog.Cleared {
        dispatchPrecondition(condition: .onQueue(.main))
        var previous: [String: AnswerEntry?] = [:]
        for key in keys where previous[key.id] == nil {
            previous[key.id] = .some(entries[key.id])
            entries[key.id] = AnswerEntry(kind: .dismissed, label: "", text: nil, at: now, ok: true, messageId: key.version)
        }
        if !previous.isEmpty { save() }
        return Cleared(previous: previous, at: now)
    }

    /// Undo of a "Clear all": each key gets back what it held, unless it was answered since.
    func restore(_ cleared: AnswerLog.Cleared) {
        dispatchPrecondition(condition: .onQueue(.main))
        for (id, before) in cleared.previous {
            guard let current = entries[id], current.kind == .dismissed, current.at == cleared.at else { continue }
            entries[id] = before
        }
        save()
    }

    struct Cleared: Equatable {
        let previous: [String: AnswerEntry?]
        let at: Date
        var count: Int { previous.count }
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

extension AnswerLog {
    /// The answer to this version of the question: one made here, else one seen on its topic, which
    /// may have come from the person's other device. A failed or dismissed entry here gives way to
    /// an answer seen since.
    func entry(for key: AnswerKey?, seen acks: AckLog) -> AnswerEntry? {
        let local = entry(for: key)
        if let local, local.ok, local.kind != .dismissed { return local }
        guard let key, let seen = acks.answer(forKey: key.id, version: key.version) else { return local }
        return AnswerEntry(kind: seen.written ? .reply : .tap, label: seen.written ? "" : seen.label,
                           text: seen.written ? seen.label : nil, at: Date(timeIntervalSince1970: TimeInterval(seen.time)),
                           ok: true, messageId: seen.version, seen: true)
    }
}

/// "Waiting on you" (DIRECTIONS 1.6): a question an agent is blocked on. Only an agent's question
/// waits: tagged `agent` with an answer, or a typed (ask-v2) question, the same set that takes one
/// answer. A plain message's buttons ("Toggle light") are not a question and stay under Activity.
enum WaitingRule {
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// `http` actions post back to the agent and the reply action carries typed text; `view` and
    /// `copy` actions are links and utilities, not answers.
    static func isAnswer(_ action: Action) -> Bool { AgentQuestion.isAnswerAction(action) }

    static func hasAnswerAction(_ actions: [Action]) -> Bool {
        actions.contains(where: isAnswer)
    }

    /// The row judged is the newest of its sequence (an update replaces it in place), so an agent's
    /// "settled" update without actions takes the question out, and a delete removes the row.
    /// A `message_clear` does not: in ntfy it means "read and dismissed", and this app sends one
    /// whenever a message is read here or on another device, so it can't tell an agent's withdrawal
    /// from the person having looked at the question.
    /// A message tagged `re-<sequence>` is the person's own written answer, never a question.
    /// An agent's ack on the question resolves it, however it was answered (ACK-SPEC).
    /// A typed question past its deadline (`exp`) waits no longer; a withdrawn one is acked (SPEC 7).
    static func isWaiting(actions: [Action], time: Date, entry: AnswerEntry?, tags: [String], acked: Bool = false,
                          now: Date = Date()) -> Bool {
        guard hasAnswerAction(actions), AgentQuestion.locksAfterAnswer(tags: tags, actions: actions), !acked,
              !tags.contains(where: ProtocolTag.isReply) else { return false }
        if entry?.ok == true { return false }
        if AskSchema.detect(in: actions).schema?.isExpired(now: now) == true { return false }
        let age = now.timeIntervalSince(time)
        return age < maxAge
    }

    /// Newest first, the same order as Activity. Priority doesn't rank: an urgent ask from days ago
    /// sat above every newer one and read as shuffled (operator, 2026-11-21). Ids break a same-second tie.
    static func precedes(time lt: Date, id li: String?, _ rt: Date, _ ri: String?) -> Bool {
        lt != rt ? lt > rt : (li ?? "") > (ri ?? "")
    }
}

/// A written reply to an agent's question that has no reply action of its own. The agent protocol
/// (`ntf ask`, the agent guide) takes a message on the question's topic tagged `re-<sequence>` as
/// the person's written answer to that question, so a waiting question tagged `agent` gets the
/// reply field too, unless it is tagged `no-reply`.
enum AgentReply {
    static let agentTag = "agent"
    /// The answer log's in-flight id for a typed reply sent this way.
    static let sendingId = "typed-reply"

    /// The page offers the field: an `agent` question with answers, not marked `no-reply`, and no
    /// view-action reply (that one posts to its own target).
    static func offersField(tags: [String], actions: [Action]) -> Bool {
        if let schema = AskSchema.detect(in: actions).schema {
            // A typed question: the schema's `reply` decides; its reply-v1 link is for older apps.
            return tags.contains(agentTag) && !tags.contains(where: ProtocolTag.isNoReply) && schema.reply != false
        }
        return tags.contains(agentTag) && !tags.contains(where: ProtocolTag.isNoReply) && WaitingRule.hasAnswerAction(actions)
            && !actions.contains { BannerReply.destination(for: $0) != nil }
    }

    /// The tags of a typed answer: `re-<sequence>,ans` (SPEC 2).
    static func answerTags(for key: AnswerKey) -> String { replyTags(for: key) + "," + ProtocolTag.answer }

    /// Sends a typed answer to the question's own topic, priority 3, tagged `re-<seq>,ans`, and logs it
    /// with `summary` (the answer in words) as the receipt's text.
    @MainActor
    static func sendAnswer(_ body: String, summary: String, written: Bool = false, to notification: Notification,
                           store: Store = .shared, log: AnswerLog = .shared) {
        guard !body.isEmpty, let subscription = notification.subscription,
              let key = AnswerKey(notification: notification), !log.isSending(key),
              // A page left open past the deadline still shows its controls until it redraws.
              AskSchema.detect(in: notification.actionsList()).schema?.isExpired() != true else { return }
        log.begin(key, actionId: "typed-answer")
        TopicPublisher.send(subscription: subscription, store: store, message: body, title: "", priority: 3,
                            tags: answerTags(for: key)) { result in
            let ok: Bool
            if case .success = result { ok = true } else { ok = false }
            // A pick reads "You answered Production"; written text and forms read "You replied".
            log.record(key, written ? AnswerEntry(kind: .reply, label: "", text: summary, at: Date(), ok: ok)
                                    : AnswerEntry(kind: .tap, label: summary, text: nil, at: Date(), ok: ok))
        }
    }

    /// The tags a typed answer to the question at `key` carries: exactly `re-<sequence>`, where the
    /// sequence is the question's sequence_id, or its message id when it has none.
    static func replyTags(for key: AnswerKey) -> String { ProtocolTag.reply(to: key.sequence) }

    /// Publishes `text` as a message on the question's topic, through the same publish path
    /// as Compose (the topic's sign-in and password), and logs it like a typed reply.
    @MainActor
    static func send(_ text: String, to notification: Notification, store: Store = .shared, log: AnswerLog = .shared) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let subscription = notification.subscription,
              let key = AnswerKey(notification: notification), !log.isSending(key) else { return }
        log.begin(key, actionId: sendingId)
        // One tag, `re-<sequence>`, so the agent can tell which open question this answers. Never
        // `agent`: that would read as the agent's own message.
        TopicPublisher.send(subscription: subscription, store: store, message: trimmed, title: "",
                            tags: replyTags(for: key)) { result in
            let ok: Bool
            if case .success = result { ok = true } else { ok = false }
            log.record(key, AnswerEntry(kind: .reply, label: "", text: trimmed, at: Date(), ok: ok))
        }
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
        let acks = ackLog
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "actions != nil AND actions != '' AND actions != '[]' AND time >= %lld AND subscription != nil",
                                        Int64(now.addingTimeInterval(-WaitingRule.maxAge).timeIntervalSince1970))
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)]
        let rows = ((try? context.fetch(request)) ?? []).filter { !$0.isDeleted }
        return rows.filter { row in
            let key = AnswerKey(notification: row)
            return WaitingRule.isWaiting(actions: row.answerableActions(), time: row.date(), entry: log.entry(for: key, seen: acks),
                                         tags: parseAllTags(row.tags),
                                         acked: key.map { acks.record(forKey: $0.id, version: $0.version) != nil } ?? false,
                                         now: now)
        }
        .sorted { WaitingRule.precedes(time: $0.date(), id: $0.id, $1.date(), $1.id) }
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
        observers.append(NotificationCenter.default.addObserver(
            forName: AckLog.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRefresh() })
        // An answered row shows its receipt for two seconds before it leaves the queue (C1).
        // "Not needed" refreshes at once through `dismiss`.
        // The check shows first (`AnswerState.sentHold`), then the receipt for the rest.
        log.$entries.dropFirst().debounce(for: .seconds(max(2, AnswerState.sentHold + 0.7)), scheduler: DispatchQueue.main)
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

    /// The last "Clear all", while its Undo is offered.
    @Published private(set) var lastClear: AnswerLog.Cleared?
    private var undoExpiry: DispatchWorkItem?
    /// How long Undo stays on screen.
    static let undoWindow: TimeInterval = 6

    /// "Clear all": every question now listed leaves the queue and the tab badge, on this device
    /// (as "Not needed"; the messages stay in their topic and in Activity, buttons live). A question
    /// that arrives afterwards, or a new version of a cleared one, waits as normal.
    func clearAll(now: Date = Date()) {
        let keys = notifications.compactMap { AnswerKey(notification: $0) }
        guard !keys.isEmpty else { return }
        let cleared = log.dismissAll(keys, now: now)
        refresh()
        lastClear = cleared
        undoExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            if self?.lastClear == cleared { self?.lastClear = nil }
        }
        undoExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow, execute: expiry)
    }

    /// Undo of the last "Clear all".
    func undoClear() {
        guard let cleared = lastClear else { return }
        undoExpiry?.cancel()
        lastClear = nil
        log.restore(cleared)
        refresh()
    }
}

extension AgentAck {
    /// With "Show agent confirmations" off, an ack the extension had to deliver (it can't drop a
    /// push without Apple's filtering entitlement) leaves Notification Center once the app runs. So
    /// does the receipt for the person's own answer, whatever the setting.
    static func removeDeliveredReceiptsIfHidden(center: UNUserNotificationCenter = .current(),
                                                shows: Bool = AgentAck.showsConfirmations()) {
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { (!shows && isReceipt($0.request.content.userInfo))
                || isAnswerReceipt($0.request.content.userInfo) }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// An ack arriving while the app is open: never a banner or sound; in Notification Center only
    /// when confirmations show.
    static func foregroundPresentation(shows: Bool) -> UNNotificationPresentationOptions {
        shows ? [.list] : []
    }

    static func isReceipt(_ userInfo: [AnyHashable: Any]) -> Bool {
        isAck(tags: (userInfo["tags"] as? String ?? "").components(separatedBy: ","))
    }

    /// The passive receipt the extension delivers for the person's own answer (`ans`, `re-<sequence>`).
    static func isAnswerReceipt(_ userInfo: [AnyHashable: Any]) -> Bool {
        AnswerMessage.answeredSequence(tags: (userInfo["tags"] as? String ?? "").components(separatedBy: ",")) != nil
    }
}
