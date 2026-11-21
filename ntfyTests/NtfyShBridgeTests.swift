import XCTest
import CryptoKit
@testable import ntfy

/// Answers every request from `reply` and records what was sent. No real network.
private final class BridgeStubProtocol: URLProtocol {
    struct Sent { let request: URLRequest; let body: Data? }
    static var sent: [Sent] = []
    static var reply: (URLRequest) -> Result<(Int, [String: String], String), URLError> = { _ in
        .success((200, [:], #"{"watching":1,"expires":1800000000}"#))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.sent.append(Sent(request: request, body: request.httpBody ?? Self.read(request.httpBodyStream)))
        switch Self.reply(request) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let (status, headers, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class NoApnsSubscriber: FcmTopicSubscriber {
    var hasApnsToken: Bool { false }
    func subscribe(toTopic topic: String, completion: @escaping (Error?) -> Void) { completion(nil) }
    func unsubscribe(fromTopic topic: String, completion: @escaping (Error?) -> Void) { completion(nil) }
}

final class NtfyShBridgeTests: XCTestCase {
    private var store: Store!
    private var defaults: UserDefaults!
    private var suite = ""
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var bridge: NtfyShBridge!

    override func setUp() {
        super.setUp()
        store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        suite = "NtfyShBridgeTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        BridgeStubProtocol.sent = []
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1800000000}"#)) }
        bridge = makeBridge()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeBridge() -> NtfyShBridge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeStubProtocol.self]
        return NtfyShBridge(store: store, defaults: defaults, session: URLSession(configuration: config),
                            appBaseUrl: "https://ntfy-me.com", now: { [unowned self] in self.clock })
    }

    private func sync(_ reason: String = "test") {
        let done = expectation(description: reason)
        bridge.sync(reason: reason) { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    private func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func lastBody() throws -> [String: Any] {
        let body = try XCTUnwrap(BridgeStubProtocol.sent.last?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: Set computation

    func testWatchSetSplitsNtfyShTopicsFromHashesAndLeavesOutTheAppServer() {
        let set = BridgeWatchSet.compute(subscriptions: [
            ("https://ntfy-me.com", "own"),            // already pushes to this app
            ("https://ntfy.sh", "zeta"),
            ("https://ntfy.sh/", "alerts_home"),
            ("https://ntfy.sh", "alerts_home"),         // duplicate
            ("https://ntfy.sh", "has space"),           // the server would reject the whole body
            ("http://ntfy.sh", "plain"),                // its FCM topic is not the one the server wakes
            ("https://home.example/ntfy", "garage"),
            ("https://home.example/ntfy/", "garage"),   // same topic URL once normalized
        ], ntfyShHasLogin: false, appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(set.ntfyShTopics, ["alerts_home", "zeta"])
        XCTAssertEqual(set.hashes, [sha("https://home.example/ntfy/garage")])
        XCTAssertEqual(set.hashes, [topicHash(baseUrl: "https://home.example/ntfy", topic: "garage")])
        XCTAssertEqual(set.skipped, 2)
    }

    func testNtfyShTopicsWithASavedLoginAreNotSent() {
        let set = BridgeWatchSet.compute(subscriptions: [("https://ntfy.sh", "private"), ("https://home.example", "a")],
                                         ntfyShHasLogin: true, appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(set.ntfyShTopics, [])
        XCTAssertEqual(set.hashes.count, 1)
        XCTAssertEqual(set.skipped, 1)
    }

    func testEachListIsCappedAtTheContractLimit() {
        let pairs = (0..<130).map { ("https://ntfy.sh", "t\($0)") } + (0..<105).map { ("https://h\($0).example", "x") }
        let set = BridgeWatchSet.compute(subscriptions: pairs, ntfyShHasLogin: false, appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(set.ntfyShTopics.count, 100)
        XCTAssertEqual(set.hashes.count, 100)
        XCTAssertEqual(set.skipped, 35)
    }

    func testTopicNamePatternMatchesTheContract() {
        for ok in ["a", "A-b_9", String(repeating: "x", count: 64)] { XCTAssertTrue(BridgeWatchSet.isValidNtfyShTopic(ok), ok) }
        for bad in ["", "a b", "ü", "a/b", String(repeating: "x", count: 65)] { XCTAssertFalse(BridgeWatchSet.isValidNtfyShTopic(bad), bad) }
    }

    func testStoreLoginOnNtfyShExcludesItsTopics() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, ["alerts"])
        XCTAssertTrue(store.saveUser(baseUrl: "https://ntfy.sh", username: "me", password: "pw"))
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, [])
    }

    // MARK: Registration

    func testRequestMatchesTheContractExactly() throws {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "mytopic")
        _ = store.saveSubscription(baseUrl: "https://home.example", topic: "door")
        _ = store.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "own")
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 1)
        let request = try XCTUnwrap(BridgeStubProtocol.sent.first?.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy-me.com/v1/ntfai/watch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try lastBody()
        XCTAssertEqual(Set(body.keys), ["device", "ntfy_sh_topics", "hashes"])
        let device = try XCTUnwrap(body["device"] as? String)
        XCTAssertNotNil(device.range(of: "^[0-9a-f]{32}$", options: .regularExpression), device)
        XCTAssertEqual(body["ntfy_sh_topics"] as? [String], ["mytopic"])
        XCTAssertEqual(body["hashes"] as? [String], [sha("https://home.example/door")])
        // The id is made once per install.
        XCTAssertEqual(bridge.deviceId, device)
        XCTAssertEqual(makeBridge().deviceId, device)
        XCTAssertEqual(bridge.record.lastOutcome, .ok)
        XCTAssertEqual(bridge.record.watching, 1)
    }

    func testUnchangedSetIsNotResentUntilADayHasPassed() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        sync()
        clock += 23 * 60 * 60
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 1, "an unchanged set within a day must not be re-posted")
        clock += 2 * 60 * 60
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 2, "the 24 h refresh keeps the server's 30-day expiry away")
    }

    func testAChangedSetIsSentAtOnce() throws {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        sync()
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "backups")
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 2)
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["alerts", "backups"])
    }

    func testUnsubscribeDropsTheEntryAndTheLastOnePostsEmptyLists() throws {
        let first = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        let second = store.saveSubscription(baseUrl: "https://home.example", topic: "door")
        sync()
        XCTAssertTrue(store.delete(subscription: first))
        sync()
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], [])
        XCTAssertEqual(try lastBody()["hashes"] as? [String], [sha("https://home.example/door")])
        XCTAssertTrue(store.delete(subscription: second))
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 3)
        XCTAssertEqual(try lastBody()["hashes"] as? [String], [])
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 3, "an accepted empty set needs no refresh")
    }

    func testFreshInstallWithNothingToWatchSendsNothing() {
        _ = store.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "own")
        sync()
        XCTAssertTrue(BridgeStubProtocol.sent.isEmpty)
    }

    func testToggleOffSendsEmptyListsAndOnResendsTheSet() throws {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        XCTAssertTrue(bridge.isEnabled, "on by default")
        sync()
        let off = expectation(description: "off")
        defaults.set(false, forKey: NtfyShBridge.enabledKey)
        bridge.sync(reason: "off") { off.fulfill() }
        wait(for: [off], timeout: 5)
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], [])
        XCTAssertEqual(try lastBody()["hashes"] as? [String], [])
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 2, "off, nothing more is sent")
        bridge.setEnabled(true)
        let settle = expectation(description: "on")
        bridge.sync(reason: "settle") { settle.fulfill() }
        wait(for: [settle], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.count, 3)
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["alerts"])
    }

    func testFailuresRetryAtTheNextTrigger() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        BridgeStubProtocol.reply = { _ in .failure(URLError(.notConnectedToInternet)) }
        sync()
        XCTAssertEqual(bridge.record.lastOutcome, .network)
        BridgeStubProtocol.reply = { _ in .success((503, [:], #"{"error":"bridge is full, try later"}"#)) }
        sync()
        XCTAssertEqual(bridge.record.lastOutcome, .full)
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1800000000}"#)) }
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 3)
        XCTAssertEqual(bridge.record.lastOutcome, .ok)
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 3)
    }

    func testRateLimitWaitsForRetryAfterThenRetries() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        BridgeStubProtocol.reply = { _ in .success((429, ["Retry-After": "120"], "")) }
        sync()
        XCTAssertEqual(bridge.record.lastOutcome, .rateLimited)
        BridgeStubProtocol.reply = { _ in .success((200, [:], "{}")) }
        clock += 60
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 1, "the server asked for 120 s")
        clock += 61
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 2)
        XCTAssertEqual(bridge.record.lastOutcome, .ok)
    }

    func testRecordSurvivesRelaunch() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        sync()
        bridge = makeBridge()
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 1)
        XCTAssertEqual(bridge.record.lastOutcome, .ok)
    }

    func testEveryReconcileTriggerAlsoSyncsTheBridge() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        let reconciler = FcmSubscriptionReconciler(store: store, subscriber: NoApnsSubscriber(), defaults: defaults, bridge: bridge)
        reconciler.reconcile(reason: "app became active")
        let done = expectation(description: "settled")
        bridge.sync(reason: "after") { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.count, 1, "registers even before an APNs token exists")
    }

    func testStatusReadsConnectedAndUnknownDevice() {
        BridgeStubProtocol.reply = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/ntfai/watch")
            return .success((200, [:], #"{"watching":2,"expires":1800000000,"connected":true}"#))
        }
        var statuses: [NtfyShBridge.Status] = []
        let first = expectation(description: "status")
        bridge.fetchStatus { statuses.append($0); first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.last?.request.url?.query, "device=\(bridge.deviceId)")
        BridgeStubProtocol.reply = { _ in .success((404, [:], "")) }
        let second = expectation(description: "unknown")
        bridge.fetchStatus { statuses.append($0); second.fulfill() }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(statuses, [.connected(watching: 2), .unknownDevice])
    }

    func testDiagnosticSummaryHasNoTopicNamesOrDeviceId() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "secret_topic_name")
        sync()
        let summary = bridge.diagnosticSummary
        XCTAssertFalse(summary.contains("secret_topic_name"))
        XCTAssertFalse(summary.contains(bridge.deviceId))
        XCTAssertTrue(summary.contains("sent 1t/0h, last ok (200)"), summary)
    }

    // MARK: Copy

    /// Red before the bridge: the ntfy.sh hint said there were no instant banners at all.
    func testNtfyShHintTellsTheTruthInBothStates() throws {
        let on = try XCTUnwrap(Config.ntfyShDeliveryHint(baseUrl: "https://ntfy.sh", bridgeOn: true))
        XCTAssertEqual(on, String(localized: "Topics on ntfy.sh get instant banners: \("ntfy-me.com") watches them for this device and keeps no message text. You can turn this off in Settings. See \("https://ntf-ai.app/docs/migrate")."))
        let off = try XCTUnwrap(Config.ntfyShDeliveryHint(baseUrl: "https://ntfy.sh", bridgeOn: false))
        XCTAssertEqual(off, String(localized: "Instant banners for ntfy.sh and other servers is off in Settings, so messages on ntfy.sh appear only when you open the app or refresh. See \("https://ntf-ai.app/docs/migrate")."))
        XCTAssertNil(Config.ntfyShDeliveryHint(baseUrl: "https://home.example", bridgeOn: true))
    }

    /// Red before the bridge: the self-hosted hint told people to point upstream at ntfy-me.com and
    /// warned that it breaks the official app.
    func testSelfHostedHintOffersTheUsualNtfyShUpstream() {
        let on = Config.selfHostedDeliveryHint(bridgeOn: true)
        XCTAssertEqual(on, String(localized: "For instant banners from your own server, set upstream-base-url to https://ntfy.sh, the usual setting, which keeps the official ntfy app working too, or to \("https://ntfy-me.com"). With no upstream, messages arrive when you refresh. See \("https://ntf-ai.app/docs/self-hosting")."))
        let off = Config.selfHostedDeliveryHint(bridgeOn: false)
        XCTAssertEqual(off, String(localized: "For instant banners from your own server, set upstream-base-url to \("https://ntfy-me.com"). https://ntfy.sh, the usual setting, works only while Instant banners for ntfy.sh and other servers is on in Settings. With no upstream, messages arrive when you refresh. See \("https://ntf-ai.app/docs/self-hosting")."))
    }

    func testPermissionPrimingAsksAsUsualForNtfyShWhileTheBridgeIsOn() {
        guard Config.ntfyShBridgeEnabled else { return }
        XCTAssertEqual(SubscriptionPermissionCopy.message(baseUrl: "https://ntfy.sh", topicURL: "https://ntfy.sh/a", topicCount: 1),
                       String(localized: "Allow notifications so each message sent to \("ntfy.sh/a") shows up on your lock screen, even when the app is closed. You'll be asked for permission next."))
    }

    static let newKeys = [
        "Topics on ntfy.sh get instant banners: %@ watches them for this device and keeps no message text. You can turn this off in Settings. See %@.",
        "Instant banners for ntfy.sh and other servers is off in Settings, so messages on ntfy.sh appear only when you open the app or refresh. See %@.",
        "For instant banners from your own server, set upstream-base-url to https://ntfy.sh, the usual setting, which keeps the official ntfy app working too, or to %@. With no upstream, messages arrive when you refresh. See %@.",
        "For instant banners from your own server, set upstream-base-url to %@. https://ntfy.sh, the usual setting, works only while Instant banners for ntfy.sh and other servers is on in Settings. With no upstream, messages arrive when you refresh. See %@.",
        "Instant banners for ntfy.sh and other servers",
        "%@ watches your ntfy.sh topics and wakes this device when a message arrives. It learns those topic names and sees their messages in passing, but keeps no message text. For your own server it learns only a hash of each topic address. Topics that need a login on ntfy.sh aren't watched. Off, ntfy.sh topics and servers whose upstream is ntfy.sh show new messages only when you open the app or refresh.",
        "ntfy.sh topics watched", "Other servers' topics watched", "Last registration", "Never", "Bridge connection",
        "Checking…", "Accepted", "Rejected by the server", "Rate limited, will retry", "Bridge full, will retry",
        "Server error, will retry", "No connection, will retry", "Connected", "Reconnecting to ntfy.sh",
        "Not registered yet", "Couldn't check", "%@, %@", "On", "Off",
        "This relay does not offer an automatic check. On your server, check upstream-base-url (https://ntfy.sh with instant banners on in Settings, or https://ntfy-me.com), its canonical base-url, and outbound HTTPS. No automatic result is available.",
        "No newer forwarded wake-up was observed during this check (about 10 seconds). Check upstream-base-url (https://ntfy.sh with instant banners on in Settings, or https://ntfy-me.com), the canonical base-url, outbound HTTPS, and the relay's status. Network or FCM trouble, delays, or evicted history can give the same result.",
        "Your server's upstream-base-url must be https://ntfy.sh, with instant banners on in Settings, or %@. Its configured base-url must exactly match the server address used for this subscription, including scheme, port, path and spelling. The relay keeps only recent acceptance times (up to 2 minutes); it does not report device delivery.",
    ]

    func testEveryNewStringResolvesInEveryLanguage() throws {
        for language in ["en", "de", "es", "fr", "it", "nl", "pl"] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)), language)
            for key in Self.newKeys {
                let value = bundle.localizedString(forKey: key, value: "__missing__", table: nil)
                XCTAssertNotEqual(value, "__missing__", "\(language): \(key)")
                if language != "en", key != "%@, %@" {
                    XCTAssertNotEqual(value, key, "\(language) is untranslated: \(key)")
                }
            }
        }
    }

    func testRetiredStringsAreGone() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).resourceURL?.appendingPathComponent("Localization/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let keys = try XCTUnwrap(catalog["strings"] as? [String: Any]).keys
        XCTAssertFalse(keys.contains("Topics on ntfy.sh have no instant banners in this app. Messages appear when you open the app or refresh. For banners, move your topic to %@. See %@."))
        XCTAssertFalse(keys.contains { $0.hasPrefix("For instant delivery from your own server, add") })
    }
}
