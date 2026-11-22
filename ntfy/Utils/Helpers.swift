import Foundation
import CryptoKit
import Combine

/// Two public hosts, one stored server identity. This deliberately does not rename FCM bindings,
/// Keychain entries, topic encryption salts or existing subscriptions.
enum HostedServer {
    static let canonicalBaseURL = "https://ntfy-me.com"
    static let publicBaseURL = "https://ntf-ai.app"
    static let hosts: Set<String> = ["ntfy-me.com", "ntf-ai.app"]

    private static func hostedOrigin(_ parts: URLComponents) -> Bool {
        guard let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), hosts.contains(host),
              parts.user == nil, parts.password == nil else { return false }
        return parts.port == nil || parts.port == (scheme == "https" ? 443 : 80)
    }

    /// Only the new host is rewritten at ingress. Previously stored legacy spellings are not moved.
    static func canonicalBaseURL(_ value: String) -> String {
        let candidate = value.lowercased() == "ntf-ai.app" ? publicBaseURL : value
        guard let parts = URLComponents(string: candidate), hostedOrigin(parts),
              parts.host?.lowercased() == "ntf-ai.app", parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil else { return value }
        return canonicalBaseURL
    }

    /// An agent's HTTP/reply action may include a topic path and query. Preserve those bytes while
    /// routing the new alias through the proven server, without rewriting unrelated origins.
    static func requestURL(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              hostedOrigin(parts), parts.host?.lowercased() == "ntf-ai.app" else { return url }
        parts.scheme = "https"; parts.host = "ntfy-me.com"; parts.port = nil
        return parts.url ?? url
    }

    /// Presentation and generated links change independently of network/persistence identity.
    static func publicURL(_ value: String) -> String {
        guard var parts = URLComponents(string: value), hostedOrigin(parts) else { return value }
        parts.scheme = "https"; parts.host = "ntf-ai.app"; parts.port = nil
        return parts.string ?? value
    }
}

/// iOS blocks connections to a server on the local network until the user allows Local Network
/// access, and the refused request fails as "The Internet connection appears to be offline."
/// For such a server, say what to do instead of reporting a false offline state.
enum LocalNetworkHint {
    static func isLocalHost(_ baseUrl: String) -> Bool {
        guard let host = URLComponents(string: baseUrl)?.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" { return false }
        if !host.contains(".") && !host.contains(":") { return true }
        for suffix in [".local", ".lan", ".home", ".home.arpa", ".internal"] where host.hasSuffix(suffix) { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 && host.split(separator: ".").count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, let b) where (16...31).contains(b): return true
            default: return false
            }
        }
        let v6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return v6.contains(":") && (v6.hasPrefix("fe80:") || v6.hasPrefix("fc") || v6.hasPrefix("fd"))
    }

    static func message(for error: Error, baseUrl: String) -> String? {
        guard (error as? URLError)?.code == .notConnectedToInternet, isLocalHost(baseUrl) else { return nil }
        return String(localized: "NTF-AI couldn't reach this server on your local network. Allow local network access when asked, or turn on Local Network in Settings > NTF-AI, then tap Subscribe again.")
    }
}

func topicUrl(baseUrl: String, topic: String) -> String {
    return "\(normalizeBaseUrl(baseUrl))/\(topic)"
}

func topicShortUrl(baseUrl: String, topic: String) -> String {
    return shortUrl(url: topicUrl(baseUrl: baseUrl, topic: topic))
}

func topicAuthUrl(baseUrl: String, topic: String) -> String {
    return "\(normalizeBaseUrl(baseUrl))/\(topic)/auth"
}

/// Every spelling of ntfy.sh that reaches the same API: http or https, `www.`, any case, the
/// default port, a trailing slash. ntfy.sh names its topics under exactly `https://ntfy.sh`, and
/// that is the address the bridge hashes for a wake-up.
enum NtfyShAddress {
    static let canonical = "https://ntfy.sh"

