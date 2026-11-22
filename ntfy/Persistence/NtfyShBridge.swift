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
        /// An anonymous check found the topic protected (401/403).
        case needsLogin
        /// The bridge reported ntfy.sh refused the name (`unwatchable`) for a reason it doesn't give.
        case refused
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
    ///   - subscriptions: every subscription's stored base URL and topic, and whether a credential
    ///     (a saved user or a custom header such as `Authorization`) may be saved for its server:
    ///     true when one is, and also when that couldn't be read (unknown counts as present).
    ///   - access: what anonymous checks found for ntfy.sh topic names, and names the server refused.
    ///
    /// Any spelling of ntfy.sh counts (`NtfyShAddress`): the wake-up lands on the `https://ntfy.sh`
    /// hash, which is the name the app binds for every spelling since 1.30 (review-130b #4):
    /// - With a credential (or credential state unknown) a name is sent only while its last
    ///   anonymous 200 is at most 36 hours old. It is rechecked from 24 hours, so a working check
    ///   keeps it in the list; a failed or rate-limited check withholds it until a fresh 200.
    /// - Without one, a valid name is sent as in 1.29.
    /// - Either way a name ntfy.sh refused (an anonymous 401/403, or the server's `unwatchable`)
    ///   waits for a fresh anonymous 200, whichever evidence is newer deciding.
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
                let answer = access[topic]
                let mayCheck = answer?.mayCheck(now: now) ?? true
                let age = answer.map { now.timeIntervalSince($0.checked) } ?? .infinity
                switch answer?.state {
                case .open? where age >= 0 && age < NtfyShAccess.sendableOpenAge:
                    if age >= NtfyShAccess.recheckOpenAge, hasLogin {
                        if mayCheck { probe.insert(topic) }
                        // The due recheck failed or was rate limited: withheld until a fresh 200.
                        if let failed = answer?.failedAt, let checked = answer?.checked, failed >= checked {
                            held.append(Entry(baseUrl: baseUrl, topic: topic, hold: .checkingAccess)); continue
                        }
                    }
                case .protected?, .refused?:
                    if answer?.current(now: now) == nil, mayCheck { probe.insert(topic) }
                    held.append(Entry(baseUrl: baseUrl, topic: topic, hold: answer?.state == .refused ? .refused : .needsLogin)); continue
                case .invalid?:
                    if answer?.current(now: now) == nil, mayCheck { probe.insert(topic) }
                    held.append(Entry(baseUrl: baseUrl, topic: topic, hold: .invalidName)); continue
                default:
                    // Never checked, only failed checks, or a 200 over 36 hours old.
                    if hasLogin {
                        if mayCheck { probe.insert(topic) }
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

extension BridgeWatchSet {
    /// "t:<name>" for each ntfy.sh topic and "h:<hash>" for each hash in a set's `signature`.
    static func members(signature: String?) -> Set<String> {
        guard let signature, signature.hasPrefix("t:"), let bar = signature.range(of: "|h:") else { return [] }
        let topics = signature[signature.index(signature.startIndex, offsetBy: 2)..<bar.lowerBound]
        let hashes = signature[bar.upperBound...]
        return Set(topics.split(separator: ",").map { "t:" + $0 } + hashes.split(separator: ",").map { "h:" + $0 })
    }
}

/// What an anonymous `GET https://ntfy.sh/<topic>/auth` said, which is the read the bridge makes,
/// or the server's refusal of the name. `state` and `checked` are the newest definitive evidence
/// (a failed check never replaces it); `failedAt` paces retries after a failed check.
struct NtfyShAccess: Codable, Equatable {
    /// `refused`: the bridge reported ntfy.sh refused the name, cause not given (from 1.30).
    enum State: String, Codable { case open, protected, invalid, refused, unknown }
    var state: State
    /// When the evidence was taken: a check's start, or when a refusal was reported.
    var checked: Date
    var failedAt: Date?

    init(state: State, checked: Date, failedAt: Date? = nil) {
        self.state = state
        self.checked = checked
        self.failedAt = failedAt
    }

    /// Merge newer evidence: a definitive answer replaces an older one (never a newer one), and a
    /// failed check only records when it failed.
    func merged(with update: NtfyShAccess) -> NtfyShAccess {
        if update.state == .unknown {
            guard state != .unknown else { return update.checked >= checked ? update : self }
            var next = self
            next.failedAt = max(failedAt ?? .distantPast, update.checked)
            return next
        }
        if state != .unknown, checked > update.checked { return self }
        return NtfyShAccess(state: update.state, checked: update.checked)
    }

    /// No check failed within the hour (or the failure is from the future: clock change).
    func mayCheck(now: Date) -> Bool {
        let failed = state == .unknown ? checked : failedAt
        guard let failed, failed <= now else { return true }
        return now.timeIntervalSince(failed) >= Self.lifetime(.unknown)
    }

    /// How long an answer holds before the topic is checked again. A protected topic can be
    /// unreserved, an open one reserved; a failed check is retried after an hour.
    static func lifetime(_ state: State) -> TimeInterval {
        switch state {
        case .open, .invalid: return 7 * 24 * 60 * 60
        case .protected, .refused: return 24 * 60 * 60
        case .unknown: return 60 * 60
        }
    }

    /// With a credential saved (or unknown), a name is sent only while its anonymous 200 is younger than this.
    static let sendableOpenAge: TimeInterval = 36 * 60 * 60
    /// And rechecked from this age, so a working check renews it before it lapses.
    static let recheckOpenAge: TimeInterval = 24 * 60 * 60

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
/// Fields added after 1.29 are optional so an older record still decodes.
struct BridgeRecord: Codable, Equatable {
    enum Outcome: String, Codable {
        case ok, rejected, rateLimited, full, unavailable, serverError, network
        /// 429 code 42912: this network's watch admission limit.
        case admissionLimited
    }
    var lastAttempt: Date?
    var lastOutcome: Outcome?
    var lastHTTPStatus: Int?
    var lastSuccess: Date?
    /// Signature of the set the server last accepted: its members are what it watches.
    var acceptedSignature: String?
    /// True from the moment a non-empty set is sent until an empty one is accepted: the server may
    /// hold entries for this device, so switching off or removing the last topic must still post.
    var mayHaveEntries = false
    var sentTopics = 0
    var sentHashes = 0
    var watching: Int?
    var expires: Date?
    /// The device's own ntfy.sh names the server reports it can't read (status and POST, from 1.30).
    var unwatchable: [String]?
    /// Bumped when a watch POST starts; a reply for an older revision is dropped.
    var revision: Int?
    /// The server said it doesn't know this device (status or renewal 404): post the set again.
    var repairRequested: Bool?
    /// The extension's last renewal attempt and success (`POST /v1/ntfai/watch/renew`).
    var lastRenewAttempt: Date?
    var lastRenew: Date?
    /// What the last status reply said about the bridge's ntfy.sh connection, and when.
    var statusConnected: Bool?
    var statusAt: Date?
    /// The registration revision that status read was for.
    var statusRevision: Int?
    /// The server's per-network watch admission limit (429 code 42912) holds new entries until then;
    /// a removal or an empty list still goes out.
    var admissionBlockedUntil: Date?
    /// A renewal answered 404. Until the server offers renewal every device gets that, so it isn't
    /// shown as a fault; it only makes the app send its list at its next trigger.
    var renewMissed: Bool?
}

/// One cooldown for every automatic request to the app's server (watch, renewal, relay checks),
/// shared by the app and the extension: a server Retry-After is honoured in full, and a failure
/// without one backs off exponentially.
struct NtfyMeHostCooldown: Codable, Equatable {
    var notBefore: Date?
    var failures = 0
    /// True when `notBefore` came from the server's Retry-After, which even a user's own action waits for.
    var serverRequested = false

    static let key = "ntfyMeHostCooldown"
    static let backoffBase: TimeInterval = 30
    static let backoffCap: TimeInterval = 60 * 60
    /// A Retry-After past this is treated as this (a registration expires after 30 days anyway).
    static let maxRetryAfter: TimeInterval = 31 * 24 * 60 * 60

    static func read(_ defaults: UserDefaults) -> NtfyMeHostCooldown {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NtfyMeHostCooldown.self, from: $0) } ?? NtfyMeHostCooldown()
    }

    /// When automatic requests may run again, or nil if they may run now.
    static func blockedUntil(_ defaults: UserDefaults, now: Date, userInitiated: Bool = false) -> Date? {
        let cooldown = read(defaults)
        guard let notBefore = cooldown.notBefore, notBefore > now else { return nil }
        return userInitiated && !cooldown.serverRequested ? nil : notBefore
    }

    /// Record how a request to the server went. The strongest deadline seen wins (review-130b #9):
    /// an answer other than 429 or 5xx ends only the client's own backoff, never a pause the server
    /// asked for that is still running (that answer may belong to a request sent before the pause),
    /// and a failure without Retry-After can't shorten a longer server pause.
    static func note(status: Int?, retryAfter: String?, defaults: UserDefaults, lock: SharedFileLock, now: Date) {
        lock.withLock {
            var cooldown = read(defaults)
            let serverPause = cooldown.serverRequested ? cooldown.notBefore.flatMap { $0 > now ? $0 : nil } : nil
            if let status, status < 500, status != 429 {
                cooldown = NtfyMeHostCooldown()
                if let serverPause { cooldown.notBefore = serverPause; cooldown.serverRequested = true }
            } else {
                cooldown.failures = min(cooldown.failures + 1, 16)
                var next: Date
                var requested: Bool
                if let delay = PollTiming.retryDelay(retryAfter, now: now, cap: maxRetryAfter), delay > 0 {
                    next = now.addingTimeInterval(delay)
                    requested = true
                } else {
                    next = now.addingTimeInterval(min(backoffBase * pow(2, Double(cooldown.failures - 1)), backoffCap))
                    requested = false
                }
                if let serverPause, serverPause >= next { next = serverPause; requested = true }
                cooldown.notBefore = next
                cooldown.serverRequested = requested
            }
            if let data = try? JSONEncoder().encode(cooldown) { defaults.set(data, forKey: key) }
        }
    }
}

extension Foundation.Notification.Name {
    /// The bridge record, access answers or wake-up evidence changed; views showing them re-read.
    /// Observers must only read in answer (`NtfyShBridge.reload()` never posts), or they recurse.
    static let ntfyShBridgeStateChanged = Foundation.Notification.Name("ntfyShBridgeStateChanged")
}

/// Tells every process that bridge state changed. A write posts a Darwin notification; the app
/// observes it once (`observeOtherProcesses`) and turns each one into a single in-process
/// `.ntfyShBridgeStateChanged` on main, so a renewal or wake the extension records reaches an open
/// screen. Before the observer exists (the extension, early launch) a write posts in-process itself.
enum BridgeStateSignal {
    static let darwinName = "\(Store.appGroup).bridgeStateChanged"
    private static let observing = NSLock()
    private static var installed = false

    static var isObserving: Bool { observing.lock(); defer { observing.unlock() }; return installed }

    static func announce() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(darwinName as CFString), nil, nil, true)
        if !isObserving { postInProcess() }
    }

    static func observeOtherProcesses() {
        observing.lock(); defer { observing.unlock() }
        guard !installed else { return }
        installed = true
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
                                        { _, _, _, _, _ in BridgeStateSignal.postInProcess() },
                                        darwinName as CFString, nil, .deliverImmediately)
    }

    static func postInProcess() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .ntfyShBridgeStateChanged, object: nil) }
    }
}

