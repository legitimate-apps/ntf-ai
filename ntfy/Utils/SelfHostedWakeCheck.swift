// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
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
/// The automatic evidence is local only (review-130d D6): messages a poll found that no push
/// brought, counted once each by message ID, from the start of the bridge's current watch of the
/// hash. Three say only that no forwarding was confirmed (`unconfirmed`). The one network check is
/// "Check again": it arms the hash, and the next fresh message a poll finds asks the relay whether
/// its wake-up went through. Its answer is kept apart from the automatic count (review-130e E2): a
/// miss while the bridge's ntfy.sh connection was confirmed up says only that this one message had
/// no confirmed wake-up (`checkMissed`), not how the server is set up. A timeout, an error or a
/// skipped check is inconclusive and leaves the arm in place (E7). Any wake-up clears both. The
/// relay reports acceptance, not delivery to this device. Evidence is read and written only for
/// the bridge's current watch of the hash (E7).
final class SelfHostedWakeCheck {
    struct Entry: Codable, Equatable {
        /// The last "Check again" answer was a miss while the bridge's connection was confirmed
        /// (non-zero); never fed by the automatic count, cleared by a relayed answer or a wake-up.
        var misses = 0
        var lastWake: Date?
        var lastCheck: Date?
        /// Misses without that confirmation (optional so 1.30 beta entries decode).
        var weakMisses: Int?
        /// "Check again": the next fresh message is checked whatever the throttles say.
        var armed: Bool?
        /// When it was armed; an arm no message answered lapses after `armLifetime`.
        var armedAt: Date?
        /// The start of the bridge watch this evidence belongs to (the record's `watchStarts`):
        /// messages from before then say nothing, and a new watch starts the evidence over. 1.30
        /// beta entries carry none and show nothing until a poll keys them.
        var watchedSince: Date?
        /// Messages already counted from a poll, by ID (newest last, bounded), so none counts twice.
        var countedIds: [String]?
    }

    enum Verdict: Equatable { case relayed, missed, unknown }
    /// `checkMissed`: the last "Check again" found no confirmed wake-up for its message.
    /// `unconfirmed`: the automatic count saw `missesToFlag` messages arrive with no push.
    enum Diagnosis: Equatable { case checkMissed, unconfirmed }

    /// Consecutive misses before the subscription shows a diagnosis.
    static let missesToFlag = 3
    /// The relay keeps acceptance times for 120 s; leave room for the request itself.
    static let maxMessageAge: TimeInterval = 100
    /// A forward can trail the message by a few seconds; ask only once it is at least this old.
    static let minMessageAge: TimeInterval = 10
    /// Clock skew allowed between the server's message time and the relay's.
    static let slack: TimeInterval = 5
    /// At most one "Check again" request across all topics this often, so many taps can't burst the relay.
    static let globalInterval: TimeInterval = 60
    /// A "Check again" no fresh message answered lapses after this.
    static let armLifetime: TimeInterval = 24 * 60 * 60
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
    /// The evidence, in its own app-group file: every read goes to disk, so a wake the extension
    /// records is seen by the app at once, not through a stale defaults cache (review-130c C7).
    private let file: SharedStateFile<[String: Entry]>
    /// The bridge's record, read for direct server watch (1.31): see `isWatchedDirectly`.
    private let bridgeRecord: SharedStateFile<BridgeRecord>
    static let fileName = "ntfai-wake-check.json"
    private let processLock = NSLock()
    private var inFlight = Set<String>()