    /// `https://ntfy.sh` for any spelling of it, nil for anything else (including a path under it).
    static func canonicalize(_ baseUrl: String) -> String? {
        var value = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if ["ntfy.sh", "www.ntfy.sh"].contains(value.lowercased()) { return canonical }
        guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), host == "ntfy.sh" || host == "www.ntfy.sh",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty, parts.port == nil || parts.port == (scheme == "https" ? 443 : 80) else { return nil }
        return canonical
    }

    static func isNtfySh(_ baseUrl: String) -> Bool { canonicalize(baseUrl) != nil }

    /// For new subscriptions (Add sheet, links, managed configuration): store ntfy.sh as
    /// `https://ntfy.sh`, anything else as typed.
    static func ingress(_ baseUrl: String) -> String { canonicalize(baseUrl) ?? baseUrl }

    /// A request URL on any ntfy.sh alias, moved to `https://ntfy.sh` with its path and query kept.
    /// Rows saved as `http://ntfy.sh` or `www.ntfy.sh` keep their stored spelling (and with it
    /// their notifications, read state, cursor, mute, sound and encryption keys); only the
    /// transport changes, as `HostedServer.requestURL` does for the app's own alias.
    static func transportURL(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), host == "ntfy.sh" || host == "www.ntfy.sh",
              parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == (scheme == "https" ? 443 : 80) else { return url }
        guard scheme != "https" || parts.host != "ntfy.sh" || parts.port != nil else { return url }
        parts.scheme = "https"; parts.host = "ntfy.sh"; parts.port = nil
        return parts.url ?? url
    }
}

/// The address a server hashes when it forwards a wake-up for one of its topics. Stored rows keep
/// their spelling; only this identity is canonical, so a row saved as `http://ntfy.sh` binds the
/// same FCM topic the bridge wakes.
func pushIdentityBaseUrl(_ baseUrl: String) -> String {
    NtfyShAddress.canonicalize(baseUrl) ?? normalizeBaseUrl(baseUrl)
}

