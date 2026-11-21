import Foundation
import Combine

/// What this install asks ntfy-me.com to watch on ntfy.sh (`POST /v1/ntfai/watch`).
///
/// Apple delivers a push only through this app's own Firebase project, and ntfy.sh pushes only
/// through the official app's. So a topic on ntfy.sh, or a self-hosted server whose upstream is
/// ntfy.sh, got no banners here. The bridge closes that: ntfy-me.com streams those topics on
/// ntfy.sh and turns each message (or forwarded poll request) into the `poll_request` wake-up on
/// `topicHash(baseUrl, topic)` that the app and NSE already handle. Nothing on the receiving side
/// changes; this type only tells the server what to watch.
struct BridgeWatchSet: Equatable {
    static let maxEntries = 100
    static let ntfyShBaseUrl = "https://ntfy.sh"

    /// Raw topic names on https://ntfy.sh, sorted and unique.
    var ntfyShTopics: [String] = []
    /// `topicHash(baseUrl, topic)` for every other server except the app's own, sorted and unique.
    var hashes: [String] = []
    /// Subscriptions left out of the set (bad name, login on ntfy.sh, over the cap, unusable spelling).
    var skipped = 0

    static let empty = BridgeWatchSet()

    var isEmpty: Bool { ntfyShTopics.isEmpty && hashes.isEmpty }

    /// Compared against the last set the server accepted; a difference means re-register.
    var signature: String { "t:" + ntfyShTopics.joined(separator: ",") + "|h:" + hashes.joined(separator: ",") }

    static func isValidNtfyShTopic(_ topic: String) -> Bool {
        topic.range(of: #"^[-_A-Za-z0-9]{1,64}$"#, options: .regularExpression) != nil
    }

    /// - Parameters:
    ///   - subscriptions: every subscription's stored base URL and topic.
    ///   - ntfyShHasLogin: a user is saved for https://ntfy.sh. The bridge reads ntfy.sh anonymously,
    ///     so it could not read those topics, and sending their names would only leak them.
    static func compute(subscriptions: [(baseUrl: String, topic: String)], ntfyShHasLogin: Bool,
                        appBaseUrl: String = Config.appBaseUrl) -> BridgeWatchSet {
        let appServer = normalizeBaseUrl(appBaseUrl)
        var topics = Set<String>()
        var hashes = Set<String>()
        var skipped = 0
        for (baseUrl, topic) in subscriptions {
            let server = normalizeBaseUrl(baseUrl)
            // The app's own server already pushes to this app.
            if server == appServer { continue }
            if URL(string: server)?.host?.lowercased() == "ntfy.sh" {
                // Only the exact spelling: the server wakes `sha256("https://ntfy.sh/" + topic)`, and
                // that is the FCM topic this app binds only for a subscription stored as https://ntfy.sh.
                if server == ntfyShBaseUrl, !ntfyShHasLogin, isValidNtfyShTopic(topic) {
                    topics.insert(topic)
                } else {
                    skipped += 1
                }
                continue
            }
            hashes.insert(topicHash(baseUrl: server, topic: topic))
        }
        let sortedTopics = topics.sorted()
        let sortedHashes = hashes.sorted()
        skipped += max(0, sortedTopics.count - maxEntries) + max(0, sortedHashes.count - maxEntries)
        return BridgeWatchSet(ntfyShTopics: Array(sortedTopics.prefix(maxEntries)),
                              hashes: Array(sortedHashes.prefix(maxEntries)), skipped: skipped)
    }
}

/// What the last registration did, kept for the next decision and for Notification status.
struct BridgeRecord: Codable, Equatable {
    enum Outcome: String, Codable {
        case ok, rejected, rateLimited, full, serverError, network
    }
    var lastAttempt: Date?
    var lastOutcome: Outcome?
    var lastHTTPStatus: Int?
    var lastSuccess: Date?
    /// Signature of the set the server last accepted.
    var acceptedSignature: String?
    /// True from the moment a non-empty set is sent until an empty one is accepted: the server may
    /// hold entries for this device, so switching off or removing the last topic must still post.
    var mayHaveEntries = false
    /// A 429's Retry-After: automatic attempts wait until then.
    var notBefore: Date?
    var sentTopics = 0
    var sentHashes = 0
    var watching: Int?
    var expires: Date?
}

final class NtfyShBridge: ObservableObject {
    private static let tag = "NtfyShBridge"
    static let enabledKey = Config.ntfyShBridgeKey
    static let deviceIdKey = "ntfyShBridgeDeviceId"
    static let recordKey = "ntfyShBridgeRecord"
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let maxRetryAfter: TimeInterval = 60 * 60

