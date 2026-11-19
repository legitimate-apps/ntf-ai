import Foundation
import CryptoKit
import UIKit

/// In-app feedback, wire format v1 (notes/legs/feedback-2026-11-19/INTERFACE.md in the workspace).
/// The note is sealed to the server's X25519 key on the device; the server stores ciphertext only.
enum FeedbackKind: String, Codable {
    case feedback, dislike
}

enum FeedbackSource: String, Codable {
    case settings, shake
    case reviewPrompt = "review_prompt"
}

struct FeedbackPayload {
    static let maximumNoteLength = 5000
    var note: String
    var email: String?
    var includeLogs: Bool
    var logs: [String: Any]?
    var source: FeedbackSource
    var appVersion = Config.version
    var build = Config.build
    var ios = UIDevice.current.systemVersion
    var deviceModel = FeedbackPayload.currentDeviceModel
    var locale = Locale.current.identifier
    var sentAt = Date()

    /// "iPhone17,1", not the marketing name. The simulator reports the device it simulates.
    static var currentDeviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Minute precision: the exact second adds nothing to a report and narrows who sent it.
    static func minuteTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter.string(from: date)
    }

    func plaintext() throws -> Data {
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let emailValue: Any = trimmedEmail.isEmpty ? NSNull() as Any : trimmedEmail as Any
        let logsValue: Any = includeLogs ? (logs.map { $0 as Any } ?? NSNull() as Any) : NSNull() as Any
        let object: [String: Any] = [
            "note": String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNoteLength)),
            "email": emailValue,
            "app_version": appVersion,
            "build": build,
            "ios": ios,
            "device_model": deviceModel,
            "locale": locale,
            "sent_at": Self.minuteTimestamp(sentAt),
            "include_logs": includeLogs,
            "logs": logsValue,
            "source": source.rawValue
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

struct FeedbackEnvelope: Codable, Equatable {
    var v = 1
    let kind: FeedbackKind
    let epk: String
    let nonce: String
    let ct: String
}

enum FeedbackCrypto {
    /// SERVER_PUBLIC from the feedback server leg; its private half lives only in the operator's vault.
    static let serverPublicKey = "l8eedHyXImaHGCHZbvDiWEpMp7yXVmJBxP7JJdJIWEA"
    static let info = Data("ntf-ai feedback v1".utf8)

    static func aad(_ kind: FeedbackKind) -> Data { Data("v1|\(kind.rawValue)".utf8) }

    static func seal(_ plaintext: Data, kind: FeedbackKind,
                     to serverKey: String = serverPublicKey,
                     ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
                     nonce: ChaChaPoly.Nonce = .init()) throws -> FeedbackEnvelope {
        guard let serverData = TopicEncryption.base64urlDecode(serverKey) else { throw CryptoKitError.incorrectKeySize }
        let server = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverData)
        let epk = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: server)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: epk + serverData,
                                                 sharedInfo: info, outputByteCount: 32)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad(kind))
        return FeedbackEnvelope(kind: kind,
                                epk: TopicEncryption.base64urlEncode(epk),
                                nonce: TopicEncryption.base64urlEncode(Data(nonce)),
                                ct: TopicEncryption.base64urlEncode(box.ciphertext + box.tag))
    }
}

enum FeedbackPostResult: Equatable {
    case accepted
    /// 4xx: the server will never take this body; retrying is pointless.
    case rejected(Int)
    /// Offline, timeout or 5xx: keep it and try again on a later foreground.
    case retryLater
}

protocol FeedbackTransport {
    func post(_ body: Data, completion: @escaping (FeedbackPostResult) -> Void)
}

struct URLSessionFeedbackTransport: FeedbackTransport {
    static let endpoint = URL(string: "https://ntf-ai.app/api/feedback")!
    /// Ephemeral: no cookies, cache or credentials travel with a report.
    private static let session = URLSession(configuration: .ephemeral)

