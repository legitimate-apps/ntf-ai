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

    private func rows(_ pairs: [(String, String)], login: Bool = false) -> [(baseUrl: String, topic: String, hasLogin: Bool)] {
        pairs.map { ($0.0, $0.1, login) }
    }

    func testWatchSetSplitsNtfyShTopicsFromHashesAndLeavesOutTheAppServer() {
        let set = BridgeWatchSet.compute(subscriptions: rows([
            ("https://ntfy-me.com", "own"),            // already pushes to this app
            ("https://ntfy.sh", "zeta"),
            ("https://ntfy.sh/", "alerts_home"),
            ("https://ntfy.sh", "alerts_home"),         // duplicate
            ("https://ntfy.sh", "has space"),           // the server would reject the whole body
            ("http://ntfy.sh", "plain"),                // 1.30: every spelling of ntfy.sh is ntfy.sh
            ("https://home.example/ntfy", "garage"),
            ("https://home.example/ntfy/", "garage"),   // same topic URL once normalized
        ]), appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(set.ntfyShTopics, ["alerts_home", "plain", "zeta"])
        XCTAssertEqual(set.hashes, [sha("https://home.example/ntfy/garage")])
        XCTAssertEqual(set.hashes, [topicHash(baseUrl: "https://home.example/ntfy", topic: "garage")])
        XCTAssertEqual(set.held, [.init(baseUrl: "https://ntfy.sh", topic: "has space", hold: .invalidName)])
    }

    /// Red on b0f4a48: http://, www., case and :443 were each skipped, so they never got banners.
    func testEverySpellingOfNtfyShIsWatched() {
        let spellings = ["http://ntfy.sh", "https://www.ntfy.sh", "HTTPS://NTFY.SH", "https://ntfy.sh:443", "http://ntfy.sh:80/", "ntfy.sh", "www.ntfy.sh"]
        for spelling in spellings {
            XCTAssertEqual(NtfyShAddress.canonicalize(spelling), "https://ntfy.sh", spelling)
            let set = BridgeWatchSet.compute(subscriptions: rows([(spelling, "alerts")]), appBaseUrl: "https://ntfy-me.com")
            XCTAssertEqual(set.ntfyShTopics, ["alerts"], spelling)
            XCTAssertEqual(set.hashes, [], spelling)
        }
        for other in ["https://ntfy.sh/sub", "https://ntfy.sh:8443", "https://user:pw@ntfy.sh", "https://notntfy.sh", "ftp://ntfy.sh", "https://ntfy.sh?x=1"] {
            XCTAssertNil(NtfyShAddress.canonicalize(other), other)
        }
    }

    /// Red on b0f4a48: the FCM name came from the stored spelling, so http://ntfy.sh bound a hash
    /// the bridge never wakes, and the extension couldn't match the wake-up to the row.
    func testEverySpellingBindsAndMatchesTheHashTheBridgeWakes() {
        let wakes = sha("https://ntfy.sh/alerts")
        for spelling in ["http://ntfy.sh", "https://www.ntfy.sh/", "https://NTFY.sh"] {
            XCTAssertEqual(topicHash(baseUrl: spelling, topic: "alerts"), wakes, spelling)
            XCTAssertEqual(firebaseTopic(baseUrl: spelling, topic: "alerts"), wakes, spelling)
        }
        _ = store.saveSubscription(baseUrl: "http://ntfy.sh", topic: "alerts")
        let match = store.findSubscriptionMatch(forPollRequestTopic: wakes)
        XCTAssertEqual(match?.baseUrl, "http://ntfy.sh")
        XCTAssertEqual(match?.topic, "alerts")
        // Other servers keep their hash exactly.
        XCTAssertEqual(topicHash(baseUrl: "http://home.example", topic: "a"), sha("http://home.example/a"))
    }

    /// The add sheet and links store ntfy.sh as https://ntfy.sh, however it was typed.
    func testNewSubscriptionsStoreTheCanonicalNtfyShAddress() {
        XCTAssertEqual(NtfyShAddress.ingress("http://www.ntfy.sh/"), "https://ntfy.sh")
        XCTAssertEqual(NtfyShAddress.ingress("http://home.example"), "http://home.example")
        XCTAssertEqual(TopicLink(scanned: "ntfy.sh/alerts")?.server, "https://ntfy.sh")
        XCTAssertEqual(TopicLink(scanned: "http://www.ntfy.sh/alerts")?.server, "https://ntfy.sh")
    }

    /// Red on b0f4a48: one saved ntfy.sh login dropped every ntfy.sh topic, public ones included.
    func testWithALoginOnlyTopicsThatAreOpenAnonymouslyAreSent() {
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        let access: [String: NtfyShAccess] = [
            "public": .init(state: .open, checked: checked),
            "private": .init(state: .protected, checked: checked),
            "flaky": .init(state: .unknown, checked: checked),
        ]
        let set = BridgeWatchSet.compute(subscriptions: rows([("https://ntfy.sh", "public"), ("https://ntfy.sh", "private"),
                                                              ("https://ntfy.sh", "flaky"), ("https://ntfy.sh", "new"),
                                                              ("https://home.example", "a")], login: true),
                                         access: access, now: checked.addingTimeInterval(60), appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(set.ntfyShTopics, ["public"])
        XCTAssertEqual(set.hashes.count, 1)
        XCTAssertEqual(set.hold(baseUrl: "https://ntfy.sh", topic: "private"), .needsLogin)
        XCTAssertEqual(set.hold(baseUrl: "https://ntfy.sh", topic: "flaky"), .checkingAccess)
        XCTAssertEqual(set.hold(baseUrl: "https://ntfy.sh", topic: "new"), .checkingAccess)
        XCTAssertEqual(set.needsProbe, ["new"])
        // Answers expire: open after 7 days, protected after 1, unknown after an hour.
        let later = BridgeWatchSet.compute(subscriptions: rows([("https://ntfy.sh", "flaky"), ("https://ntfy.sh", "private")], login: true),
                                           access: access, now: checked.addingTimeInterval(2 * 3600), appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(later.needsProbe, ["flaky"])
        let nextDay = BridgeWatchSet.compute(subscriptions: rows([("https://ntfy.sh", "private")], login: true),
                                             access: access, now: checked.addingTimeInterval(25 * 3600), appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(nextDay.needsProbe, ["private"])
    }

    func testAccessAnswersAreClassifiedByStatus() {
        XCTAssertEqual(NtfyShAccess.classify(status: 200), .open)
        XCTAssertEqual(NtfyShAccess.classify(status: 401), .protected)
        XCTAssertEqual(NtfyShAccess.classify(status: 403), .protected)
        XCTAssertEqual(NtfyShAccess.classify(status: 400), .invalid)
        XCTAssertEqual(NtfyShAccess.classify(status: 429), .unknown)
        XCTAssertEqual(NtfyShAccess.classify(status: nil), .unknown)
    }

    func testEachListIsCappedAtTheContractLimit() {
        let pairs = (0..<130).map { ("https://ntfy.sh", "t\($0)") } + (0..<105).map { ("https://h\($0).example", "x") }
        let set = BridgeWatchSet.compute(subscriptions: rows(pairs), appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(set.ntfyShTopics.count, 100)
        XCTAssertEqual(set.hashes.count, 100)
        XCTAssertEqual(set.skipped, 35)
        XCTAssertTrue(set.held.allSatisfy { $0.hold == .overCap })
    }

    func testTopicNamePatternMatchesTheContract() {
        for ok in ["a", "A-b_9", String(repeating: "x", count: 64)] { XCTAssertTrue(BridgeWatchSet.isValidNtfyShTopic(ok), ok) }
        for bad in ["", "a b", "ü", "a/b", String(repeating: "x", count: 65)] { XCTAssertFalse(BridgeWatchSet.isValidNtfyShTopic(bad), bad) }
    }

    /// Red on b0f4a48: with a login saved, `alerts` (public) was never sent. Now it is checked
    /// anonymously, the way the bridge reads it, and sent; `mine` (403) is held back and named.
    func testStoreLoginOnNtfyShChecksEachTopicAnonymouslyAndSendsTheOpenOnes() throws {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "alerts")
        _ = store.saveSubscription(baseUrl: "http://ntfy.sh", topic: "mine")
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, ["alerts", "mine"])
        XCTAssertTrue(store.saveUser(baseUrl: "https://ntfy.sh", username: "me", password: "pw"))
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, [])
        XCTAssertEqual(bridge.subscribedSet().needsProbe, ["alerts", "mine"])
        BridgeStubProtocol.reply = { request in
            if request.url?.path == "/mine/auth" { return .success((403, [:], #"{"code":40301}"#)) }
            if request.url?.path == "/alerts/auth" { return .success((200, [:], #"{"success":true}"#)) }
            return .success((200, [:], #"{"watching":1,"expires":1800000000}"#))
        }
        sync()
        let probes = BridgeStubProtocol.sent.filter { $0.request.url?.path.hasSuffix("/auth") == true }
        XCTAssertEqual(probes.count, 2)
        for probe in probes {
            XCTAssertEqual(probe.request.url?.host, "ntfy.sh")
            XCTAssertEqual(probe.request.httpMethod ?? "GET", "GET")
            XCTAssertNil(probe.request.value(forHTTPHeaderField: "Authorization"), "the check must be anonymous")
        }
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["alerts"])
        XCTAssertEqual(bridge.topicState(baseUrl: "http://ntfy.sh", topic: "mine", wakes: nil), .held(.needsLogin))
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "alerts", wakes: nil), .watched)
        // Cached: the next sync doesn't ask again.
        BridgeStubProtocol.sent = []
        clock = clock.addingTimeInterval(25 * 3600)
        sync()
        XCTAssertTrue(BridgeStubProtocol.sent.filter { $0.request.url?.path.hasSuffix("/auth") == true }.map { $0.request.url!.path } == ["/mine/auth"],
                      "only the protected answer (1 day) is due again")
    }

    func testARateLimitedCheckSendsNothingAndWaitsAnHour() throws {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "a")
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "b")
        XCTAssertTrue(store.saveUser(baseUrl: "https://ntfy.sh", username: "me", password: "pw"))
        BridgeStubProtocol.reply = { request in
            request.url?.path.hasSuffix("/auth") == true ? .success((429, [:], "")) : .success((200, [:], #"{"watching":0}"#))
        }
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.filter { $0.request.url?.path.hasSuffix("/auth") == true }.count, 1, "a 429 stops the round")
        XCTAssertEqual(bridge.subscribedSet().needsProbe, [])
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "b", wakes: nil), .held(.checkingAccess))
        clock = clock.addingTimeInterval(3601)
        XCTAssertEqual(bridge.subscribedSet().needsProbe, ["a", "b"])
    }

    /// The server's own `unwatchable` list (S1) names topics it couldn't read anonymously.
    func testUnwatchableFromThePostAndStatusIsShownAsNeedsLogin() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "phil")
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":0,"expires":1800000000,"unwatchable":["phil"]}"#)) }
        sync()
        XCTAssertEqual(bridge.currentRecord.unwatchable, ["phil"])
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "phil", wakes: nil), .held(.needsLogin))
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"connected":true,"unwatchable":[]}"#)) }
        let done = expectation(description: "status")
        bridge.fetchStatus { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(bridge.currentRecord.unwatchable, [])
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "phil", wakes: nil), .watched)
    }

    func testTopicStateNamesBridgeOffAndUnavailable() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "a")
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy-me.com", topic: "x", wakes: nil), .direct)
        BridgeStubProtocol.reply = { _ in .success((503, [:], "")) }
        sync()
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", wakes: nil), .held(.bridgeUnavailable))
        bridge.setEnabled(false)
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", wakes: nil), .held(.bridgeOff))
    }

    // MARK: Notification status (A6)

    /// Red on b0f4a48: status showed two counts, so a topic with no banners was invisible.
    func testReportListsEachServerWithItsCountAndEveryTopicThatGetsNoBanners() throws {
        let suite = "wakes.\(UUID())"
        let wakeDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { wakeDefaults.removePersistentDomain(forName: suite) }
        let wakes = SelfHostedWakeCheck(defaults: wakeDefaults, network: false, now: { [unowned self] in self.clock })
        for (base, topic) in [("https://ntfy.sh", "alerts"), ("http://www.ntfy.sh", "lights"), ("https://ntfy.sh", "bad name"),
                              ("https://home.example", "garage"), ("https://home.example", "backups"), ("https://ntfy-me.com", "own")] {
            _ = store.saveSubscription(baseUrl: base, topic: topic)
        }
        sync()
        let garage = topicHash(baseUrl: "https://home.example", topic: "garage")
        // Three polled messages in a row without a wake-up.
        wakeDefaults.set(try JSONEncoder().encode([garage: SelfHostedWakeCheck.Entry(misses: 3, lastWake: nil, lastCheck: clock)]),
                         forKey: SelfHostedWakeCheck.key)
        let report = bridge.report(wakes: wakes)
        XCTAssertEqual(report.groups.map(\.server), ["https://ntfy.sh", "https://home.example"])
        XCTAssertEqual(report.groups[0].watching, 2)
        XCTAssertEqual(report.groups[0].held, [.init(topic: "bad name", hold: .invalidName)])
        XCTAssertEqual(report.groups[1].watching, 1)
        XCTAssertEqual(report.groups[1].held, [.init(topic: "garage", hold: .notSetUp(address: "https://home.example"))])
        XCTAssertTrue(NtfyShBridgeCopy.reason(.notSetUp(address: "https://home.example")).contains("https://home.example"))
        // A wake-up clears it.
        wakes.recordWake(hash: garage)
        XCTAssertEqual(bridge.report(wakes: wakes).groups[1].held, [])
        bridge.setEnabled(false)
        XCTAssertTrue(bridge.report(wakes: wakes).groups.flatMap(\.held).allSatisfy { $0.hold == .bridgeOff || $0.hold == .invalidName })
    }

    // MARK: Users who never open the app (A3)

    /// Red on b0f4a48: nothing outside the app process ever refreshed the registration.
    func testExtensionRefreshesAWeekOldRegistrationAtMostHourly() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "a")
        XCTAssertTrue(bridge.extensionShouldRefresh(), "never registered")
        sync()
        XCTAssertFalse(bridge.extensionShouldRefresh(), "just registered")
        clock = clock.addingTimeInterval(6 * 24 * 3600)
        XCTAssertFalse(bridge.extensionShouldRefresh(), "six days")
        clock = clock.addingTimeInterval(24 * 3600 + 1)
        XCTAssertTrue(bridge.extensionShouldRefresh(), "over a week")
        BridgeStubProtocol.reply = { _ in .failure(URLError(.notConnectedToInternet)) }
        let before = BridgeStubProtocol.sent.count
        bridge.refreshFromExtensionIfStale()
        let deadline = Date().addingTimeInterval(3)
        while BridgeStubProtocol.sent.count == before, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(BridgeStubProtocol.sent.count, before + 1)
        let settle = Date().addingTimeInterval(3)
        while bridge.currentRecord.lastOutcome != .network, Date() < settle { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(bridge.extensionShouldRefresh(), "a failed try waits an hour")
        clock = clock.addingTimeInterval(3601)
        XCTAssertTrue(bridge.extensionShouldRefresh())
        bridge.setEnabled(false)
        XCTAssertFalse(bridge.extensionShouldRefresh())
    }

    /// The extension compiles the bridge, so it can refresh without the app.
    func testBridgeAndWakeCheckBuildIntoTheExtension() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ntfy.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: url, encoding: .utf8)
        let nse = try XCTUnwrap(project.range(of: "9474F1E0282F3FFD00CDE4DD /* Sources */ = {"))
        let phase = project[nse.upperBound...].prefix { $0 != ")" }
        XCTAssertTrue(phase.contains("NtfyShBridge.swift in Sources"))
        XCTAssertTrue(phase.contains("SelfHostedWakeCheck.swift in Sources"))
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
        "%@ watches your ntfy.sh topics and wakes this device when a message arrives. It learns those topic names and sees their messages in passing, but keeps no message text. For your own server it learns only a hash of each topic address. With a login saved for ntfy.sh, the app first checks each ntfy.sh topic without the login, and only topics anyone can read are sent. Off, ntfy.sh topics and servers whose upstream is ntfy.sh show new messages only when you open the app or refresh.",
        "Instant banners", "Watching %lld", "And %lld more",
        "Needs a login on ntfy.sh, so new messages show when you open the app.",
        "Checking whether anyone can read this topic on ntfy.sh. Until then, new messages show when you open the app.",
        "This address or topic name can't be watched on ntfy.sh, so new messages show when you open the app.",
        "Over the limit of 100 topics per list, so new messages show when you open the app.",
        "Instant banners for ntfy.sh and other servers is off in Settings, so new messages show when you open the app.",
        "%@ is busy or unreachable and will retry on its own. Until then, new messages show when you open the app.",
        "No wake-up arrived for recent messages, so this server isn't set up for instant banners. Ask its admin to set upstream-base-url to https://ntfy.sh and base-url to exactly %@, the address this app uses. Until then, new messages show when you open the app.",
        "Last registration", "Never", "Bridge connection",
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
        XCTAssertFalse(keys.contains { $0.contains("Topics that need a login on ntfy.sh aren't watched.") })
        XCTAssertFalse(keys.contains("ntfy.sh topics watched"))
    }

    func testLocalNetworkHostsAreRecognized() {
        for url in ["http://192.168.1.20:8080", "http://192.168.1.5", "https://172.20.0.2", "http://169.254.3.4",
                    "http://ntfy.local", "http://nas.lan", "http://server.home.arpa", "http://nas", "http://[fd12:3456::1]:80", "http://[fe80::1]"] {
            XCTAssertTrue(LocalNetworkHint.isLocalHost(url), url)
        }
        for url in ["https://ntfy.sh", "https://ntfy-me.com", "http://172.32.0.1", "http://8.8.8.8", "http://localhost:8080",
                    "https://ntfy.example.com", "http://100.64.0.1", "not a url"] {
            XCTAssertFalse(LocalNetworkHint.isLocalHost(url), url)
        }
    }

    func testOfflineErrorFromLocalServerExplainsLocalNetworkAccess() {
        let offline = URLError(.notConnectedToInternet)
        let hint = LocalNetworkHint.message(for: offline, baseUrl: "http://192.168.1.20:8080")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("Local Network") ?? false)
        XCTAssertNil(LocalNetworkHint.message(for: offline, baseUrl: "https://ntfy.sh"), "a public server keeps the real offline error")
        XCTAssertNil(LocalNetworkHint.message(for: URLError(.timedOut), baseUrl: "http://192.168.1.20:8080"), "only the refused-connection error gets the hint")
    }
}