    static var defaults: UserDefaults { UserDefaults(suiteName: Store.appGroup) ?? .standard }

    /// The setting, on by default (operator, 2026-10-06: "ON by default, disclosed").
    static var isEnabledSetting: Bool { Config.ntfyShBridgeEnabled }

    /// Under unit tests the host app must not register the simulator with the real server.
    static let shared = NtfyShBridge(store: .shared, network: NSClassFromString("XCTestCase") == nil)

    @Published private(set) var record: BridgeRecord

    private let store: Store
    private let defaults: UserDefaults
    private let session: URLSession?
    private let appBaseUrl: String
    private let now: () -> Date
    private let lock = NSLock()
    private var inFlight = false
    private var rerunRequested = false
    private var pendingCompletions: [() -> Void] = []
    private var recordStorage: BridgeRecord

    init(store: Store, defaults: UserDefaults = NtfyShBridge.defaults, session: URLSession? = nil,
         network: Bool = true, appBaseUrl: String = Config.appBaseUrl, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.defaults = defaults
        self.appBaseUrl = appBaseUrl
        self.now = now
        if let session {
            self.session = session
        } else if network {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config)
        } else {
            self.session = nil
        }
        let saved = (defaults.data(forKey: Self.recordKey)).flatMap { try? JSONDecoder().decode(BridgeRecord.self, from: $0) }
            ?? BridgeRecord()
        self.record = saved
        self.recordStorage = saved
    }

    /// The record as last saved, readable from any thread; `record` is its main-thread copy for views.
    var currentRecord: BridgeRecord {
        lock.lock(); defer { lock.unlock() }
        return recordStorage
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        sync(reason: enabled ? "setting turned on" : "setting turned off")
    }

    /// 32 lowercase hex characters, made once per install and tied to nothing else.
    var deviceId: String {
        if let id = defaults.string(forKey: Self.deviceIdKey), id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil {
            return id
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(id, forKey: Self.deviceIdKey)
        return id
    }

    var endpoint: URL? { URL(string: normalizeBaseUrl(appBaseUrl) + "/v1/ntfai/watch") }

    /// The set the subscriptions call for, whatever the setting says.
    func subscribedSet() -> BridgeWatchSet {
        var pairs: [(baseUrl: String, topic: String)] = []
        var hasLogin = false
        store.context.performAndWait {
            pairs = (store.getSubscriptions() ?? []).compactMap {
                guard let baseUrl = $0.baseUrl, let topic = $0.topic else { return nil }
                return (baseUrl, topic)
            }
            hasLogin = store.getUser(baseUrl: BridgeWatchSet.ntfyShBaseUrl) != nil
        }
        return BridgeWatchSet.compute(subscriptions: pairs, ntfyShHasLogin: hasLogin, appBaseUrl: appBaseUrl)
    }

    /// What should be registered now: empty when the setting is off.
    func desiredSet() -> BridgeWatchSet {
        isEnabled ? subscribedSet() : .empty
    }

    /// Register the current set if it changed or the last success is over a day old.
    ///
    /// Cheap to call on every trigger: with nothing to do it is a fetch and a return. A failure
    /// leaves `acceptedSignature` alone, so the next trigger tries again; there are no timers.
    func sync(reason: String, completion: (() -> Void)? = nil) {
        lock.lock()
        if inFlight {
            rerunRequested = true
            if let completion { pendingCompletions.append(completion) }
            lock.unlock()
            Log.d(Self.tag, "sync(\(reason)) queued behind a registration in flight")
            return
        }
        inFlight = true
        lock.unlock()

        let desired = desiredSet()
        let current = currentRecord
        if let skip = skipReason(desired: desired, record: current) {
            Log.d(Self.tag, "sync(\(reason)): \(skip)")
            finish(completion)
            return
        }
        guard let session, let url = endpoint else {
            Log.d(Self.tag, "sync(\(reason)): no network in this process")
            finish(completion)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.body(device: deviceId, set: desired)

        var started = current
        started.lastAttempt = now()
        started.sentTopics = desired.ntfyShTopics.count
        started.sentHashes = desired.hashes.count
        if !desired.isEmpty { started.mayHaveEntries = true }
        save(started)
        Log.i(Self.tag, "sync(\(reason)): registering \(desired.ntfyShTopics.count) ntfy.sh topic(s), "
              + "\(desired.hashes.count) hash(es), \(desired.skipped) skipped")

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handle(desired: desired, data: data, response: response as? HTTPURLResponse, error: error)
                self.finish(completion)
            }
        }.resume()
    }