/// The app process is the only writer of watch membership (`sync`). The extension only renews an
/// existing registration (`renewFromExtensionIfStale`), which can't change or create membership.
/// Every read of the record goes to the shared defaults, and every write is a read-modify-write
/// under `SharedFileLock`, so neither process overwrites the other's newer state.
final class NtfyShBridge: ObservableObject {
    private static let tag = "NtfyShBridge"
    static let enabledKey = Config.ntfyShBridgeKey
    static let deviceIdKey = "ntfyShBridgeDeviceId"
    static let recordKey = "ntfyShBridgeRecord"
    static let accessKey = "ntfyShBridgeAccess"
    static let probeCooldownKey = "ntfyShProbeNotBefore"
    static let lockName = "ntfai-bridge.lock"
    /// Anonymous access checks per sync, so a big account can't burst ntfy.sh's per-IP limits.
    static let maxProbesPerSync = 20
    /// The extension renews a registration older than this when it handles a bridged wake-up,
    /// well inside the server's 30-day expiry.
    static let extensionRefreshAge: TimeInterval = 7 * 24 * 60 * 60
    /// And tries at most this often, so a failing renewal can't run on every push.
    static let extensionRetryInterval: TimeInterval = 60 * 60
    /// After a renewal answered a plain 404 (no renewal route), it is tried again this often.
    static let renewMissedRetryInterval: TimeInterval = 24 * 60 * 60
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    /// A probe 429 without a usable Retry-After waits this long; one with it waits at most a day.
    static let probeBackoff: TimeInterval = 60 * 60
    /// Below this much time left in a wake, no new request is started.
    static let minimumRequestTime: TimeInterval = 3
    /// A status reply saying "connected" counts as strong evidence for a miss this close to it.
    static let connectedEvidenceAge: TimeInterval = 10 * 60

    static var defaults: UserDefaults { UserDefaults(suiteName: Store.appGroup) ?? .standard }

    /// The setting, on by default (operator, 2026-10-06: "ON by default, disclosed").
    static var isEnabledSetting: Bool { Config.ntfyShBridgeEnabled }

    /// Under unit tests the host app must not register the simulator with the real server.
    static let shared = NtfyShBridge(store: .shared, network: NSClassFromString("XCTestCase") == nil,
                                     observesCredentialChanges: NSClassFromString("XCTestCase") == nil)

    /// The record as last read; refreshed from the shared defaults on every read (`currentRecord`).
    @Published private(set) var record: BridgeRecord

