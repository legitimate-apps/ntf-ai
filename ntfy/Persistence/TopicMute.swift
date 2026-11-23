import Foundation
import CoreData
import UserNotifications

/// A deadline is evaluated at delivery, without a timer or a change to FCM bindings.
/// nil means resumed; distantFuture is persisted for "until resumed".
enum TopicMuteDuration: String, CaseIterable, Identifiable {
    case minutes30, hour1, hours2, hours8, tomorrow, untilResumed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .minutes30: return String(localized: "\(30) minutes")
        case .hour1: return String(localized: "\(1) hours")
        case .hours2: return String(localized: "\(2) hours")
        case .hours8: return String(localized: "\(8) hours")
        case .tomorrow:
            // Preserve the existing AM/PM spacing while honoring the locale and clock preference.
            let time = DateFormatter.localizedString(from: deadline(), dateStyle: .none, timeStyle: .short)
                .replacingOccurrences(of: "\u{202F}", with: " ")
            return String(localized: "Until tomorrow, \(time)")
        case .untilResumed: return String(localized: "Until resumed")
        }
    }
    func deadline(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .minutes30: return now.addingTimeInterval(30 * 60)
        case .hour1: return now.addingTimeInterval(60 * 60)
        case .hours2: return now.addingTimeInterval(2 * 60 * 60)
        case .hours8: return now.addingTimeInterval(8 * 60 * 60)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: 8, minute: 30, second: 0, of: tomorrow)!
        case .untilResumed: return .distantFuture
        }
    }
}

enum TopicMute {
    static func isMuted(until: Date?, now: Date = Date()) -> Bool {
        until.map { $0 > now } ?? false
    }
    static func status(until: Date?, now: Date = Date()) -> String? {
        guard let until, isMuted(until: until, now: now) else { return nil }
        if until == .distantFuture { return String(localized: "Notifications muted until resumed") }
        return String(localized: "Notifications muted until \(DateFormatter.localizedString(from: until, dateStyle: .medium, timeStyle: .short))")
    }
}

extension Store {
    /// Read on a new context, so an already-running NSE sees app writes without waiting for
    /// persistent-history notifications or reusing a registered object's old snapshot.
    func isTopicMuted(baseUrl: String, topic: String, now: Date = Date()) -> Bool {
        let reader = container.newBackgroundContext()
        var muted = false
        reader.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Subscription")
            request.predicate = NSPredicate(format: "baseUrl == %@ AND topic == %@", normalizeBaseUrl(baseUrl), topic)
            request.fetchLimit = 1
            do {
                let until = try reader.fetch(request).first?.value(forKey: "mutedUntil") as? Date
                muted = TopicMute.isMuted(until: until, now: now)
            } catch {
                // A temporarily unavailable store must not let an alert bypass a user's mute.
                Log.w(Store.tag, "Cannot read topic mute; delivering quietly", error)
                muted = true
            }
        }
        return muted
    }

    func isNotificationMuted(userInfo: [AnyHashable: Any], now: Date = Date()) -> Bool {
        let topic = userInfo["topic"] as? String ?? ""
        let baseUrl = userInfo["base_url"] as? String
        if userInfo["event"] as? String == "poll_request",
           let target = findSubscriptionMatch(forPollRequestTopic: topic, preferredBaseUrl: baseUrl) {
            var resolved = userInfo
            resolved["base_url"] = target.baseUrl; resolved["topic"] = target.topic
            return QuietHours.load().isQuiet(userInfo: resolved, now: now)
                || isTopicMuted(baseUrl: target.baseUrl, topic: target.topic, now: now)
        }
        return QuietHours.load().isQuiet(userInfo: userInfo, now: now)
            || isTopicMuted(baseUrl: baseUrl ?? Config.appBaseUrl, topic: topic, now: now)
    }

    func setTopicMute(until: Date?, subscription: Subscription) throws {
        var failure: Error?
        context.performAndWait {
            let previous = subscription.mutedUntil
            subscription.mutedUntil = until
            do { try context.save() }
            catch { subscription.mutedUntil = previous; failure = error }
        }
        if let failure { throw failure }
    }
}

extension UNMutableNotificationContent {
    func applyTopicMute(store: Store = .shared, now: Date = Date()) {
        guard store.isNotificationMuted(userInfo: userInfo, now: now) else { return }
        silenceTopicAlert()
    }

    /// Applied after priority mapping and again at the final delivery boundary. Badge and
    /// message content remain intact. Passive notifications stay in Notification Center.
    func applyTopicMute(baseUrl: String, topic: String, store: Store = .shared, now: Date = Date()) {
        var resolved = userInfo
        resolved["base_url"] = baseUrl; resolved["topic"] = topic
        guard store.isNotificationMuted(userInfo: resolved, now: now) else { return }
        silenceTopicAlert()
    }

    private func silenceTopicAlert() {
        sound = nil
        interruptionLevel = .passive
        relevanceScore = 0
    }
}