    static func body(device: String, set: BridgeWatchSet) -> Data? {
        struct Body: Encodable {
            let device: String
            let ntfy_sh_topics: [String]
            let hashes: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(Body(device: device, ntfy_sh_topics: set.ntfyShTopics, hashes: set.hashes))
    }

    private func skipReason(desired: BridgeWatchSet, record: BridgeRecord) -> String? {
        if let notBefore = record.notBefore, notBefore > now() {
            return "waiting for the server's Retry-After"
        }
        if desired.isEmpty {
            return record.mayHaveEntries ? nil : "nothing to register"
        }
        if desired.signature == record.acceptedSignature, let success = record.lastSuccess,
           now().timeIntervalSince(success) < Self.refreshInterval, success <= now() {
            return "up to date"
        }
        return nil
    }

    private func handle(desired: BridgeWatchSet, data: Data?, response: HTTPURLResponse?, error: Error?) {
        var next = currentRecord
        next.lastHTTPStatus = response?.statusCode
        next.notBefore = nil
        guard error == nil, let response else {
            next.lastOutcome = .network
            save(next)
            Log.w(Self.tag, "Registration failed: \(error?.localizedDescription ?? "no response"); retrying at the next trigger")
            return
        }
        switch response.statusCode {
        case 200:
            struct Reply: Decodable { let watching: Int?; let expires: Double? }
            let reply = data.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }
            next.lastOutcome = .ok
            next.lastSuccess = now()
            next.acceptedSignature = desired.signature
            next.mayHaveEntries = !desired.isEmpty
            next.watching = reply?.watching
            next.expires = reply?.expires.map { Date(timeIntervalSince1970: $0) }
            Log.i(Self.tag, "Registration accepted: watching \(reply?.watching.map(String.init) ?? "?")")
        case 429:
            next.lastOutcome = .rateLimited
            let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
            if seconds.isFinite, seconds > 0 { next.notBefore = now().addingTimeInterval(min(seconds, Self.maxRetryAfter)) }
            Log.w(Self.tag, "Registration rate limited (Retry-After \(Int(seconds)) s); retrying at a later trigger")
        case 503:
            next.lastOutcome = .full
            Log.w(Self.tag, "Bridge is full (503); retrying at the next trigger")
        case 400..<500:
            next.lastOutcome = .rejected
            let detail = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(300) ?? ""
            Log.e(Self.tag, "Registration rejected (HTTP \(response.statusCode)): \(detail)")
        default:
            next.lastOutcome = .serverError
            Log.w(Self.tag, "Registration failed (HTTP \(response.statusCode)); retrying at the next trigger")
        }
        save(next)
    }