/// The hash 1.29 and earlier bound, from the stored spelling. Only for tearing those names down.
func legacyTopicHash(baseUrl: String, topic: String) -> String {
    let digest = SHA256.hash(data: Data(topicUrl(baseUrl: normalizeBaseUrl(baseUrl), topic: topic).utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined()
}

func topicHash(baseUrl: String, topic: String) -> String {
    let data = Data(topicUrl(baseUrl: pushIdentityBaseUrl(baseUrl), topic: topic).utf8)
    let digest = SHA256.hash(data: data)
    return digest.compactMap { String(format: "%02x", $0)}.joined()
}

func firebaseTopic(baseUrl: String, topic: String) -> String {
    return normalizeBaseUrl(baseUrl) == normalizeBaseUrl(Config.appBaseUrl)
        ? topic
        : topicHash(baseUrl: baseUrl, topic: topic)
}

func normalizeBaseUrl(_ baseUrl: String) -> String {
    var normalized = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    return HostedServer.canonicalBaseURL(normalized)
}

func shortUrl(url: String) -> String {
    return HostedServer.publicURL(url)
        .replacingOccurrences(of: "http://", with: "")
        .replacingOccurrences(of: "https://", with: "")
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func parseAllTags(_ tags: String?) -> [String] {
    return (tags?.components(separatedBy: ",") ?? [])
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

func parseEmojiTags(_ tags: String?) -> [String] {
    return parseEmojiTags(parseAllTags(tags))
}

func parseEmojiTags(_ tags: [String]?) -> [String] {
    guard let tags = tags else { return [] }
    var emojiTags: [String] = []
    for tag in tags where !ProtocolTag.isHidden(tag) {
        if let emoji = EmojiManager.shared.getEmojiByAlias(alias: tag) {
            emojiTags.append(emoji.getUnicode())
        }
    }
    return emojiTags
}

func parseNonEmojiTags(_ tags: String?) -> [String] {
    return parseAllTags(tags)
        .filter { !ProtocolTag.isHidden($0) && EmojiManager.shared.getEmojiByAlias(alias: $0) == nil }
}

/// A link the app opens for a message: its click URL or a `view` action's URL. A tap opens it with
/// no further question, so only the web and the system's mail, phone and message composers qualify;
/// any other scheme (`shortcuts://`, `file:`, another app's deep link) is refused, so a message
/// can't launch an arbitrary app or action by being tapped.
enum ClickURL {
    static let schemes: Set<String> = ["http", "https", "mailto", "tel", "sms"]

    static func url(from click: String?) -> URL? {
        guard let click = click?.trimmingCharacters(in: .whitespacesAndNewlines), !click.isEmpty,
              let url = URL(string: click), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" { return url.host?.isEmpty == false ? url : nil }
        return url
    }

    /// A `view` action whose URL the app would open; any other kind of action passes.
    static func allows(_ action: Action) -> Bool { action.action != "view" || url(from: action.url) != nil }
}

/// Tags the agent protocol passes between `ntf` and the app. They steer behaviour and are never
/// shown, as chips or emoji. `agent` is not one of them: it says who wrote the message, so it shows.
enum ProtocolTag {
    /// On a question: the agent takes no written answer, so the page offers no reply field.
    static let noReply = "no-reply"
    /// On a written answer: `re-<sequence>` names the question it answers, so two open questions
    /// on one topic stay apart. A message carrying it is the person's own reply.
    static let replyPrefix = "re-"

    static func reply(to sequence: String) -> String { replyPrefix + sequence }

    static func isReply(_ tag: String) -> Bool {
        tag.lowercased().hasPrefix(replyPrefix) && tag.count > replyPrefix.count
    }

    static func isNoReply(_ tag: String) -> Bool { tag.lowercased() == noReply }

    /// On a written answer from 1.27 on: the body is a structured answer to a typed question
    /// (agent protocol v2, SPEC 2), sent with `re-<sequence>`.
    static let answer = "ans"

    static func isAnswer(_ tag: String) -> Bool { tag.lowercased() == answer }

    /// `@name` on an agent's message names the agent (SPEC 6); shown as the sender, not a tag.
    /// Only a tag that names an agent is hidden; any other `@` tag stays a chip, as before 1.27.
    static func isIdentity(_ tag: String) -> Bool { AgentIdentity.name(tags: [tag]) != nil }

    static func isHidden(_ tag: String) -> Bool {
        isNoReply(tag) || isReply(tag) || AgentAck.isAck(tag) || isAnswer(tag) || isIdentity(tag)
    }
}

/// The agent's confirmation that it got the person's answer (ACK-SPEC, build 48): a message on the
/// question's sequence tagged `agent,ack`, its body an optional short note. It never replaces the
/// question: the app keeps the question, records the ack beside it, and shows a receipt. The newest
/// ack on a sequence wins. It never alerts, whatever priority it was sent at.
///
/// An agent that stopped waiting (a timeout) still sends the full settle of ntf 0.1/0.2: the question
/// again, without buttons, with one line appended. Every app version reads that as resolved, so the
/// quieter outcome needs no second tag. `settle(body:tags:hasActions:)` reads those lines.
enum AgentAck {
    static let tag = "ack"
    /// What ntf sends when there is no note; stock ntfy clients show the body as it is.
    static let defaultBody = "\u{2713} Got it"
    /// Settings, "Show agent confirmations". Default on. In the app group, so the extension reads it.
    static let showKey = "showAgentConfirmations"

    static var defaults: UserDefaults { UserDefaults(suiteName: Config.appGroupId) ?? .standard }

    static func isAck(_ tag: String) -> Bool { tag.lowercased() == Self.tag }
    static func isAck(tags: [String]?) -> Bool { tags?.contains(where: isAck) == true }

    static func showsConfirmations(_ defaults: UserDefaults = AgentAck.defaults) -> Bool {
        defaults.object(forKey: showKey) as? Bool ?? true
    }

    /// The body without a leading check, lower-cased: "\u{2713} Got: Lock" is "got: lock".
    private static func bare(_ body: String?) -> String {
        var text = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, "\u{2713}\u{2714}\u{2705}".contains(first) { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A body an agent sends when it has nothing to add: "\u{2713} Got it", "\u{2713} Got your reply" or
    /// "\u{2713} Got: Lock" (what `ntf ask` sends). These are never shown as a note.
    static func isDefaultBody(_ body: String?) -> Bool {
        let text = bare(body).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        return text.isEmpty || text == "got it" || text == "got your reply" || text.hasPrefix("got: ")
    }

    /// The note under "Agent got it", or nil for a default body.
    static func note(fromBody body: String?) -> String? {
        isDefaultBody(body) ? nil : body?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer an ack names ("\u{2713} Got: Lock" is "Lock"), for a question answered on another device.
    static func answer(fromBody body: String?) -> String? {
        let text = bare(body)
        guard text.lowercased().hasPrefix("got: ") else { return nil }
        let label = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    struct Record: Codable, Equatable {
        /// The ack's own message id and time.
        var id: String
        var time: Int64
        var note: String?
        var answer: String?
        /// The id of the question version it confirms: a new question on the sequence waits again.
        var version: String
        /// `ntf withdraw` took the question back (a `message_delete` on its sequence, SPEC 7) rather
        /// than confirm it: kept with the acks so the app and the extension share it.
        var withdrawn: Bool? = nil
    }

    /// A person's answer to a question, seen on its topic (a message tagged `ans` and `re-<sequence>`):
    /// the answer in words, never the raw body, so a form reads "Branch: main · Replicas: 2".
    struct SeenAnswer: Codable, Equatable {
        /// The answer message's own id and time.
        var id: String
        var time: Int64
        /// The answer in words.
        var label: String
        /// Written text or a form: the page says "You replied" and shows `label` under it.
        var written: Bool
        /// The id of the question version it answers.
        var version: String
        /// Read from an end-to-end encrypted message, so it came from someone with the topic's
        /// password. Only such an answer silences the question's banner and reminders: on a plain
        /// topic any writer could have sent it.
        var verified: Bool? = nil
    }

    enum Outcome: Equatable {
        /// The agent got the answer; the label when the line names it.
        case got(String?)
        /// No answer came, or the agent stopped waiting.
        case movedOn
    }

    struct Settle: Equatable {
        /// The question as it was, without the appended line.
        var question: String
        var outcome: Outcome
    }

    /// A full settle (ntf 0.1/0.2): the question's text, a blank line, and one of "\u{2713} Agent got: X",
    /// "\u{2713} Agent got your reply", "No answer in 10 min; the agent moved on" or "The agent stopped
    /// waiting; no answer needed". Only on an agent message without buttons.
    static func settle(body: String?, tags: [String], hasActions: Bool) -> Settle? {
        guard !hasActions, tags.contains(where: { $0.lowercased() == "agent" }) else { return nil }
        let text = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let question: String
        let line: String
        if let split = text.range(of: "\n\n", options: .backwards) {
            question = String(text[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            line = String(text[split.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            question = ""
            line = text
        }
        let outcome: Outcome
        if line.hasPrefix("\u{2713} Agent got: ") {
            let label = line.dropFirst("\u{2713} Agent got: ".count).trimmingCharacters(in: .whitespaces)
            outcome = .got(label.isEmpty ? nil : label)
        } else if line == "\u{2713} Agent got your reply" || line == "\u{2713} Agent got it" {
            outcome = .got(nil)
        } else if line.hasPrefix("No answer in "), line.hasSuffix("; the agent moved on") {
            outcome = .movedOn
        } else if line == "The agent stopped waiting; no answer needed" {
            outcome = .movedOn
        } else {
            return nil
        }
        return Settle(question: question, outcome: outcome)
    }
}

/// The acks received, in the app group's defaults so the extension and the app share them. Keyed
/// like `AnswerKey.id`: server, topic and sequence. No Core Data entity, so no migration.
final class AckLog: ObservableObject {
    static let shared = AckLog(defaults: AgentAck.defaults, observesOtherProcesses: true)
    static let defaultsKey = "agentAcks.v1"
    static let didChange = Foundation.Notification.Name("ntfy.ackLogDidChange")
    /// Posted across processes after every save. The extension records an ack that arrives by push,
    /// often before the app's own poll sees it (and the app then skips it as already seen), so
    /// without this an open page whose question is already read never learns of the ack.
    static let darwinName = "\(Config.appGroupId).agentAcks"
    /// Old acks drop out past this many; a question is out of Waiting after seven days anyway.
    static let limit = 500

    /// Bumped on the main queue whenever an ack lands here, or the extension may have added one.
    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults, observesOtherProcesses: Bool = false) {
        self.defaults = defaults
        if observesOtherProcesses {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    Unmanaged<AckLog>.fromOpaque(observer).takeUnretainedValue().changed()
                },
                Self.darwinName as CFString, nil, .deliverImmediately)
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    /// Redraw what shows acks: one was saved here, or the extension may have saved one meanwhile.
    func changed() {
        DispatchQueue.main.async {
            self.revision &+= 1
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    static func key(baseUrl: String, topic: String, sequence: String) -> String {
        "\(normalizeBaseUrl(baseUrl))|\(topic)|\(sequence)"
    }

    private func all() -> [String: AgentAck.Record] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: AgentAck.Record].self, from: data) else { return [:] }
        return decoded
    }

    /// The ack on this version of the question, if any.
    func record(forKey key: String, version: String?) -> AgentAck.Record? {
        lock.lock(); defer { lock.unlock() }
        guard let record = all()[key], version == nil || record.version == version else { return nil }
        return record
    }

    /// Keeps the newest ack per question version. False when an ack as new or newer is already there.
    @discardableResult
    func save(_ record: AgentAck.Record, forKey key: String) -> Bool {
        lock.lock()
        var records = all()
        if let current = records[key], current.version == record.version,
           current.time > record.time || current.id == record.id {
            lock.unlock()
            return false
        }
        records[key] = record
        if records.count > Self.limit {
            for old in records.sorted(by: { $0.value.time < $1.value.time }).prefix(records.count - Self.limit) {
                records.removeValue(forKey: old.key)
            }
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.defaultsKey) }
        lock.unlock()
        changed()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.darwinName as CFString), nil, nil, true)
        return true
    }

    /// Answers to a question seen on its topic (agent protocol v2, SPEC 2): a message tagged `ans`
    /// and `re-<sequence>`, sent from this device or another one. The store keeps no row for it;
    /// the question shows it instead. Kept beside the acks, so the app and the extension share it
    /// and the same redraw covers both.
    static let answersKey = "agentAnswers.v1"

    private func answers() -> [String: AgentAck.SeenAnswer] {
        guard let data = defaults.data(forKey: Self.answersKey),
              let decoded = try? JSONDecoder().decode([String: AgentAck.SeenAnswer].self, from: data) else { return [:] }
        return decoded
    }

    /// The answer seen for this version of the question, if any.
    func answer(forKey key: String, version: String?) -> AgentAck.SeenAnswer? {
        lock.lock(); defer { lock.unlock() }
        guard let answer = answers()[key], version == nil || answer.version == version else { return nil }
        return answer
    }

    /// Keeps the newest answer per question version. False when one as new or newer is already there.
    @discardableResult
    func saveAnswer(_ answer: AgentAck.SeenAnswer, forKey key: String) -> Bool {
        lock.lock()
        var entries = answers()
        // For one question version an answer read from an encrypted message outranks a plain one,
        // which any topic writer can publish: a plain answer never replaces it, it always replaces a
        // plain one. Between answers of the same standing the newest wins.
        if let current = entries[key], current.version == answer.version, current.id == answer.id
            || ((current.verified == true) == (answer.verified == true) ? current.time > answer.time
                                                                          : current.verified == true) {
            lock.unlock()
            return false
        }
        entries[key] = answer
        if entries.count > Self.limit {
            for old in entries.sorted(by: { $0.value.time < $1.value.time }).prefix(entries.count - Self.limit) {
                entries.removeValue(forKey: old.key)
            }
        }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.answersKey) }
        lock.unlock()
        changed()
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.darwinName as CFString), nil, nil, true)
        return true
    }
}

/// Topic names ntfy accepts: letters, digits, dash and underscore, at most 64 characters.
func isValidTopicName(_ topic: String) -> Bool {
    topic.range(of: "^[-_A-Za-z0-9]{1,64}$", options: .regularExpression) != nil
}

/// The publish commands the app shows people to copy and run.
///
/// Every one carries the full URL, scheme included. The empty-topic screen used to show
/// `curl -d "hi" ntfy-me.com/<topic>`: without a scheme curl sends plain http, the server answers
/// 301, curl does not follow it for a POST body, and the message never arrives. A first-time user
/// copying the one example the app gives them then concludes the app does not work.
enum PublishCommand {
    /// What the server needs beyond the URL, as far as the copied command can carry it. Secrets are
    /// never put in the command: curl asks for the password, and header values are placeholders.
    struct Auth: Equatable {
        var username: String?
        var accessToken = false
        var headerNames: [String] = []

        static let none = Auth()
        var isEmpty: Bool { username == nil && !accessToken && headerNames.isEmpty }
    }

    /// Stands in for a custom header's value, which stays in the Keychain.
    static let headerValuePlaceholder = "<value>"

    static func publishUrl(baseUrl: String, topic: String) -> String {
        let url = HostedServer.publicURL(topicUrl(baseUrl: baseUrl, topic: topic))
        let lowered = url.lowercased()
        return lowered.hasPrefix("https://") || lowered.hasPrefix("http://") ? url : "https://\(url)"
    }

    static func simple(baseUrl: String, topic: String, auth: Auth = .none) -> String {
        command(["-d", "Hello from NTF-AI"], baseUrl: baseUrl, topic: topic, auth: auth)
    }

    /// An agent's first message, tagged `agent` as the agent guide teaches, so written replies
    /// (untagged) can be told apart from it.
    static func agentSend(baseUrl: String, topic: String, auth: Auth = .none) -> String {
        command(["-H", "Tags: agent", "-d", "Build finished"], baseUrl: baseUrl, topic: topic, auth: auth)
    }

    static func titled(baseUrl: String, topic: String, auth: Auth = .none) -> String {
        command(["-H", "Title: Backup finished", "-H", "Priority: high", "-d", "All files copied"],
                baseUrl: baseUrl, topic: topic, auth: auth)
    }

    /// POSIX single-quoting: everything between single quotes is literal, so `&`, `$`, `;`, spaces
    /// or `!` in a custom server's base path reach curl as one argument. A single quote inside is
    /// closed, escaped and reopened. A self-hosted base URL like `https://example.com/ntfy&prod`
    /// otherwise backgrounds a truncated curl and runs `prod/<topic>` as a command.
    static func shellQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func command(_ options: [String], baseUrl: String, topic: String, auth: Auth) -> String {
        var parts = ["curl"]
        if let username = auth.username {
            // `--user name` without a password makes curl prompt for it, so it never lands in a
            // clipboard, shell history or a screenshot.
            parts += ["--user", shellQuoted(username)]
        }
        if auth.accessToken {
            parts += ["-H", shellQuoted("Authorization: Bearer <token>")]
        }
        for name in auth.headerNames {
            parts += ["-H", shellQuoted("\(name): \(headerValuePlaceholder)")]
        }
        for (index, option) in options.enumerated() {
            parts.append(index % 2 == 0 ? option : shellQuoted(option))
        }
        parts.append(shellQuoted(publishUrl(baseUrl: baseUrl, topic: topic)))
        return parts.joined(separator: " ")
    }
}

/// Suggests a topic name for someone who has never picked one.
///
/// On a public server the topic name is the only thing keeping a topic private: anyone who knows
/// it can read and send to it. So the suggestion is a short readable word plus 16 random characters
/// (about 79 bits), drawn without look-alike characters (0/O, 1/l/I) because people retype these on
/// other machines. The default random source is the system's cryptographically secure one.
enum TopicNameGenerator {
    static let prefix = "alerts-"
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    static let randomCharacterCount = 16

    static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    static func random<G: RandomNumberGenerator>(using generator: inout G) -> String {
        var characters: [Character] = []
        for index in 0..<randomCharacterCount {
            if index > 0 && index % 4 == 0 { characters.append("-") }
            characters.append(alphabet.randomElement(using: &generator)!)
        }
        return prefix + String(characters)
    }
}