// MARK: - A5: a wake-up that beats the server's cache write

final class SingleMessagePollTests: XCTestCase {
    private func message(_ id: String = "m1") -> Message {
        Message(id: id, time: 1_800_000_000, event: "message", topic: "alerts", message: "real text")
    }

    /// A clock the scheduler advances, so the backoff runs instantly.
    private final class FakeTime {
        var now: TimeInterval = 0
        var delays: [TimeInterval] = []
        var timeouts: [TimeInterval] = []
    }

    private func run(_ answers: [(Message?, Error?)], budget: TimeInterval = NotificationServiceTiming.pollTimeout,
                     answerTakes: TimeInterval = 0.1) -> (Message?, Error?, Int, FakeTime) {
        let time = FakeTime()
        var queue = answers
        var result: (Message?, Error?, Int)?
        SingleMessagePoll.run(budget: budget, clock: { time.now }, schedule: { delay, work in
            time.delays.append(delay); time.now += delay; work()
        }, fetch: { timeout, done in
            time.timeouts.append(timeout)
            time.now += answerTakes
            let next = queue.isEmpty ? (nil, PollEmptyResult()) : queue.removeFirst()
            done(next.0, next.1)
        }) { message, error, attempts in result = (message, error, attempts) }
        let r = try! XCTUnwrap(result)
        return (r.0, r.1, r.2, time)
    }