    private let store: Store
    private let defaults: UserDefaults
    private let session: URLSession?
    private let appBaseUrl: String
    private let now: () -> Date
    let lock: SharedFileLock
    /// The record's own app-group file (from 1.30; 1.29 kept it in the shared defaults).
    let recordFile: SharedStateFile<BridgeRecord>
    private let isExtension: Bool
    private let processLock = NSLock()
    private var inFlight = false
    private var rerunRequested = false
    private var pendingCompletions: [() -> Void] = []
    /// The earliest deadline among syncs queued behind the one in flight (review-130b #2), and
    /// whether any of them came from the user.
    private var pendingDeadline: Date?
    private var pendingUserInitiated = false

    init(store: Store, defaults: UserDefaults = NtfyShBridge.defaults, session: URLSession? = nil,
         network: Bool = true, appBaseUrl: String = Config.appBaseUrl, now: @escaping () -> Date = Date.init,
         lock: SharedFileLock? = nil, stateDirectory: URL = SharedStateFile<BridgeRecord>.sharedDirectory,
         isExtension: Bool = Bundle.main.bundlePath.hasSuffix(".appex"), observesCredentialChanges: Bool = false) {
        self.store = store
        self.defaults = defaults
        self.appBaseUrl = appBaseUrl
        self.now = now
        self.lock = lock ?? .named(Self.lockName)
        self.recordFile = SharedStateFile(name: Self.recordFileName, directory: stateDirectory, lock: self.lock)
        self.isExtension = isExtension
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
        self.record = BridgeRecord()
        self.readSubscriptions = { store.getSubscriptions() }
        self.record = readRecord()
        if observesCredentialChanges, !isExtension {
            // A login or header saved, edited or removed changes which ntfy.sh names may be sent.
            credentialObserver = NotificationCenter.default.addObserver(forName: .serverCredentialsChanged, object: nil, queue: .main) { [weak self] _ in
                self?.sync(reason: "a server credential changed")
            }
        }
    }

    private var credentialObserver: NSObjectProtocol?

    static let recordFileName = "ntfai-bridge-record.json"

    /// The record on disk now; before the first write since 1.30, the one 1.29 left in the defaults.
    private func readRecord() -> BridgeRecord {
        recordFile.read() ?? legacyRecord() ?? BridgeRecord()
    }

    private func legacyRecord() -> BridgeRecord? {
        defaults.data(forKey: Self.recordKey).flatMap { try? JSONDecoder().decode(BridgeRecord.self, from: $0) }
    }

    /// The record as its file holds it now, whichever process wrote it last.
    var currentRecord: BridgeRecord { readRecord() }

    /// Re-read for views (another process may have written). A pure read: it never posts
    /// `.ntfyShBridgeStateChanged`, because the views call it in answer to that notification.
    func reload() {
        let next = currentRecord
        let apply = { if self.record != next { self.record = next } }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// Read-modify-write of the record file under the shared lock. Returns the record as saved,
    /// or nil when the lock wasn't had in time or the write failed: then nothing changed.
    @discardableResult
    private func mutate(_ change: (inout BridgeRecord) -> Void) -> BridgeRecord? {
        let legacy = legacyRecord()
        let outcome: (BridgeRecord, BridgeRecord)? = recordFile.update { stored in
            let before = stored ?? legacy ?? BridgeRecord()
            var next = before
            change(&next)
            // The first write since 1.29 moves the record out of the defaults, even unchanged.
            let write = next != before || stored == nil
            if write { stored = next }
            return (write, (next, before))
        }
        guard let (saved, previous) = outcome else {
            Log.w(Self.tag, "Bridge record not updated (lock or write failed)")
            return nil
        }
        if legacy != nil, recordFile.read() != nil { defaults.removeObject(forKey: Self.recordKey) }
        publish(saved, previous: previous)
        return saved
    }

    /// After a write: refresh `record`, and announce only when the saved record differs from the
    /// one before the write (`previous`), so an unchanged write posts nothing.
    private func publish(_ next: BridgeRecord, previous: BridgeRecord) {
        let apply = { if self.record != next { self.record = next } }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        if next != previous { BridgeStateSignal.announce() }
    }

    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        sync(reason: enabled ? "setting turned on" : "setting turned off", userInitiated: true)
    }

    /// 32 lowercase hex characters, made once per install (under the shared lock, so the app and
    /// the extension can't each make one) and tied to nothing else.
    /// nil only when the shared lock can't be had in time (then no request goes out).
    var deviceId: String? {
        lock.withLock {
            if let id = existingDeviceId { return id }
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            defaults.set(id, forKey: Self.deviceIdKey)
            return id
        }
    }

    /// The installation ID if one was made; renewal never makes one.
    var existingDeviceId: String? {
        guard let id = defaults.string(forKey: Self.deviceIdKey), id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { return nil }
        return id
    }

    var endpoint: URL? { URL(string: normalizeBaseUrl(appBaseUrl) + "/v1/ntfai/watch") }
    var renewEndpoint: URL? { URL(string: normalizeBaseUrl(appBaseUrl) + "/v1/ntfai/watch/renew") }

    /// Whether any credential is saved for a server: a user, or custom headers (an `Authorization`
    /// header among them). For ntfy.sh any spelling's credential counts, and so does a read that
    /// failed (`ntfySh` is true then: unknown is treated as present, review-130b #4).
    private func credentialServers(_ subscriptions: [Subscription]) -> (users: Set<String>, ntfySh: Bool) {
        let fetched = try? store.context.fetch(User.fetchRequest())
        let users = Set((fetched ?? []).compactMap { $0.baseUrl.map(normalizeBaseUrl) })
        var spellings = Set([NtfyShAddress.canonical])
        for subscription in subscriptions {
            if let baseUrl = subscription.baseUrl, NtfyShAddress.isNtfySh(baseUrl) { spellings.insert(normalizeBaseUrl(baseUrl)) }
        }
        let headers = spellings.contains {
            switch store.credentialStore.readHTTPHeaders(baseUrl: $0) {
            case .success(let headers): return !headers.isEmpty
            case .failure: return true
            }
        }
        return (users, fetched == nil || headers || users.contains(where: NtfyShAddress.isNtfySh))
    }

    /// The set the subscriptions call for, whatever the setting says.
    /// For display: the set, or empty when the subscriptions can't be read.
    func subscribedSet() -> BridgeWatchSet { readSubscribedSet() ?? .empty }

    /// Reads the subscription rows (replaceable in tests to simulate an unreadable store).
    var readSubscriptions: () -> [Subscription]?

