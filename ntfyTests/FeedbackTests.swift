import XCTest
import CryptoKit
@testable import ntfy

/// Opens an envelope the way the server does, written separately from the app's sealing code.
private func openEnvelope(_ envelope: FeedbackEnvelope, server: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
    func decode(_ text: String) throws -> Data {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return try XCTUnwrap(Data(base64Encoded: base64), "not base64url: \(text)")
    }
    let epk = try decode(envelope.epk)
    let shared = try server.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk))
    let ikm = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
    let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: epk + server.publicKey.rawRepresentation,
                                     info: Data("ntf-ai feedback v1".utf8), outputByteCount: 32)
    let ct = try decode(envelope.ct)
    let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: decode(envelope.nonce)),
                                       ciphertext: ct.dropLast(16), tag: ct.suffix(16))
    return try ChaChaPoly.open(box, using: key, authenticating: Data("v1|\(envelope.kind.rawValue)".utf8))
}

private func b64url(_ data: Data) -> String { TopicEncryption.base64urlEncode(data) }

final class FeedbackCryptoTests: XCTestCase {
    func testSealedEnvelopeOpensWithTheServerKeyAndBindsTheKind() throws {
        let server = Curve25519.KeyAgreement.PrivateKey()
        let plaintext = Data(#"{"note":"hello"}"#.utf8)
        let envelope = try FeedbackCrypto.seal(plaintext, kind: .dislike, to: b64url(server.publicKey.rawRepresentation))
        XCTAssertEqual(try openEnvelope(envelope, server: server), plaintext)
        XCTAssertEqual(envelope.v, 1)
        for field in [envelope.epk, envelope.nonce, envelope.ct] {
            XCTAssertNil(field.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), "b64url without padding: \(field)")
        }
        XCTAssertEqual(envelope.epk.count, 43) // 32 bytes
        XCTAssertEqual(envelope.nonce.count, 16) // 12 bytes
        // The kind is authenticated: relabelled feedback doesn't open.
        let relabelled = FeedbackEnvelope(kind: .feedback, epk: envelope.epk, nonce: envelope.nonce, ct: envelope.ct)
        XCTAssertThrowsError(try openEnvelope(relabelled, server: server))
        XCTAssertThrowsError(try openEnvelope(envelope, server: Curve25519.KeyAgreement.PrivateKey()))
        // Every send uses a fresh ephemeral key and nonce.
        let again = try FeedbackCrypto.seal(plaintext, kind: .dislike, to: b64url(server.publicKey.rawRepresentation))
        XCTAssertNotEqual(again.epk, envelope.epk)
        XCTAssertNotEqual(again.nonce, envelope.nonce)
    }