    /// Red on b0f4a48: the first empty 200 delivered "Open the app to load it".
    func testEmptyAnswersAreAskedAgainUntilTheMessageIsStored() {
        let (message, error, attempts, time) = run([(nil, PollEmptyResult()), (nil, PollEmptyResult()), (self.message(), nil)])
        XCTAssertEqual(message?.message, "real text")
        XCTAssertNil(error)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(time.delays, [0.4, 0.8])
    }

    func testRealErrorsAreNotRetried() {
        for failure: Error in [URLError(.timedOut), URLError(.notConnectedToInternet), PollHTTPError(status: 401, retryAfter: nil, retryCondition: nil)] {
            let (message, error, attempts, time) = run([(nil, failure), (self.message(), nil)])
            XCTAssertNil(message)
            XCTAssertNotNil(error)
            XCTAssertEqual(attempts, 1, "\(failure)")
            XCTAssertEqual(time.delays, [])
        }
    }

    func testRetriesStayInsideTheExtensionsPollBudget() {
        let (message, error, attempts, time) = run([], answerTakes: 0.3)
        XCTAssertNil(message)
        XCTAssertTrue(error is PollEmptyResult)
        XCTAssertEqual(time.delays, [0.4, 0.8, 1.6, 3.2])
        XCTAssertEqual(attempts, 5)
        XCTAssertLessThanOrEqual(time.now, NotificationServiceTiming.pollTimeout)
        // Each request gets only what is left of the budget.
        XCTAssertEqual(time.timeouts.first, NotificationServiceTiming.pollTimeout)
        XCTAssertTrue(zip(time.timeouts, time.timeouts.dropFirst()).allSatisfy { $0 > $1 })
        // A slow server: the last wait would pass the budget, so it stops early.
        let (_, _, slowAttempts, slow) = run([], answerTakes: 1.5)
        XCTAssertLessThan(slowAttempts, 5)
        XCTAssertLessThanOrEqual(slow.now, NotificationServiceTiming.pollTimeout + 1.5)
    }