    /// The set the subscriptions call for, or nil when they couldn't be read (review-130b E): an
    /// unreadable store is not an empty one, and must never replace the server's list.
    func readSubscribedSet() -> BridgeWatchSet? {
        var rows: [(baseUrl: String, topic: String, hasLogin: Bool)]?
        store.context.performAndWait {
            guard let subscriptions = readSubscriptions() else { return }
            let credentials = credentialServers(subscriptions)
            rows = subscriptions.compactMap {
                guard let baseUrl = $0.baseUrl, let topic = $0.topic else { return nil }
                let login = NtfyShAddress.isNtfySh(baseUrl) ? credentials.ntfySh
                    : credentials.users.contains(normalizeBaseUrl(baseUrl)) || !store.credentialStore.httpHeaders(baseUrl: baseUrl).isEmpty
                return (baseUrl, topic, login)
            }
        }
        guard let rows else { return nil }
        return BridgeWatchSet.compute(subscriptions: rows, access: access, now: now(), appBaseUrl: appBaseUrl)
    }

    // MARK: Anonymous access checks

    /// Cached answers per ntfy.sh topic name.
    var access: [String: NtfyShAccess] {
        defaults.data(forKey: Self.accessKey).flatMap { try? JSONDecoder().decode([String: NtfyShAccess].self, from: $0) } ?? [:]
    }

    private func saveAccess(_ update: [String: NtfyShAccess]) {
        guard !update.isEmpty else { return }
        lock.withLock {
            var merged = access
            // Newer evidence wins: an answer to a check that started before a refusal can't undo it.
            for (name, answer) in update { merged[name] = merged[name].map { $0.merged(with: answer) } ?? answer }
            // Forget names checked over a month ago (unsubscribed long since).
            merged = merged.filter { now().timeIntervalSince(max($0.value.checked, $0.value.failedAt ?? .distantPast)) < 30 * 24 * 60 * 60 }
            if let data = try? JSONEncoder().encode(merged) { defaults.set(data, forKey: Self.accessKey) }
        }
        BridgeStateSignal.announce()
    }

    /// The server can't read these names anonymously: forget any earlier 200, so they leave the
    /// next set and return only after a fresh anonymous 200.
    private func markRefused(_ names: [String]?) {
        guard let names, !names.isEmpty else { return }
        saveAccess(Dictionary(uniqueKeysWithValues: Set(names).map { ($0, NtfyShAccess(state: .refused, checked: now())) }))
    }

    var probeBlockedUntil: Date? {
        (defaults.object(forKey: Self.probeCooldownKey) as? Date).flatMap { $0 > now() ? $0 : nil }
    }

    /// `GET https://ntfy.sh/<topic>/auth` with no credentials: 200 when anyone may read it, which is
    /// exactly what the bridge can do. Sequential and capped; each answer is saved as it lands, and
    /// a 429 stops the round until ntfy.sh's Retry-After (at most a day) or an hour.
    private func probe(_ topics: [String], deadline: Date?, completion: @escaping () -> Void) {
        guard let session, !topics.isEmpty, probeBlockedUntil == nil else { completion(); return }
        var queue = Array(topics.prefix(Self.maxProbesPerSync))
        func next() {
            guard !queue.isEmpty else { completion(); return }
            let remaining = deadline.map { $0.timeIntervalSince(now()) } ?? .infinity
            guard remaining >= Self.minimumRequestTime else {
                Log.d(Self.tag, "Access checks: no time left in this wake; \(queue.count) wait for the next")
                completion(); return
            }
            let topic = queue.removeFirst()
            guard let url = URL(string: NtfyShAddress.canonical + "/" + topic + "/auth") else { next(); return }
            var request = URLRequest(url: url)
            request.timeoutInterval = min(15, remaining - 1)
            request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
            // The answer is as old as the request: a refusal reported while it ran is newer.
            let started = now()
            start(session.dataTask(with: request) { _, response, error in
                let http = response as? HTTPURLResponse
                let status = error == nil ? http?.statusCode : nil
                Log.d(Self.tag, "Access check: HTTP \(status.map(String.init) ?? "none")")
                if status == 429 {
                    let delay = PollTiming.retryDelay(http?.value(forHTTPHeaderField: "Retry-After"), now: self.now(), cap: 24 * 60 * 60)
                    self.defaults.set(self.now().addingTimeInterval(max(delay ?? Self.probeBackoff, 1)), forKey: Self.probeCooldownKey)
                    // Rate limited is a failed check: the name stays withheld until a fresh 200.
                    self.saveAccess([topic: NtfyShAccess(state: .unknown, checked: started)])
                    completion(); return
                }
                self.saveAccess([topic: NtfyShAccess(state: NtfyShAccess.classify(status: status), checked: started)])
                next()
            }, deadline: deadline)
        }
        next()
    }

    /// What should be registered now: empty when the setting is off.
    /// Empty only for the setting turned off or a successfully read empty set; nil when the
    /// subscriptions couldn't be read (then nothing is sent).
    func desiredSet() -> BridgeWatchSet? {
        isEnabled ? readSubscribedSet() : .empty
    }

    /// Register the current set if it changed, the server lost it, or the last success is over a
    /// day old. App process only.
    ///
    /// Cheap to call on every trigger: with nothing to do it is a fetch and a return. A failure
    /// leaves `acceptedSignature` alone and starts the shared backoff; there are no timers.
    /// - Parameters:
    ///   - userInitiated: the user's own action (the setting); skips the backoff, not a server Retry-After.
    ///   - deadline: in a background wake, no request starts that couldn't finish by then.
    func sync(reason: String, userInitiated: Bool = false, deadline: Date? = nil, completion: (() -> Void)? = nil) {
        guard !isExtension else {
            Log.d(Self.tag, "sync(\(reason)) ignored: only the app changes what is watched")
            completion?()
            return
        }
        processLock.lock()
        if inFlight {
            rerunRequested = true
            if let completion { pendingCompletions.append(completion) }
            if let deadline { pendingDeadline = min(pendingDeadline ?? deadline, deadline) }
            pendingUserInitiated = pendingUserInitiated || userInitiated
            processLock.unlock()
            Log.d(Self.tag, "sync(\(reason)) queued behind a registration in flight")
            return
        }
        inFlight = true
        processLock.unlock()

        let pending = isEnabled && session != nil ? (readSubscribedSet()?.needsProbe ?? []) : []
        if !pending.isEmpty {
            Log.d(Self.tag, "sync(\(reason)): checking up to \(min(pending.count, Self.maxProbesPerSync)) ntfy.sh topic(s) anonymously first")
            probe(pending, deadline: deadline) {
                self.register(reason: reason, userInitiated: userInitiated, deadline: deadline, completion: completion)
            }
            return
        }
        register(reason: reason, userInitiated: userInitiated, deadline: deadline, completion: completion)
    }