/// What the extension needs to honour a topic's mute and quiet-hours exception before it opens the
/// store (review-130c C6): every subscription's address, topic, wake-up hash and mute deadline, in
/// one small app-group file the app rewrites whenever a subscription changes.
struct NotificationPolicySnapshot: Codable, Equatable {
    struct Topic: Codable, Equatable {
        var baseUrl: String
        var topic: String
        var hash: String
        var mutedUntil: Date?
    }
    var topics: [Topic] = []
    /// Which app process took it, and in what order its reads were taken (review-130d D5): a
    /// snapshot never replaces a newer one from the same process. A new process (the app relaunched)
    /// always replaces it, since nothing of the old one can still be writing. Nil before 1.30 round 4.
    var writer: String?
    var generation: Int?

    /// This process's writer identity.
    static let processWriter = UUID().uuidString
    private static let generationLock = NSLock()
    private static var lastGeneration = 0
    /// The next generation, taken where the subscriptions are read, so it orders the reads.
    static func nextGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        lastGeneration += 1
        return lastGeneration
    }

    /// `self` may replace `stored`: no file yet, another process's, or an older read of this one.
    func supersedes(_ stored: NotificationPolicySnapshot?) -> Bool {
        guard let stored, stored.writer == writer, let mine = generation, let theirs = stored.generation else { return true }
        return mine > theirs
    }

    static let fileName = "ntfai-notification-policy.json"
    static var file: SharedStateFile<NotificationPolicySnapshot> { SharedStateFile(name: fileName) }

    /// The subscription a push names: by wake-up hash (a poll_request), else by topic on the server
    /// it names (the app's own when none). Nil when the snapshot doesn't know it.
    func resolve(userInfo: [AnyHashable: Any]) -> Topic? {
        let name = userInfo["topic"] as? String ?? ""
        if let byHash = topics.first(where: { $0.hash == name }) { return byHash }
        let server = normalizeBaseUrl(userInfo["base_url"] as? String ?? Config.appBaseUrl)
        return topics.first { $0.topic == name && normalizeBaseUrl($0.baseUrl) == server }
    }

    /// The push should be silent: its topic is muted, or quiet hours hold for it (with its
    /// exception and urgency honoured). Unknown topics fall to quiet hours for the address given.
    func isQuiet(userInfo: [AnyHashable: Any], quietHours: QuietHours, now: Date = Date()) -> Bool {
        guard let topic = resolve(userInfo: userInfo) else { return quietHours.isQuiet(userInfo: userInfo, now: now) }
        if TopicMute.isMuted(until: topic.mutedUntil, now: now) { return true }
        var resolved = userInfo
        resolved["base_url"] = topic.baseUrl; resolved["topic"] = topic.topic
        return quietHours.isQuiet(userInfo: resolved, now: now)
    }
}

extension Store {
    /// Rewrites the policy snapshot from the subscriptions (app process).
    func writeNotificationPolicy() {
        guard let snapshot = readNotificationPolicy() else { return }
        publishNotificationPolicy(snapshot)
    }

    /// The policy as the subscriptions say now, with the generation of this read. Nil when they
    /// can't be read: the last good snapshot stays rather than an empty one (review-130d D5).
    func readNotificationPolicy() -> NotificationPolicySnapshot? {
        var snapshot: NotificationPolicySnapshot?
        context.performAndWait {
            do {
                let subscriptions = try subscriptionSnapshotFetch?(context) ?? context.fetch(Subscription.fetchRequest())
                var read = NotificationPolicySnapshot(writer: NotificationPolicySnapshot.processWriter,
                                                      generation: NotificationPolicySnapshot.nextGeneration())
                read.topics = subscriptions.compactMap { sub in
                    guard let baseUrl = sub.baseUrl, let topic = sub.topic else { return nil }
                    return .init(baseUrl: baseUrl, topic: topic, hash: sub.urlHash(), mutedUntil: sub.mutedUntil)
                }.sorted { ($0.baseUrl, $0.topic) < ($1.baseUrl, $1.topic) }
                snapshot = read
            } catch { Log.w(Store.tag, "Cannot read subscriptions; keeping the last notification policy", error) }
        }
        return snapshot
    }

    /// Writes `snapshot` unless the file already holds a newer read (checked inside the file's
    /// transaction, so two writers finishing out of order can't publish the older one).
    @discardableResult
    func publishNotificationPolicy(_ snapshot: NotificationPolicySnapshot) -> Bool {
        let written = NotificationPolicySnapshot.file.update { stored -> (write: Bool, result: Bool) in
            guard snapshot.supersedes(stored) else { return (false, false) }
            stored = snapshot
            return (true, true)
        }
        if written == nil { Log.w(Store.tag, "Cannot write the notification policy snapshot") }
        return written == true
    }

    /// Keeps the snapshot current: written now and after every save that touches a subscription.
    func startNotificationPolicySnapshot() -> NSObjectProtocol {
        writeNotificationPolicy()
        return NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { [weak self] note in
            guard let self, let saved = note.object as? NSManagedObjectContext,
                  saved.persistentStoreCoordinator === self.container.persistentStoreCoordinator else { return }
            let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
            guard keys.contains(where: { ((note.userInfo?[$0] as? Set<NSManagedObject>) ?? []).contains { $0 is Subscription } }) else { return }
            DispatchQueue.global(qos: .utility).async { self.writeNotificationPolicy() }
        }
    }
}