    /// Red on b0f4a48: an empty 200 was a JSON decode error, indistinguishable from garbage.
    func testEmptyBodyIsTheDistinctNotStoredYetError() throws {
        for body in ["", "\n", "  \n\n"] {
            XCTAssertThrowsError(try ApiService.singleMessage(from: Data(body.utf8), id: "m1")) { XCTAssertTrue($0 is PollEmptyResult) }
        }
        let other = #"{"id":"zz","time":1,"event":"message","topic":"alerts","message":"x"}"#
        XCTAssertThrowsError(try ApiService.singleMessage(from: Data(other.utf8), id: "m1")) { XCTAssertTrue($0 is PollEmptyResult) }
        XCTAssertThrowsError(try ApiService.singleMessage(from: Data("<html>".utf8), id: "m1")) { XCTAssertFalse($0 is PollEmptyResult) }
        let line = #"{"id":"m1","time":1,"event":"message","topic":"alerts","message":"real text"}"#
        XCTAssertEqual(try ApiService.singleMessage(from: Data((line + "\n").utf8), id: "m1").message, "real text")
    }
}

// MARK: - A4: self-hosted servers that never wake the device

final class SelfHostedWakeCheckTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var replies: [(Int, String)] = []
    private var sent: [URLRequest] = []
    private var check: SelfHostedWakeCheck!
    private let base = "http://192.168.1.20:8099"

    override func setUp() {
        super.setUp()
        suite = "SelfHostedWakeCheckTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        check = SelfHostedWakeCheck(defaults: defaults, relayBaseUrl: "https://ntfy-me.com", read: { [unowned self] request, done in
            self.sent.append(request)
            let (status, body) = self.replies.isEmpty ? (200, #"{"relayed":false,"relayed_at":null,"window_seconds":120}"#) : self.replies.removeFirst()
            done(Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
        }, schedule: { [unowned self] delay, work in self.clock = self.clock.addingTimeInterval(delay); work() },
           now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var garageHash: String { topicHash(baseUrl: base, topic: "garage") }

    @discardableResult
    private func arrive(age: TimeInterval = 2) -> SelfHostedWakeCheck.Verdict? {
        var verdict: SelfHostedWakeCheck.Verdict?? = .none
        check.messageArrivedByPoll(baseUrl: base, topic: "garage", messageTime: clock.addingTimeInterval(-age)) { verdict = .some($0) }
        return verdict ?? nil
    }

    /// Red on b0f4a48: a server that never forwarded looked the same as a working one.
    func testThreeMissesInARowFlagNotSetUpAndAWakeClearsIt() throws {
        XCTAssertEqual(arrive(), .missed)
        XCTAssertEqual(sent.count, 1)
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy-me.com/v1/ntfyme/relay-check")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String], ["hash": garageHash])
        XCTAssertFalse(check.isNotSetUp(hash: garageHash))
        clock = clock.addingTimeInterval(SelfHostedWakeCheck.checkInterval)
        XCTAssertEqual(arrive(), .missed)
        clock = clock.addingTimeInterval(SelfHostedWakeCheck.checkInterval)
        XCTAssertEqual(arrive(), .missed)
        XCTAssertTrue(check.isNotSetUp(hash: garageHash))
        check.recordWake(hash: garageHash)
        XCTAssertFalse(check.isNotSetUp(hash: garageHash))
    }

    func testARelayedWakeUpAtTheMessageTimeIsWorking() {
        let at = Int64(clock.timeIntervalSince1970 * 1000)
        replies = [(200, #"{"relayed":true,"relayed_at":\#(at),"window_seconds":120}"#)]
        XCTAssertEqual(arrive(age: 12), .relayed)
        XCTAssertEqual(check.entry(hash: garageHash)?.misses, 0)
    }

    func testAnOlderRelayDoesNotCountForThisMessage() {
        let at = Int64((clock.timeIntervalSince1970 - 60) * 1000)
        replies = [(200, #"{"relayed":true,"relayed_at":\#(at),"window_seconds":120}"#)]
        XCTAssertEqual(arrive(age: 2), .missed)
    }

    func testErrorsAndRateLimitsChangeNothing() {
        replies = [(429, ""), (500, ""), (200, "nonsense")]
        for _ in 0..<3 {
            XCTAssertEqual(arrive(), .unknown)
            clock = clock.addingTimeInterval(SelfHostedWakeCheck.checkInterval)
        }
        XCTAssertEqual(check.entry(hash: garageHash)?.misses, 0)
    }

    func testNoCheckForOldMessagesRecentWakesOrWithinTenMinutes() {
        XCTAssertNil(arrive(age: 300), "the relay keeps 120 s")
        XCTAssertEqual(sent.count, 0)
        XCTAssertEqual(arrive(), .missed)
        XCTAssertNil(arrive(), "throttled")
        XCTAssertEqual(sent.count, 1)
        check.recordWake(hash: garageHash)
        clock = clock.addingTimeInterval(SelfHostedWakeCheck.checkInterval)
        XCTAssertNil(arrive(), "a wake-up within six hours already proves it works")
        XCTAssertEqual(sent.count, 1)
    }

    func testWaitsUntilTheForwardHadTimeToLand() {
        var waited: TimeInterval = 0
        check = SelfHostedWakeCheck(defaults: defaults, relayBaseUrl: "https://ntfy-me.com", read: { _, done in
            done(Data(#"{"relayed":false,"relayed_at":null,"window_seconds":120}"#.utf8),
                 HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }, schedule: { delay, work in waited = delay; work() }, now: { [unowned self] in self.clock })
        arrive(age: 1)
        XCTAssertEqual(waited, SelfHostedWakeCheck.minMessageAge - 1, accuracy: 0.001)
    }

    func testOnlyPolledSelfHostedMessagesAreChecked() {
        let m = Message(id: "m", time: Int64(clock.timeIntervalSince1970) - 2, event: "message", topic: "garage")
        SubscriptionManager.checkWakeUps(baseUrl: "https://ntfy.sh", messages: [m], check: check, bridgeRegistered: true, appBaseUrl: "https://ntfy-me.com")
        SubscriptionManager.checkWakeUps(baseUrl: "https://ntfy-me.com", messages: [m], check: check, bridgeRegistered: true, appBaseUrl: "https://ntfy-me.com")
        SubscriptionManager.checkWakeUps(baseUrl: base, messages: [m], check: check, bridgeRegistered: false, appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(sent.count, 0)
        SubscriptionManager.checkWakeUps(baseUrl: base, messages: [m], check: check, bridgeRegistered: true, appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(sent.count, 1)
    }
}