    private func register(reason: String, userInitiated: Bool, deadline: Date?, completion: (() -> Void)?) {
        guard let desired = desiredSet() else {
            Log.w(Self.tag, "sync(\(reason)): subscriptions couldn't be read; leaving the server's list as it is")
            finish(completion)
            return
        }
        let current = currentRecord
        if let skip = skipReason(desired: desired, record: current, userInitiated: userInitiated) {
            Log.d(Self.tag, "sync(\(reason)): \(skip)")
            finish(completion)
            return
        }
        let remaining = deadline.map { $0.timeIntervalSince(now()) } ?? .infinity
        guard remaining >= Self.minimumRequestTime else {
            Log.d(Self.tag, "sync(\(reason)): no time left in this wake")
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
        if remaining.isFinite { request.timeoutInterval = min(15, remaining - 0.5) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        guard let device = deviceId else {
            Log.w(Self.tag, "sync(\(reason)): shared state busy; not registering now")
            finish(completion)
            return
        }
        request.httpBody = Self.body(device: device, set: desired)

        guard let started = mutate({ next in
            next.revision = (next.revision ?? 0) + 1
            next.lastAttempt = now()
            next.sentTopics = desired.ntfyShTopics.count
            next.sentHashes = desired.hashes.count
            if !desired.isEmpty { next.mayHaveEntries = true }
        }) else {
            Log.w(Self.tag, "sync(\(reason)): couldn't record the attempt; not registering now")
            finish(completion)
            return
        }
        let revision = started.revision ?? 0
        Log.i(Self.tag, "sync(\(reason)): registering \(desired.ntfyShTopics.count) ntfy.sh topic(s), "
              + "\(desired.hashes.count) hash(es), \(desired.skipped) skipped")

        start(session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.handle(desired: desired, revision: revision, data: data, response: response as? HTTPURLResponse, error: error)
                self.finish(completion)
            }
        }, deadline: deadline)
    }

