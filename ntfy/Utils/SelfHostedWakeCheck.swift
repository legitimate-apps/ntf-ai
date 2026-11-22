import Foundation

/// Tells a self-hosted server that will never wake this device from one that works, without
/// probing it or publishing anything.
///
/// A stock server with `upstream-base-url` set forwards a `poll_request` for each message to its
/// upstream, on the topic `sha256(base-url + "/" + topic)`. The app binds the same hash from the
/// address the user typed, so a server with no upstream, another upstream, or a `base-url` that
/// isn't exactly that address (LAN IP vs name, http vs https, a port) never wakes it. Those
/// forwards aren't cached on ntfy.sh (a poll_request is published with `cache=false`), so the one
/// place that sees them is this app's server: it records the time of every wake-up it relays for a
/// hash, its own and the ntfy.sh bridge's, and answers `POST /v1/ntfyme/relay-check`.
///
/// So when a message from a self-hosted topic reaches the app by a poll (not by a push) while it is
/// still fresh, ask the relay whether a wake-up for that hash went through around then. Only while
/// the bridge holds this hash. A few misses in a row while the bridge's ntfy.sh connection was
/// confirmed up mean the server isn't set up for this address (`notSetUp`); misses without that
/// confirmation only say no forwarding was confirmed (`unconfirmed`). Any wake-up clears both.
/// The relay reports acceptance, not delivery to this device.
final class SelfHostedWakeCheck {
    struct Entry: Codable, Equatable {
        /// Misses counted while the bridge's connection was confirmed (strong evidence).
        var misses = 0
        var lastWake: Date?
        var lastCheck: Date?
        /// Misses without that confirmation (optional so 1.30 beta entries decode).
        var weakMisses: Int?
        /// "Check again": the next fresh message is checked whatever the throttles say.
        var armed: Bool?
    }

    enum Verdict: Equatable { case relayed, missed, unknown }
    enum Diagnosis: Equatable { case notSetUp, unconfirmed }

    /// Consecutive misses before the subscription shows a diagnosis.
    static let missesToFlag = 3
    /// The relay keeps acceptance times for 120 s; leave room for the request itself.
    static let maxMessageAge: TimeInterval = 100
    /// A forward can trail the message by a few seconds; ask only once it is at least this old.
    static let minMessageAge: TimeInterval = 10
    /// Clock skew allowed between the server's message time and the relay's.
    static let slack: TimeInterval = 5
    /// At most one check per topic this often.
    static let checkInterval: TimeInterval = 10 * 60
    /// And at most one check across all topics this often, so many topics can't burst the relay.
    static let globalInterval: TimeInterval = 60
    /// A wake-up seen this recently means it works; no check needed.
    static let recentWake: TimeInterval = 6 * 60 * 60
    static let key = "selfHostedWakeCheck"
    static let globalKey = "selfHostedWakeCheckLast"

    typealias Read = (URLRequest, @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    static let shared = SelfHostedWakeCheck(network: NSClassFromString("XCTestCase") == nil)

    private let defaults: UserDefaults
    private let relayBaseUrl: String
    private let read: Read?
    private let schedule: Schedule
    private let now: () -> Date
    private let lock: SharedFileLock
    private let processLock = NSLock()
    private var inFlight = Set<String>()

    init(defaults: UserDefaults = NtfyShBridge.defaults, relayBaseUrl: String = Config.appBaseUrl, network: Bool = true,
         read: Read? = nil,
         schedule: @escaping Schedule = { delay, work in DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work) },
         now: @escaping () -> Date = Date.init, lock: SharedFileLock? = nil) {
        self.defaults = defaults
        self.relayBaseUrl = relayBaseUrl
        self.schedule = schedule
        self.now = now
        self.lock = lock ?? .named(NtfyShBridge.lockName)
        if let read {
            self.read = read
        } else if network {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 10
            let session = URLSession(configuration: config)
            self.read = { request, completion in
                session.dataTask(with: request) { data, response, error in completion(data, response as? HTTPURLResponse, error) }.resume()
            }
        } else {
            self.read = nil
        }
    }

    // MARK: State

    var entries: [String: Entry] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func entry(hash: String) -> Entry? { entries[hash] }

    func isNotSetUp(hash: String) -> Bool { diagnosis(hash: hash) == .notSetUp }

    func diagnosis(hash: String) -> Diagnosis? {
        guard let entry = entries[hash] else { return nil }
        if entry.misses >= Self.missesToFlag { return .notSetUp }
        if entry.misses + (entry.weakMisses ?? 0) >= Self.missesToFlag { return .unconfirmed }
        return nil
    }

