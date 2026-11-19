import Foundation
import CoreData
import CryptoKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

/// Removes what a log line could carry about the person: topics become per-report hashes; titles,
/// bodies, usernames, passwords, tokens, emails, file names, other hosts and every URL's path and
/// query go. Literal values the app knows (its topics, recent messages, users, hosts) are removed
/// first; patterns catch the rest. Over-redacting is acceptable, leaking is not.
struct FeedbackScrubber {
    static let allowedHosts: Set<String> = ["ntf-ai.app", "ntfy-me.com", "ntfy.sh"]
    /// Values shorter than this are left alone as literals: "OK" or "a" would shred every line.
    static let minimumLiteralLength = 3
    /// A cut-short copy this long or longer is still recognised as the value.
    static let truncatedPrefixLength = 12

    private let topics: [String]
    private let literals: [String]
    private let salt: SymmetricKey

    init(topics: [String], literals: [String], salt: SymmetricKey = SymmetricKey(size: .bits128)) {
        let keep = { (value: String) in value.count >= Self.minimumLiteralLength }
        self.topics = Array(Set(topics.filter(keep))).sorted { $0.count > $1.count }
        // Long messages may appear cut short in a log; their first line and first 40 characters go too.
        var all = Set<String>()
        for value in literals where keep(value) {
            all.insert(value)
            if let first = value.split(whereSeparator: \.isNewline).first.map(String.init), keep(first) { all.insert(first) }
        }
        self.literals = all.sorted { $0.count > $1.count }
        self.salt = salt
    }