    init(defaults: UserDefaults = NtfyShBridge.defaults, relayBaseUrl: String = Config.appBaseUrl, network: Bool = true,
         read: Read? = nil,
         schedule: @escaping Schedule = { delay, work in DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work) },
         now: @escaping () -> Date = Date.init, lock: SharedFileLock? = nil,
         stateDirectory: URL = SharedStateFile<BridgeRecord>.sharedDirectory) {
        self.defaults = defaults
        self.relayBaseUrl = relayBaseUrl
        self.schedule = schedule
        self.now = now
        self.lock = lock ?? .at(stateDirectory, NtfyShBridge.lockName)
        self.file = SharedStateFile(name: Self.fileName, directory: stateDirectory, lock: self.lock)
        self.bridgeRecord = SharedStateFile(name: NtfyShBridge.recordFileName, directory: stateDirectory, lock: self.lock)
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
        switch file.load() {
        case .value(let entries): return entries
        case .missing: return legacyEntries
        case .unreadable: return [:]
        }
    }

    /// What 1.30 betas kept in the shared defaults, until the first write moves it to the file.
    private var legacyEntries: [String: Entry] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func entry(hash: String) -> Entry? { entries[hash] }

    /// ntf-ai.app may be watching this topic on its server directly (1.31): the server was sent
    /// it, and no accepted list has removed it since. Its wake-ups then come on this same hash
    /// whatever the server's own forwarding does, so a wake proves nothing about the server, and
    /// a message a poll found isn't a forward the server missed. The evidence stays as it was
    /// before the direct watch, so turning it off shows the server's own diagnosis again (device
    /// check g2 of build 67: two direct wakes had cleared "No recent forwarding confirmed").
    func isWatchedDirectly(hash: String) -> Bool {
        bridgeRecord.read()?.mayHold.contains("s:" + hash) ?? false
    }

    /// What the evidence of the watch that began at `watchStart` says. Evidence of another watch
    /// (an older one before the next poll resets it, or none) says nothing (review-130e E7).
    func diagnosis(hash: String, watchStart: Date?) -> Diagnosis? {
        guard let watchStart, let entry = entries[hash], entry.watchedSince == watchStart else { return nil }
        if entry.misses > 0 { return .checkMissed }
        if (entry.weakMisses ?? 0) >= Self.missesToFlag { return .unconfirmed }
        return nil
    }

    /// Read-modify-write under the lock the extension also takes, so a wake it records can't be
    /// overwritten by a check result computed before it. `change` returns false to write nothing;
    /// with `create` false a missing entry stays missing (a late answer can't revive a forgotten topic).
    private func update(_ hash: String, create: Bool = true, _ change: (inout Entry) -> Bool) {
        let legacy = legacyEntries
        let changed: Bool = file.update { stored in
            var all = stored ?? legacy
            guard create || all[hash] != nil else { return (false, false) }
            var entry = all[hash] ?? Entry()
            guard change(&entry) else { return (false, false) }
            all[hash] = entry
            // Keep the table small: drop topics with nothing to say for a month. An armed entry
            // stays (a topic never checked before has nothing else yet).
            let cutoff = now().addingTimeInterval(-30 * 24 * 60 * 60)
            all = all.filter { ($0.value.lastWake ?? $0.value.lastCheck ?? $0.value.watchedSince ?? .distantPast) > cutoff || $0.value.misses > 0
                || ($0.value.weakMisses ?? 0) > 0 || $0.value.armed == true }
            stored = all
            return (true, true)
        } ?? false
        if changed {
            defaults.removeObject(forKey: Self.key)
            BridgeStateSignal.announce()
        }
    }

    /// A wake-up for this hash reached the device (the extension calls this for every hashed
    /// poll_request). It works, whatever the checks said.
    func recordWake(hash: String) {
        guard Self.isHash(hash), !isWatchedDirectly(hash: hash) else { return }
        update(hash) { $0.misses = 0; $0.weakMisses = nil; $0.lastWake = now(); return true }
    }

    /// "Check again": check the next fresh message on this topic even if one ran recently.
    func arm(hash: String) {
        guard Self.isHash(hash) else { return }
        update(hash) { $0.armed = true; $0.armedAt = now(); return true }
    }

    /// Armed and not lapsed. The screens show this, so it clears when the check completes (any
    /// verdict), the topic is forgotten, or the arm times out (review-130b #8).
    func isArmed(hash: String) -> Bool {
        guard let entry = entries[hash], entry.armed == true, let at = entry.armedAt else { return false }
        let age = now().timeIntervalSince(at)
        return age >= -Self.slack && age < Self.armLifetime
    }

    /// Forget a topic (unsubscribed).
    func forget(hash: String) {
        let legacy = legacyEntries
        let removed: Bool = file.update { stored in
            var all = stored ?? legacy
            guard all.removeValue(forKey: hash) != nil else { return (false, false) }
            stored = all
            return (true, true)
        } ?? false
        if removed {
            defaults.removeObject(forKey: Self.key)
            BridgeStateSignal.announce()
        }
    }

    static func isHash(_ topic: String) -> Bool {
        topic.count == 64 && topic.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    // MARK: Evidence from polls

    /// A message a poll found is counted only once it is this old (a push can trail it) and while
    /// it is younger than `pollEvidenceAge`.
    static let pollEvidenceAge: TimeInterval = 12 * 60 * 60
    /// At most this many messages counted from one poll.
    static let pollEvidenceLimit = 3
    /// Message IDs remembered per hash so none is counted twice.
    static let countedIdLimit = 50

    /// Messages a poll found that no push brought (device check of build 62). A message the
    /// extension received is already stored, so a poll's new messages are the ones no wake-up
    /// delivered. Each one sent after the bridge's current watch of the hash began (`watchStart`)
    /// and after the last wake-up, aged `maxMessageAge` to `pollEvidenceAge`, counts once (by ID)
    /// as a weak miss, with no network request (ntfy.sh doesn't cache forwarded poll_requests).
    /// A different `watchStart` is a new watch: the evidence of the old one is dropped first.
    /// Weak misses only ever show "No recent forwarding confirmed"; any wake-up clears them.
    /// Returns the misses counted.
    @discardableResult
    func messagesFoundByPoll(hash: String, watchStart: Date, messages: [(id: String, time: Date)]) -> Int {
        guard Self.isHash(hash), !isWatchedDirectly(hash: hash) else { return 0 }
        let current = now()
        var counted = 0
        update(hash) { entry in
            var changed = false
            // A poll that read the watch before a newer one began must not take the entry back (E7):
            // watch starts only move forward (each is the time of a committed 200).
            if let stored = entry.watchedSince, stored > watchStart { return false }
            if entry.watchedSince != watchStart {
                let arm = (entry.armed, entry.armedAt, entry.lastWake)
                entry = Entry()
                (entry.armed, entry.armedAt, entry.lastWake) = arm
                entry.watchedSince = watchStart
                changed = true
            }
            let floor = max(watchStart, entry.lastWake ?? .distantPast)
            let seen = Set(entry.countedIds ?? [])
            let candidates = messages.filter { message in
                let age = current.timeIntervalSince(message.time)
                return !seen.contains(message.id) && message.time > floor && age >= Self.maxMessageAge && age <= Self.pollEvidenceAge
            }.sorted { $0.time < $1.time }.suffix(Self.pollEvidenceLimit)
            guard !candidates.isEmpty else { return changed }
            entry.weakMisses = (entry.weakMisses ?? 0) + candidates.count
            entry.countedIds = Array(((entry.countedIds ?? []) + candidates.map(\.id)).suffix(Self.countedIdLimit))
            counted = candidates.count
            return true
        }
        return counted
    }

    /// The bridge doesn't hold this hash now: the evidence of the watch that ended goes with it.
    /// `observedAt`: when the caller saw no watch (on the bridge's clock). A watch that began after
    /// it is a new one whose evidence a late observer must not erase (followups-1301 F5).
    func notWatched(hash: String, observedAt: Date? = nil) {
        guard let entry = entries[hash], entry.watchedSince != nil || entry.misses > 0 || entry.weakMisses != nil else { return }
        update(hash, create: false) { entry in
            if let observedAt, let since = entry.watchedSince, since > observedAt { return false }
            let arm = (entry.armed, entry.armedAt, entry.lastWake)
            entry = Entry()
            (entry.armed, entry.armedAt, entry.lastWake) = arm
            return true
        }
    }

    // MARK: Checking

    /// Whether a message at `messageTime` on this hash should be checked now, and after how long;
    /// a yes also reserves the hash and the global slot. nil: don't check (not armed by "Check
    /// again", too old, another check within the minute, one already running, the relay asked for a pause).
    func plan(hash: String, messageTime: Date) -> TimeInterval? {
        let current = now()
        let age = current.timeIntervalSince(messageTime)
        // Nothing is looked up that nobody asked for (review-130d D6).
        guard isArmed(hash: hash) else { return nil }
        // A relayed wake-up from ntf-ai.app's own direct watch would read as the server's forward.
        guard !isWatchedDirectly(hash: hash) else { return nil }
        guard age <= Self.maxMessageAge - 1, age > -Self.slack else { return nil }
        guard NtfyMeHostCooldown.blockedUntil(lock, now: current) == nil else { return nil }
        processLock.lock(); defer { processLock.unlock() }
        guard !inFlight.contains(hash) else { return nil }
        let globalFree: Bool = lock.withLock { () -> Bool in
            if let last = defaults.object(forKey: Self.globalKey) as? Date, current.timeIntervalSince(last) < Self.globalInterval, last <= current {
                return false
            }
            defaults.set(current, forKey: Self.globalKey)
            return true
        } ?? false
        guard globalFree else { return nil }
        inFlight.insert(hash)
        return max(0, Self.minMessageAge - age)
    }

    /// A fresh message from a self-hosted topic was saved by a poll while "Check again" is armed.
    /// Checks only while the relay still holds the time, never counts a message whose wake-up
    /// arrived while it waited or while the check ran, and counts a miss as strong only when
    /// `evidence()` holds as the answer lands. `watch()` is the topic's current watch start (nil
    /// once it is unsubscribed, unwatched or expired); the answer applies only to the same watch,
    /// and never to a topic forgotten meanwhile (review-130d D6).
    func messageArrivedByPoll(baseUrl: String, topic: String, messageTime: Date,
                              watch: @escaping () -> Date? = { .distantPast },
                              evidence: @escaping () -> Bool = { false }, completion: ((Verdict?) -> Void)? = nil) {
        let hash = topicHash(baseUrl: baseUrl, topic: topic)
        guard read != nil, let generation = watch(), let delay = plan(hash: hash, messageTime: messageTime) else { completion?(nil); return }
        guard let tap = entries[hash]?.armedAt else { finish(hash); completion?(nil); return }
        let started = now()
        schedule(delay) {
            // The push may have landed while we waited, or the dispatch ran late.
            if let wake = self.entries[hash]?.lastWake, wake >= started.addingTimeInterval(-Self.maxMessageAge) {
                self.finish(hash); completion?(nil); return
            }
            guard self.now().timeIntervalSince(messageTime) <= Self.maxMessageAge else {
                self.finish(hash); completion?(nil); return
            }
            // Re-checked at dispatch, not only when planned (review-130b #9): a pause the server
            // asked for meanwhile, the setting turned off or the hash no longer admitted stops it.
            guard NtfyMeHostCooldown.blockedUntil(self.lock, now: self.now()) == nil, watch() == generation else {
                self.finish(hash); completion?(nil); return
            }
            // The tap this check answers is still the one in force and inside its 24 hours (E7): an
            // arm that lapsed or was answered meanwhile isn't a reason to send the hash.
            guard let armedAt = self.entries[hash]?.armedAt, armedAt >= tap, self.isArmed(hash: hash) else {
                self.finish(hash); completion?(nil); return
            }
            // The tap this request answers is the one in force now, which may be newer than the
            // one it was planned under (followups-1301 F5): that one is consumed by the answer.
            let dispatchTap = armedAt
            let asked = self.now()
            self.check(hash: hash, messageTime: messageTime) { verdict in
                let strong = verdict == .missed && evidence()
                // Unsubscribed, unwatched or watched anew while the answer was on the wire: it says
                // nothing about the topic as it is now, and must not revive or re-arm it.
                guard watch() == generation else { self.finish(hash); completion?(nil); return }
                // A timeout, an error or an unreadable answer is inconclusive (E7): the tap stays
                // armed for the next eligible message, and nothing is counted.
                guard verdict != .unknown else { self.finish(hash); completion?(verdict); return }
                self.update(hash, create: false) { entry in
                    guard entry.watchedSince == nil || entry.watchedSince == generation else { return false }
                    entry.watchedSince = generation
                    entry.lastCheck = self.now()
                    // This tap is answered; one made while the answer was on the wire stays armed.
                    if (entry.armedAt ?? .distantPast) <= max(started, dispatchTap) { entry.armed = nil; entry.armedAt = nil }
                    // A wake recorded after the check started supersedes its answer.
                    if let wake = entry.lastWake, wake >= asked { return true }
                    switch verdict {
                    case .relayed: entry.misses = 0; entry.weakMisses = nil
                    // Only this one result, kept apart from the automatic count (E2). A miss with
                    // the connection unconfirmed says nothing about the server.
                    case .missed: if strong { entry.misses = 1 }
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
                                        lock: self.lock, now: self.now())
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
