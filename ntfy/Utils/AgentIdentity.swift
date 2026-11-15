import CryptoKit
import Foundation
import Intents
import UIKit
import UserNotifications

/// Who sent an agent's message (agent protocol v2, SPEC 6): an `@name` tag names the agent, and the
/// message's `icon` may carry its picture. The app shows both (or a monogram) on the card and the
/// question page, groups each agent's messages in Notification Center under its own thread, and,
/// where iOS allows it, shows the banner as a message from that agent (INSendMessageIntent).
enum AgentIdentity {
    static let maxNameLength = 32

    /// The first valid `@name` tag: 1-32 characters of letters, digits, space, `.`, `_` or `-`.
    static func name(tags: [String]?) -> String? {
        for tag in tags ?? [] where tag.hasPrefix("@") {
            let name = String(tag.dropFirst())
            guard (1...maxNameLength).contains(name.count), name.trimmingCharacters(in: .whitespaces) == name,
                  name.unicodeScalars.allSatisfy(isNameScalar) else { continue }
            return name
        }
        return nil
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122, 32, 46, 95, 45: return true
        default: return false
        }
    }

    /// The letter on the emerald circle when there is no picture.
    static func monogram(_ name: String) -> String {
        name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }

    /// One Notification Center thread, and one conversation, per agent per topic.
    static func conversationIdentifier(topicURL: String, name: String) -> String { "\(topicURL)#\(name)" }

    /// The picture is fetched only when the topic is end-to-end encrypted (only the password holder
    /// wrote it) or the icon is on the topic's own server. Any other host would learn the phone's IP
    /// address from a URL anyone who can write to the topic picks; the monogram shows instead.
    static func avatarAllowed(iconURL: String?, topicBaseURL: String, encrypted: Bool) -> Bool {
        guard let iconURL, let icon = URLComponents(string: iconURL), icon.scheme?.lowercased() == "https",
              let iconHost = icon.host?.lowercased(), !iconHost.isEmpty, icon.user == nil, icon.password == nil else { return false }
        if encrypted { return true }
        guard let base = URLComponents(string: topicBaseURL), let baseHost = base.host?.lowercased() else { return false }
        let hosts: Set<String> = HostedServer.hosts.contains(baseHost) ? HostedServer.hosts : [baseHost]
        return hosts.contains(iconHost) && (icon.port ?? 443) == (base.port ?? (base.scheme == "http" ? 80 : 443))
    }
}

/// Fetches and keeps agent pictures: an ephemeral session with no cookies or credentials, three
/// seconds, at most 256 KB, PNG, JPEG or HEIC only, scaled down to 128 px and cached in the app group
/// by URL (the newest 50).
final class AgentAvatarStore {
    static let shared = AgentAvatarStore(directory: FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: Config.appGroupId)?
        .appendingPathComponent("agent-avatars", isDirectory: true))

    static let maxBytes = 256 * 1024
    static let timeout: TimeInterval = 3
    static let side: CGFloat = 128
    static let keep = 50

    private let directory: URL?
    private let session: URLSession

    init(directory: URL?, session: URLSession? = nil) {
        self.directory = directory
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    private func file(for url: String) -> URL? {
        let digest = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(digest + ".png")
    }

    func cached(_ url: String) -> Data? {
        guard let file = file(for: url) else { return nil }
        return try? Data(contentsOf: file)
    }

    /// The agent picture for `message`, or nil (monogram) without any request when policy refuses it.
    func avatar(for message: Message, baseUrl: String, completion: @escaping (Data?) -> Void) {
        guard AgentIdentity.name(tags: message.tags) != nil else { completion(nil); return }
        avatar(icon: message.icon, baseUrl: baseUrl, encrypted: message.encryption == .decrypted, completion: completion)
    }

    func avatar(icon: String?, baseUrl: String, encrypted: Bool, completion: @escaping (Data?) -> Void) {
        guard let icon, AgentIdentity.avatarAllowed(iconURL: icon, topicBaseURL: baseUrl, encrypted: encrypted) else {
            completion(nil); return
        }
        load(icon, completion: completion)
    }

    /// The picture as PNG, from the cache or the network; nil on any failure. Never called for a
    /// URL that `AgentIdentity.avatarAllowed` refused.
    func load(_ url: String, completion: @escaping (Data?) -> Void) {
        if let data = cached(url) { completion(data); return }
        guard let remote = URL(string: url) else { completion(nil); return }
        var request = URLRequest(url: remote, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpShouldHandleCookies = false
        session.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                  data.count <= Self.maxBytes, Self.isAllowedImage(data, mimeType: http.mimeType),
                  let png = Self.scaled(data) else { completion(nil); return }
            self.store(png, for: url)
            completion(png)
        }.resume()
    }

    static func isAllowedImage(_ data: Data, mimeType: String?) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        let png = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let jpeg = bytes.starts(with: [0xFF, 0xD8, 0xFF])
        let heic = bytes.count >= 12 && String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp"
            && ["heic", "heix", "mif1", "msf1", "hevc"].contains(String(decoding: bytes[8..<12], as: UTF8.self))
        return png || jpeg || heic
    }

    static func scaled(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.pngData()
    }

    private func store(_ png: Data, for url: String) {
        guard let directory, let file = file(for: url) else { return }
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: file, options: .atomic)
        let entries = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard entries.count > Self.keep else { return }
        let dated = entries.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        dated.sorted { $0.1 < $1.1 }.prefix(entries.count - Self.keep).forEach { try? files.removeItem(at: $0.0) }
    }
}