    /// Starts `task`; in a wake, cancels it at the deadline (a request timeout is an inactivity
    /// limit, not a wall-clock one).
    private func start(_ task: URLSessionDataTask, deadline: Date?) {
        task.resume()
        guard let deadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak task] in
            guard let task, task.state == .running else { return }
            Log.d(Self.tag, "Request cancelled at the wake's deadline")
            task.cancel()
        }
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

    private func skipReason(desired: BridgeWatchSet, record: BridgeRecord, userInitiated: Bool) -> String? {
        if let until = NtfyMeHostCooldown.blockedUntil(defaults, now: now(), userInitiated: userInitiated) {
            return "waiting until \(until) (server Retry-After or backoff)"
        }
        if desired.isEmpty {
            return record.mayHaveEntries ? nil : "nothing to register"
        }
        // Admission (42912) limits adding entries only: a list that adds nothing still goes out.
        if let until = record.admissionBlockedUntil, until > now(),
           !BridgeWatchSet.members(signature: desired.signature).isSubset(of: BridgeWatchSet.members(signature: record.acceptedSignature)) {
            return "waiting until \(until) for watch admission (42912)"
        }
        if record.repairRequested == true || record.renewMissed == true { return nil }
        if desired.signature == record.acceptedSignature, let success = record.lastSuccess,
           now().timeIntervalSince(success) < Self.refreshInterval, success <= now() {
            return "up to date"
        }
        return nil
    }

    private func handle(desired: BridgeWatchSet, revision: Int, data: Data?, response: HTTPURLResponse?, error: Error?) {
        let status = error == nil ? response?.statusCode : nil
        struct Reply: Decodable { let watching: Int?; let expires: Double?; let unwatchable: [String]?; let error: String?; let code: Int? }
        let reply = data.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }
        let retryAfter = response?.value(forHTTPHeaderField: "Retry-After")
        // 42912 is about this network's share of watch entries, not the request budget: it pauses
        // adding entries only, not every request to the server (review-130b #9).
        let admission = status == 429 && reply?.code == 42912
        if !admission {
            NtfyMeHostCooldown.note(status: status, retryAfter: retryAfter, defaults: defaults, lock: lock, now: now())
        }
        var obsolete = false
        mutate { next in
            guard (next.revision ?? 0) == revision else { obsolete = true; return }
            next.lastHTTPStatus = response?.statusCode
            guard let status else {
                next.lastOutcome = .network
                Log.w(Self.tag, "Registration failed: \(error?.localizedDescription ?? "no response"); backing off")
                return
            }
            switch status {
            case 200:
                next.unwatchable = reply?.unwatchable
                next.lastOutcome = .ok
                next.lastSuccess = now()
                next.acceptedSignature = desired.signature
                next.mayHaveEntries = !desired.isEmpty
                next.watching = reply?.watching
                next.expires = reply?.expires.map { Date(timeIntervalSince1970: $0) }
                next.repairRequested = nil
                next.renewMissed = nil
                next.admissionBlockedUntil = nil
                Log.i(Self.tag, "Registration accepted: watching \(reply?.watching.map(String.init) ?? "?")")
            case 429 where admission:
                next.lastOutcome = .admissionLimited
                let delay = PollTiming.retryDelay(retryAfter, now: now(), cap: NtfyMeHostCooldown.maxRetryAfter) ?? Self.probeBackoff
                next.admissionBlockedUntil = now().addingTimeInterval(max(delay, 1))
                Log.w(Self.tag, "Watch admission limit reached (42912); not adding entries until \(next.admissionBlockedUntil!)")
            case 429:
                next.lastOutcome = .rateLimited
                Log.w(Self.tag, "Registration rate limited; waiting for the server's Retry-After")
            case 503:
                // The server also answers 503 when it is off or can't save; only its own words mean full.
                next.lastOutcome = reply?.error?.lowercased().contains("full") == true ? .full : .unavailable
                Log.w(Self.tag, "Bridge unavailable (503); backing off")
            case 400..<500:
                next.lastOutcome = .rejected
                let detail = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(300) ?? ""
                Log.e(Self.tag, "Registration rejected (HTTP \(status)): \(detail)")
            default:
                next.lastOutcome = .serverError
                Log.w(Self.tag, "Registration failed (HTTP \(status)); backing off")
            }
        }
        if obsolete { Log.d(Self.tag, "Dropped the reply to an older registration"); return }
        if status == 200 { markRefused(reply?.unwatchable) }
    }

    private func finish(_ completion: (() -> Void)?) {
        processLock.lock()
        inFlight = false
        let rerun = rerunRequested
        rerunRequested = false
        let queued = pendingCompletions
        pendingCompletions = []
        let deadline = pendingDeadline
        pendingDeadline = nil
        let userInitiated = pendingUserInitiated
        pendingUserInitiated = false
        processLock.unlock()
        completion?()
        if rerun {
            sync(reason: "queued while a registration was in flight", userInitiated: userInitiated, deadline: deadline) { queued.forEach { $0() } }
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
            + (record.repairRequested == true ? ", repair pending" : "")
    }

    // MARK: Per-topic truth (topic details, Notification status)

    enum TopicState: Equatable {
        /// On the app's own server: pushed directly, the bridge isn't involved.
        case direct
        /// Accepted by the server, bound for push here, and nothing says the bridge is down.
        case watched
        case held(TopicHold)
    }

    enum TopicHold: Equatable {
        case needsLogin, refused, checkingAccess, invalidName, overCap
        /// The setting is off (and the server confirmed the removal).
        case bridgeOff
        /// The setting is off and the server may still hold this device's list: removal is pending.
        case removalPending
        /// The last registration failed and the server doesn't hold this topic.
        case bridgeUnavailable
        /// Requested, not yet accepted by the server.
        case registering
        /// The server says it doesn't know this device; the next app trigger sends the list again.
        case notRegistered
        /// The server's last status said it isn't watching ntfy.sh: reconnecting or waiting on ntfy.sh's request budget
        /// (its status API reports one `connected` flag, so the two read the same).
        case upstreamPending
        /// The server watches it, but this device hasn't confirmed the push binding yet.
        case pushNotReady
        /// Self-hosted: strong evidence that no wake-up is forwarded; `address` is the one used in the app.
        case notSetUp(address: String)
        /// Self-hosted: recent messages arrived without a confirmed forward, but the evidence is weak.
        case noForwardingConfirmed(address: String)

        /// True of every topic on the server, so the status screen says it once instead of per topic.
        var isServerWide: Bool {
            switch self {
            case .bridgeOff, .removalPending, .bridgeUnavailable, .notRegistered, .upstreamPending: return true
            default: return false
            }
        }

        /// A self-hosted diagnosis the user can retest with the next message.
        var offersCheckAgain: Bool {
            switch self {
            case .notSetUp, .noForwardingConfirmed: return true
            default: return false
            }
        }

        /// Not a fault: the state is on its way to `.watched`.
        var isPending: Bool { self == .checkingAccess || self == .registering || self == .pushNotReady }
    }

    /// Why a subscription does or doesn't get instant banners through the bridge.
    /// - Parameter fcmBound: the row's push binding is confirmed (nil when unknown).
    func topicState(baseUrl: String, topic: String, set: BridgeWatchSet? = nil,
                    wakes: SelfHostedWakeCheck? = .shared, fcmBound: Bool? = nil) -> TopicState {
        if normalizeBaseUrl(baseUrl) == normalizeBaseUrl(appBaseUrl) {
            // Pushed directly, which needs the push binding like a bridged topic (review-130b #7).
            return fcmBound == false ? .held(.pushNotReady) : .direct
        }
        let ntfySh = NtfyShAddress.isNtfySh(baseUrl)
        if !ntfySh, URL(string: normalizeBaseUrl(baseUrl))?.host?.lowercased() == "ntfy.sh" { return .held(.invalidName) }
        let record = currentRecord
        guard isEnabled else { return .held(record.mayHaveEntries ? .removalPending : .bridgeOff) }
        let set = set ?? subscribedSet()
        if let hold = set.hold(baseUrl: baseUrl, topic: topic) {
            switch hold {
            case .needsLogin: return .held(.needsLogin)
            case .refused: return .held(.refused)
            case .checkingAccess: return .held(.checkingAccess)
            case .invalidName: return .held(.invalidName)
            case .overCap: return .held(.overCap)
            }
        }
        // A name the server reported refused is held by the access answers above until a newer
        // anonymous 200 (review-130b #4); the record's copy of the list may be older than that.
        if record.repairRequested == true { return .held(.notRegistered) }
        // The server forgets a list at its expiry unless renewed (review-130b #7).
        if let expires = record.expires, expires <= now() { return .held(.notRegistered) }
        let hash = topicHash(baseUrl: baseUrl, topic: topic)
        let member = ntfySh ? "t:" + topic : "h:" + hash
        // Without its push binding no wake reaches this row, whatever the bridge accepts.
        if fcmBound == false { return .held(.pushNotReady) }
        guard BridgeWatchSet.members(signature: record.acceptedSignature).contains(member) else {
            if let outcome = record.lastOutcome, outcome != .ok { return .held(.bridgeUnavailable) }
            return .held(.registering)
        }
        if record.statusConnected == false { return .held(.upstreamPending) }
        if !ntfySh, let wakes {
            switch wakes.diagnosis(hash: hash) {
            case .notSetUp?: return .held(.notSetUp(address: normalizeBaseUrl(baseUrl)))
            case .unconfirmed?: return .held(.noForwardingConfirmed(address: normalizeBaseUrl(baseUrl)))
            case nil: break
            }
        }
        return .watched
    }

    /// The server accepted `hash` in its last successful reply and still knows this device: only
    /// then can a relay check say anything about the topic's server.
    func isAdmitted(hash: String) -> Bool {
        let record = currentRecord
        // The accepted set stands until the next 200 replaces it, so a later failed POST (adding
        // another topic) doesn't un-admit this one.
        return isEnabled && record.repairRequested != true
            && BridgeWatchSet.members(signature: record.acceptedSignature).contains("h:" + hash)
    }

    /// Strong evidence for counting a missed forward on `hash`: admitted, and a status read taken
    /// within about ten minutes of the miss, for the registration revision in force now, said the
    /// bridge's ntfy.sh connection was up (review-130b #8). Otherwise the miss is weak.
    func forwardingEvidence(hash: String) -> Bool {
        let record = currentRecord
        guard isAdmitted(hash: hash), record.statusConnected == true, let at = record.statusAt,
              abs(now().timeIntervalSince(at)) <= Self.connectedEvidenceAge,
              record.statusRevision != nil, record.statusRevision == record.revision else { return false }
        return true
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
        var rows: [(baseUrl: String, topic: String, bound: Bool)] = []
        store.context.performAndWait {
            rows = (store.getSubscriptions() ?? []).compactMap {
                guard let baseUrl = $0.baseUrl, let topic = $0.topic else { return nil }
                return (baseUrl, topic, $0.fcmSubscribed)
            }
        }
        let set = subscribedSet()
        var groups: [String: Report.Group] = [:]
        for row in rows {
            let state = topicState(baseUrl: row.baseUrl, topic: row.topic, set: set, wakes: wakes, fcmBound: row.bound)
            if state == .direct { continue }
            let server = NtfyShAddress.canonicalize(row.baseUrl) ?? normalizeBaseUrl(row.baseUrl)
            var group = groups[server] ?? Report.Group(server: server, watching: 0, held: [])
            switch state {
            case .watched: group.watching += 1
            case .held(let hold): group.held.append(Report.Held(topic: row.topic, hold: hold))
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
        return isEnabled && record.lastOutcome == .ok && record.acceptedSignature != nil && record.repairRequested != true
    }

    // MARK: Renewal from the extension

    /// True when a bridged wake-up should also renew this device's registration: the server holds
    /// entries for it, the last success or renewal is over a week old (the server forgets a device
    /// after 30 days), the last renewal attempt wasn't within the hour, and the server isn't asking
    /// for a pause. A user who lives on banners and never opens the app stays registered.
    func extensionShouldRenew(_ record: BridgeRecord) -> Bool {
        guard isEnabled, record.mayHaveEntries, record.acceptedSignature != nil,
              record.repairRequested != true else { return false }
        if let attempt = record.lastRenewAttempt, attempt <= now() {
            // A renewal that answered a plain 404 (no renewal route) is retried about once a day.
            let interval = record.renewMissed == true ? Self.renewMissedRetryInterval : Self.extensionRetryInterval
            if now().timeIntervalSince(attempt) < interval { return false }
        }
        guard NtfyMeHostCooldown.blockedUntil(defaults, now: now()) == nil else { return false }
        let newest = [record.lastSuccess, record.lastRenew].compactMap { $0 }.max()
        guard let newest else { return false }
        return now().timeIntervalSince(newest) >= Self.extensionRefreshAge
    }

    /// A renewal claimed by this process: which install and which record revision it renews.
    struct RenewClaim: Equatable {
        let device: String
        let revision: Int
    }

    /// Claim a renewal atomically (two extension processes can't both renew), reading the install
    /// ID and the record revision inside the same lock.
    func claimRenewal() -> RenewClaim? {
        lock.withLock { () -> RenewClaim? in
            guard let device = existingDeviceId else { return nil }
            var claim: RenewClaim?
            mutate { next in
                guard extensionShouldRenew(next) else { return }
                next.lastRenewAttempt = now()
                claim = RenewClaim(device: device, revision: next.revision ?? 0)
            }
            return claim
        } ?? nil
    }

    /// Apply a renewal's answer only to the registration it renewed: a 200 or 404 that lands after
    /// the app registered again (a new revision) or after the install ID changed is dropped.
    @discardableResult
    func applyRenewal(_ claim: RenewClaim, _ change: (inout BridgeRecord) -> Void) -> Bool {
        lock.withLock { () -> Bool in
            guard existingDeviceId == claim.device else { return false }
            var applied = false
            mutate { next in
                guard (next.revision ?? 0) == claim.revision else { return }
                change(&next)
                applied = true
            }
            return applied
        } ?? false
    }

    /// Called by the extension for a wake-up on a non-hosted topic. Never waited on, and never
    /// sends a watch list: `POST /v1/ntfai/watch/renew {"device"}` only extends an existing
    /// registration (S8, CONTRACT.md). A 404 with code 40400 means the server has no watch for this
    /// device: the app re-sends its list at its next trigger. Any other 404 (a server without the
    /// route) also makes the app resend, without showing a fault, and renewal is tried again about
    /// once a day. 200 inside the server's hourly interval returns the current expiry; 429 and 503
    /// feed the shared cooldown; anything else changes nothing. An answer for a registration the
    /// app has since replaced is dropped (`applyRenewal`).
    func renewFromExtensionIfStale(completion: (() -> Void)? = nil) {
        guard let session, let url = renewEndpoint, let claim = claimRenewal() else { completion?(); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONEncoder().encode(["device": claim.device])
        Log.i(Self.tag, "Renewing this device's registration")
        session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            let status = error == nil ? http?.statusCode : nil
            NtfyMeHostCooldown.note(status: status, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                    defaults: self.defaults, lock: self.lock, now: self.now())
            struct Reply: Decodable { let expires: Double }
            struct Failure: Decodable { let code: Int? }
            var applied = true
            switch status {
            case 200?:
                if let reply = data.flatMap({ try? JSONDecoder().decode(Reply.self, from: $0) }) {
                    applied = self.applyRenewal(claim) {
                        $0.lastRenew = self.now(); $0.expires = Date(timeIntervalSince1970: reply.expires); $0.renewMissed = nil
                    }
                }
            case 404? where data.flatMap({ try? JSONDecoder().decode(Failure.self, from: $0) })?.code == 40400:
                // S8's own answer: the server has no watch for this device. The app sends its list
                // at its next trigger; until then its topics say so.
                applied = self.applyRenewal(claim) { $0.repairRequested = true }
            case 404?:
                // Any other 404 (a server without renewal): not a fault, but resend to be safe.
                applied = self.applyRenewal(claim) { $0.renewMissed = true }
            default:
                break
            }
            Log.d(Self.tag, "Renewal: HTTP \(status.map(String.init) ?? "none")" + (applied ? "" : ", dropped (registration changed meanwhile)"))
            completion?()
        }.resume()
    }

    // MARK: Status

    enum Status: Equatable {
        case connected(watching: Int)
        /// The server isn't covering every entry yet: reconnecting, or waiting for ntfy.sh's budget.
        case notConnected(watching: Int)
        case unknownDevice
        case unavailable
        /// Not asked: the server asked for a pause until then. The screen asks again after it.
        case waiting(until: Date)
    }

    /// Orders status reads in this process: only the newest one's answer is recorded or shown.
    private var statusGeneration = 0

    /// `GET /v1/ntfai/watch?device=` for Notification status. Only asked when that screen opens or
    /// the user asks to check again. A 404 means the server lost this device: the app sends its
    /// list again. Reads are numbered (review-130b #7): an answer overtaken by a newer read is
    /// dropped, state and screen alike, and one that crossed a newer registration is read again.
    func fetchStatus(completion: @escaping (Status) -> Void) {
        fetchStatus(retryOnNewRegistration: true, completion: completion)
    }

    private func fetchStatus(retryOnNewRegistration: Bool, completion: @escaping (Status) -> Void) {
        guard let session, let endpoint, let device = existingDeviceId,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            completion(existingDeviceId == nil && session != nil ? .unknownDevice : .unavailable)
            return
        }
        components.queryItems = [URLQueryItem(name: "device", value: device)]
        guard let url = components.url else { completion(.unavailable); return }
        // The status read shares the server's cooldown with every other request to it (review-130 #9).
        if let until = NtfyMeHostCooldown.blockedUntil(defaults, now: now()) { completion(.waiting(until: until)); return }
        processLock.lock()
        statusGeneration += 1
        let generation = statusGeneration
        processLock.unlock()
        let revision = currentRecord.revision ?? 0
        var request = URLRequest(url: url)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            struct Reply: Decodable { let watching: Int; let connected: Bool; let unwatchable: [String]? }
            let http = response as? HTTPURLResponse
            let code = error == nil ? http?.statusCode : nil
            if code == 429 || (code ?? 500) >= 500 {
                NtfyMeHostCooldown.note(status: code, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                        defaults: self.defaults, lock: self.lock, now: self.now())
            }
            self.processLock.lock()
            let newest = generation == self.statusGeneration
            self.processLock.unlock()
            guard newest else {
                Log.d(Self.tag, "Status: dropped an answer overtaken by a newer read")
                return
            }
            var status = Status.unavailable
            var repair = false
            var refused: [String]?
            var crossed = false
            self.mutate { next in
                guard (next.revision ?? 0) == revision else { crossed = true; return }
                if code == 404 {
                    status = .unknownDevice
                    if next.mayHaveEntries || next.acceptedSignature != nil { next.repairRequested = true; repair = true }
                } else if code == 200, let data, let reply = try? JSONDecoder().decode(Reply.self, from: data) {
                    status = reply.connected ? .connected(watching: reply.watching) : .notConnected(watching: reply.watching)
                    next.unwatchable = reply.unwatchable
                    next.statusConnected = reply.connected
                    next.statusAt = self.now()
                    next.statusRevision = revision
                    refused = reply.unwatchable
                }
            }
            if crossed {
                // A registration started meanwhile: this answer describes the list it replaced.
                Log.d(Self.tag, "Status: answer crossed a newer registration" + (retryOnNewRegistration ? "; reading again" : ""))
                DispatchQueue.main.async {
                    if retryOnNewRegistration { self.fetchStatus(retryOnNewRegistration: false, completion: completion) }
                    else { completion(.unavailable) }
                }
                return
            }
            self.markRefused(refused)
            Log.d(Self.tag, "Status: \(status) (HTTP \(code.map(String.init) ?? "none"))")
            DispatchQueue.main.async {
                completion(status)
                if repair { self.sync(reason: "server doesn't know this device") }
            }
        }.resume()
    }
}