    /// Read-modify-write under the lock the extension also takes, so a wake it records can't be
    /// overwritten by a check result computed before it. `change` returns false to write nothing.
    private func update(_ hash: String, _ change: (inout Entry) -> Bool) {
        lock.withLock {
            var all = entries
            var entry = all[hash] ?? Entry()
            guard change(&entry) else { return }
            all[hash] = entry
            // Keep the table small: drop topics with nothing to say for a month.
            let cutoff = now().addingTimeInterval(-30 * 24 * 60 * 60)
            all = all.filter { ($0.value.lastWake ?? $0.value.lastCheck ?? .distantPast) > cutoff || $0.value.misses > 0 || ($0.value.weakMisses ?? 0) > 0 }
            if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .ntfyShBridgeStateChanged, object: nil) }
    }

    /// A wake-up for this hash reached the device (the extension calls this for every hashed
    /// poll_request). It works, whatever the checks said.
    func recordWake(hash: String) {
        guard Self.isHash(hash) else { return }
        update(hash) { $0.misses = 0; $0.weakMisses = nil; $0.lastWake = now(); return true }
    }

    /// "Check again": check the next fresh message on this topic even if one ran recently.
    func arm(hash: String) {
        guard Self.isHash(hash) else { return }
        update(hash) { $0.armed = true; return true }
    }

    func isArmed(hash: String) -> Bool { entries[hash]?.armed == true }

    /// Forget a topic (unsubscribed).
    func forget(hash: String) {
        lock.withLock {
            var all = entries
            guard all.removeValue(forKey: hash) != nil, let data = try? JSONEncoder().encode(all) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    static func isHash(_ topic: String) -> Bool {
        topic.count == 64 && topic.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // MARK: Checking

    /// Whether a message at `messageTime` on this hash should be checked now, and after how long;
    /// a yes also reserves the hash and the global slot. nil: don't check (too old, checked
    /// recently here or for any topic, a recent wake-up, one already running, the relay asked for a pause).
    func plan(hash: String, messageTime: Date) -> TimeInterval? {
        let current = now()
        let age = current.timeIntervalSince(messageTime)
        guard age <= Self.maxMessageAge - 1, age > -Self.slack else { return nil }
        guard NtfyMeHostCooldown.blockedUntil(defaults, now: current) == nil else { return nil }
        let entry = entries[hash]
        let armed = entry?.armed == true
        if !armed {
            if let wake = entry?.lastWake, current.timeIntervalSince(wake) < Self.recentWake,
               entry?.misses == 0, (entry?.weakMisses ?? 0) == 0 { return nil }
            if let check = entry?.lastCheck, current.timeIntervalSince(check) < Self.checkInterval, check <= current { return nil }
        }
        processLock.lock(); defer { processLock.unlock() }
        guard !inFlight.contains(hash) else { return nil }
        let globalFree: Bool = lock.withLock {
            if let last = defaults.object(forKey: Self.globalKey) as? Date, current.timeIntervalSince(last) < Self.globalInterval, last <= current {
                return false
            }
            defaults.set(current, forKey: Self.globalKey)
            return true
        }
        guard globalFree else { return nil }
        inFlight.insert(hash)
        return max(0, Self.minMessageAge - age)
    }

    /// A message from a self-hosted topic was saved by a poll. Checks only while the relay still
    /// holds the time, never counts a message whose wake-up arrived while it waited or while the
    /// check ran, and counts a miss as strong only when `evidence()` holds as the answer lands.
    func messageArrivedByPoll(baseUrl: String, topic: String, messageTime: Date,
                              evidence: @escaping () -> Bool = { false }, completion: ((Verdict?) -> Void)? = nil) {
        let hash = topicHash(baseUrl: baseUrl, topic: topic)
        guard read != nil, let delay = plan(hash: hash, messageTime: messageTime) else { completion?(nil); return }
        let started = now()
        schedule(delay) {
            // The push may have landed while we waited, or the dispatch ran late.
            if let wake = self.entries[hash]?.lastWake, wake >= started.addingTimeInterval(-Self.maxMessageAge) {
                self.finish(hash); completion?(nil); return
            }
            guard self.now().timeIntervalSince(messageTime) <= Self.maxMessageAge else {
                self.finish(hash); completion?(nil); return
            }
            let asked = self.now()
            self.check(hash: hash, messageTime: messageTime) { verdict in
                let strong = verdict == .missed && evidence()
                self.update(hash) { entry in
                    entry.lastCheck = self.now()
                    // A wake recorded after the check started supersedes its answer.
                    if let wake = entry.lastWake, wake >= asked { return true }
                    switch verdict {
                    case .relayed: entry.misses = 0; entry.weakMisses = nil; entry.armed = nil
                    case .missed:
                        if strong { entry.misses += 1 } else { entry.weakMisses = (entry.weakMisses ?? 0) + 1 }
                        entry.armed = nil
                    case .unknown: break
                    }
                    return true
                }
                self.finish(hash)
                completion?(verdict)
            }
        }
    }

    private func finish(_ hash: String) {
        processLock.lock(); inFlight.remove(hash); processLock.unlock()
    }

    /// `POST <app server>/v1/ntfyme/relay-check {"hash":H}`. A failure, a rate limit or an odd
    /// answer is `.unknown` and changes nothing but the throttle; 429 and 5xx feed the shared cooldown.
    func check(hash: String, messageTime: Date, completion: @escaping (Verdict) -> Void) {
        guard let read, let url = URL(string: normalizeBaseUrl(relayBaseUrl) + "/v1/ntfyme/relay-check") else { completion(.unknown); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONEncoder().encode(["hash": hash])
        read(request) { data, response, error in
            let status = error == nil ? response?.statusCode : nil
            if status == nil || status == 429 || (status ?? 0) >= 500 {
                NtfyMeHostCooldown.note(status: status, retryAfter: response?.value(forHTTPHeaderField: "Retry-After"),
                                        defaults: self.defaults, lock: self.lock, now: self.now())
            }
            // The same contract RelayCheck.Snapshot reads; repeated here because the extension
            // compiles this file without RelayCheck.
            struct Snapshot: Decodable {
                let relayed: Bool
                let relayedAt: Int64?
                let windowSeconds: Int
                enum CodingKeys: String, CodingKey { case relayed, relayedAt = "relayed_at", windowSeconds = "window_seconds" }
                var isValid: Bool { windowSeconds == 120 && (relayed ? (relayedAt ?? 0) > 0 : relayedAt == nil) }
            }
            guard error == nil, response?.statusCode == 200, let data,
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.isValid else {
                completion(.unknown); return
            }
            guard snapshot.relayed, let at = snapshot.relayedAt else { completion(.missed); return }
            let relayed = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
            completion(relayed >= messageTime.addingTimeInterval(-Self.slack) ? .relayed : .missed)
        }
    }
}