    /// The same topic gets the same hash within one report, and a different one in the next.
    func topicToken(_ topic: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(topic.utf8), using: salt)
        return "topic-" + mac.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func clean(_ input: String) -> String {
        var text = input
        for topic in topics {
            text = text.replacingOccurrences(of: topic, with: topicToken(topic), options: [.caseInsensitive])
        }
        text = replace(#"(?i)\b[a-z][a-z0-9+.\-]*://[^\s"'<>]+"#, in: text) { url in
            let parsed = URLComponents(string: url)
            let scheme = parsed?.scheme?.lowercased() ?? "url"
            let host = parsed?.host?.lowercased() ?? ""
            let shownHost = Self.allowedHosts.contains(host) ? host : "<host>"
            let hasMore = !(parsed?.path ?? "").isEmpty && parsed?.path != "/" || parsed?.query != nil
            return "\(scheme)://\(shownHost)" + (hasMore ? "/<path>" : "")
        }
        for literal in literals { text = removeLiteral(literal, from: text) }
        text = replace(#"(?i)[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}"#, in: text) { _ in "<email>" }
        text = replace(#"(?i)\b(bearer|basic)\s+[a-z0-9._~+/=\-]+"#, in: text, template: "$1 <secret>")
        text = replace(#"\btk_[A-Za-z0-9]+"#, in: text) { _ in "<token>" }
        text = replace(#"(?i)\b(password|passwd|pwd|pass|token|secret|authorization|auth|username|user|login|api[_-]?key|credential)(\s*[:=]\s*|\s+)("[^"]*"|\S+)"#,
                       in: text, template: "$1$2<redacted>")
        text = replace(#"(?i)\b(title|message|body|note|reply|answer|text)\s*[:=]\s*.*$"#, in: text, template: "$1: <text>")
        text = replace(#""[^"\n]*"|“[^”\n]*”|'[^'\n]{2,}'"#, in: text) { _ in "\"<text>\"" }
        // Topic names the app no longer knows, e.g. one just removed: "topic x", "topic=x".
        text = replace(#"(?i)\b(topics?)(\s*[:=]\s*|\s+)([A-Za-z0-9_\-]{1,64})"#, in: text) { match in
            guard let range = match.range(of: #"[A-Za-z0-9_\-]+$"#, options: .regularExpression) else { return match }
            let name = String(match[range])
            return name.hasPrefix("topic-") ? match : match.replacingCharacters(in: range, with: topicToken(name))
        }
        text = replace(#"(?i)[^\s/\\:]+\.(?:jpe?g|png|gif|heic|heif|webp|tiff?|bmp|pdf|txt|rtf|md|csv|json|xml|zip|gz|tar|7z|mp4|mov|m4v|m4a|mp3|wav|aac|caf|aiff?|ogg|doc|docx|xls|xlsx|ppt|pptx|pages|numbers|key|apk|ipa|dmg|log)\b"#,
                       in: text) { _ in "<file>" }
        text = replace(#"\b(?:\d{1,3}\.){3}\d{1,3}\b|\b(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}\b"#, in: text) { _ in "<ip>" }
        text = replace(#"(?i)\b(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9\-]{1,62}\b"#, in: text) { host in
            Self.allowedHosts.contains(host.lowercased()) ? host : "<host>"
        }
        // FCM tokens, keys and other opaque strings.
        text = replace(#"[A-Za-z0-9_\-+/]{24,}={0,2}"#, in: text) { _ in "<secret>" }
        return text
    }

    /// Removes the value and any cut-short copy of it: a log may show only its first characters.
    private func removeLiteral(_ literal: String, from input: String) -> String {
        let lead = String(literal.prefix(Self.truncatedPrefixLength))
        var text = input.replacingOccurrences(of: literal, with: "<text>", options: [.caseInsensitive])
        guard literal.count > Self.truncatedPrefixLength else { return text }
        var searchStart = text.startIndex
        while let found = text.range(of: lead, options: [.caseInsensitive], range: searchStart..<text.endIndex) {
            var end = found.upperBound
            var literalIndex = literal.index(literal.startIndex, offsetBy: lead.count)
            while end < text.endIndex, literalIndex < literal.endIndex,
                  String(text[end]).caseInsensitiveCompare(String(literal[literalIndex])) == .orderedSame {
                end = text.index(after: end)
                literalIndex = literal.index(after: literalIndex)
            }
            text.replaceSubrange(found.lowerBound..<end, with: "<text>")
            searchStart = text.index(found.lowerBound, offsetBy: "<text>".count)
        }
        return text
    }

    private func replace(_ pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private func replace(_ pattern: String, in text: String, with transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}

/// The optional diagnostic bundle: counts, flags and cleaned log lines, never content.
enum FeedbackDiagnostics {
    static let maximumBytes = 400_000

    struct Inputs {
        var logLines: [String]
        var topics: [String]
        var literals: [String]
        var serverURLs: [String]
        var settings: [String: Bool]
        var notificationState: [String: String]
        var pushTokenPresent: Bool
        var coreDataBytes: Int
        var diagnostics: [[String: Any]]
    }

    static func serverType(_ baseUrl: String) -> String {
        let host = URLComponents(string: baseUrl)?.host?.lowercased() ?? ""
        return FeedbackScrubber.allowedHosts.contains(host) ? host : "other"
    }

    /// Pure: everything it needs is in `inputs`, so tests can prove what leaves.
    static func bundle(_ inputs: Inputs, scrubber: FeedbackScrubber? = nil) -> [String: Any] {
        let scrubber = scrubber ?? FeedbackScrubber(topics: inputs.topics, literals: inputs.literals)
        var byServer: [String: Int] = [:]
        for url in inputs.serverURLs { byServer[serverType(url), default: 0] += 1 }
        var bundle: [String: Any] = [
            "schema": 1,
            "settings": inputs.settings,
            "notifications": inputs.notificationState,
            "push_token_present": inputs.pushTokenPresent,
            "subscriptions": ["count": inputs.serverURLs.count, "by_server": byServer],
            "core_data_bytes": inputs.coreDataBytes,
            "metrickit": inputs.diagnostics
        ]
        var lines = inputs.logLines.map(scrubber.clean)
        bundle["log"] = lines
        // Drop the oldest lines until the bundle fits.
        while size(of: bundle) > maximumBytes, !lines.isEmpty {
            lines.removeFirst(max(1, lines.count / 8))
            bundle["log"] = lines
        }
        if size(of: bundle) > maximumBytes { bundle["metrickit"] = [] }
        return bundle
    }

    static func size(of object: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: object))?.count ?? Int.max
    }

    /// Reads the app's state on the main queue (Core Data's view context), then builds the bundle.
    static func collect(store: Store = .shared, completion: @escaping ([String: Any]) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
            DispatchQueue.main.async {
                completion(bundle(gather(store: store, notificationSettings: notificationSettings)))
            }
        }
    }

    private static func gather(store: Store, notificationSettings: UNNotificationSettings) -> Inputs {
        let subscriptions = store.getSubscriptions() ?? []
        var literals: [String] = []
        let context = store.context
        let users = (try? context.fetch(NSFetchRequest<User>(entityName: "User"))) ?? []
        for user in users { literals += [user.username, user.password].compactMap { $0 } }
        let request = NSFetchRequest<Notification>(entityName: "Notification")
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: false)]
        request.fetchLimit = 300
        for notification in (try? context.fetch(request)) ?? [] {
            literals += [notification.title, notification.message, notification.attachmentName,
                         notification.attachmentUrl, notification.click].compactMap { $0 }
        }
        for subscription in subscriptions {
            if let name = subscription.customDisplayName { literals.append(name) }
            if let host = URLComponents(string: subscription.baseUrl ?? "")?.host,
               !FeedbackScrubber.allowedHosts.contains(host.lowercased()) { literals.append(host) }
        }
        let defaults = UserDefaults.standard
        let agentDefaults = AgentAck.defaults
        let settings: [String: Bool] = [
            "open_web_links_in_app": defaults.bool(forKey: InAppBrowser.preferenceKey),
            "show_server_addresses": defaults.object(forKey: TopicServerAddressPolicy.preferenceKey) as? Bool
                ?? TopicServerAddressPolicy.defaultValue,
            "agent_confirmations": agentDefaults.object(forKey: AgentAck.showKey) as? Bool ?? true,
            "agent_reminders": agentDefaults.object(forKey: AgentReminder.settingKey) as? Bool ?? true,
            "shake_to_send_feedback": FeedbackSettings.shakeEnabled(),
            "quiet_hours_set": defaults.object(forKey: QuietHours.key) != nil
                || (UserDefaults(suiteName: Store.appGroup)?.object(forKey: QuietHours.key) != nil),
            "custom_default_server": serverType(store.getDefaultBaseUrl()) == "other"
        ]
        let notificationState: [String: String] = [
            "authorization": describe(notificationSettings.authorizationStatus),
            "alert": describe(notificationSettings.alertSetting),
            "sound": describe(notificationSettings.soundSetting),
            "badge": describe(notificationSettings.badgeSetting),
            "lock_screen": describe(notificationSettings.lockScreenSetting),
            "notification_center": describe(notificationSettings.notificationCenterSetting)
        ]
        let storeURL = context.persistentStoreCoordinator?.persistentStores.first?.url
        let storeBytes = ["", "-wal", "-shm"].reduce(0) { total, suffix in
            guard let path = storeURL.map({ $0.path + suffix }),
                  let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else { return total }
            return total + size.intValue
        }
        return Inputs(logLines: RecentLog.shared.snapshot(),
                      topics: subscriptions.compactMap { $0.topic },
                      literals: literals,
                      serverURLs: subscriptions.compactMap { $0.baseUrl },
                      settings: settings,
                      notificationState: notificationState,
                      pushTokenPresent: FirebaseApp.app() != nil && !(Messaging.messaging().fcmToken ?? "").isEmpty,
                      coreDataBytes: storeBytes,
                      diagnostics: metricKitSummaries())
    }

    /// The newest ten reports: kind, period end and Apple's already-projected metadata. No call stacks.
    private static func metricKitSummaries() -> [[String: Any]] {
        let store = DiagnosticReportStore.shared
        return ((try? store.reports()) ?? []).prefix(10).compactMap { report in
            guard let url = try? store.file(for: report), let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let meta = (object["diagnostic"] as? [String: Any])?["diagnosticMetaData"] as? [String: Any] ?? [:]
            return ["kind": report.kind.rawValue,
                    "period_end": FeedbackPayload.minuteTimestamp(report.date),
                    "metadata": meta]
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "not_supported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown"
        }
    }
}