/// Every user-facing sentence about the bridge, so Settings, Notification status and the tests
/// read the same text.
enum NtfyShBridgeCopy {
    static var serverName: String { normalizeBaseUrl(Config.appBaseUrl).replacingOccurrences(of: "https://", with: "") }

    static var settingTitle: String { String(localized: "Instant banners for ntfy.sh and other servers") }

    /// What goes where (review-130 #12): ntfy-me.com gets the installation ID, ntfy.sh names and
    /// other servers' hashes, plus hash-only forwarding checks; ntfy.sh gets the anonymous access check.
    static var settingFooter: String {
        String(localized: "On, NTF-AI sends \(serverName) an installation ID made only for this, the names of your ntfy.sh topics, and a hash of each topic address on your other servers. \(serverName) watches those topics on ntfy.sh and wakes this device when a message arrives; it sees messages in passing and keeps no message text. If you saved credentials for ntfy.sh, or NTF-AI can't tell whether you did, it first checks each ntfy.sh topic with ntfy.sh without sending them and sends only topics anyone can read. It checks again when NTF-AI next runs, about once a day: a topic made private is dropped then, and one it can't check is held back. For your other servers, NTF-AI may ask \(serverName) whether a wake-up for a topic's hash went through. Off, ntfy.sh topics and servers whose upstream is ntfy.sh show new messages only when you open the app or refresh.")
    }