    func testWireJSONHasExactlyTheV1Fields() throws {
        let envelope = try FeedbackCrypto.seal(Data("x".utf8), kind: .feedback)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "kind", "epk", "nonce", "ct"])
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["kind"] as? String, "feedback")
        XCTAssertEqual(FeedbackCrypto.serverPublicKey.count, 43)
    }

    /// The server leg's known-answer vector (TEST-VECTOR.json, throwaway keys): the app's sealing
    /// must give its envelope byte for byte.
    func testServerKnownAnswerVector() throws {
        func decode(_ s: String) -> Data { TopicEncryption.base64urlDecode(s)! }
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: decode("ZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5_gIGCg4Q"))
        let plaintext = Data("{\"note\":\"Test vector: ünïcode ok\",\"email\":null,\"app_version\":\"1.29.0\",\"build\":\"50\",\"ios\":\"26.1\",\"device_model\":\"iPhone17,1\",\"locale\":\"en_US\",\"sent_at\":\"2026-11-19T04:10Z\",\"include_logs\":false,\"logs\":null,\"source\":\"settings\"}".utf8)
        let envelope = try FeedbackCrypto.seal(plaintext, kind: .feedback, to: "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw",
                                               ephemeral: ephemeral, nonce: ChaChaPoly.Nonce(data: decode("yMnKy8zNzs_Q0dLT")))
        XCTAssertEqual(envelope, FeedbackEnvelope(kind: .feedback, epk: "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY", nonce: "yMnKy8zNzs_Q0dLT",
            ct: "Oq5nMTbDSVTroNa5bBXSstcpK5Gve9JvZTR6sVkI9fJG6RbmCtaBxdaaPh7WVKgYI0JEKwkbZBU3a1I9pw5aDHvH9ZxkAXy3VMl6xmIhYf1HA1h1vK0NlYUJlMQ3809sHqX6G8HapPq4EiwaUpM5jeVO0eCvpfB8ahI60X7bCU_IG18kEz6Vo831Yvr04hWfFLculvrb1WE2xsXV4mu_RqD_esVwbw-f_VShqq9MAbqQ9Ag46r35V7VpYDpXijrWp-MZVy6FL4JHVNpcpqp_bKp1WeVkZnr7Vx21ITAmojhWJDcjgDwPWmuu_pZT3gW865U"))
        let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: decode("AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"))
        XCTAssertEqual(try openEnvelope(envelope, server: server), plaintext)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? NSDictionary)
        XCTAssertEqual(wire, { () -> NSDictionary in
            ["v": 1, "kind": "feedback", "epk": "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY", "nonce": "yMnKy8zNzs_Q0dLT", "ct": "Oq5nMTbDSVTroNa5bBXSstcpK5Gve9JvZTR6sVkI9fJG6RbmCtaBxdaaPh7WVKgYI0JEKwkbZBU3a1I9pw5aDHvH9ZxkAXy3VMl6xmIhYf1HA1h1vK0NlYUJlMQ3809sHqX6G8HapPq4EiwaUpM5jeVO0eCvpfB8ahI60X7bCU_IG18kEz6Vo831Yvr04hWfFLculvrb1WE2xsXV4mu_RqD_esVwbw-f_VShqq9MAbqQ9Ag46r35V7VpYDpXijrWp-MZVy6FL4JHVNpcpqp_bKp1WeVkZnr7Vx21ITAmojhWJDcjgDwPWmuu_pZT3gW865U"]
        }())
    }

    func testPayloadCarriesOnlyTheDeclaredFields() throws {
        var payload = FeedbackPayload(note: "  It works  ", email: "  ", includeLogs: false, logs: ["log": ["x"]], source: .shake)
        payload.sentAt = Date(timeIntervalSince1970: 1_795_000_000.9)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.plaintext()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["note", "email", "app_version", "build", "ios", "device_model", "locale",
                                          "sent_at", "include_logs", "logs", "source"])
        XCTAssertEqual(object["note"] as? String, "It works")
        XCTAssertTrue(object["email"] is NSNull, "a blank email is null")
        XCTAssertTrue(object["logs"] is NSNull, "unchecked box: no logs, even if some were gathered")
        XCTAssertEqual(object["include_logs"] as? Bool, false)
        XCTAssertEqual(object["source"] as? String, "shake")
        XCTAssertEqual(object["sent_at"] as? String, "2026-11-18T11:06Z")
        XCTAssertNotNil((object["device_model"] as? String)?.range(of: #"^(iPhone|iPad|iPod)\d+,\d+$"#, options: .regularExpression))

        payload.includeLogs = true
        payload.email = "me@example.org"
        payload.source = .reviewPrompt
        payload.note = String(repeating: "a", count: 6000)
        let checked = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.plaintext()) as? [String: Any])
        XCTAssertNotNil(checked["logs"] as? [String: Any])
        XCTAssertEqual(checked["email"] as? String, "me@example.org")
        XCTAssertEqual(checked["source"] as? String, "review_prompt")
        XCTAssertEqual((checked["note"] as? String)?.count, 5000)
    }
}

