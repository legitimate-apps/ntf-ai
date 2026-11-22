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
    static let ntfyShBaseUrl = NtfyShAddress.canonical

    /// Why one subscription is not in the set the server watches.
    enum Hold: String, Codable, Equatable {
        /// A login is saved for ntfy.sh and an anonymous check found the topic protected.
        case needsLogin
        /// A login is saved for ntfy.sh and the topic hasn't been checked anonymously yet.
        case checkingAccess
        /// ntfy.sh doesn't allow the name, so the server would refuse it.
        case invalidName
        /// Past the contract's 100 entries per list.
        case overCap
    }

    struct Entry: Equatable {
        let baseUrl: String
        let topic: String
        let hold: Hold
    }

    /// Raw topic names on https://ntfy.sh, sorted and unique.
    var ntfyShTopics: [String] = []
    /// `topicHash(baseUrl, topic)` for every other server except the app's own, sorted and unique.
    var hashes: [String] = []
    /// Subscriptions left out of the set, each with its reason.
    var held: [Entry] = []
    /// ntfy.sh topics (with a login saved) that need an anonymous access check before they can be sent.
    var needsProbe: [String] = []

    var skipped: Int { held.count }

    static let empty = BridgeWatchSet()

    var isEmpty: Bool { ntfyShTopics.isEmpty && hashes.isEmpty }

    /// Compared against the last set the server accepted; a difference means re-register.
    var signature: String { "t:" + ntfyShTopics.joined(separator: ",") + "|h:" + hashes.joined(separator: ",") }

    static func isValidNtfyShTopic(_ topic: String) -> Bool {
        topic.range(of: #"^[-_A-Za-z0-9]{1,64}$"#, options: .regularExpression) != nil
    }

    func hold(baseUrl: String, topic: String) -> Hold? {
        held.first { $0.baseUrl == baseUrl && $0.topic == topic }?.hold
    }

    /// - Parameters:
    ///   - subscriptions: every subscription's stored base URL and topic, and whether a login is saved for its server.
    ///   - access: what anonymous checks found for ntfy.sh topic names (only consulted with a login).
    ///
    /// Any spelling of ntfy.sh counts (`NtfyShAddress`): the wake-up lands on the `https://ntfy.sh`
    /// hash, which is the name the app binds for every spelling since 1.30. Without a login every
    /// valid name is sent, as in 1.29; the server reports any it can't read (`unwatchable`). With a
    /// login a name is sent only once an anonymous check answered 200, so a protected name never
    /// reaches ntfy-me.com.
    static func compute(subscriptions: [(baseUrl: String, topic: String, hasLogin: Bool)],
                        access: [String: NtfyShAccess] = [:], now: Date = Date(),
                        appBaseUrl: String = Config.appBaseUrl) -> BridgeWatchSet {
        let appServer = normalizeBaseUrl(appBaseUrl)
        var topics = Set<String>()
        var hashes: [String: (baseUrl: String, topic: String)] = [:]
        var topicOwners: [String: [(baseUrl: String, topic: String)]] = [:]
        var held: [Entry] = []
        var probe = Set<String>()
        for (baseUrl, topic, hasLogin) in subscriptions {
            let server = normalizeBaseUrl(baseUrl)
            // The app's own server already pushes to this app.
            if server == appServer { continue }
            if NtfyShAddress.isNtfySh(server) {
                guard isValidNtfyShTopic(topic) else {
                    held.append(Entry(baseUrl: baseUrl, topic: topic, hold: .invalidName)); continue
                }
                if hasLogin {
                    switch access[topic]?.current(now: now) {
                    case .open?: break
                    case .protected?:
                        held.append(Entry(baseUrl: baseUrl, topic: topic, hold: .needsLogin)); continue
                    case .invalid?:
                        held.append(Entry(baseUrl: baseUrl, topic: topic, hold: .invalidName)); continue
                    case .unknown?:
                        held.append(Entry(baseUrl: baseUrl, topic: topic, hold: .checkingAccess)); continue
                    case nil:
                        probe.insert(topic)
                        held.append(Entry(baseUrl: baseUrl, topic: topic, hold: .checkingAccess)); continue
                    }
                }
                topics.insert(topic)
                topicOwners[topic, default: []].append((baseUrl, topic))
                continue
            }
            if URL(string: server)?.host?.lowercased() == "ntfy.sh" {
                // A path under ntfy.sh is not an ntfy server; nothing could wake it.
                continue
            }
            hashes[topicHash(baseUrl: server, topic: topic)] = (baseUrl, topic)
        }
        let sortedTopics = topics.sorted()
        let sortedHashes = hashes.keys.sorted()
        for topic in sortedTopics.dropFirst(maxEntries) {
            for owner in topicOwners[topic] ?? [] { held.append(Entry(baseUrl: owner.baseUrl, topic: owner.topic, hold: .overCap)) }
        }
        for hash in sortedHashes.dropFirst(maxEntries) {
            if let owner = hashes[hash] { held.append(Entry(baseUrl: owner.baseUrl, topic: owner.topic, hold: .overCap)) }
        }
        return BridgeWatchSet(ntfyShTopics: Array(sortedTopics.prefix(maxEntries)),
                              hashes: Array(sortedHashes.prefix(maxEntries)), held: held, needsProbe: probe.sorted())
    }
}

