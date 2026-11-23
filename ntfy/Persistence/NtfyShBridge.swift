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
    ///
    /// Privacy evidence that may be missing makes a name wait for a fresh 200 (review-130c C1,
    /// review-130d D1): a recheck marked as started (`rechecking`) and not answered yet keeps a
    /// credentialed name's earlier 200 from being reused, and a status read or registration whose
    /// refusals may not have been saved does the same for every name it could report on, with a
    /// login or without: `barriers[name]` is the start of the latest such request for that name,
    /// and `barrier` the latest one whose names aren't known (it covers every name).
    static func compute(subscriptions: [(baseUrl: String, topic: String, hasLogin: Bool)],
                        access: [String: NtfyShAccess] = [:], barrier: Date? = nil, barriers: [String: Date] = [:],
                        now: Date = Date(), appBaseUrl: String = Config.appBaseUrl) -> BridgeWatchSet {
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
                // A refusal for this name may have been lost: only a public answer newer than that counts.
                let floor = [barrier, barriers[topic]].compactMap { $0 }.max()
                let unconfirmed = floor.map { floor in answer.map { $0.state == .unknown || $0.checked < floor } ?? true } ?? false
                switch answer?.state {
                case .open? where age >= 0 && age < NtfyShAccess.sendableOpenAge:
                    if !hasLogin, unconfirmed {
                        if mayCheck { probe.insert(topic) }
                        held.append(Entry(baseUrl: baseUrl, topic: topic, hold: .checkingAccess)); continue
                    }
                    if hasLogin, let answer {
                        let due = age >= NtfyShAccess.recheckOpenAge
                        let barred = answer.rechecking.map { $0 > answer.checked } == true || unconfirmed
                        if due || barred, mayCheck { probe.insert(topic) }
                        // A recheck is running or failed, or a refusal may have been lost: withheld until a fresh 200.
                        let failed = answer.failedAt.map { $0 >= answer.checked } == true
                        if barred || (due && failed) {
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
                    if hasLogin || unconfirmed {
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
                              hashes: Array(sortedHashes.prefix(maxEntries)), held: held,
                              // Oldest evidence first, so a capped round reaches every name in turn.
                              needsProbe: probe.sorted { (access[$0]?.evidenceAt ?? .distantPast, $0) < (access[$1]?.evidenceAt ?? .distantPast, $1) })
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
/// (a failed check never replaces it), `failedAt` the newest failed check, kept apart from it, and
/// `rechecking` when the newest recheck started. Every time is a request's start, so evidence
/// is ordered by when it was asked for, not when it was handled (review-130c C1).
struct NtfyShAccess: Codable, Equatable {
    /// `refused`: the bridge reported ntfy.sh refused the name, cause not given (from 1.30).
    enum State: String, Codable { case open, protected, invalid, refused, unknown }
    var state: State
    /// When the evidence was taken: the start of the check or of the request that reported a refusal.
    var checked: Date
    var failedAt: Date?
    /// Set durably before an anonymous recheck starts; until a definitive answer at least as new
    /// lands, an earlier 200 can't be reused, even after the process is killed.
    var rechecking: Date?

    init(state: State, checked: Date, failedAt: Date? = nil, rechecking: Date? = nil) {
        self.state = state
        self.checked = checked
        self.failedAt = failedAt
        self.rechecking = rechecking
    }

    /// The newest time anything was learned about the name.
    var evidenceAt: Date { max(checked, failedAt ?? .distantPast) }

    /// Merge evidence in any order and get the same result: the newest definitive answer (by
    /// request start; on a tie the more cautious one), the newest failure and the newest recheck
    /// mark, each kept on its own.
    func merged(with update: NtfyShAccess) -> NtfyShAccess {
        let failures = [failedAt, state == .unknown ? checked : nil,
                        update.failedAt, update.state == .unknown ? update.checked : nil].compactMap { $0 }
        let answers = [self, update].filter { $0.state != .unknown }
        let newest = answers.max { a, b in
            a.checked != b.checked ? a.checked < b.checked : (a.state == .open && b.state != .open)
        }
        var next: NtfyShAccess
        if let newest {
            next = NtfyShAccess(state: newest.state, checked: newest.checked, failedAt: failures.max())
        } else {
            next = NtfyShAccess(state: .unknown, checked: failures.max() ?? max(checked, update.checked))
        }
        next.rechecking = [rechecking, update.rechecking].compactMap { $0 }.max()
        return next
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

/// Everything the app knows about which ntfy.sh names may be sent, in one app-group file under the
/// bridge lock (review-130c C1): the answers, the requests whose refusals aren't saved yet, and
/// ntfy.sh's pause on anonymous checks. Read from disk on every decision, never from a cache.
struct NtfyShAccessLedger: Codable, Equatable {
    var answers: [String: NtfyShAccess] = [:]
    /// Status reads and registrations sent and not yet handled, by id: their start. A refusal one
    /// of them reports may be lost with the process, so it is a barrier for its names (`compute`).
    var pending: [String: Date]?
    /// The raw ntfy.sh names each pending request can report on (from fix round 4, review-130d
    /// D1). A pending request without an entry here (written by an earlier build) covers every name.
    var pendingNames: [String: [String]]?
    /// ntfy.sh asked for a pause on anonymous checks (429) until then.
    var probeNotBefore: Date?

    /// The barriers for a process: requests this process sent are covered by its own memory
    /// (`unsavedAccess`) until it saves their refusals, so only another run's count: one that may
    /// have died before saving what it learned. Per name, the latest such request's start (any
    /// unresolved request newer than a 200 may have overturned it, review-130d D1); `all` for
    /// requests whose names aren't recorded.
    func barriers(excludingRun run: String) -> (all: Date?, names: [String: Date]) {
        var all: Date?
        var names: [String: Date] = [:]
        for (id, started) in pending ?? [:] where !id.hasPrefix(run + "/") {
            guard let covered = pendingNames?[id] else { all = max(all ?? started, started); continue }
            for name in covered { names[name] = max(names[name] ?? started, started) }
        }
        return (all, names)
    }

    /// Removes a request from the barrier list.
    mutating func resolve(_ id: String) {
        pending?[id] = nil
        pendingNames?[id] = nil
    }

    static let fileName = "ntfai-bridge-access.json"
    /// A pending entry this old is from a process that died long ago; its 200s were rechecked since.
    static let pendingLifetime: TimeInterval = 7 * 24 * 60 * 60
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
    /// The installation ID and the setting as the app last committed them (review-130c C3): the
    /// extension renews only for these, so a stale read of the shared defaults can't extend a
    /// watch the user turned off.
    var device: String?
    var optedOut: Bool?
    /// The revision of a registration sent and not yet answered. Renewal waits while one is
    /// unresolved, so it can't renew, or report missing, a list that is being replaced (C3).
    var attempting: Int?
    /// The revision the server last accepted (changes on every accepted registration).
    var acceptedRevision: Int?
    /// When each accepted hash ("h:<hash>") entered the accepted set: the start of its watch, which
    /// the self-hosted evidence is keyed by (review-130d D6). Kept across replacements that keep it.
    var watchStarts: [String: Date]?
    /// Members ("t:<name>", "h:<hash>") a registration sent and not acknowledged may have installed
    /// beyond the accepted set (review-130d D2): its 200 can be lost after the server applied it.
    /// Added before each POST, cleared by the next acknowledged one.
    var unconfirmed: [String]?
    /// Bumped, with the record, each time the setting is committed (the Settings toggle, or an
    /// opt-out found by a sync). A sync that read the setting under an older value sends no list
    /// and starts no further check (review-130e E4); the sync the change queued sends the new one.
    var enablement: Int?

    /// Everything the server may hold for this device: the accepted set and what any
    /// unacknowledged registration may have added.
    var mayHold: Set<String> {
        BridgeWatchSet.members(signature: acceptedSignature).union(unconfirmed ?? [])
    }

    /// Names and hashes the server may still hold that the current set no longer asks for
    /// (review-130c C2, review-130d D2): "t:<name>" and "h:<hash>". Everything, when the setting is off.
    func pendingRemovals(desired: BridgeWatchSet?) -> Set<String> {
        guard optedOut != true, let desired else { return optedOut == true ? mayHold : [] }
        return mayHold.subtracting(BridgeWatchSet.members(signature: desired.signature))
    }
}

/// One cooldown for every automatic request to the app's server (watch, renewal, status, relay
/// checks), shared by the app and the extension in its own app-group file under the bridge lock.
/// The server's Retry-After and the client's own backoff are separate deadlines (review-130c C10):
/// a user's action may skip only the client's, each keeps the strongest deadline of its kind, and a
/// later failure can never weaken a pause the server asked for.
struct NtfyMeHostCooldown: Codable, Equatable {
    /// From a Retry-After: every request waits, even a user's own.
    var serverNotBefore: Date?
    /// The client's exponential backoff after failures without one.
    var clientNotBefore: Date?
    var failures = 0

    static let fileName = "ntfai-host-cooldown.json"
    static let backoffBase: TimeInterval = 30
    static let backoffCap: TimeInterval = 60 * 60
    /// A Retry-After past this is treated as this (a registration expires after 30 days anyway).
    static let maxRetryAfter: TimeInterval = 31 * 24 * 60 * 60

    /// Next to the lock it is written under, so tests with their own lock get their own file.
    static func file(_ lock: SharedFileLock) -> SharedStateFile<NtfyMeHostCooldown> {
        SharedStateFile(url: URL(fileURLWithPath: lock.path + ".cooldown.json"), lock: lock)
    }

    /// Pauses this process noted but couldn't save (lock busy), honoured until a save lands. Each
    /// has a generation, so a save clears only the value it wrote, never a newer one noted while
    /// it was writing (review-130d D9).
    private static let unsavedLock = NSLock()
    private static var unsaved: [String: (value: NtfyMeHostCooldown, generation: Int)] = [:]
    private static var generations = 0
    /// When this process first found the file unreadable (corrupt, or protected before first unlock).
    private static var unreadableSince: [String: Date] = [:]
    /// An unreadable file may have held a pause: every request waits this long after this process
    /// first finds it so (review-130d D9). The next answer from the server rewrites the file.
    static let unreadablePause: TimeInterval = 60
    /// Test hook: runs after a save lands, before the unsaved value is cleared.
    static var afterSaveForTesting: (() -> Void)?

    static func read(_ lock: SharedFileLock, now: Date = Date()) -> NtfyMeHostCooldown {
        let loaded = file(lock).load()
        unsavedLock.lock(); defer { unsavedLock.unlock() }
        var stored: NtfyMeHostCooldown
        switch loaded {
        case .value(let value): stored = value; unreadableSince[lock.path] = nil
        case .missing: stored = NtfyMeHostCooldown(); unreadableSince[lock.path] = nil
        case .unreadable:
            // Not an empty record: a short pause the server may have asked for, then requests resume.
            let since = unreadableSince[lock.path] ?? now
            unreadableSince[lock.path] = since
            stored = NtfyMeHostCooldown(serverNotBefore: since.addingTimeInterval(unreadablePause))
        }
        guard let pending = unsaved[lock.path] else { return stored }
        return stored.strongest(with: pending.value)
    }

    /// The later deadline of each kind.
    func strongest(with other: NtfyMeHostCooldown) -> NtfyMeHostCooldown {
        let later = { (a: Date?, b: Date?) in [a, b].compactMap { $0 }.max() }
        return NtfyMeHostCooldown(serverNotBefore: later(serverNotBefore, other.serverNotBefore),
                                  clientNotBefore: later(clientNotBefore, other.clientNotBefore),
                                  failures: max(failures, other.failures))
    }

    /// When the next request may start (the later active deadline), or nil if it may start now.
    func notBefore(now: Date, userInitiated: Bool = false) -> Date? {
        let server = serverNotBefore.flatMap { $0 > now ? $0 : nil }
        let client = userInitiated ? nil : clientNotBefore.flatMap { $0 > now ? $0 : nil }
        return [server, client].compactMap { $0 }.max()
    }

    /// When automatic requests may run again, or nil if they may run now. Asked before every
    /// request, so a pause this process couldn't save is written now, for the other process too
    /// (review-130d D9).
    static func blockedUntil(_ lock: SharedFileLock, now: Date, userInitiated: Bool = false) -> Date? {
        unsavedLock.lock(); let unsavedHere = unsaved[lock.path] != nil; unsavedLock.unlock()
        if unsavedHere { save(lock) { _ in } }
        return read(lock, now: now).notBefore(now: now, userInitiated: userInitiated)
    }

    /// Record how a request to the server went. An answer other than 429 or 5xx ends only the
    /// client's backoff, never a running server pause (that answer may belong to a request sent
    /// before the pause). A Retry-After extends the server's deadline, a failure without one the
    /// client's; neither shortens the other.
    static func note(status: Int?, retryAfter: String?, lock: SharedFileLock, now: Date) {
        let change = { (cooldown: inout NtfyMeHostCooldown) in
            if let status, status < 500, status != 429 {
                cooldown.failures = 0
                cooldown.clientNotBefore = nil
                return
            }
            cooldown.failures = min(cooldown.failures + 1, 16)
            if let delay = PollTiming.retryDelay(retryAfter, now: now, cap: maxRetryAfter), delay > 0 {
                let until = now.addingTimeInterval(delay)
                cooldown.serverNotBefore = max(cooldown.serverNotBefore ?? .distantPast, until)
            } else {
                let until = now.addingTimeInterval(min(backoffBase * pow(2, Double(cooldown.failures - 1)), backoffCap))
                cooldown.clientNotBefore = max(cooldown.clientNotBefore ?? .distantPast, until)
            }
        }
        guard !save(lock, change) else { return }
        // Not saved: kept in force in this process so a pause is never lost to a busy lock.
        let onDisk = file(lock).read()
        unsavedLock.lock(); defer { unsavedLock.unlock() }
        var pending = unsaved[lock.path]?.value ?? onDisk ?? NtfyMeHostCooldown()
        change(&pending)
        generations += 1
        unsaved[lock.path] = (pending, generations)
    }

    /// Applies `change` to the file, with this process's unsaved pauses merged in, and clears the
    /// unsaved value it wrote. A file that can't be read is replaced: the answer at hand is the
    /// newest evidence there is (its pause was honoured meanwhile, `read`). False when not saved.
    @discardableResult
    private static func save(_ lock: SharedFileLock, _ change: (inout NtfyMeHostCooldown) -> Void) -> Bool {
        let stateFile = file(lock)
        var merged: Int?
        let saved: Bool? = lock.withLock { () -> Bool? in
            unsavedLock.lock()
            let pending = unsaved[lock.path]
            let since = unreadableSince[lock.path]
            unsavedLock.unlock()
            merged = pending?.generation
            if case .unreadable = stateFile.load() {
                var next = NtfyMeHostCooldown(serverNotBefore: since.map { $0.addingTimeInterval(unreadablePause) })
                if let pending { next = next.strongest(with: pending.value) }
                change(&next)
                guard (try? JSONEncoder().encode(next).write(to: stateFile.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return false }
                return true
            }
            return stateFile.update { stored in
                var next = stored ?? NtfyMeHostCooldown()
                if let pending { next = next.strongest(with: pending.value) }
                change(&next)
                let write = next != stored
                if write { stored = next }
                return (write, true)
            }
        } ?? nil
        guard saved == true else { return false }
        afterSaveForTesting?()
        unsavedLock.lock(); defer { unsavedLock.unlock() }
        if let merged, unsaved[lock.path]?.generation == merged { unsaved[lock.path] = nil }
        unreadableSince[lock.path] = nil
        return true
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
    static let maxProbesPerSync = 5
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
    /// Time an access check leaves in a wake for the removal or replacement after it (review-130d D10).
    static let registrationReserve: TimeInterval = 5
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
    /// The monotonic clock the access checks' cutoff is kept on (review-130e E9).
    private let uptime: () -> TimeInterval
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
    private var pendingWake: WakeContext?
    private var pendingForeground = false
    private var pendingUserInitiated = false
    /// The access ledger's own app-group file, under the same lock as the record.
    let accessFile: SharedStateFile<NtfyShAccessLedger>
    /// Names this instance's requests in the ledger's barrier list (`NtfyShAccessLedger.pending`).
    private let run = UUID().uuidString

    init(store: Store, defaults: UserDefaults = NtfyShBridge.defaults, session: URLSession? = nil,
         network: Bool = true, appBaseUrl: String = Config.appBaseUrl, now: @escaping () -> Date = Date.init,
         lock: SharedFileLock? = nil, stateDirectory: URL = SharedStateFile<BridgeRecord>.sharedDirectory,
         isExtension: Bool = Bundle.main.bundlePath.hasSuffix(".appex"), observesCredentialChanges: Bool = false,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store
        self.defaults = defaults
        self.appBaseUrl = appBaseUrl
        self.now = now
        self.uptime = uptime
        self.lock = lock ?? .at(stateDirectory, Self.lockName)
        self.recordFile = SharedStateFile(name: Self.recordFileName, directory: stateDirectory, lock: self.lock)
        self.accessFile = SharedStateFile(name: NtfyShAccessLedger.fileName, directory: stateDirectory, lock: self.lock)
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
        // Committed after the setting, so a sync that sees the new generation also sees the new
        // setting; one that read the old generation sends nothing (review-130e E4).
        mutate { record in
            record.enablement = (record.enablement ?? 0) + 1
            if !enabled { record.optedOut = true }
        }
        sync(reason: enabled ? "setting turned on" : "setting turned off", userInitiated: true)
    }

    /// The setting's generation as committed now.
    private var enablement: Int { currentRecord.enablement ?? 0 }

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
        guard let rows = readRows() else { return nil }
        let ledger = loadLedger()
        let barriers = ledger?.barriers(excludingRun: run)
        return BridgeWatchSet.compute(subscriptions: rows, access: access,
                                      barrier: ledger == nil ? .distantFuture : barriers?.all, barriers: barriers?.names ?? [:],
                                      now: now(), appBaseUrl: appBaseUrl)
    }

    /// Every subscription's stored address and topic, and whether a credential may be saved for
    /// it; nil when the store couldn't be read.
    private func readRows() -> [(baseUrl: String, topic: String, hasLogin: Bool)]? {
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
        return rows
    }

    // MARK: Anonymous access checks

    /// The answers as committed, with any this process couldn't save laid over them (newer
    /// evidence wins). For display; decisions read the ledger inside the lock (`register`).
    var access: [String: NtfyShAccess] {
        Self.merge(loadLedger()?.answers ?? [:], unsavedAnswers)
    }

    /// The access ledger as its file holds it, or the answers 1.29 and the 1.30 betas kept in the
    /// shared defaults before the first write; nil when the file can't be read now.
    private func loadLedger() -> NtfyShAccessLedger? {
        switch accessFile.load() {
        case .value(let ledger): return ledger
        case .missing: return legacyLedger()
        case .unreadable: return nil
        }
    }

    private func legacyLedger() -> NtfyShAccessLedger {
        var ledger = NtfyShAccessLedger()
        ledger.answers = defaults.data(forKey: Self.accessKey)
            .flatMap { try? JSONDecoder().decode([String: NtfyShAccess].self, from: $0) } ?? [:]
        ledger.probeNotBefore = defaults.object(forKey: Self.probeCooldownKey) as? Date
        return ledger
    }

    /// Read-modify-write of the ledger under the bridge lock. False when the lock wasn't had in
    /// time, the file can't be read or the write failed: then nothing changed.
    @discardableResult
    private func updateLedger(_ change: (inout NtfyShAccessLedger) -> Void) -> Bool {
        let migrating = !FileManager.default.fileExists(atPath: accessFile.url.path)
        let saved: Bool? = accessFile.update { stored in
            var ledger = stored ?? legacyLedger()
            change(&ledger)
            // Forget names checked over a month ago (unsubscribed long since), and requests from
            // a run that ended before it could say what they found.
            let current = now()
            ledger.answers = ledger.answers.filter { current.timeIntervalSince($0.value.evidenceAt) < 30 * 24 * 60 * 60 }
            ledger.pending = ledger.pending?.filter { current.timeIntervalSince($0.value) < NtfyShAccessLedger.pendingLifetime }
            if ledger.pending?.isEmpty == true { ledger.pending = nil }
            ledger.pendingNames = ledger.pendingNames?.filter { ledger.pending?[$0.key] != nil }
            if ledger.pendingNames?.isEmpty == true { ledger.pendingNames = nil }
            let write = stored != ledger
            if write { stored = ledger }
            return (write, true)
        }
        guard saved == true else { return false }
        if migrating {
            defaults.removeObject(forKey: Self.accessKey)
            defaults.removeObject(forKey: Self.probeCooldownKey)
        }
        BridgeStateSignal.announce()
        return true
    }

    private static func merge(_ base: [String: NtfyShAccess], _ update: [String: NtfyShAccess]) -> [String: NtfyShAccess] {
        var merged = base
        for (name, answer) in update { merged[name] = merged[name].map { $0.merged(with: answer) } ?? answer }
        return merged
    }

    /// Evidence this process couldn't save (the lock timed out or the write failed): honoured by
    /// every set this process computes, and written with the next save that works. A same-process
    /// belt only: across a restart the durable recheck marks and request barriers in the ledger are
    /// what keep an earlier 200 from being reused (review-130c C1).
    private let unsavedLock = NSLock()
    private var unsavedAccess: [String: NtfyShAccess] = [:]
    /// Barriers of this run's requests that were answered but couldn't be cleared yet.
    private var unsavedClears = Set<String>()

    private var unsavedAnswers: [String: NtfyShAccess] {
        unsavedLock.lock(); defer { unsavedLock.unlock() }
        return unsavedAccess
    }

    /// Writes what earlier saves couldn't. False while that still fails: then this cycle sends no list.
    private func flushUnsavedAccess() -> Bool {
        unsavedLock.lock(); let pending = unsavedAccess; let clears = unsavedClears; unsavedLock.unlock()
        guard !pending.isEmpty || !clears.isEmpty else { return true }
        return commitEvidence([:], clearing: nil)
    }

    /// Commits answers (with any earlier ones that couldn't be saved) and clears a request's
    /// barrier, in one write. Returns false when it couldn't be written; the answers then stay in
    /// force in this process and the barrier stays on disk.
    @discardableResult
    private func commitEvidence(_ update: [String: NtfyShAccess], clearing request: String?) -> Bool {
        unsavedLock.lock()
        unsavedAccess = Self.merge(unsavedAccess, update)
        if let request { unsavedClears.insert(request) }
        let pending = unsavedAccess
        let clears = unsavedClears
        unsavedLock.unlock()
        let saved = updateLedger { ledger in
            ledger.answers = Self.merge(ledger.answers, pending)
            for id in clears { ledger.resolve(id) }
        }
        guard saved else {
            Log.w(Self.tag, "Access evidence not saved (lock busy or write failed); kept in force in this process")
            return false
        }
        unsavedLock.lock()
        // Drop what was written; evidence that arrived meanwhile stays for the next save.
        for (name, answer) in pending where unsavedAccess[name] == answer { unsavedAccess[name] = nil }
        unsavedClears.subtract(clears)
        unsavedLock.unlock()
        return true
    }

    /// The server can't read these names anonymously, as of a request that started at `asked`:
    /// any 200 from before then no longer counts, so they leave the next set and return only
    /// after a fresh anonymous 200. Also clears that request's barrier.
    @discardableResult
    func recordRefusals(_ names: [String]?, asked: Date, clearing request: String? = nil) -> Bool {
        let refusals = Dictionary(Set(names ?? []).map { ($0, NtfyShAccess(state: .refused, checked: asked)) }, uniquingKeysWith: { a, _ in a })
        return commitEvidence(refusals, clearing: request)
    }

    /// Registers a request that may report refusals for `names`, before it is sent. While it
    /// stands, another run treats every earlier 200 of those names as unconfirmed, with a login
    /// or without (`compute(barriers:)`, review-130d D1).
    private func openBarrier(at started: Date, names: [String]) -> String? {
        let id = run + "/" + UUID().uuidString
        return updateLedger { ledger in
            ledger.pending = (ledger.pending ?? [:]).merging([id: started]) { a, _ in a }
            ledger.pendingNames = (ledger.pendingNames ?? [:]).merging([id: names.sorted()]) { a, _ in a }
        } ? id : nil
    }

    var probeBlockedUntil: Date? {
        loadLedger()?.probeNotBefore.flatMap { $0 > now() ? $0 : nil }
    }

    /// `GET https://ntfy.sh/<topic>/auth` with no credentials: 200 when anyone may read it, which is
    /// exactly what the bridge can do. Sequential; each name is marked as being rechecked just
    /// before its own request and its answer committed as it lands (review-130d D10), and a 429
    /// stops the round until ntfy.sh's Retry-After (at most a day) or an hour. `completion(false)`
    /// when a mark or an answer couldn't be committed: then the cycle sends no list.
    ///
    /// In a wake the checks end at a cutoff on the monotonic clock, `registrationReserve` before
    /// the wake's deadline (review-130e E9): none starts after it, the time left is checked again
    /// after each mark, and a check still running at the cutoff is cancelled, so the list that
    /// follows keeps its time. Before each check the setting's generation and the subscriptions
    /// are read again: no check after the setting changed, none for a topic removed during the
    /// round (review-130e E4).
    private func probe(_ topics: [String], generation: Int, deadline: Date?, wake: WakeContext?, completion: @escaping (Bool) -> Void) {
        guard let session, !topics.isEmpty else { completion(true); return }
        let budget = remainingTime(deadline, wake) - Self.registrationReserve
        let cutoff = budget.isFinite ? uptime() + budget : nil
        let left = { cutoff.map { $0 - self.uptime() } ?? .infinity }
        var queue = topics
        func next() {
            guard !queue.isEmpty else { completion(true); return }
            guard left() >= Self.minimumRequestTime else {
                Log.d(Self.tag, "Access checks: the rest of this wake is kept for the list; \(queue.count) wait for the next")
                completion(true); return
            }
            guard enablement == generation, isEnabled else {
                Log.d(Self.tag, "Access checks: the setting changed; the sync it queued decides")
                completion(true); return
            }
            let topic = queue.removeFirst()
            guard let rows = readRows() else { completion(true); return }
            guard rows.contains(where: { NtfyShAddress.isNtfySh(normalizeBaseUrl($0.baseUrl)) && $0.topic == topic }) else {
                Log.d(Self.tag, "Access checks: a topic was removed during the round; not checked")
                next(); return
            }
            guard let url = URL(string: NtfyShAddress.canonical + "/" + topic + "/auth") else { next(); return }
            // The answer is as old as the request: a refusal reported for a later request is newer.
            let started = now()
            // Until a fresh answer lands, this name's earlier 200 can't be reused, even after a kill.
            var prior: Date?
            guard updateLedger({ ledger in
                prior = ledger.answers[topic]?.rechecking
                if ledger.answers[topic] != nil { ledger.answers[topic]?.rechecking = started }
            }) else { completion(false); return }
            afterProbeMarkForTesting?(topic)
            let remaining = left()
            guard remaining >= Self.minimumRequestTime else {
                // Nothing was sent, so nothing can come back: the name keeps its standing.
                unmark(topic, started: started, prior: prior)
                Log.d(Self.tag, "Access checks: the cutoff passed while marking; \(queue.count + 1) wait for the next")
                completion(true); return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = min(15, remaining - 1)
            request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
            let once = Once()
            let task = session.dataTask(with: request) { _, response, error in
                guard once.claim() else { return }
                self.setIssued(topic, false)
                let http = response as? HTTPURLResponse
                let status = error == nil ? http?.statusCode : nil
                Log.d(Self.tag, "Access check: HTTP \(status.map(String.init) ?? "none")")
                if status == 429 {
                    let delay = PollTiming.retryDelay(http?.value(forHTTPHeaderField: "Retry-After"), now: self.now(), cap: 24 * 60 * 60)
                    let until = self.now().addingTimeInterval(max(delay ?? Self.probeBackoff, 1))
                    // Rate limited is a failed check: the name stays withheld until a fresh 200.
                    var saved = self.commitEvidence([topic: NtfyShAccess(state: .unknown, checked: started)], clearing: nil)
                    saved = saved && self.updateLedger { $0.probeNotBefore = max($0.probeNotBefore ?? .distantPast, until) }
                    completion(saved); return
                }
                guard self.commitEvidence([topic: NtfyShAccess(state: NtfyShAccess.classify(status: status), checked: started)], clearing: nil) else {
                    completion(false); return
                }
                next()
            }
            // Marked issued before it can answer, so a finished check never shows as running.
            setIssued(topic, true)
            guard start(task, deadline: deadline, wake: wake) else {
                // The wake ended between the check above and the start: nothing was sent.
                once.claim()
                setIssued(topic, false)
                unmark(topic, started: started, prior: prior)
                completion(true); return
            }
            BridgeStateSignal.announce()
            if let cutoff {
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0, cutoff - uptime())) { [weak task] in
                    guard let task, task.state == .running else { return }
                    Log.d(Self.tag, "Access check cancelled at the cutoff; the wake's last seconds are for the list")
                    task.cancel()
                }
            }
        }
        next()
    }

    /// Test hook: runs after a name's recheck mark is committed, before its request.
    var afterProbeMarkForTesting: ((String) -> Void)?

    /// Takes back a recheck mark whose request was never sent, unless a newer one replaced it.
    private func unmark(_ topic: String, started: Date, prior: Date?) {
        updateLedger { ledger in
            if ledger.answers[topic]?.rechecking == started { ledger.answers[topic]?.rechecking = prior }
        }
    }

    /// Names whose anonymous check this instance sent and hasn't seen answered (review-130e E8).
    private var issuedChecks = Set<String>()

    private func setIssued(_ topic: String, _ issued: Bool) {
        unsavedLock.lock(); defer { unsavedLock.unlock() }
        if issued { issuedChecks.insert(topic) } else { issuedChecks.remove(topic) }
    }

    /// An access check for `topic` is out and its answer hasn't landed: the topic shows "Checking".
    func isCheckIssued(_ topic: String) -> Bool {
        unsavedLock.lock(); defer { unsavedLock.unlock() }
        return issuedChecks.contains(topic)
    }

    /// What should be registered now: empty when the setting is off.
    /// Empty only for the setting turned off or a successfully read empty set; nil when the
    /// subscriptions couldn't be read (then nothing is sent).
    func desiredSet() -> BridgeWatchSet? {
        isEnabled ? readSubscribedSet() : .empty
    }

    /// Time left for a request in this wake (infinite outside one).
    private func remainingTime(_ deadline: Date?, _ wake: WakeContext?) -> TimeInterval {
        min(deadline.map { $0.timeIntervalSince(now()) } ?? .infinity, wake?.remaining ?? .infinity)
    }

    /// Register the current set if it changed, the server lost it, or the last success is over a
    /// day old. App process only.
    ///
    /// Cheap to call on every trigger: with nothing to do it is a fetch and a return. A failure
    /// leaves `acceptedSignature` alone and starts the shared backoff; there are no timers.
    /// - Parameters:
    ///   - userInitiated: the user's own action (the setting); skips the client's backoff, not a server Retry-After.
    ///   - deadline, wake: in a background wake, no request starts that couldn't finish by then,
    ///     and the wake's cancellation stops what is running (review-130c C4). A sync without
    ///     either is a foreground one; queued behind a wake, it never inherits the wake's deadline.
    func sync(reason: String, userInitiated: Bool = false, deadline: Date? = nil, wake: WakeContext? = nil, completion: (() -> Void)? = nil) {
        guard !isExtension else {
            Log.d(Self.tag, "sync(\(reason)) ignored: only the app changes what is watched")
            completion?()
            return
        }
        // Turned off: the extension stops renewing at once, before any gate can delay the
        // removal itself (review-130d D2).
        if !isEnabled { recordOptOut() }
        processLock.lock()
        if inFlight {
            rerunRequested = true
            if let completion { pendingCompletions.append(completion) }
            if deadline == nil && wake == nil {
                pendingForeground = true
            } else {
                if let deadline { pendingDeadline = min(pendingDeadline ?? deadline, deadline) }
                if let wake, pendingWake == nil || wake.remaining < (pendingWake?.remaining ?? .infinity) { pendingWake = wake }
            }
            pendingUserInitiated = pendingUserInitiated || userInitiated
            processLock.unlock()
            Log.d(Self.tag, "sync(\(reason)) queued behind a registration in flight")
            return
        }
        inFlight = true
        processLock.unlock()
        let done = { self.finish(completion) }
        // Read before the setting, so a change committed after this read makes this sync stale.
        let generation = enablement

        // Privacy evidence this process couldn't save yet goes first; while it can't be saved,
        // no list with names goes out (review-130c C1). Turned off, the list is empty.
        let flushed = flushUnsavedAccess()
        guard isEnabled, session != nil else {
            register(reason: reason, userInitiated: userInitiated, generation: generation, deadline: deadline, wake: wake, done: done)
            return
        }
        guard flushed else {
            Log.w(Self.tag, "sync(\(reason)): access evidence couldn't be saved; sending no list this time")
            done()
            return
        }
        // Pick the names to check. Each is marked as being rechecked just before its own check
        // (`probe`, review-130d D10), so a name the wake never reaches keeps its standing.
        let rows = readRows()
        var plan: [String]?
        var shrinkFirst = false
        lock.withLock {
            guard let rows else { return }
            guard let ledger = loadLedger() else {
                // No ntfy.sh name to decide: nothing to check, and the list needs no access evidence.
                if !rows.contains(where: { NtfyShAddress.isNtfySh(normalizeBaseUrl($0.baseUrl)) }) { plan = [] }
                return
            }
            let barriers = ledger.barriers(excludingRun: run)
            let set = BridgeWatchSet.compute(subscriptions: rows, access: Self.merge(ledger.answers, unsavedAnswers),
                                             barrier: barriers.all, barriers: barriers.names, now: now(), appBaseUrl: appBaseUrl)
            // A removal already known goes out before the optional checks (review-130d D2). A name
            // held only until its check isn't known to go: the checks decide it.
            let awaitingCheck = Set(set.held.filter { $0.hold == .checkingAccess }.map { "t:" + $0.topic })
            shrinkFirst = recordFile.read().map { !$0.pendingRemovals(desired: set).subtracting(awaitingCheck).isEmpty } ?? false
            if let until = ledger.probeNotBefore, until > now() { plan = []; return }
            plan = Array(set.needsProbe.prefix(Self.maxProbesPerSync))
        }
        guard let plan else {
            Log.w(Self.tag, "sync(\(reason)): couldn't read the subscriptions or the access answers; sending no list this time")
            done()
            return
        }
        guard !plan.isEmpty else {
            register(reason: reason, userInitiated: userInitiated, generation: generation, deadline: deadline, wake: wake, done: done)
            return
        }
        let checkThenRegister = {
            Log.d(Self.tag, "sync(\(reason)): checking up to \(plan.count) ntfy.sh topic(s) anonymously first")
            self.probe(plan, generation: generation, deadline: deadline, wake: wake) { saved in
                guard saved else {
                    Log.w(Self.tag, "sync(\(reason)): an access answer couldn't be saved; sending no list this time")
                    done()
                    return
                }
                self.register(reason: reason, userInitiated: userInitiated, generation: generation, deadline: deadline, wake: wake, done: done)
            }
        }
        if shrinkFirst {
            register(reason: reason + " (removal first)", userInitiated: userInitiated, generation: generation, deadline: deadline, wake: wake,
                     shrinkOnly: true, done: checkThenRegister)
        } else {
            checkThenRegister()
        }
    }

    /// Commits the opt-out the extension reads (`optedOut`), so no renewal extends the list while
    /// the empty one waits for a gate (review-130d D2). Turning on clears it with the next POST.
    private func recordOptOut() {
        guard currentRecord.optedOut != true else { return }
        mutate { record in
            record.optedOut = true
            record.enablement = (record.enablement ?? 0) + 1
        }
    }

    /// Decides the body and sends it in one critical section under the bridge lock (review-130c
    /// C1): the set is computed from the access evidence committed at that moment, the attempt and
    /// the request's barrier are committed, and the request starts before the lock is released, so
    /// no refusal can be committed between choosing the names and sending them.
    /// - Parameter shrinkOnly: send only what is still wanted of what the server holds, and only
    ///   when that removes something; `done` runs either way.
    /// - Parameter generation: the setting's generation the sync began under; a newer one
    ///   committed since (an opt-out) means this one sends nothing (review-130e E4).
    private func register(reason: String, userInitiated: Bool, generation: Int, deadline: Date?, wake: WakeContext?,
                          shrinkOnly: Bool = false, done: @escaping () -> Void) {
        guard let session, let url = endpoint else {
            Log.d(Self.tag, "sync(\(reason)): no network in this process")
            done()
            return
        }
        let enabled = isEnabled
        let rows = enabled ? readRows() : []
        var note = "shared state busy; not registering now"
        var dispatched = false
        lock.withLock {
            guard let rows else { note = "subscriptions couldn't be read; leaving the server's list as it is"; return }
            // Only ntfy.sh names need the access answers; an empty list or hashes alone don't (review-130d D2).
            let ledger = loadLedger()
            let needsLedger = rows.contains { NtfyShAddress.isNtfySh(normalizeBaseUrl($0.baseUrl)) }
            guard ledger != nil || !needsLedger else { note = "access answers can't be read; sending nothing"; return }
            let record: BridgeRecord
            switch recordFile.load() {
            case .unreadable: note = "bridge record can't be read; sending nothing"; return
            case .missing: record = legacyRecord() ?? BridgeRecord()
            case .value(let stored): record = stored
            }
            guard (record.enablement ?? 0) == generation else {
                note = "the setting changed since this sync began; the sync it queued sends the list"; return
            }
            let barriers = ledger?.barriers(excludingRun: run)
            var computed = enabled
                ? BridgeWatchSet.compute(subscriptions: rows, access: Self.merge(ledger?.answers ?? [:], unsavedAnswers),
                                         barrier: barriers?.all, barriers: barriers?.names ?? [:], now: now(), appBaseUrl: appBaseUrl)
                : .empty
            if shrinkOnly {
                let accepted = BridgeWatchSet.members(signature: record.acceptedSignature)
                computed = BridgeWatchSet(ntfyShTopics: computed.ntfyShTopics.filter { accepted.contains("t:" + $0) },
                                          hashes: computed.hashes.filter { accepted.contains("h:" + $0) })
                guard !record.pendingRemovals(desired: computed).isEmpty else { note = "no removal pending"; return }
            }
            let desired: BridgeWatchSet
            switch plan(desired: computed, record: record, userInitiated: userInitiated) {
            case .skip(let why): note = why; return
            case .send(let set): desired = set
            }
            let remaining = remainingTime(deadline, wake)
            guard remaining >= Self.minimumRequestTime else { note = "no time left in this wake"; return }
            guard let device = deviceId else { return }
            let started = now()
            // Only a list with ntfy.sh names can come back with refusals (review-130d D2).
            var barrier: String?
            if !desired.ntfyShTopics.isEmpty {
                guard let id = openBarrier(at: started, names: desired.ntfyShTopics) else {
                    note = "couldn't record the request; not registering now"; return
                }
                barrier = id
            }
            let priorUnconfirmed = record.unconfirmed
            guard let saved = mutate({ next in
                next.revision = (next.revision ?? 0) + 1
                next.attempting = next.revision
                next.lastAttempt = started
                next.sentTopics = desired.ntfyShTopics.count
                next.sentHashes = desired.hashes.count
                next.device = device
                next.optedOut = enabled ? nil : true
                if !desired.isEmpty { next.mayHaveEntries = true }
                let extra = BridgeWatchSet.members(signature: desired.signature).union(next.unconfirmed ?? [])
                    .subtracting(BridgeWatchSet.members(signature: next.acceptedSignature))
                next.unconfirmed = extra.isEmpty ? nil : extra.sorted()
            }) else {
                if let barrier { commitEvidence([:], clearing: barrier) }
                note = "couldn't record the attempt; not registering now"
                return
            }
            let revision = saved.revision ?? 0
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            if remaining.isFinite { request.timeoutInterval = min(15, remaining - 0.5) }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = Self.body(device: device, set: desired)
            Log.i(Self.tag, "sync(\(reason)): registering \(desired.ntfyShTopics.count) ntfy.sh topic(s), "
                  + "\(desired.hashes.count) hash(es), \(computed.skipped) skipped")
            let once = Once()
            let respond = { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
                guard once.claim() else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.handle(desired: desired, revision: revision, started: started, barrier: barrier,
                                priorUnconfirmed: priorUnconfirmed, data: data, response: response as? HTTPURLResponse, error: error)
                    done()
                }
            }
            let task = session.dataTask(with: request) { respond($0, $1, $2) }
            if !start(task, deadline: deadline, wake: wake) {
                // Not sent after all (the wake ended): resolve the attempt as a network failure.
                respond(nil, nil, URLError(.cancelled))
            }
            dispatched = true
        }
        if !dispatched {
            Log.d(Self.tag, "sync(\(reason)): \(note)")
            done()
        }
    }

    /// Starts `task` unless the wake has ended or has too little time left, with its cancellation
    /// installed first (review-130c C4); outside a wake, a deadline still cancels it then.
    @discardableResult
    private func start(_ task: URLSessionDataTask, deadline: Date?, wake: WakeContext?) -> Bool {
        if let wake {
            guard wake.start(task, minimum: Self.minimumRequestTime) else { return false }
        } else {
            task.resume()
        }
        guard let deadline else { return true }
        let delay = max(0, deadline.timeIntervalSince(now()))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak task] in
            guard let task, task.state == .running else { return }
            Log.d(Self.tag, "Request cancelled at the wake's deadline")
            task.cancel()
        }
        return true
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

    private enum Plan { case skip(String), send(BridgeWatchSet) }

    private func plan(desired: BridgeWatchSet, record: BridgeRecord, userInitiated: Bool) -> Plan {
        if let until = NtfyMeHostCooldown.blockedUntil(lock, now: now(), userInitiated: userInitiated) {
            return .skip("waiting until \(until) (server Retry-After or backoff)")
        }
        let accepted = BridgeWatchSet.members(signature: record.acceptedSignature)
        // What the server may hold beyond the list: removals, including what a lost 200 installed (D2).
        let removals = record.mayHold.subtracting(BridgeWatchSet.members(signature: desired.signature))
        if desired.isEmpty {
            return record.mayHaveEntries || !removals.isEmpty ? .send(desired) : .skip("nothing to register")
        }
        // Admission (42912) limits adding entries only. A list that adds nothing still goes out,
        // and one that adds and removes sends its removals first: what it keeps of the accepted
        // list, without the additions (review-130c C2).
        if let until = record.admissionBlockedUntil, until > now(),
           !BridgeWatchSet.members(signature: desired.signature).isSubset(of: accepted) {
            let kept = BridgeWatchSet(ntfyShTopics: desired.ntfyShTopics.filter { accepted.contains("t:" + $0) },
                                      hashes: desired.hashes.filter { accepted.contains("h:" + $0) })
            if BridgeWatchSet.members(signature: kept.signature) != accepted
                || !record.mayHold.subtracting(BridgeWatchSet.members(signature: kept.signature)).isEmpty { return .send(kept) }
            return .skip("waiting until \(until) for watch admission (42912)")
        }
        // Turned back on: the opt-out the extension reads is cleared by this POST.
        if record.repairRequested == true || record.renewMissed == true || record.optedOut == true { return .send(desired) }
        if desired.signature == record.acceptedSignature, removals.isEmpty, let success = record.lastSuccess,
           now().timeIntervalSince(success) < Self.refreshInterval, success <= now() {
            return .skip("up to date")
        }
        return .send(desired)
    }

    private func handle(desired: BridgeWatchSet, revision: Int, started: Date, barrier: String?,
                        priorUnconfirmed: [String]?, data: Data?, response: HTTPURLResponse?, error: Error?) {
        let status = error == nil ? response?.statusCode : nil
        struct Reply: Decodable { let watching: Int?; let expires: Double?; let unwatchable: [String]?; let error: String?; let code: Int? }
        let reply = data.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }
        // Refusals are about the names, not the list: committed first, dated by the request's
        // start, and kept even for a reply to an older registration. This also clears the barrier.
        if barrier != nil || reply?.unwatchable?.isEmpty == false {
            recordRefusals(status == 200 ? reply?.unwatchable : nil, asked: started, clearing: barrier)
        }
        let retryAfter = response?.value(forHTTPHeaderField: "Retry-After")
        // 42912 is about this network's share of watch entries, not the request budget: it pauses
        // adding entries only, not every request to the server (review-130b #9).
        let admission = status == 429 && reply?.code == 42912
        if !admission {
            NtfyMeHostCooldown.note(status: status, retryAfter: retryAfter, lock: lock, now: now())
        }
        var obsolete = false
        mutate { next in
            if next.attempting == revision { next.attempting = nil }
            guard (next.revision ?? 0) == revision else { obsolete = true; return }
            next.lastHTTPStatus = response?.statusCode
            // The server's own refusal installed nothing; a lost or failed reply may have (D2).
            if let status, (400..<500).contains(status) { next.unconfirmed = priorUnconfirmed }
            guard let status else {
                next.lastOutcome = .network
                Log.w(Self.tag, "Registration failed: \(error?.localizedDescription ?? "no response"); backing off")
                return
            }
            switch status {
            case 200:
                next.unwatchable = reply?.unwatchable
                next.lastOutcome = .ok
                // A repaired device or a lapsed watch is a new watch for every entry.
                let lapsed = next.repairRequested == true || next.expires.map { $0 <= now() } ?? false
                let before = lapsed ? [] : BridgeWatchSet.members(signature: next.acceptedSignature)
                let starts = lapsed ? [:] : next.watchStarts ?? [:]
                var kept: [String: Date] = [:]
                for member in BridgeWatchSet.members(signature: desired.signature) where member.hasPrefix("h:") {
                    // A hash already watched keeps its start (1.30 betas recorded none: their last success).
                    kept[member] = starts[member] ?? (before.contains(member) ? next.lastSuccess : nil) ?? now()
                }
                next.watchStarts = kept.isEmpty ? nil : kept
                next.lastSuccess = now()
                next.acceptedSignature = desired.signature
                next.acceptedRevision = revision
                // A list replaces the device's whole list: nothing earlier may still be installed.
                next.unconfirmed = nil
                next.mayHaveEntries = !desired.isEmpty
                next.watching = reply?.watching
                next.expires = reply?.expires.map { Date(timeIntervalSince1970: $0) }
                next.repairRequested = nil
                next.renewMissed = nil
                // A shrink sent during an admission pause leaves the pause in force for the additions.
                if let until = next.admissionBlockedUntil, until <= now() { next.admissionBlockedUntil = nil }
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
        if obsolete { Log.d(Self.tag, "Dropped the reply to an older registration") }
    }

    private func finish(_ completion: (() -> Void)?) {
        processLock.lock()
        inFlight = false
        let rerun = rerunRequested
        rerunRequested = false
        let queued = pendingCompletions
        pendingCompletions = []
        // A foreground request queued behind a wake runs in the foreground (review-130c C4).
        let foreground = pendingForeground
        let deadline = foreground ? nil : pendingDeadline
        let wake = foreground ? nil : pendingWake
        pendingDeadline = nil
        pendingWake = nil
        pendingForeground = false
        let userInitiated = pendingUserInitiated
        pendingUserInitiated = false
        processLock.unlock()
        completion?()
        if rerun {
            sync(reason: "queued while a registration was in flight", userInitiated: userInitiated, deadline: deadline, wake: wake) { queued.forEach { $0() } }
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
        /// Needs an access check that hasn't been sent: queued behind the names checked first
        /// (`maxProbesPerSync` per run, review-130d D10), or not yet reachable in a run (review-130e E8).
        case waitingToCheck
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
        /// Self-hosted: the last "Check again" found no confirmed wake-up for its message, while
        /// the bridge's connection was confirmed. About that message, not the server's setup (review-130e E2).
        case checkMissed
        /// Self-hosted: recent messages arrived without a confirmed forward (the automatic, weak count).
        case noForwardingConfirmed

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
            case .checkMissed, .noForwardingConfirmed: return true
            default: return false
            }
        }

        /// Not a fault: the state is on its way to `.watched`.
        var isPending: Bool { self == .checkingAccess || self == .waitingToCheck || self == .registering || self == .pushNotReady }
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
            // "Checking" only while its request is out; queued or not yet eligible, it waits (review-130e E8).
            case .checkingAccess: return .held(isCheckIssued(topic) ? .checkingAccess : .waitingToCheck)
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
        // A reading of the list the server accepted then; one about an older list says nothing now.
        if record.statusConnected == false, record.statusRevision == record.acceptedRevision { return .held(.upstreamPending) }
        if !ntfySh, let wakes {
            // Only the evidence of the watch in force now (review-130e E7).
            switch wakes.diagnosis(hash: hash, watchStart: watchStart(hash: hash)) {
            case .checkMissed?: return .held(.checkMissed)
            case .unconfirmed?: return .held(.noForwardingConfirmed)
            case nil: break
            }
        }
        return .watched
    }

    /// The server accepted `hash` in its last successful reply, still knows this device, and the
    /// watch hasn't expired: only then can a missed wake-up say anything about the topic's server.
    func isAdmitted(hash: String) -> Bool { watchStart(hash: hash) != nil }

    /// When the current watch of an admitted `hash` began (nil when it isn't admitted). The
    /// self-hosted evidence counts only messages after it, and a new watch starts it over (D6).
    func watchStart(hash: String) -> Date? {
        let record = currentRecord
        // The accepted set stands until the next 200 replaces it, so a later failed POST (adding
        // another topic) doesn't un-admit this one.
        guard isEnabled, record.repairRequested != true, record.optedOut != true,
              record.expires.map({ $0 > now() }) ?? true,
              BridgeWatchSet.members(signature: record.acceptedSignature).contains("h:" + hash) else { return nil }
        return record.watchStarts?["h:" + hash] ?? record.lastSuccess ?? .distantPast
    }

    /// Strong evidence for counting a missed forward on `hash`: admitted, and a status read taken
    /// within about ten minutes of the miss, for the registration revision in force now, said the
    /// bridge's ntfy.sh connection was up (review-130b #8). Otherwise the miss is weak.
    func forwardingEvidence(hash: String) -> Bool {
        let record = currentRecord
        guard isAdmitted(hash: hash), record.statusConnected == true, let at = record.statusAt,
              abs(now().timeIntervalSince(at)) <= Self.connectedEvidenceAge,
              record.statusRevision != nil, record.statusRevision == record.acceptedRevision else { return false }
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
        /// Names ntfy-me.com may still hold that this device no longer sends (removed topics, a
        /// topic that stopped qualifying, or all of them after turning off), until it confirms.
        /// Shown even when no subscription row is left to carry it (review-130c C2).
        var removing = 0
        /// Off, and the server hasn't confirmed it dropped this device's list.
        var optOutPending = false
        /// At least one topic is listed as getting no banners (alone or under its server's reason):
        /// only then does the note about "these topics" have something to refer to.
        var listsTopics: Bool { groups.contains { !$0.held.isEmpty } }
    }

    /// What the server may still hold beyond the current set, from committed state.
    func pendingRemoval() -> (count: Int, optOut: Bool) {
        let record = currentRecord
        if !isEnabled || record.optedOut == true {
            let held = record.mayHold
            return record.mayHaveEntries || !held.isEmpty ? (held.count, true) : (0, false)
        }
        return (record.pendingRemovals(desired: readSubscribedSet()).count, false)
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
        let removal = pendingRemoval()
        return Report(groups: ordered.map { var g = $0; g.held.sort { $0.topic < $1.topic }; return g },
                      removing: removal.count, optOutPending: removal.optOut)
    }

    /// On, and the server accepted the set it holds now.
    var isRegistered: Bool {
        let record = currentRecord
        return isEnabled && record.lastOutcome == .ok && record.acceptedSignature != nil && record.repairRequested != true
    }

    // MARK: Renewal from the extension

    /// How long an attempt recorded before its POST stays unresolved: past this the process that
    /// sent it is gone (the request's own timeout is 15 s), so it no longer defers renewal.
    static let attemptLifetime: TimeInterval = 120

    /// True when a bridged wake-up should also renew this device's registration: the server holds
    /// entries for it, the last success or renewal is over a week old (the server forgets a device
    /// after 30 days), the last renewal attempt wasn't within the hour, no replacement list is
    /// being sent, and the server isn't asking for a pause. A user who lives on banners and never
    /// opens the app stays registered. Reads only the committed record (review-130c C3).
    func extensionShouldRenew(_ record: BridgeRecord) -> Bool {
        guard record.optedOut != true, record.mayHaveEntries, record.acceptedSignature != nil,
              record.repairRequested != true else { return false }
        // A replacement in flight: its answer, not a renewal's, decides what the server holds.
        if record.attempting != nil, let attempt = record.lastAttempt,
           now().timeIntervalSince(attempt) < Self.attemptLifetime, attempt <= now() { return false }
        if let attempt = record.lastRenewAttempt, attempt <= now() {
            // A renewal that answered a plain 404 (no renewal route) is retried about once a day.
            let interval = record.renewMissed == true ? Self.renewMissedRetryInterval : Self.extensionRetryInterval
            if now().timeIntervalSince(attempt) < interval { return false }
        }
        guard NtfyMeHostCooldown.blockedUntil(lock, now: now()) == nil else { return false }
        let newest = [record.lastSuccess, record.lastRenew].compactMap { $0 }.max()
        guard let newest else { return false }
        return now().timeIntervalSince(newest) >= Self.extensionRefreshAge
    }

    /// A renewal claimed by this process: which install and which record revision it renews.
    struct RenewClaim: Equatable {
        let device: String
        let revision: Int
    }

    /// Claim a renewal atomically (two extension processes can't both renew). The install ID, the
    /// setting and the revision come from the record as committed, and the claim is returned only
    /// once its attempt stamp is written: an unsaved claim isn't a claim (review-130c C3).
    func claimRenewal() -> RenewClaim? {
        let legacyDevice = existingDeviceId
        var claim: RenewClaim?
        guard mutate({ next in
            claim = nil
            guard let device = next.device ?? legacyDevice, extensionShouldRenew(next) else { return }
            next.lastRenewAttempt = now()
            claim = RenewClaim(device: device, revision: next.revision ?? 0)
        }) != nil else { return nil }
        return claim
    }

    /// Apply a renewal's answer only to the registration it renewed: a 200 or 404 that lands after
    /// the app registered again (a new revision), turned the setting off or changed the install ID
    /// is dropped. True only when the change was committed.
    @discardableResult
    func applyRenewal(_ claim: RenewClaim, _ change: (inout BridgeRecord) -> Void) -> Bool {
        let legacyDevice = existingDeviceId
        var applied = false
        guard mutate({ next in
            applied = false
            guard (next.revision ?? 0) == claim.revision, next.optedOut != true,
                  (next.device ?? legacyDevice) == claim.device else { return }
            change(&next)
            applied = true
        }) != nil else { return false }
        return applied
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
                                    lock: self.lock, now: self.now())
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
        /// Not asked, or asked and told to wait: no read until then. The screen asks again after it.
        case waiting(until: Date)
        /// The setting is off: nothing is asked.
        case off
    }

    /// Orders status reads in this process: only the current read's answer is recorded or shown.
    private var statusGeneration = 0
    /// Callers waiting on the read in flight (reads are coalesced: one at a time).
    private var statusWaiters: [(Status) -> Void] = []
    private var statusInFlight = false

    /// Drops the read in flight, its record write and its answer (the screen left, the setting
    /// changed). Refusals it reports are still recorded: they are about the names.
    func cancelStatus() {
        processLock.lock()
        statusGeneration += 1
        statusWaiters = []
        statusInFlight = false
        processLock.unlock()
    }

    private func isCurrentStatus(_ generation: Int) -> Bool {
        processLock.lock(); defer { processLock.unlock() }
        return generation == statusGeneration
    }

    /// `GET /v1/ntfai/watch?device=` for Notification status. Only asked when that screen opens or
    /// the user asks to check again, and never while the setting is off. Concurrent calls share
    /// one read. A 404 means the server lost this device: the app sends its list again. A read
    /// cancelled or overtaken (`cancelStatus`, a newer registration) is dropped at the record
    /// write and again before it is shown; one that crossed a newer registration is read again.
    func fetchStatus(completion: @escaping (Status) -> Void) {
        guard isEnabled else { completion(.off); return }
        processLock.lock()
        statusWaiters.append(completion)
        guard !statusInFlight else { processLock.unlock(); return }
        statusInFlight = true
        statusGeneration += 1
        let generation = statusGeneration
        processLock.unlock()
        readStatus(generation: generation, retryOnNewRegistration: true)
    }

    private func deliverStatus(_ status: Status, generation: Int) {
        DispatchQueue.main.async {
            self.processLock.lock()
            guard generation == self.statusGeneration else {
                self.processLock.unlock()
                Log.d(Self.tag, "Status: dropped an answer to a superseded read")
                return
            }
            let waiters = self.statusWaiters
            self.statusWaiters = []
            self.statusInFlight = false
            self.processLock.unlock()
            waiters.forEach { $0(status) }
        }
    }

    private func readStatus(generation: Int, retryOnNewRegistration: Bool) {
        let record = currentRecord
        guard let session, let endpoint, let device = record.device ?? existingDeviceId,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            deliverStatus(existingDeviceId == nil && session != nil ? .unknownDevice : .unavailable, generation: generation)
            return
        }
        components.queryItems = [URLQueryItem(name: "device", value: device)]
        guard let url = components.url else { deliverStatus(.unavailable, generation: generation); return }
        // The status read shares the server's cooldown with every other request to it (review-130 #9).
        if let until = NtfyMeHostCooldown.blockedUntil(lock, now: now()) { deliverStatus(.waiting(until: until), generation: generation); return }
        let revision = record.revision ?? 0
        let accepted = record.acceptedRevision
        // The answer may report refusals: register it first, so another run can't reuse a 200 it overturns.
        let started = now()
        // It can report on the names the server may hold for this device (review-130d D1).
        let names = record.mayHold.filter { $0.hasPrefix("t:") }.map { String($0.dropFirst(2)) }
        guard let barrier = openBarrier(at: started, names: names) else {
            Log.d(Self.tag, "Status: couldn't record the read; not asking now")
            deliverStatus(.unavailable, generation: generation)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            struct Reply: Decodable { let watching: Int; let connected: Bool; let unwatchable: [String]? }
            let http = response as? HTTPURLResponse
            let code = error == nil ? http?.statusCode : nil
            let decoded = code == 200 ? data.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) } : nil
            // Refusals are about the names: recorded first, dated by the read's start, even when
            // this read was superseded or crossed a newer registration (review-130c C1).
            self.recordRefusals(decoded?.unwatchable, asked: started, clearing: barrier)
            if code == 429 || (code ?? 500) >= 500 {
                NtfyMeHostCooldown.note(status: code, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                                        lock: self.lock, now: self.now())
            }
            if code == 429 {
                // A real 429: say when the next read may go, from the deadline the server gave.
                let until = NtfyMeHostCooldown.blockedUntil(self.lock, now: self.now()) ?? self.now().addingTimeInterval(60)
                self.deliverStatus(.waiting(until: until), generation: generation)
                return
            }
            var status = Status.unavailable
            var repair = false
            var crossed = false
            var stale = false
            self.mutate { next in
                guard self.isCurrentStatus(generation) else { stale = true; return }
                guard (next.revision ?? 0) == revision else { crossed = true; return }
                if code == 404 {
                    status = .unknownDevice
                    if next.mayHaveEntries || next.acceptedSignature != nil { next.repairRequested = true; repair = true }
                } else if let reply = decoded {
                    status = reply.connected ? .connected(watching: reply.watching) : .notConnected(watching: reply.watching)
                    next.unwatchable = reply.unwatchable
                    next.statusConnected = reply.connected
                    next.statusAt = self.now()
                    // The server describes the list it accepted: tie the reading to that revision.
                    next.statusRevision = accepted
                }
            }
            if stale { Log.d(Self.tag, "Status: superseded read; not recorded"); return }
            if crossed {
                // A registration started meanwhile: this answer describes the list it replaced.
                Log.d(Self.tag, "Status: answer crossed a newer registration" + (retryOnNewRegistration ? "; reading again" : ""))
                if retryOnNewRegistration { self.readStatus(generation: generation, retryOnNewRegistration: false) }
                else { self.deliverStatus(.unavailable, generation: generation) }
                return
            }
            Log.d(Self.tag, "Status: \(status) (HTTP \(code.map(String.init) ?? "none"))")
            self.deliverStatus(status, generation: generation)
            if repair { DispatchQueue.main.async { self.sync(reason: "server doesn't know this device") } }
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
        String(localized: "On, NTF-AI sends \(serverName) an installation ID made only for this, the names of your ntfy.sh topics, and a hash of each topic address on your other servers. \(serverName) watches those topics on ntfy.sh and wakes this device when a message arrives; it sees messages in passing and keeps no message text. If you saved credentials for ntfy.sh, or NTF-AI can't tell whether you did, it first asks ntfy.sh, without your credentials, whether anyone can read each topic, and sends only topics anyone can read. Without saved credentials, NTF-AI can initially send a topic name to \(serverName) without checking it. NTF-AI can ask ntfy.sh again, without your credentials, if access was refused or an interrupted request left access uncertain. When a topic stops qualifying, NTF-AI asks \(serverName) to stop watching it. If you tap Check again, NTF-AI can send \(serverName) the topic’s hash when it fetches an eligible message for that topic within 24 hours. It also sends that hash if you approve a test in Check self-hosted wake-ups. When you turn this off, NTF-AI asks \(serverName) to stop watching. Once it removes the topics, they stop receiving instant banners through ntfy.sh. Direct delivery through \(serverName) continues.")
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
        case .waitingToCheck:
            text = String(localized: "Waiting to check whether anyone can read this topic on ntfy.sh. Open the app or refresh to see new messages while you wait.")
        case .refused:
            text = String(localized: "\(serverName) couldn't watch this topic on ntfy.sh, so it gets no instant banners for now. NTF-AI checks again when it next runs, about once a day. Until then, new messages show when you open the app.")
        case .invalidName:
            text = String(localized: "This address or topic name can't be watched on ntfy.sh, so new messages show when you open the app.")
        case .overCap:
            text = String(localized: "Over the limit of 100 topics per list, so new messages show when you open the app.")
        case .bridgeOff:
            text = String(localized: "Instant banners through ntfy.sh are off in Settings. Messages that would come through ntfy.sh show when you open the app.")
        case .removalPending:
            text = String(localized: "Asking \(serverName) to stop watching this device's topics. If it hasn't confirmed yet, NTF-AI asks again the next time it runs.")
        case .bridgeUnavailable:
            text = String(localized: "\(serverName) couldn't take this device's list. NTF-AI tries again the next time it runs. Until then, messages that would come through ntfy.sh show when you open the app.")
        case .registering:
            text = String(localized: "Being added to what \(serverName) watches. Once it accepts the list, a message to this topic can wake this device.")
        case .notRegistered:
            text = String(localized: "\(serverName) no longer has this device's list. NTF-AI sends it again the next time it runs; if banners don't return, open NTF-AI.")
        case .upstreamPending:
            text = String(localized: "\(serverName) may not be watching all of this device's ntfy.sh topics right now. It may be reconnecting, or waiting until ntfy.sh accepts more requests. Until then, some new messages may show only when you open the app.")
        case .pushNotReady:
            text = String(localized: "This device hasn't finished push setup for this topic yet. Until then, new messages show when you open the app.")
        case .checkMissed:
            text = String(localized: "The relay didn’t confirm a wake-up for the last checked message. If this keeps happening, ask your server admin to check the forwarding settings.")
        case .noForwardingConfirmed:
            text = String(localized: "No recent forwarding confirmed for this topic. Tap Check again to check the next eligible message.")
        }
        guard selfHosted, hold == .bridgeOff || hold == .bridgeUnavailable || hold == .removalPending else { return text }
        return text + " " + directUpstreamNote
    }

    static var checkAgain: String { String(localized: "Check again") }
    static var checkArmed: String { String(localized: "NTF-AI will try to check the next eligible message it fetches for this topic within 24 hours.") }

    /// Notification status while ntfy-me.com still holds names this device no longer sends (review-130c C2).
    static func removing(_ count: Int) -> String { String(localized: "Removing \(count) topics from \(serverName)") }
    static var removalUnconfirmed: String { String(localized: "\(serverName) hasn't confirmed yet. NTF-AI asks again the next time it runs.") }

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
        case .notConnected: return String(localized: "Some topics may be waiting for push")
        case .unknownDevice: return String(localized: "Not registered yet")
        case .unavailable: return String(localized: "Couldn't check")
        case .waiting(let until):
            guard until > Date() else { return String(localized: "Waiting to retry") }
            let time = DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)
            return String(localized: "Waiting to retry after \(time)")
        case .off: return off
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