final class FeedbackScrubberTests: XCTestCase {
    private let topic = "garage-door-alerts"
    private let title = "Backup finished on nas01"
    private let body = "Your photos library copied 4,312 files"
    private let host = "push.example-home.net"
    private let username = "alice_admin"
    private let password = "hunter2-correct-horse"
    private let token = "tk_AgQdq7mVBoFD37zQVN29RhuMzNIz2"
    private let fcm = "fGx9Lq2Z0b:APA91bHxk3m2-Vq8zPpL0aR7sT5uW1yXcD3eF6gH"
    private let email = "alex.reader@example.com"
    private let attachment = "IMG_4821.HEIC"

    private var log: [String] {
        [
            "12:00:01 D Store: Subscribing to \(topic) on https://\(host)/\(topic)?since=all&auth=abc",
            "12:00:02 D AppDelegate: Notification title: \(title)",
            "12:00:03 D AppDelegate: Showing \"\(body)\"",
            "12:00:04 I ApiService: user \(username) password=\(password)",
            "12:00:05 D ApiService: Authorization: Bearer \(token)",
            "12:00:06 D AppDelegate: Firebase token received: \(fcm)",
            "12:00:07 D Compose: reply-to \(email)",
            "12:00:08 D Attachments: downloading \(attachment) (2 MB)",
            "12:00:09 D Poll: polling https://ntfy.sh/mytopic/json?poll=1 and https://ntf-ai.app",
            "12:00:10 D Poll: topic old-removed-topic gone; server 192.168.1.20 down",
            "12:00:11 D Store: \(body.prefix(20))",
        ]
    }