/// What an anonymous `GET https://ntfy.sh/<topic>/auth` said, which is the read the bridge makes.
struct NtfyShAccess: Codable, Equatable {
    enum State: String, Codable { case open, protected, invalid, unknown }
    var state: State
    var checked: Date

    /// How long an answer holds before the topic is checked again. A protected topic can be
    /// unreserved, an open one reserved; a failed check is retried after an hour.
    static func lifetime(_ state: State) -> TimeInterval {
        switch state {
        case .open, .invalid: return 7 * 24 * 60 * 60
        case .protected: return 24 * 60 * 60
        case .unknown: return 60 * 60
        }
    }

    /// The answer while it is fresh, nil once it is due again.
    func current(now: Date) -> State? {
        let age = now.timeIntervalSince(checked)
        return age >= 0 && age < Self.lifetime(state) ? state : nil
    }

    static func classify(status: Int?) -> State {
        switch status {
        case 200?: return .open
        case 401?, 403?: return .protected
        case 400?: return .invalid
        default: return .unknown
        }
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
    /// The device's own ntfy.sh names the server reports it can't read (status and POST, from 1.30).
    var unwatchable: [String]?
}

final class NtfyShBridge: ObservableObject {
    private static let tag = "NtfyShBridge"
    static let enabledKey = Config.ntfyShBridgeKey
    static let deviceIdKey = "ntfyShBridgeDeviceId"
    static let recordKey = "ntfyShBridgeRecord"
    static let accessKey = "ntfyShBridgeAccess"
    /// Anonymous access checks per sync, so a big account can't burst ntfy.sh's per-IP limits.
    static let maxProbesPerSync = 20
    /// The extension refreshes a registration older than this when it handles a bridged wake-up,
    /// well inside the server's 30-day expiry.
    static let extensionRefreshAge: TimeInterval = 7 * 24 * 60 * 60
    /// And tries at most this often, so a failing refresh can't run on every push.
    static let extensionRetryInterval: TimeInterval = 60 * 60
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
        var rows: [(baseUrl: String, topic: String, hasLogin: Bool)] = []
        store.context.performAndWait {
            let users = Set(((try? store.context.fetch(User.fetchRequest())) ?? []).compactMap { $0.baseUrl.map(normalizeBaseUrl) })
            let ntfyShLogin = users.contains(where: NtfyShAddress.isNtfySh)
            rows = (store.getSubscriptions() ?? []).compactMap {
                guard let baseUrl = $0.baseUrl, let topic = $0.topic else { return nil }
                let login = NtfyShAddress.isNtfySh(baseUrl) ? ntfyShLogin : users.contains(normalizeBaseUrl(baseUrl))
                return (baseUrl, topic, login)
            }
        }
        return BridgeWatchSet.compute(subscriptions: rows, access: access, now: now(), appBaseUrl: appBaseUrl)
    }

    // MARK: Anonymous access checks (a login is saved for ntfy.sh)

    /// Cached answers per ntfy.sh topic name.
    var access: [String: NtfyShAccess] {
        defaults.data(forKey: Self.accessKey).flatMap { try? JSONDecoder().decode([String: NtfyShAccess].self, from: $0) } ?? [:]
    }

    private func saveAccess(_ update: [String: NtfyShAccess]) {
        lock.lock(); defer { lock.unlock() }
        var merged = access
        update.forEach { merged[$0.key] = $0.value }
        // Forget names checked over a month ago (unsubscribed long since).
        merged = merged.filter { now().timeIntervalSince($0.value.checked) < 30 * 24 * 60 * 60 }
        if let data = try? JSONEncoder().encode(merged) { defaults.set(data, forKey: Self.accessKey) }
    }

