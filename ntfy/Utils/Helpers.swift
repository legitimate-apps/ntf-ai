import Foundation
import CryptoKit

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

func topicUrl(baseUrl: String, topic: String) -> String {
    return "\(normalizeBaseUrl(baseUrl))/\(topic)"
}

func topicShortUrl(baseUrl: String, topic: String) -> String {
    return shortUrl(url: topicUrl(baseUrl: baseUrl, topic: topic))
}

func topicAuthUrl(baseUrl: String, topic: String) -> String {
    return "\(normalizeBaseUrl(baseUrl))/\(topic)/auth"
}

func topicHash(baseUrl: String, topic: String) -> String {
    let data = Data(topicUrl(baseUrl: normalizeBaseUrl(baseUrl), topic: topic).utf8)
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
    for tag in tags {
        if let emoji = EmojiManager.shared.getEmojiByAlias(alias: tag) {
            emojiTags.append(emoji.getUnicode())
        }
    }
    return emojiTags
}

func parseNonEmojiTags(_ tags: String?) -> [String] {
    return parseAllTags(tags)
        .filter { EmojiManager.shared.getEmojiByAlias(alias: $0) == nil }
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