    func testNothingSensitiveLeavesInTheBundle() throws {
        let scrubber = FeedbackScrubber(topics: [topic], literals: [title, body, username, password, attachment, host])
        let inputs = FeedbackDiagnostics.Inputs(
            logLines: log, topics: [topic], literals: [title, body, username, password, attachment, host],
            serverURLs: ["https://\(host)", "https://ntf-ai.app", "https://ntfy.sh", "https://ntfy-me.com"],
            settings: ["shake_to_send_feedback": true], notificationState: ["authorization": "authorized"],
            pushTokenPresent: true, coreDataBytes: 4096, diagnostics: [])
        let bundle = FeedbackDiagnostics.bundle(inputs, scrubber: scrubber)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: bundle), as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        for secret in [topic, title, body, String(body.prefix(20)), host, "example-home", username, password, token,
                       "AgQdq7mVBoFD", fcm, "APA91b", email, attachment, "IMG_4821", "since=all", "auth=abc", "mytopic",
                       "poll=1", "old-removed-topic", "192.168.1.20", "nas01"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(secret), "leaked \(secret): \(json)")
        }
        // What is meant to remain does.
        XCTAssertTrue(json.contains("https://ntfy.sh/<path>"))
        XCTAssertTrue(json.contains("https://ntf-ai.app"))
        XCTAssertTrue(json.contains(scrubber.topicToken(topic)))
        XCTAssertTrue(json.contains("Subscribing to"))
        let byServer = try XCTUnwrap((bundle["subscriptions"] as? [String: Any])?["by_server"] as? [String: Int])
        XCTAssertEqual(byServer, ["other": 1, "ntf-ai.app": 1, "ntfy.sh": 1, "ntfy-me.com": 1])
        XCTAssertEqual(bundle["push_token_present"] as? Bool, true)
    }

    /// A message that contains a topic name or a URL is still removed whole: literals are matched against the
    /// original text, before topics and URLs are rewritten into a form the literal no longer matches.
    func testAMessageContainingATopicOrURLIsRemovedWhole() {
        let topicName = "wellhouse-alarms"
        let message = "Pump on \(topicName) tripped, see https://example-home.lan/pump Kestrelward"
        let scrubber = FeedbackScrubber(topics: [topicName], literals: [message, "example-home.lan"])
        let cleaned = scrubber.clean("12:00:01 D Store: \(message)\n12:00:02 D Poll: https://example-home.lan/x/y ok")
        for secret in ["Kestrelward", "tripped", "Pump on", topicName, "example-home", "/pump", "/x/y"] {
            XCTAssertFalse(cleaned.localizedCaseInsensitiveContains(secret), "leaked \(secret): \(cleaned)")
        }
        XCTAssertTrue(cleaned.contains("Store: <text>"), cleaned)
    }

    func testTopicHashesAreStableWithinAReportAndDifferAcrossReports() {
        let one = FeedbackScrubber(topics: [topic], literals: [])
        let two = FeedbackScrubber(topics: [topic], literals: [])
        XCTAssertEqual(one.clean("a \(topic) b \(topic)"), "a \(one.topicToken(topic)) b \(one.topicToken(topic))")
        XCTAssertNotEqual(one.topicToken(topic), two.topicToken(topic))
        XCTAssertNotNil(one.topicToken(topic).range(of: #"^topic-[0-9a-f]{8}$"#, options: .regularExpression))
    }

    func testBundleStaysUnderTheCap() throws {
        let line = String(repeating: "x ", count: 140)
        let inputs = FeedbackDiagnostics.Inputs(logLines: Array(repeating: line, count: 3000), topics: [], literals: [],
                                                serverURLs: [], settings: [:], notificationState: [:],
                                                pushTokenPresent: false, coreDataBytes: 0, diagnostics: [])
        let bundle = FeedbackDiagnostics.bundle(inputs)
        XCTAssertLessThanOrEqual(FeedbackDiagnostics.size(of: bundle), FeedbackDiagnostics.maximumBytes)
        XCTAssertFalse((bundle["log"] as? [String] ?? []).isEmpty, "trims the oldest lines, keeps the newest")
    }

    func testRecentLogKeepsTheNewestLinesOnly() {
        let recent = RecentLog()
        for i in 0..<(RecentLog.capacity + 5) { recent.append("line \(i) " + String(repeating: "y", count: 400)) }
        let lines = recent.snapshot()
        XCTAssertEqual(lines.count, RecentLog.capacity)
        XCTAssertTrue(lines.last?.contains("line \(RecentLog.capacity + 4)") ?? false)
        XCTAssertTrue(lines.allSatisfy { $0.count <= RecentLog.maximumLineLength + 9 })
    }
}

private final class FakeTransport: FeedbackTransport {
    var results: [FeedbackPostResult]
    var posted: [Data] = []
    init(_ results: [FeedbackPostResult]) { self.results = results }
    func post(_ body: Data, completion: @escaping (FeedbackPostResult) -> Void) {
        posted.append(body)
        completion(results.isEmpty ? .accepted : results.removeFirst())
    }
}

final class FeedbackQueueTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedbackQueue-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func payload() -> FeedbackPayload {
        FeedbackPayload(note: "note", email: nil, includeLogs: false, logs: nil, source: .settings)
    }

    func testStatusClassification() {
        XCTAssertEqual(URLSessionFeedbackTransport.classify(status: 202), .accepted)
        XCTAssertEqual(URLSessionFeedbackTransport.classify(status: 400), .rejected(400))
        XCTAssertEqual(URLSessionFeedbackTransport.classify(status: 429), .rejected(429))
        XCTAssertEqual(URLSessionFeedbackTransport.classify(status: 500), .retryLater)
        XCTAssertEqual(URLSessionFeedbackTransport.classify(status: 503), .retryLater)
        XCTAssertEqual(URLSessionFeedbackTransport.classify(status: nil), .retryLater, "offline")
    }

    func testOfflineQueuesTheSealedBodyAndFourHundredsAreDropped() throws {
        let queue = FeedbackQueue(directory: directory)
        var results: [FeedbackSendResult] = []
        FeedbackSender(transport: FakeTransport([.retryLater]), queue: queue).send(payload(), kind: .feedback) { results.append($0) }
        FeedbackSender(transport: FakeTransport([.rejected(400)]), queue: queue).send(payload(), kind: .feedback) { results.append($0) }
        FeedbackSender(transport: FakeTransport([.accepted]), queue: queue).send(payload(), kind: .feedback) { results.append($0) }
        XCTAssertEqual(results, [.queued, .failed, .sent])
        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        let stored = try Data(contentsOf: pending[0])
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("note"), "the queue holds ciphertext only")
        XCTAssertNoThrow(try JSONDecoder().decode(FeedbackEnvelope.self, from: stored))
    }

    func testFlushSendsOldestFirstAndStopsWhileStillOffline() throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let queue = FeedbackQueue(directory: directory, now: { clock })
        for i in 0..<3 { try queue.enqueue(Data("body\(i)".utf8)); clock += 1 }
        let offline = FakeTransport([.accepted, .retryLater])
        let done = expectation(description: "flush")
        FeedbackSender(transport: offline, queue: queue).flush { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(offline.posted.map { String(decoding: $0, as: UTF8.self) }, ["body0", "body1"])
        XCTAssertEqual(queue.pending().count, 2, "the one that failed and the one never tried stay")

        let online = FakeTransport([.rejected(400), .accepted])
        let again = expectation(description: "flush again")
        FeedbackSender(transport: online, queue: queue).flush { again.fulfill() }
        wait(for: [again], timeout: 1)
        XCTAssertEqual(online.posted.map { String(decoding: $0, as: UTF8.self) }, ["body1", "body2"])
        XCTAssertTrue(queue.pending().isEmpty, "a 4xx is never retried")
    }

    func testQueueIsBoundedInCountAndAge() throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let queue = FeedbackQueue(directory: directory, now: { clock })
        for i in 0..<(FeedbackQueue.maximumCount + 3) { try queue.enqueue(Data("b\(i)".utf8)); clock += 1 }
        let pending = queue.pending()
        XCTAssertEqual(pending.count, FeedbackQueue.maximumCount)
        XCTAssertEqual(try String(decoding: Data(contentsOf: pending[0]), as: UTF8.self), "b3", "the oldest go first")
        clock += FeedbackQueue.maximumAge + 60
        XCTAssertTrue(queue.pending().isEmpty)
    }
}