    private func save(_ next: BridgeRecord) {
        lock.lock(); recordStorage = next; lock.unlock()
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.recordKey) }
        if Thread.isMainThread { record = next } else { DispatchQueue.main.async { self.record = next } }
    }

    private func finish(_ completion: (() -> Void)?) {
        lock.lock()
        inFlight = false
        let rerun = rerunRequested
        rerunRequested = false
        let queued = pendingCompletions
        pendingCompletions = []
        lock.unlock()
        completion?()
        if rerun {
            sync(reason: "queued while a registration was in flight") { queued.forEach { $0() } }
        } else {
            queued.forEach { $0() }
        }
    }

    /// For feedback reports: counts, outcome and age, nothing that identifies a topic or the device.
    var diagnosticSummary: String {
        let record = currentRecord
        let age = record.lastSuccess.map { "\(Int(now().timeIntervalSince($0) / 60))m ago" } ?? "never"
        return "sent \(record.sentTopics)t/\(record.sentHashes)h, last \(record.lastOutcome?.rawValue ?? "none")"
            + (record.lastHTTPStatus.map { " (\($0))" } ?? "") + ", success \(age), watching \(record.watching.map(String.init) ?? "?")"
    }

    // MARK: Status

    enum Status: Equatable {
        case connected(watching: Int)
        case notConnected(watching: Int)
        case unknownDevice
        case unavailable
    }

    /// `GET /v1/ntfai/watch?device=` for Notification status. Only asked when that screen opens.
    func fetchStatus(completion: @escaping (Status) -> Void) {
        guard let session, let endpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(.unavailable)
            return
        }
        components.queryItems = [URLQueryItem(name: "device", value: deviceId)]
        guard let url = components.url else { completion(.unavailable); return }
        var request = URLRequest(url: url)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            struct Reply: Decodable { let watching: Int; let connected: Bool }
            let status: Status
            let code = (response as? HTTPURLResponse)?.statusCode
            if code == 404 {
                status = .unknownDevice
            } else if code == 200, let data, let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                status = reply.connected ? .connected(watching: reply.watching) : .notConnected(watching: reply.watching)
            } else {
                status = .unavailable
            }
            Log.d(Self.tag, "Status: \(status) (HTTP \(code.map(String.init) ?? "none"))")
            DispatchQueue.main.async { completion(status) }
        }.resume()
    }
}

/// Every user-facing sentence about the bridge, so Settings, Notification status and the tests
/// read the same text.
enum NtfyShBridgeCopy {
    static var serverName: String { normalizeBaseUrl(Config.appBaseUrl).replacingOccurrences(of: "https://", with: "") }

    static var settingTitle: String { String(localized: "Instant banners for ntfy.sh and other servers") }

    static var settingFooter: String {
        String(localized: "\(serverName) watches your ntfy.sh topics and wakes this device when a message arrives. It learns those topic names and sees their messages in passing, but keeps no message text. For your own server it learns only a hash of each topic address. Topics that need a login on ntfy.sh aren't watched. Off, ntfy.sh topics and servers whose upstream is ntfy.sh show new messages only when you open the app or refresh.")
    }

    static var on: String { String(localized: "On") }
    static var off: String { String(localized: "Off") }
    static var ntfyShTopics: String { String(localized: "ntfy.sh topics watched") }
    static var otherTopics: String { String(localized: "Other servers' topics watched") }
    static var lastRegistration: String { String(localized: "Last registration") }
    static var never: String { String(localized: "Never") }
    static var connection: String { String(localized: "Bridge connection") }
    static var checking: String { String(localized: "Checking…") }

    static func outcome(_ outcome: BridgeRecord.Outcome) -> String {
        switch outcome {
        case .ok: return String(localized: "Accepted")
        case .rejected: return String(localized: "Rejected by the server")
        case .rateLimited: return String(localized: "Rate limited, will retry")
        case .full: return String(localized: "Bridge full, will retry")
        case .serverError: return String(localized: "Server error, will retry")
        case .network: return String(localized: "No connection, will retry")
        }
    }

    static func status(_ status: NtfyShBridge.Status) -> String {
        switch status {
        case .connected: return String(localized: "Connected")
        case .notConnected: return String(localized: "Reconnecting to ntfy.sh")
        case .unknownDevice: return String(localized: "Not registered yet")
        case .unavailable: return String(localized: "Couldn't check")
        }
    }

    /// "5 minutes ago, Accepted": when the last attempt ran and how it went.
    static func lastRegistration(_ record: BridgeRecord, now: Date = Date()) -> String {
        guard let attempt = record.lastAttempt else { return never }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: min(attempt, now), relativeTo: now)
        guard let outcome = record.lastOutcome else { return when }
        return String(localized: "\(when), \(self.outcome(outcome))")
    }
}