    /// `GET https://ntfy.sh/<topic>/auth` with no credentials: 200 when anyone may read it, which is
    /// exactly what the bridge can do. Sequential and capped; a 429 stops the round.
    private func probe(_ topics: [String], completion: @escaping () -> Void) {
        guard let session, !topics.isEmpty else { completion(); return }
        var queue = Array(topics.prefix(Self.maxProbesPerSync))
        var results: [String: NtfyShAccess] = [:]
        func next() {
            guard !queue.isEmpty else { saveAccess(results); completion(); return }
            let topic = queue.removeFirst()
            guard let url = URL(string: NtfyShAddress.canonical + "/" + topic + "/auth") else { next(); return }
            var request = URLRequest(url: url)
            request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
            session.dataTask(with: request) { _, response, error in
                let status = error == nil ? (response as? HTTPURLResponse)?.statusCode : nil
                results[topic] = NtfyShAccess(state: NtfyShAccess.classify(status: status), checked: self.now())
                Log.d(Self.tag, "Access check: HTTP \(status.map(String.init) ?? "none")")
                if status == 429 {
                    // Mark the rest unknown too, so they wait an hour like this one.
                    queue.forEach { results[$0] = NtfyShAccess(state: .unknown, checked: self.now()) }
                    queue = []
                }
                next()
            }.resume()
        }
        next()
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

        let pending = isEnabled && session != nil ? subscribedSet().needsProbe : []
        if !pending.isEmpty {
            Log.d(Self.tag, "sync(\(reason)): checking \(min(pending.count, Self.maxProbesPerSync)) ntfy.sh topic(s) anonymously first")
            probe(pending) { self.register(reason: reason, completion: completion) }
            return
        }
        register(reason: reason, completion: completion)
    }

    private func register(reason: String, completion: (() -> Void)?) {
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
            struct Reply: Decodable { let watching: Int?; let expires: Double?; let unwatchable: [String]? }
            let reply = data.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }
            next.unwatchable = reply?.unwatchable
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

    // MARK: Per-topic truth (topic details, Notification status)

    enum TopicState: Equatable {
        /// On the app's own server: pushed directly, the bridge isn't involved.
        case direct
        /// In the set the bridge watches.
        case watched
        case held(TopicHold)
    }

    enum TopicHold: Equatable {
        case needsLogin, checkingAccess, invalidName, overCap, bridgeOff, bridgeUnavailable
        /// Self-hosted: no wake-up seen for recent messages; `address` is the one used in the app.
        case notSetUp(address: String)

        /// The setting is off or the bridge can't take the list: true of every topic on the server,
        /// so the status screen says it once instead of once per topic.
        var isServerWide: Bool { self == .bridgeOff || self == .bridgeUnavailable }
    }

    /// Why a subscription does or doesn't get instant banners through the bridge.
    func topicState(baseUrl: String, topic: String, set: BridgeWatchSet? = nil,
                    wakes: SelfHostedWakeCheck? = .shared) -> TopicState {
        if normalizeBaseUrl(baseUrl) == normalizeBaseUrl(appBaseUrl) { return .direct }
        let ntfySh = NtfyShAddress.isNtfySh(baseUrl)
        if !ntfySh, URL(string: normalizeBaseUrl(baseUrl))?.host?.lowercased() == "ntfy.sh" { return .held(.invalidName) }
        guard isEnabled else { return .held(.bridgeOff) }
        let set = set ?? subscribedSet()
        if let hold = set.hold(baseUrl: baseUrl, topic: topic) {
            switch hold {
            case .needsLogin: return .held(.needsLogin)
            case .checkingAccess: return .held(.checkingAccess)
            case .invalidName: return .held(.invalidName)
            case .overCap: return .held(.overCap)
            }
        }
        let record = currentRecord
        if ntfySh, record.unwatchable?.contains(topic) == true { return .held(.needsLogin) }
        if !ntfySh, let wakes, wakes.isNotSetUp(hash: topicHash(baseUrl: baseUrl, topic: topic)) {
            return .held(.notSetUp(address: normalizeBaseUrl(baseUrl)))
        }
        // The set the server holds isn't this one and the last try failed: nothing is watched yet.
        if let outcome = record.lastOutcome, outcome != .ok, record.acceptedSignature != set.signature {
            return .held(.bridgeUnavailable)
        }
        if record.lastOutcome == .full { return .held(.bridgeUnavailable) }
        return .watched
    }

    /// Notification status, per server: how many topics are watched and every topic that isn't, with why.
    struct Report: Equatable {
        struct Held: Equatable {
            let topic: String
            let hold: TopicHold
        }
        struct Group: Equatable {
            let server: String
            var watching: Int
            var held: [Held]
            /// The server-wide reason, if any (shown once).
            var serverWide: TopicHold? { held.first { $0.hold.isServerWide }?.hold }
            /// Topics held for a reason of their own.
            var topicHeld: [Held] { held.filter { !$0.hold.isServerWide } }
        }
        var groups: [Group]
    }