final class ReviewPromptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func inputs(_ change: (inout ReviewPromptPolicy.Inputs) -> Void = { _ in }) -> ReviewPromptPolicy.Inputs {
        var i = ReviewPromptPolicy.Inputs(current: "1.28.0", lastPrompted: nil, lastDislike: nil,
                                          firstLaunch: now.addingTimeInterval(-7 * day), launchCount: 5,
                                          goodMomentThisSession: true, crashSinceLastLaunch: false,
                                          questionWaiting: false, notificationsAuthorized: true,
                                          topicsHealthy: true, now: now)
        change(&i)
        return i
    }

    func testEligibilityRules() {
        XCTAssertTrue(ReviewPromptPolicy.shouldAsk(inputs()))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.firstLaunch = self.now.addingTimeInterval(-7 * self.day + 1) }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.firstLaunch = nil }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.launchCount = 4 }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.launchCount = 1 }), "never on first launch")
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.goodMomentThisSession = false }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.crashSinceLastLaunch = true }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.questionWaiting = true }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.lastPrompted = "1.28.0" }), "once per version")
        XCTAssertTrue(ReviewPromptPolicy.shouldAsk(inputs { $0.lastPrompted = "1.27.0" }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs {
            $0.lastPrompted = "1.27.0"; $0.lastDislike = self.now.addingTimeInterval(-119 * self.day)
        }), "Not really keeps it away for 120 days, even on a new version")
        XCTAssertTrue(ReviewPromptPolicy.shouldAsk(inputs { $0.lastDislike = self.now.addingTimeInterval(-120 * self.day) }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.notificationsAuthorized = false }))
        XCTAssertFalse(ReviewPromptPolicy.shouldAsk(inputs { $0.topicsHealthy = false }))
    }

    func testLaunchesAreCountedOncePerProcessAndCrashesAreSinceThePreviousLaunch() {
        let suite = "ReviewPromptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ReviewPrompt(defaults: defaults, current: "1.28.0")
        first.recordLaunch(now: now)
        first.recordLaunch(now: now + 10)
        XCTAssertEqual(defaults.integer(forKey: ReviewPrompt.launchCountKey), 1)
        let second = ReviewPrompt(defaults: defaults, current: "1.28.0")
        second.recordLaunch(now: now + day)
        XCTAssertEqual(defaults.integer(forKey: ReviewPrompt.launchCountKey), 2)
        func crashed(_ arrival: Date?) -> Bool {
            second.inputs(now: now + day, crashArrival: arrival, questionWaiting: false,
                          notificationsAuthorized: true, topicsHealthy: true).crashSinceLastLaunch
        }
        XCTAssertFalse(crashed(nil))
        XCTAssertFalse(crashed(now - 1), "a crash before the previous launch is old news")
        XCTAssertTrue(crashed(now + 5), "reported during the previous session")
        XCTAssertTrue(crashed(now + day + 1), "delivered at this launch: the last session crashed")
        XCTAssertFalse(second.inputs(now: now, crashArrival: nil, questionWaiting: false, notificationsAuthorized: true,
                                     topicsHealthy: true).goodMomentThisSession, "no moment yet this session")
    }

    func testNotReallyStartsTheQuietPeriod() {
        let suite = "ReviewPromptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ReviewPrompt(defaults: defaults, current: "1.28.0").answeredNotReally(now: now)
        XCTAssertEqual(defaults.object(forKey: ReviewPrompt.dislikeKey) as? Date, now)
        let presented = expectation(description: "feedback opens as a dislike")
        DispatchQueue.main.async {
            XCTAssertEqual(FeedbackCenter.shared.request?.kind, .dislike)
            XCTAssertEqual(FeedbackCenter.shared.request?.source, .reviewPrompt)
            FeedbackCenter.shared.request = nil
            presented.fulfill()
        }
        wait(for: [presented], timeout: 1)
    }
}