extension UNMutableNotificationContent {
    /// Groups an agent's message under its own thread: `topicURL#name` (SPEC 6).
    func applyAgentThread(message: Message, baseUrl: String) {
        guard let name = AgentIdentity.name(tags: message.tags) else { return }
        threadIdentifier = AgentIdentity.conversationIdentifier(topicURL: topicUrl(baseUrl: baseUrl, topic: message.topic), name: name)
    }
}

extension AgentIdentity {
    /// The incoming message the banner is drawn from: the agent as sender, one conversation per
    /// agent per topic, its picture when there is one.
    @available(iOS 15.0, *)
    static func messageIntent(body: String, name: String, avatar: Data?, conversation: String) -> INSendMessageIntent {
        let image = avatar.map { INImage(imageData: $0) }
        let sender = INPerson(personHandle: INPersonHandle(value: conversation, type: .unknown),
                              nameComponents: nil, displayName: name, image: image, contactIdentifier: nil,
                              customIdentifier: conversation)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: body,
                                         speakableGroupName: nil, conversationIdentifier: conversation,
                                         serviceName: nil, sender: sender, attachments: nil)
        if let image { intent.setImage(image, forParameterNamed: \.sender) }
        return intent
    }

    /// The banner as a message from the agent, with its name and picture, when iOS accepts it. That
    /// takes the Communication Notifications capability (`entitlement.diff`); without it iOS throws
    /// and the content comes back unchanged, so the banner is today's.
    @available(iOS 15.0, *)
    static func communicationContent(_ content: UNMutableNotificationContent, name: String, avatar: Data?,
                                     conversation: String, donate: Bool = true) -> UNNotificationContent {
        let intent = messageIntent(body: content.body, name: name, avatar: avatar, conversation: conversation)
        if donate {
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            interaction.donate(completion: nil)
        }
        guard let updated = try? content.updating(from: intent) else { return content }
        return keepingDecisions(of: content, in: updated)
    }

    /// What the app decided (alerting, sound, actions, thread, payload, badge, picture attachment)
    /// survives whatever the intent changed.
    static func keepingDecisions(of content: UNNotificationContent, in updated: UNNotificationContent) -> UNNotificationContent {
        guard let result = updated.mutableCopy() as? UNMutableNotificationContent else { return content }
        if #available(iOS 15.0, *) {
            result.interruptionLevel = content.interruptionLevel
            result.relevanceScore = content.relevanceScore
        }
        result.sound = content.sound
        result.categoryIdentifier = content.categoryIdentifier
        result.threadIdentifier = content.threadIdentifier
        result.userInfo = content.userInfo
        result.badge = content.badge
        if result.attachments.isEmpty { result.attachments = content.attachments }
        return result
    }
}