    /// Notification status, under the bridge rows, shown only with topics using the bridge (review-130b #10).
    static var renewalNote: String {
        String(localized: "For these topics, opening the app lets it set up or repair banners. NTF-AI also keeps this device's list current in the background when the system allows it, which isn't guaranteed.")
    }

    static var instantBanners: String { String(localized: "Instant banners") }
    static func watching(_ count: Int) -> String { String(localized: "Watching \(count)") }

    /// A self-hosted server can wake this device without the bridge when its upstream is ntfy-me.com.
    static var directUpstreamNote: String {
        String(localized: "A server whose upstream is \(serverName) can still wake this device directly, if that server is set up for it and push works on this device.")
    }

    /// Why one topic gets no instant banners, in the words the user sees on the topic and in
    /// Notification status. `selfHosted` adds that a server using ntfy-me.com directly is unaffected.
    static func reason(_ hold: NtfyShBridge.TopicHold, selfHosted: Bool = false) -> String {
        let text: String
        switch hold {
        case .needsLogin:
            text = String(localized: "This topic on ntfy.sh can't be read without a login, so it gets no instant banners. With your login saved, its messages show when you open the app or refresh.")
        case .checkingAccess:
            text = String(localized: "Checking whether this topic is public on ntfy.sh. NTF-AI checks when it next runs, about once a day. Until then, new messages show when you open the app.")
        case .refused:
            text = String(localized: "ntfy.sh didn't let NTF-AI check this topic, so it gets no instant banners for now. NTF-AI checks again when it next runs, about once a day. Until then, new messages show when you open the app.")
        case .invalidName:
            text = String(localized: "This address or topic name can't be watched on ntfy.sh, so new messages show when you open the app.")
        case .overCap:
            text = String(localized: "Over the limit of 100 topics per list, so new messages show when you open the app.")
        case .bridgeOff:
            text = String(localized: "Instant banners through ntfy.sh are off in Settings. Messages that would come through ntfy.sh show when you open the app.")
        case .removalPending:
            text = String(localized: "Removing this device's topics from \(serverName). NTF-AI tries again the next time it runs.")
        case .bridgeUnavailable:
            text = String(localized: "\(serverName) couldn't take this device's list. NTF-AI tries again the next time it runs. Until then, messages that would come through ntfy.sh show when you open the app.")
        case .registering:
            text = String(localized: "Being added to what \(serverName) watches. Once it accepts the list, a message to this topic can wake this device.")
        case .notRegistered:
            text = String(localized: "\(serverName) no longer has this device's list. NTF-AI sends it again the next time it runs; if banners don't return, open NTF-AI.")
        case .upstreamPending:
            text = String(localized: "\(serverName) isn't watching ntfy.sh for this device right now. It may be reconnecting, or waiting until ntfy.sh accepts more requests. Until then, new messages show when you open the app.")
        case .pushNotReady:
            text = String(localized: "This device hasn't finished push setup for this topic yet. Until then, new messages show when you open the app.")
        case .notSetUp(let address):
            text = String(localized: "No wake-up arrived for recent messages, so this server isn't set up for instant banners. Ask its admin to set upstream-base-url to https://ntfy.sh and base-url to exactly \(address), the address this app uses. Until then, new messages show when you open the app.")
        case .noForwardingConfirmed(let address):
            text = String(localized: "No recent forwarding confirmed for this server. If banners don't come, its upstream-base-url may not be https://ntfy.sh, or its base-url may not be exactly \(address). Check again to test with the next message.")
        }
        guard selfHosted, hold == .bridgeOff || hold == .bridgeUnavailable || hold == .removalPending else { return text }
        return text + " " + directUpstreamNote
    }

    static var checkAgain: String { String(localized: "Check again") }
    static var checkArmed: String { String(localized: "NTF-AI checks the next message from this server that arrives within a day.") }

    static var on: String { String(localized: "On") }
    static var off: String { String(localized: "Off") }
    static var pending: String { String(localized: "Pending") }
    static var lastRegistration: String { String(localized: "Last registration") }
    static var never: String { String(localized: "Never") }
    static var connection: String { String(localized: "Bridge connection") }
    static var checking: String { String(localized: "Checking…") }
    static func showMore(_ count: Int) -> String { String(localized: "Show \(count) more") }

    static func outcome(_ outcome: BridgeRecord.Outcome) -> String {
        switch outcome {
        case .ok: return String(localized: "Accepted")
        case .rejected: return String(localized: "Rejected by the server")
        case .rateLimited: return String(localized: "Rate limited, will retry")
        case .full: return String(localized: "Bridge full, will retry")
        case .unavailable: return String(localized: "Unavailable, will retry")
        case .serverError: return String(localized: "Server error, will retry")
        case .network: return String(localized: "No connection, will retry")
        case .admissionLimited: return String(localized: "Watch limit reached, will retry")
        }
    }

    static func status(_ status: NtfyShBridge.Status) -> String {
        switch status {
        case .connected: return String(localized: "Connected")
        case .notConnected: return String(localized: "Not watching ntfy.sh right now")
        case .unknownDevice: return String(localized: "Not registered yet")
        case .unavailable: return String(localized: "Couldn't check")
        case .waiting: return String(localized: "Will check again shortly")
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