    /// ntfy.sh first, then other servers by address; the app's own server isn't listed (it pushes directly).
    func report(wakes: SelfHostedWakeCheck? = .shared) -> Report {
        var pairs: [(baseUrl: String, topic: String)] = []
        store.context.performAndWait {
            pairs = (store.getSubscriptions() ?? []).compactMap {
                guard let baseUrl = $0.baseUrl, let topic = $0.topic else { return nil }
                return (baseUrl, topic)
            }
        }
        let set = subscribedSet()
        var groups: [String: Report.Group] = [:]
        for pair in pairs {
            let state = topicState(baseUrl: pair.baseUrl, topic: pair.topic, set: set, wakes: wakes)
            if state == .direct { continue }
            let server = NtfyShAddress.canonicalize(pair.baseUrl) ?? normalizeBaseUrl(pair.baseUrl)
            var group = groups[server] ?? Report.Group(server: server, watching: 0, held: [])
            switch state {
            case .watched: group.watching += 1
            case .held(let hold): group.held.append(Report.Held(topic: pair.topic, hold: hold))
            case .direct: break
            }
            groups[server] = group
        }
        let ordered = groups.values.sorted {
            ($0.server == NtfyShAddress.canonical ? 0 : 1, $0.server) < ($1.server == NtfyShAddress.canonical ? 0 : 1, $1.server)
        }
        return Report(groups: ordered.map { var g = $0; g.held.sort { $0.topic < $1.topic }; return g })
    }

    /// On, and the server accepted the set it holds now.
    var isRegistered: Bool {
        let record = currentRecord
        return isEnabled && record.lastOutcome == .ok && record.acceptedSignature != nil
    }

    // MARK: Refresh from the extension

    /// True when a bridged wake-up should also refresh this device's registration: it is over a
    /// week old (the server forgets a device after 30 days without a POST), and the last attempt
    /// wasn't within the hour. A user who lives on banners and never opens the app stays registered.
    func extensionShouldRefresh() -> Bool {
        guard isEnabled else { return false }
        let record = currentRecord
        if let attempt = record.lastAttempt, now().timeIntervalSince(attempt) < Self.extensionRetryInterval, attempt <= now() { return false }
        guard let success = record.lastSuccess else { return record.mayHaveEntries || record.lastAttempt == nil }
        return now().timeIntervalSince(success) >= Self.extensionRefreshAge
    }

    /// Called by the extension for a wake-up on a non-hosted topic. Never waited on: the banner
    /// goes out first, and a POST the system cuts short is retried by the next wake or launch.
    func refreshFromExtensionIfStale() {
        guard extensionShouldRefresh() else { return }
        sync(reason: "extension refresh")
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
            struct Reply: Decodable { let watching: Int; let connected: Bool; let unwatchable: [String]? }
            let status: Status
            let code = (response as? HTTPURLResponse)?.statusCode
            if code == 404 {
                status = .unknownDevice
            } else if code == 200, let data, let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                status = reply.connected ? .connected(watching: reply.watching) : .notConnected(watching: reply.watching)
                var next = self.currentRecord
                next.unwatchable = reply.unwatchable
                self.save(next)
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
        String(localized: "\(serverName) watches your ntfy.sh topics and wakes this device when a message arrives. It learns those topic names and sees their messages in passing, but keeps no message text. For your own server it learns only a hash of each topic address. With a login saved for ntfy.sh, the app first checks each ntfy.sh topic without the login, and only topics anyone can read are sent. Off, ntfy.sh topics and servers whose upstream is ntfy.sh show new messages only when you open the app or refresh.")
    }

    static var instantBanners: String { String(localized: "Instant banners") }
    static func watching(_ count: Int) -> String { String(localized: "Watching \(count)") }

    /// Why one topic gets no instant banners, in the words the user sees on the topic and in
    /// Notification status.
    static func reason(_ hold: NtfyShBridge.TopicHold) -> String {
        switch hold {
        case .needsLogin:
            return String(localized: "Needs a login on ntfy.sh, so new messages show when you open the app.")
        case .checkingAccess:
            return String(localized: "Checking whether anyone can read this topic on ntfy.sh. Until then, new messages show when you open the app.")
        case .invalidName:
            return String(localized: "This address or topic name can't be watched on ntfy.sh, so new messages show when you open the app.")
        case .overCap:
            return String(localized: "Over the limit of 100 topics per list, so new messages show when you open the app.")
        case .bridgeOff:
            return String(localized: "Instant banners for ntfy.sh and other servers is off in Settings, so new messages show when you open the app.")
        case .bridgeUnavailable:
            return String(localized: "\(serverName) is busy or unreachable and will retry on its own. Until then, new messages show when you open the app.")
        case .notSetUp(let address):
            return String(localized: "No wake-up arrived for recent messages, so this server isn't set up for instant banners. Ask its admin to set upstream-base-url to https://ntfy.sh and base-url to exactly \(address), the address this app uses. Until then, new messages show when you open the app.")
        }
    }

    static var on: String { String(localized: "On") }
    static var off: String { String(localized: "Off") }
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