final class ShakeGuardTests: XCTestCase {
    func testShakeOpensOnlyWhenNothingElseClaimsIt() {
        XCTAssertTrue(ShakeGuard.shouldOpen(enabled: true, active: true, editingText: false, presenting: false))
        XCTAssertFalse(ShakeGuard.shouldOpen(enabled: false, active: true, editingText: false, presenting: false))
        XCTAssertFalse(ShakeGuard.shouldOpen(enabled: true, active: true, editingText: true, presenting: false),
                       "iOS uses shake for undo while typing")
        XCTAssertFalse(ShakeGuard.shouldOpen(enabled: true, active: true, editingText: false, presenting: true))
        XCTAssertFalse(ShakeGuard.shouldOpen(enabled: true, active: false, editingText: false, presenting: false))
    }

    func testShakeSettingDefaultsOnAndDetectsATextField() throws {
        let suite = "ShakeGuardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(FeedbackSettings.shakeEnabled(defaults))
        defaults.set(false, forKey: FeedbackSettings.shakeKey)
        XCTAssertFalse(FeedbackSettings.shakeEnabled(defaults))

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            previousKey?.makeKey()
        }
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.addSubview(field)
        window.makeKeyAndVisible()
        XCTAssertFalse(FeedbackCenter.editingText())
        XCTAssertTrue(field.becomeFirstResponder())
        XCTAssertTrue(FeedbackCenter.editingText())
        field.resignFirstResponder()
    }
}