    static func classify(status: Int?) -> FeedbackPostResult {
        guard let status else { return .retryLater }
        switch status {
        case 200..<300: return .accepted
        case 400..<500: return .rejected(status)
        default: return .retryLater
        }
    }

    func post(_ body: Data, completion: @escaping (FeedbackPostResult) -> Void) {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        Self.session.dataTask(with: request) { _, response, error in
            let status = error == nil ? (response as? HTTPURLResponse)?.statusCode : nil
            Log.d("Feedback", "Feedback POST answered \(status.map { "HTTP \($0)" } ?? "with no response")")
            completion(Self.classify(status: status))
        }.resume()
    }
}

/// Envelopes waiting for a connection. They are already encrypted, so the queue never holds the note
/// in the clear. Bounded in count and age; excluded from backup.
final class FeedbackQueue {
    static let shared = FeedbackQueue(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FeedbackQueue", isDirectory: true))
    static let maximumCount = 20
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    private let directory: URL
    private let lock = NSLock()
    private let now: () -> Date

    init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    func enqueue(_ body: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        // Sortable by time, so the oldest is sent (and dropped at the cap) first.
        let name = String(format: "%013.0f-%@.json", now().timeIntervalSince1970 * 1000, UUID().uuidString)
        try body.write(to: directory.appendingPathComponent(name),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        pruneLocked()
    }

    /// Oldest first.
    func pending() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        return files()
    }

    func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneLocked() {
        var items = files()
        let cutoff = (now().timeIntervalSince1970 - Self.maximumAge) * 1000
        for url in items where (Double(url.lastPathComponent.prefix(13)) ?? 0) < cutoff {
            try? FileManager.default.removeItem(at: url)
        }
        items = files()
        for url in items.dropLast(Self.maximumCount) { try? FileManager.default.removeItem(at: url) }
    }
}

enum FeedbackSendResult: Equatable {
    case sent
    case queued
    case failed
}

final class FeedbackSender {
    static let shared = FeedbackSender()
    private let transport: FeedbackTransport
    private let queue: FeedbackQueue
    private var flushing = false
    private let lock = NSLock()

    init(transport: FeedbackTransport = URLSessionFeedbackTransport(), queue: FeedbackQueue = .shared) {
        self.transport = transport
        self.queue = queue
    }

    /// Seals and posts. Offline or a server error keeps the sealed body for the next foreground.
    func send(_ payload: FeedbackPayload, kind: FeedbackKind, completion: @escaping (FeedbackSendResult) -> Void) {
        let body: Data
        do {
            body = try JSONEncoder().encode(FeedbackCrypto.seal(payload.plaintext(), kind: kind))
        } catch {
            Log.e("Feedback", "Could not seal feedback", error)
            completion(.failed)
            return
        }
        transport.post(body) { [queue] result in
            switch result {
            case .accepted:
                completion(.sent)
            case .rejected(let status):
                Log.w("Feedback", "Server refused feedback with HTTP \(status)")
                completion(.failed)
            case .retryLater:
                do {
                    try queue.enqueue(body)
                    completion(.queued)
                } catch {
                    completion(.failed)
                }
            }
        }
    }

    /// Sends what earlier attempts left, oldest first, stopping at the first sign it is still offline.
    func flush(completion: (() -> Void)? = nil) {
        lock.lock()
        guard !flushing else { lock.unlock(); completion?(); return }
        flushing = true
        lock.unlock()
        var remaining = queue.pending()
        func next() {
            guard !remaining.isEmpty else { finish(); return }
            let url = remaining.removeFirst()
            guard let body = try? Data(contentsOf: url) else { queue.remove(url); next(); return }
            transport.post(body) { [queue] result in
                switch result {
                case .accepted, .rejected: queue.remove(url); next()
                case .retryLater: finish()
                }
            }
        }
        func finish() {
            lock.lock(); flushing = false; lock.unlock()
            completion?()
        }
        next()
    }
}
