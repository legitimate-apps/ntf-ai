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
/// still fresh, ask the relay whether a wake-up for that hash went through around then. A few
/// misses in a row mean the server isn't set up for this address; any wake-up clears it.
final class SelfHostedWakeCheck {
    struct Entry: Codable, Equatable {
        var misses = 0
        var lastWake: Date?
        var lastCheck: Date?
    }

    enum Verdict: Equatable { case relayed, missed, unknown }

    /// Consecutive misses before the subscription shows "not set up".
    static let missesToFlag = 3
    /// The relay keeps acceptance times for 120 s; leave room for the request itself.
    static let maxMessageAge: TimeInterval = 100
    /// A forward can trail the message by a few seconds; ask only once it is at least this old.
    static let minMessageAge: TimeInterval = 10
    /// Clock skew allowed between the server's message time and the relay's.
    static let slack: TimeInterval = 5
    /// At most one check per topic this often.
    static let checkInterval: TimeInterval = 10 * 60
    /// A wake-up seen this recently means it works; no check needed.
    static let recentWake: TimeInterval = 6 * 60 * 60
    static let key = "selfHostedWakeCheck"

    typealias Read = (URLRequest, @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    static let shared = SelfHostedWakeCheck(network: NSClassFromString("XCTestCase") == nil)

    private let defaults: UserDefaults
    private let relayBaseUrl: String
    private let read: Read?
    private let schedule: Schedule
    private let now: () -> Date
    private let lock = NSLock()
    private var inFlight = Set<String>()

    init(defaults: UserDefaults = NtfyShBridge.defaults, relayBaseUrl: String = Config.appBaseUrl, network: Bool = true,
         read: Read? = nil,
         schedule: @escaping Schedule = { delay, work in DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work) },
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.relayBaseUrl = relayBaseUrl
        self.schedule = schedule
        self.now = now
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

    func isNotSetUp(hash: String) -> Bool { (entries[hash]?.misses ?? 0) >= Self.missesToFlag }

    private func update(_ hash: String, _ change: (inout Entry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var all = entries
        var entry = all[hash] ?? Entry()
        change(&entry)
        all[hash] = entry
        // Keep the table small: drop topics with nothing to say for a month.
        let cutoff = now().addingTimeInterval(-30 * 24 * 60 * 60)
        all = all.filter { ($0.value.lastWake ?? $0.value.lastCheck ?? .distantPast) > cutoff || $0.value.misses > 0 }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }

    /// A wake-up for this hash reached the device (the extension calls this for every hashed
    /// poll_request). It works, whatever the checks said.
    func recordWake(hash: String) {
        guard Self.isHash(hash) else { return }
        update(hash) { $0.misses = 0; $0.lastWake = now() }
    }

    /// Forget a topic (unsubscribed).
    func forget(hash: String) {
        lock.lock(); defer { lock.unlock() }
        var all = entries
        guard all.removeValue(forKey: hash) != nil, let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func isHash(_ topic: String) -> Bool {
        topic.count == 64 && topic.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // MARK: Checking

    /// Whether a message at `messageTime` on this hash should be checked now, and after how long.
    /// nil: don't check (too old, checked recently, a recent wake-up, one already running).
    func plan(hash: String, messageTime: Date) -> TimeInterval? {
        let current = now()
        let age = current.timeIntervalSince(messageTime)
        guard age <= Self.maxMessageAge - 1, age > -Self.slack else { return nil }
        let entry = entries[hash]
        if let wake = entry?.lastWake, current.timeIntervalSince(wake) < Self.recentWake, entry?.misses == 0 { return nil }
        if let check = entry?.lastCheck, current.timeIntervalSince(check) < Self.checkInterval, check <= current { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !inFlight.contains(hash) else { return nil }
        return max(0, Self.minMessageAge - age)
    }

    /// A message from a self-hosted topic was saved by a poll. Checks at most once per topic per
    /// ten minutes, only while the relay still holds the time, and never counts a message whose
    /// wake-up arrived while it waited.
    func messageArrivedByPoll(baseUrl: String, topic: String, messageTime: Date, completion: ((Verdict?) -> Void)? = nil) {
        let hash = topicHash(baseUrl: baseUrl, topic: topic)
        guard read != nil, let delay = plan(hash: hash, messageTime: messageTime) else { completion?(nil); return }
        lock.lock(); inFlight.insert(hash); lock.unlock()
        let started = now()
        schedule(delay) {
            // The push may have landed while we waited: that's a wake-up, nothing to check.
            if let wake = self.entries[hash]?.lastWake, wake >= started.addingTimeInterval(-Self.maxMessageAge) {
                self.finish(hash); completion?(nil); return
            }
            self.check(hash: hash, messageTime: messageTime) { verdict in
                switch verdict {
                case .relayed: self.update(hash) { $0.misses = 0; $0.lastCheck = self.now() }
                case .missed: self.update(hash) { $0.misses += 1; $0.lastCheck = self.now() }
                case .unknown: self.update(hash) { $0.lastCheck = self.now() }
                }
                self.finish(hash)
                completion?(verdict)
            }
        }
    }

    private func finish(_ hash: String) {
        lock.lock(); inFlight.remove(hash); lock.unlock()
    }

    /// `POST <app server>/v1/ntfyme/relay-check {"hash":H}`. A failure, a rate limit or an odd
    /// answer is `.unknown` and changes nothing but the throttle.
    func check(hash: String, messageTime: Date, completion: @escaping (Verdict) -> Void) {
        guard let read, let url = URL(string: normalizeBaseUrl(relayBaseUrl) + "/v1/ntfyme/relay-check") else { completion(.unknown); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONEncoder().encode(["hash": hash])
        read(request) { data, response, error in
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
