import XCTest
import CryptoKit
import UIKit
import UserNotifications
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

    /// A subscription whose push binding FCM confirmed, as a working install has.
    @discardableResult
    private func save(_ baseUrl: String, _ topic: String, bound: Bool = true) -> Subscription {
        let row = store.saveSubscription(baseUrl: baseUrl, topic: topic)
        if bound { store.setFcmSubscribed(row, true) }
        return row
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
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
        // Cached: the next sync doesn't ask again within a day.
        BridgeStubProtocol.sent = []
        clock = clock.addingTimeInterval(3600)
        sync()
        XCTAssertTrue(BridgeStubProtocol.sent.filter { $0.request.url?.path.hasSuffix("/auth") == true }.isEmpty)
        // After a day both answers are due again (review-130 #4: a 200 is sendable for a day only).
        clock = clock.addingTimeInterval(24 * 3600)
        sync()
        XCTAssertEqual(Set(BridgeStubProtocol.sent.filter { $0.request.url?.path.hasSuffix("/auth") == true }.map { $0.request.url!.path }),
                       ["/alerts/auth", "/mine/auth"])
    }

    func testARateLimitedCheckSendsNothingAndWaitsAnHour() throws {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "a")
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "b")
        XCTAssertTrue(store.saveUser(baseUrl: "https://ntfy.sh", username: "me", password: "pw"))
        BridgeStubProtocol.reply = { request in
            request.url?.path.hasSuffix("/auth") == true ? .success((429, [:], "")) : .success((200, [:], #"{"watching":0}"#))
        }
        sync()
        let probes = { BridgeStubProtocol.sent.filter { $0.request.url?.path.hasSuffix("/auth") == true }.count }
        XCTAssertEqual(probes(), 1, "a 429 stops the round")
        XCTAssertEqual(bridge.probeBlockedUntil, clock.addingTimeInterval(3600))
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "b", wakes: nil), .held(.checkingAccess))
        clock = clock.addingTimeInterval(1800)
        sync()
        XCTAssertEqual(probes(), 1, "no check inside the hour")
        clock = clock.addingTimeInterval(1801)
        XCTAssertNil(bridge.probeBlockedUntil)
        sync()
        XCTAssertEqual(probes(), 2)
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
        // review-130 #4: the refusal is cached, so it stays out until a fresh anonymous 200.
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "phil", wakes: nil), .held(.needsLogin))
        clock = clock.addingTimeInterval(25 * 3600)
        BridgeStubProtocol.reply = { request in
            request.url?.path == "/phil/auth" ? .success((200, [:], "{}")) : .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
        }
        sync()
        XCTAssertEqual(bridge.access["phil"]?.state, .open)
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "phil", wakes: nil), .watched)
    }

    func testTopicStateNamesBridgeOffAndUnavailable() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "a")
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy-me.com", topic: "x", wakes: nil), .direct)
        BridgeStubProtocol.reply = { _ in .success((503, [:], "")) }
        sync()
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", wakes: nil), .held(.bridgeUnavailable))
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":0}"#)) }
        bridge.setEnabled(false)
        // The user's own action skips the backoff; until the empty list is accepted, it is pending.
        waitUntil { bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", wakes: nil) == .held(.bridgeOff) }
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
            save(base, topic)
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
        // Until the server confirms the empty list, the entries may still be there.
        XCTAssertEqual(bridge.report(wakes: wakes).groups.first?.serverWide, .removalPending)
        sync("settle off")
        let off = bridge.report(wakes: wakes)
        XCTAssertTrue(off.groups.flatMap(\.held).allSatisfy { $0.hold == .bridgeOff || $0.hold == .invalidName })
        // Off is said once per server, not once per topic.
        XCTAssertEqual(off.groups.map(\.serverWide), [.bridgeOff, .bridgeOff])
        XCTAssertTrue(off.groups.flatMap(\.topicHeld).allSatisfy { $0.hold == .invalidName })
        XCTAssertNil(report.groups[0].serverWide)
        XCTAssertEqual(report.groups[1].topicHeld, report.groups[1].held)
    }

    // MARK: Users who never open the app (A3)

    private func extensionBridge() -> NtfyShBridge {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeStubProtocol.self]
        return NtfyShBridge(store: store, defaults: defaults, session: URLSession(configuration: config),
                            appBaseUrl: "https://ntfy-me.com", now: { [unowned self] in self.clock }, isExtension: true)
    }

    private func renew(_ bridge: NtfyShBridge) {
        let done = expectation(description: "renew")
        bridge.renewFromExtensionIfStale { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    /// Red on 0c3563e (review-130 #1): the extension re-sent its own idea of the watch list, which
    /// could undo the app's newer one (an unsubscribe, or the setting turned off).
    func testExtensionNeverSendsAWatchListOnlyRenewsTheDevice() throws {
        save("https://ntfy.sh", "a")
        let nse = extensionBridge()
        let done = expectation(description: "sync")
        nse.sync(reason: "from the extension") { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(BridgeStubProtocol.sent.isEmpty, "only the app changes what is watched")
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, 1)
        renew(nse)
        XCTAssertEqual(BridgeStubProtocol.sent.count, 1, "just registered: nothing to renew")
        clock += 7 * 24 * 3600 + 1
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"expires":1900000000}"#)) }
        renew(nse)
        let request = try XCTUnwrap(BridgeStubProtocol.sent.last?.request)
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy-me.com/v1/ntfai/watch/renew")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(Set(try lastBody().keys), ["device"])
        XCTAssertEqual(try lastBody()["device"] as? String, bridge.deviceId)
        XCTAssertEqual(bridge.currentRecord.expires, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(bridge.currentRecord.lastRenew, clock)
        let count = BridgeStubProtocol.sent.count
        renew(nse)
        XCTAssertEqual(BridgeStubProtocol.sent.count, count, "renewed: another week before the next")
    }

    /// Until the server offers renewal, everyone gets 404 or 405: nothing shows as broken, and a
    /// 404 only makes the app send its list at its next trigger. Never creates an install ID.
    func testRenewalThatIsNotSupportedChangesNothingVisible() throws {
        let nse = extensionBridge()
        save("https://ntfy.sh", "a")
        renew(nse)
        XCTAssertNil(nse.existingDeviceId, "renewal never makes an install ID")
        sync()
        clock += 8 * 24 * 3600
        BridgeStubProtocol.reply = { _ in .success((405, [:], "")) }
        renew(nse)
        XCTAssertNil(bridge.currentRecord.renewMissed)
        clock += 3601
        BridgeStubProtocol.reply = { _ in .success((404, [:], #"{"error":"page not found"}"#)) }
        renew(nse)
        XCTAssertEqual(bridge.currentRecord.renewMissed, true)
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .watched)
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
        let before = BridgeStubProtocol.sent.count
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, before + 1, "the app sends its list")
        XCTAssertEqual(BridgeStubProtocol.sent.last?.request.url?.path, "/v1/ntfai/watch")
        XCTAssertNil(bridge.currentRecord.renewMissed)
        // S8's own "no such device" answer is a repair the topics show until the app re-sends.
        clock += 8 * 24 * 3600
        BridgeStubProtocol.reply = { _ in .success((404, [:], #"{"code":40400,"http":404,"error":"watch not found; open the app to register the current watch list"}"#)) }
        renew(nse)
        XCTAssertEqual(bridge.currentRecord.repairRequested, true)
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .held(.notRegistered))
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
        sync()
        XCTAssertNil(bridge.currentRecord.repairRequested)
    }

    /// Red on 0c3563e: two processes could each make an install ID.
    func testTwoCreatorsRacingMakeOneInstallId() {
        let path = NSTemporaryDirectory() + "bridge-lock-\(UUID()).lock"
        let first = NtfyShBridge(store: store, defaults: defaults, network: false, lock: SharedFileLock(path: path))
        let second = NtfyShBridge(store: store, defaults: defaults, network: false, lock: SharedFileLock(path: path))
        var ids = [String](repeating: "", count: 64)
        let idsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let id = (i % 2 == 0 ? first : second).deviceId
            idsLock.lock(); ids[i] = id; idsLock.unlock()
        }
        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertEqual(first.existingDeviceId, ids[0])
    }

    /// Red on 0c3563e: the reply to an older registration overwrote the record of a newer one
    /// (another process or a rerun had started since).
    func testAReplyToAnOlderRegistrationIsDropped() throws {
        save("https://ntfy.sh", "a")
        let defaults = self.defaults!
        BridgeStubProtocol.reply = { _ in
            // A newer registration starts elsewhere while this one is on the wire.
            var record = (defaults.data(forKey: NtfyShBridge.recordKey).flatMap { try? JSONDecoder().decode(BridgeRecord.self, from: $0) }) ?? BridgeRecord()
            record.revision = (record.revision ?? 0) + 1
            defaults.set(try! JSONEncoder().encode(record), forKey: NtfyShBridge.recordKey)
            return .success((200, [:], #"{"watching":1,"expires":1800000000}"#))
        }
        sync()
        XCTAssertNil(bridge.currentRecord.acceptedSignature, "an obsolete reply records nothing")
        XCTAssertNil(bridge.currentRecord.lastOutcome)
    }

    /// Red on 0c3563e (review-130 #7): one failed POST (adding b) turned every topic, a included,
    /// into "couldn't take this device's list".
    func testAcceptedTopicStaysWatchedWhenAddingAnotherFails() {
        save("https://ntfy.sh", "a")
        sync()
        save("https://ntfy.sh", "b")
        BridgeStubProtocol.reply = { _ in .success((503, [:], #"{"error":"could not save watches"}"#)) }
        sync()
        XCTAssertEqual(bridge.currentRecord.lastOutcome, .unavailable, "503 without 'full' is not 'full'")
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .watched)
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "b", fcmBound: true), .held(.bridgeUnavailable))
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: false), .held(.pushNotReady))
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "b", fcmBound: false), .held(.pushNotReady),
                       "an unbound row gets no wake even once accepted, so it doesn't say 'being added'")
        XCTAssertEqual(NtfyShBridgeCopy.outcome(.unavailable), String(localized: "Unavailable, will retry"))
    }

    /// Red on 0c3563e: a status 404 (the server lost this device) still showed every topic watched.
    func testStatusThatDoesNotKnowTheDeviceRepairs() {
        save("https://ntfy.sh", "a")
        sync()
        BridgeStubProtocol.reply = { request in
            request.httpMethod == "GET" ? .success((404, [:], "")) : .success((200, [:], #"{"watching":1,"expires":1800000000}"#))
        }
        let status = expectation(description: "status")
        bridge.fetchStatus { XCTAssertEqual($0, .unknownDevice); status.fulfill() }
        wait(for: [status], timeout: 5)
        XCTAssertEqual(bridge.currentRecord.repairRequested, true)
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .held(.notRegistered))
        waitUntil { BridgeStubProtocol.sent.filter { $0.request.httpMethod == "POST" }.count == 2 }
        waitUntil { bridge.currentRecord.repairRequested == nil }
        XCTAssertEqual(BridgeStubProtocol.sent.filter { $0.request.httpMethod == "POST" }.count, 2, "re-sent at once")
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .watched)
        // A status reply saying the bridge's ntfy.sh connection is down.
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"connected":false}"#)) }
        let down = expectation(description: "down")
        bridge.fetchStatus { _ in down.fulfill() }
        wait(for: [down], timeout: 5)
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .held(.reconnecting))
    }

    // MARK: Protected names (review-130 #4)

    /// Red on 0c3563e: a custom Authorization header didn't count as a login, so a private topic
    /// was sent without the anonymous check.
    func testACustomHeaderCountsAsALogin() {
        _ = store.credentialStore.setHTTPHeaders(["Authorization": "Bearer tk_x"], baseUrl: "https://ntfy.sh")
        save("https://ntfy.sh", "private_q7x")
        let set = bridge.subscribedSet()
        XCTAssertEqual(set.ntfyShTopics, [])
        XCTAssertEqual(set.needsProbe, ["private_q7x"])
    }

    /// Red on 0c3563e: the relay's `unwatchable` left the cached 200 in place, so the name kept
    /// being sent. Now it leaves the set until a fresh anonymous 200.
    func testUnwatchableDropsTheCachedPositive() throws {
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        save("https://ntfy.sh", "a_q7x")
        BridgeStubProtocol.reply = { request in
            request.url?.path.hasSuffix("/auth") == true ? .success((200, [:], "{}"))
                : .success((200, [:], #"{"watching":0,"expires":1800000000,"unwatchable":["a_q7x"]}"#))
        }
        sync()
        XCTAssertEqual(bridge.access["a_q7x"]?.state, .protected)
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, [])
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a_q7x", fcmBound: true), .held(.needsLogin))
    }

    /// Red on 0c3563e: a 200 cached for a week kept a name in the set after it was made private.
    /// Older than a day it is checked again first; a name the server already holds stays meanwhile.
    func testAPositiveOlderThanADayIsRecheckedBeforeItIsSent() throws {
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        save("https://ntfy.sh", "a_q7x")
        save("https://ntfy.sh", "b_q7x")
        sync()
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, ["a_q7x", "b_q7x"])
        clock += 2 * 24 * 3600
        let stale = BridgeWatchSet.compute(subscriptions: [("https://ntfy.sh", "a_q7x", true), ("https://ntfy.sh", "c_q7x", true)],
                                           access: bridge.access.merging(["c_q7x": NtfyShAccess(state: .open, checked: clock.addingTimeInterval(-2 * 24 * 3600))]) { $1 },
                                           accepted: ["t:a_q7x"], now: clock, appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(stale.needsProbe, ["a_q7x", "c_q7x"])
        XCTAssertEqual(stale.ntfyShTopics, ["a_q7x"], "accepted: stays while its recheck is outstanding")
        XCTAssertEqual(stale.held.map(\.topic), ["c_q7x"], "never accepted: waits for the recheck")
        // The recheck says private now: it goes.
        BridgeStubProtocol.reply = { request in
            request.url?.path == "/a_q7x/auth" ? .success((401, [:], "")) : .success((200, [:], #"{"watching":1,"expires":1800000000}"#))
        }
        sync()
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["b_q7x"])
    }

    /// Probes are saved one at a time, and a 429 from ntfy.sh stops the round and waits.
    func testProbesAreSavedAsTheyLandAndA429Waits() {
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        for topic in ["a_q7x", "b_q7x", "c_q7x"] { save("https://ntfy.sh", topic) }
        BridgeStubProtocol.reply = { request in
            switch request.url?.path {
            case "/a_q7x/auth": return .success((200, [:], ""))
            case "/b_q7x/auth": return .success((429, ["Retry-After": "600"], ""))
            case "/c_q7x/auth": return .success((200, [:], ""))
            default: return .success((200, [:], #"{"watching":1,"expires":1800000000}"#))
            }
        }
        sync()
        XCTAssertEqual(bridge.access["a_q7x"]?.state, .open)
        XCTAssertNil(bridge.access["b_q7x"])
        XCTAssertNil(bridge.access["c_q7x"], "stopped at the 429")
        XCTAssertEqual(bridge.probeBlockedUntil, clock.addingTimeInterval(600))
        XCTAssertEqual(try? lastBody()["ntfy_sh_topics"] as? [String], ["a_q7x"])
    }

    // MARK: Budgets (review-130 #2, #9)

    /// Red on 0c3563e: a background wake waited on the bridge with no deadline.
    func testNoRequestStartsThatCouldNotFinishByTheDeadline() {
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        save("https://ntfy.sh", "a_q7x")
        let done = expectation(description: "sync")
        bridge.sync(reason: "background wake", deadline: clock.addingTimeInterval(2)) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(BridgeStubProtocol.sent.isEmpty)
        let later = expectation(description: "sync")
        bridge.sync(reason: "background wake", deadline: clock.addingTimeInterval(20)) { later.fulfill() }
        wait(for: [later], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.count, 2, "a probe, then the list")
        XCTAssertLessThanOrEqual(BridgeStubProtocol.sent[0].request.timeoutInterval, 15)
    }

    func testBackgroundWakeCompletesOnceAtTheDeadlineAtTheLatest() {
        var calls: [UIBackgroundFetchResult] = []
        var fire: (() -> Void)?
        let wake = BackgroundWakeCompletion(deadline: 25, schedule: { delay, work in
            XCTAssertEqual(delay, 25); fire = work
        }) { calls.append($0) }
        fire?()
        XCTAssertEqual(calls, [.noData], "the deadline completes a wake whose work never finished")
        wake.noteNewData()
        wake.complete()
        XCTAssertEqual(calls.count, 1)
        var second: [UIBackgroundFetchResult] = []
        var fire2: (() -> Void)?
        let quick = BackgroundWakeCompletion(deadline: 25, schedule: { _, work in fire2 = work }) { second.append($0) }
        quick.noteNewData()
        quick.complete()
        fire2?()
        XCTAssertEqual(second, [.newData])
    }

    /// Red on 0c3563e: a Retry-After over an hour was cut to an hour, and nothing was shared.
    func testRetryAfterIsHonouredInFullAcrossEveryRequestToTheServer() throws {
        save("https://ntfy.sh", "a")
        sync()
        clock += 8 * 24 * 3600
        BridgeStubProtocol.reply = { _ in .success((429, ["Retry-After": "\(3 * 24 * 3600)"], "")) }
        sync()
        XCTAssertEqual(bridge.currentRecord.lastOutcome, .rateLimited)
        let sent = BridgeStubProtocol.sent.count
        clock += 2 * 24 * 3600
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
        let user = expectation(description: "user")
        bridge.sync(reason: "setting", userInitiated: true) { user.fulfill() }
        wait(for: [user], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.count, sent, "even the user's own action waits for the server's Retry-After")
        // The extension's renewal and the relay check share the cooldown.
        renew(extensionBridge())
        XCTAssertEqual(BridgeStubProtocol.sent.count, sent)
        let wakes = SelfHostedWakeCheck(defaults: defaults, read: { _, _ in XCTFail("no relay check in the cooldown") },
                                        schedule: { _, work in work() }, now: { [unowned self] in self.clock })
        XCTAssertNil(wakes.plan(hash: topicHash(baseUrl: "https://home.example", topic: "g"), messageTime: clock))
        let status = expectation(description: "status")
        bridge.fetchStatus { XCTAssertEqual($0, .unavailable); status.fulfill() }
        wait(for: [status], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.count, sent, "nor the status read")
        clock += 24 * 3600 + 1
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, sent + 1)
        XCTAssertEqual(bridge.currentRecord.lastOutcome, .ok)
    }

    /// Without a Retry-After, failures back off 30 s, 60 s, 120 s... to an hour; the user's own
    /// action skips that backoff.
    func testFailuresBackOffExponentiallyAndTheUserCanSkipIt() {
        save("https://ntfy.sh", "a")
        BridgeStubProtocol.reply = { _ in .failure(URLError(.notConnectedToInternet)) }
        sync()
        XCTAssertEqual(NtfyMeHostCooldown.read(defaults).notBefore, clock.addingTimeInterval(30))
        clock += 31
        sync()
        XCTAssertEqual(NtfyMeHostCooldown.read(defaults).notBefore, clock.addingTimeInterval(60))
        let sent = BridgeStubProtocol.sent.count
        clock += 30
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, sent, "inside the backoff")
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1800000000}"#)) }
        let user = expectation(description: "user")
        bridge.sync(reason: "setting", userInitiated: true) { user.fulfill() }
        wait(for: [user], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.count, sent + 1)
        XCTAssertNil(NtfyMeHostCooldown.read(defaults).notBefore, "a success clears it")
        for _ in 0..<20 { NtfyMeHostCooldown.note(status: 500, retryAfter: nil, defaults: defaults, lock: bridge.lock, now: clock) }
        XCTAssertEqual(NtfyMeHostCooldown.read(defaults).notBefore, clock.addingTimeInterval(3600), "capped at an hour")
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
        clock += 31
        BridgeStubProtocol.reply = { _ in .success((503, [:], #"{"error":"bridge is full, try later"}"#)) }
        sync()
        XCTAssertEqual(bridge.record.lastOutcome, .full)
        clock += 61
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
        _ = bridge.deviceId
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
        "On, NTF-AI sends %@ an installation ID made only for this, the names of your ntfy.sh topics, and a hash of each topic address on your other servers. %@ watches those topics on ntfy.sh and wakes this device when a message arrives; it sees messages in passing and keeps no message text. With a login saved, NTF-AI checks each ntfy.sh topic with ntfy.sh without it first and sends only topics anyone can read. A topic made private later is dropped at its next check, within about a day. For your other servers, NTF-AI may ask %@ whether a wake-up for a topic's hash went through. Off, ntfy.sh topics and servers whose upstream is ntfy.sh show new messages only when you open the app or refresh.",
        "Instant banners start once NTF-AI has been opened after installing or updating. NTF-AI keeps this device's list current in the background when the system allows it, which isn't guaranteed; if banners stop, open NTF-AI.",
        "A server whose upstream is %@ still wakes this device.",
        "Instant banners", "Watching %lld", "Show %lld more",
        "This topic on ntfy.sh can't be read without a login, so it gets no instant banners. With your login saved, its messages show when you open the app or refresh.",
        "Checking with ntfy.sh whether anyone can read this topic. Until then, new messages show when you open the app.",
        "This address or topic name can't be watched on ntfy.sh, so new messages show when you open the app.",
        "Over the limit of 100 topics per list, so new messages show when you open the app.",
        "Instant banners through ntfy.sh are off in Settings. Messages that would come through ntfy.sh show when you open the app.",
        "Removing this device's topics from %@. NTF-AI tries again the next time it runs.",
        "%@ couldn't take this device's list. NTF-AI tries again the next time it runs. Until then, messages that would come through ntfy.sh show when you open the app.",
        "Being added to what %@ watches. Instant banners start once it accepts the list.",
        "%@ no longer has this device's list. NTF-AI sends it again the next time it runs; if banners don't return, open NTF-AI.",
        "%@ is reconnecting to ntfy.sh. Until it is back, new messages show when you open the app.",
        "This device hasn't finished push setup for this topic yet. Until then, new messages show when you open the app.",
        "No recent forwarding confirmed for this server. If banners don't come, its upstream-base-url may not be https://ntfy.sh, or its base-url may not be exactly %@. Check again to test with the next message.",
        "Check again", "The next message from this server will be checked.", "Pending", "Unavailable, will retry",
        "This message is no longer on %@, or the server doesn't keep messages.",
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
        // Retired in the 1.30 fix round (review-130 #4, #7, #12).
        for retired in ["And %lld more", "Needs a login on ntfy.sh, so new messages show when you open the app.",
                        "Checking whether anyone can read this topic on ntfy.sh. Until then, new messages show when you open the app.",
                        "Instant banners for ntfy.sh and other servers is off in Settings, so new messages show when you open the app.",
                        "%@ is busy or unreachable and will retry on its own. Until then, new messages show when you open the app."] {
            XCTAssertFalse(keys.contains(retired), retired)
        }
        XCTAssertFalse(keys.contains { $0.hasPrefix("%@ watches your ntfy.sh topics") })
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

    private func run(_ answers: [(Message?, Error?)], deadline: TimeInterval = NotificationServiceTiming.pollTimeout,
                     answerTakes: TimeInterval = 0.1, dispatchLate: TimeInterval = 0) -> (Message?, Error?, Int, FakeTime) {
        let time = FakeTime()
        var queue = answers
        var result: (Message?, Error?, Int)?
        SingleMessagePoll.run(deadline: deadline, clock: { time.now }, schedule: { delay, work in
            time.delays.append(delay); time.now += delay + dispatchLate; work()
        }, cutoff: { _, _ in }, fetch: { timeout, done in
            time.timeouts.append(timeout)
            // Like URLSession: a read that would take longer than its timeout times out.
            guard answerTakes <= timeout else { time.now += timeout; done(nil, URLError(.timedOut)); return nil }
            time.now += answerTakes
            let next = queue.isEmpty ? (nil, PollEmptyResult()) : queue.removeFirst()
            done(next.0, next.1)
            return nil
        }) { message, error, attempts in
            XCTAssertNil(result, "completion runs once")
            result = (message, error, attempts)
        }
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

    /// Every retry empty: the server consistently says it doesn't have the message (review-130 #11).
    func testRetriesStayInsideTheDeadlineAndAConsistentEmptyIsMissing() {
        let (message, error, attempts, time) = run([], answerTakes: 0.3)
        XCTAssertNil(message)
        XCTAssertTrue(error is PollMissingResult, "\(String(describing: error))")
        XCTAssertEqual(time.delays, [0.4, 0.8, 1.6, 3.2])
        XCTAssertEqual(attempts, 5)
        XCTAssertLessThanOrEqual(time.now, NotificationServiceTiming.pollTimeout)
        XCTAssertEqual(time.timeouts.first, NotificationServiceTiming.pollTimeout)
        XCTAssertTrue(zip(time.timeouts, time.timeouts.dropFirst()).allSatisfy { $0 > $1 })
        // A slow server: the next wait would pass the deadline, so it stops early, inconclusive.
        let (_, slowError, slowAttempts, slow) = run([], answerTakes: 1.5)
        XCTAssertLessThan(slowAttempts, 5)
        XCTAssertFalse(slowError is PollMissingResult, "running out of time is not evidence the message is gone")
        XCTAssertLessThanOrEqual(slow.now, NotificationServiceTiming.pollTimeout)
    }

    /// Red on 0c3563e (review-130 #5): a retry that dequeued late, or an answer that came after
    /// the budget, still ran.
    func testALateRetryOrALateAnswerDoesNotRunPastTheDeadline() {
        let (_, error, attempts, time) = run([], dispatchLate: 5)
        XCTAssertEqual(attempts, 2, "the second retry dequeued past the deadline and didn't start")
        XCTAssertTrue(error is PollEmptyResult)
        XCTAssertLessThanOrEqual(time.timeouts.count, 2)
        let (message, lateError, _, _) = run([(self.message(), nil)], deadline: 2, answerTakes: 3)
        XCTAssertNil(message, "an answer after the deadline is dropped")
        XCTAssertEqual((lateError as? URLError)?.code, .timedOut)
    }

    func testTheCutoffCancelsTheReadAndCompletesOnce() {
        var fire: (() -> Void)?
        var cancelled = 0
        var answer: ((Message?, Error?) -> Void)?
        var results: [Error?] = []
        SingleMessagePoll.run(deadline: 8, clock: { 0 }, schedule: { _, work in work() }, cutoff: { _, work in fire = work },
                              fetch: { _, done in answer = done; return { cancelled += 1 } }) { _, error, _ in results.append(error) }
        XCTAssertTrue(results.isEmpty)
        fire?()
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(results.count, 1)
        answer?(Message(id: "m1", time: 1, event: "message", topic: "alerts"), nil)
        XCTAssertEqual(results.count, 1, "a late answer finds the gate closed")
    }

    func testAnOldWakeIsReadOnce() {
        XCTAssertEqual(SingleMessagePoll.delays(messageAge: 5), SingleMessagePoll.emptyRetryDelays)
        XCTAssertEqual(SingleMessagePoll.delays(messageAge: nil), SingleMessagePoll.emptyRetryDelays)
        XCTAssertEqual(SingleMessagePoll.delays(messageAge: 120), [])
    }

    /// Red on 0c3563e (review-130 #11): a message the server no longer has said "Open the app to load it".
    func testMissingMessageCopyOnlyForAConsistentEmpty() {
        let content = UNMutableNotificationContent()
        let missing = NotificationHealth.fetchFailureContent(content, topic: "alerts", missingOn: "home.example")
        XCTAssertEqual(missing.body, DeliveryHealthCopy.missingMessage(server: "home.example"))
        XCTAssertEqual(missing.body, String(localized: "This message is no longer on \("home.example"), or the server doesn't keep messages."))
        let network = NotificationHealth.fetchFailureContent(content, topic: "alerts")
        XCTAssertEqual(network.body, DeliveryHealthCopy.fetchFailure(topic: "alerts"))
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
    private func arrive(age: TimeInterval = 2, topic: String = "garage", strong: Bool = true) -> SelfHostedWakeCheck.Verdict? {
        var verdict: SelfHostedWakeCheck.Verdict?? = .none
        check.messageArrivedByPoll(baseUrl: base, topic: topic, messageTime: clock.addingTimeInterval(-age),
                                   evidence: { strong }) { verdict = .some($0) }
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

    /// Red on 0c3563e (review-130 #8): misses while the bridge's connection wasn't confirmed told
    /// the admin to fix a server that may be fine. Weak evidence says only "not confirmed".
    func testMissesWithoutConfirmedForwardingAreOnlyUnconfirmed() {
        for _ in 0..<3 {
            XCTAssertEqual(arrive(strong: false), .missed)
            clock = clock.addingTimeInterval(SelfHostedWakeCheck.checkInterval)
        }
        XCTAssertEqual(check.diagnosis(hash: garageHash), .unconfirmed)
        XCTAssertFalse(check.isNotSetUp(hash: garageHash))
        // "Check again" checks the next message even inside the interval.
        XCTAssertEqual(arrive(strong: true), .missed)
        XCTAssertNil(arrive(strong: true), "throttled")
        check.arm(hash: garageHash)
        clock = clock.addingTimeInterval(SelfHostedWakeCheck.globalInterval)
        XCTAssertEqual(arrive(strong: true), .missed)
        XCTAssertFalse(check.isArmed(hash: garageHash), "one message per tap")
    }

    /// Red on 0c3563e: a wake recorded by the extension while the check was on the wire was
    /// overwritten by the miss computed before it.
    func testAWakeThatLandsDuringTheCheckWins() {
        let lateWake = SelfHostedWakeCheck(defaults: defaults, relayBaseUrl: "https://ntfy-me.com", read: { [unowned self] request, done in
            self.clock = self.clock.addingTimeInterval(1)
            SelfHostedWakeCheck(defaults: self.defaults, network: false, now: { self.clock }).recordWake(hash: self.garageHash)
            done(Data(#"{"relayed":false,"relayed_at":null,"window_seconds":120}"#.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }, schedule: { _, work in work() }, now: { [unowned self] in self.clock })
        check = lateWake
        _ = arrive()
        XCTAssertEqual(check.entry(hash: garageHash)?.misses, 0)
        XCTAssertNil(check.entry(hash: garageHash)?.weakMisses)
    }

    /// At most one relay check a minute across all topics, so many topics can't burst the relay.
    func testChecksArePacedAcrossTopics() {
        XCTAssertEqual(arrive(topic: "garage"), .missed)
        XCTAssertNil(arrive(topic: "porch"))
        clock = clock.addingTimeInterval(SelfHostedWakeCheck.globalInterval)
        XCTAssertEqual(arrive(topic: "porch"), .missed)
        XCTAssertEqual(sent.count, 2)
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

    /// Only polled self-hosted messages, and only for a hash the bridge's last accepted list holds.
    func testOnlyPolledSelfHostedMessagesTheBridgeHoldsAreChecked() throws {
        let m = Message(id: "m", time: Int64(clock.timeIntervalSince1970) - 2, event: "message", topic: "garage")
        let bridge = NtfyShBridge(store: Store(inMemory: true, credentialStore: InMemoryCredentialStore()), defaults: defaults,
                                  network: false, appBaseUrl: "https://ntfy-me.com", now: { [unowned self] in self.clock })
        for server in ["https://ntfy.sh", "https://ntfy-me.com", base] {
            SubscriptionManager.checkWakeUps(baseUrl: server, messages: [m], check: check, bridge: bridge, appBaseUrl: "https://ntfy-me.com")
        }
        XCTAssertEqual(sent.count, 0, "not admitted: the bridge never accepted this hash")
        var record = BridgeRecord()
        record.acceptedSignature = "t:|h:" + garageHash
        record.lastOutcome = .ok
        defaults.set(try JSONEncoder().encode(record), forKey: NtfyShBridge.recordKey)
        SubscriptionManager.checkWakeUps(baseUrl: base, messages: [m], check: check, bridge: bridge, appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(check.entry(hash: garageHash)?.weakMisses, 1, "no confirmed connection: weak")
        XCTAssertEqual(check.entry(hash: garageHash)?.misses, 0)
    }
}

// MARK: - review-130 #3: every ntfy.sh alias is fetched over https://ntfy.sh

final class NtfyShTransportTests: XCTestCase {
    /// Red on 0c3563e: a row saved as http://ntfy.sh polled over plain http (credentials in the
    /// clear), and one saved as www.ntfy.sh polled a host that doesn't resolve.
    func testEveryAliasIsFetchedOverHttpsNtfySh() {
        let cases = [
            ("http://ntfy.sh/alerts/json?poll=1&id=m1", "https://ntfy.sh/alerts/json?poll=1&id=m1"),
            ("https://www.ntfy.sh/alerts/json?poll=1", "https://ntfy.sh/alerts/json?poll=1"),
            ("http://WWW.ntfy.sh:80/a", "https://ntfy.sh/a"),
            ("https://ntfy.sh:443/a", "https://ntfy.sh/a"),
            ("https://ntfy.sh/a", "https://ntfy.sh/a"),
        ]
        for (from, to) in cases {
            XCTAssertEqual(NtfyShAddress.transportURL(URL(string: from)!).absoluteString, to, from)
        }
        for same in ["https://ntfy.sh:8443/a", "http://home.example/a", "https://notntfy.sh/a", "http://192.168.1.20:8080/a"] {
            XCTAssertEqual(NtfyShAddress.transportURL(URL(string: same)!).absoluteString, same)
        }
    }

    func testCredentialsGoWithTheCanonicalRequestAndStayOffOtherHosts() {
        let credentials = InMemoryCredentialStore()
        _ = credentials.setHTTPHeaders(["X-Token": "secret"], baseUrl: "https://ntfy.sh")
        let api = ApiService(credentialStore: credentials)
        for row in ["http://ntfy.sh", "https://www.ntfy.sh"] {
            let url = URL(string: topicUrl(baseUrl: row, topic: "alerts") + "/json?poll=1")!
            let request = api.newRequest(url: url, baseUrl: row, user: BasicUser(username: "u", password: "p"))
            XCTAssertEqual(request.url?.absoluteString, "https://ntfy.sh/alerts/json?poll=1", row)
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"), row)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Token"), "secret", "headers saved for https://ntfy.sh serve every alias")
            var away = request
            away.url = URL(string: "https://elsewhere.example/x")
            let redirected = ServerCredentials.removingCredentialsFromCrossOriginRedirect(away, baseUrl: row, customHeaderNames: ["X-Token"])
            XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(redirected.value(forHTTPHeaderField: "X-Token"))
            let same = ServerCredentials.removingCredentialsFromCrossOriginRedirect(request, baseUrl: row, customHeaderNames: ["X-Token"])
            XCTAssertNotNil(same.value(forHTTPHeaderField: "Authorization"), "https://ntfy.sh is this row's origin now")
        }
    }

    /// Upgrade fixture: rows saved as http:// and www. keep their spelling, object and messages;
    /// only the transport changes, and a login saved under any spelling serves them.
    func testUpgradedAliasRowsKeepTheirDataAndFindTheLogin() {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        for row in ["http://ntfy.sh", "https://www.ntfy.sh"] {
            let subscription = store.saveSubscription(baseUrl: row, topic: "alerts")
            let id = subscription.objectID
            XCTAssertEqual(store.getBasicUser(baseUrl: row)?.username, "u", row)
            XCTAssertEqual(store.getSubscription(baseUrl: row, topic: "alerts")?.objectID, id)
            XCTAssertEqual(subscription.baseUrl, row)
        }
        XCTAssertNil(store.getBasicUser(baseUrl: "https://home.example"))
    }
}

// MARK: - review-130 #5: an alert claimed before its row exists

final class PresentationClaimTests: XCTestCase {
    /// Red on 0c3563e: the extension's fallback for a poll_request recorded nothing (no row yet),
    /// so the app's next poll alerted the same message again.
    func testAClaimBeforeTheRowExistsKeepsTheLaterPollQuiet() {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        _ = store.saveSubscription(baseUrl: "https://home.example", topic: "door")
        let message = Message(id: "m1_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "open")
        XCTAssertFalse(store.wasAlerted(message: message, baseUrl: "https://home.example"))
        store.recordPresentation(message: message, baseUrl: "https://home.example")
        XCTAssertTrue(store.wasAlerted(message: message, baseUrl: "https://home.example"))
        XCTAssertTrue(store.hasClaimBeforeRow(message: message, baseUrl: "https://home.example/"))
        let other = Message(id: "m2_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "x")
        XCTAssertFalse(store.wasAlerted(message: other, baseUrl: "https://home.example"))
        // The app's poll stores the row later: it is not a candidate to alert.
        _ = store.ingest(pushedMessage: message, baseUrl: "https://home.example", topic: "door")
        XCTAssertTrue(store.alertCandidates(from: [message], baseUrl: "https://home.example").isEmpty)
    }
}

extension PresentationClaimTests {
    /// The claims go with the topic's rows: resubscribing doesn't inherit a deleted topic's claims.
    func testUnsubscribingDropsTheTopicsClaims() {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        let row = store.saveSubscription(baseUrl: "https://home.example", topic: "door")
        let message = Message(id: "m3_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "open")
        store.recordPresentation(message: message, baseUrl: "https://home.example")
        XCTAssertTrue(store.hasClaimBeforeRow(message: message, baseUrl: "https://home.example"))
        XCTAssertTrue(store.delete(subscription: row))
        XCTAssertFalse(store.hasClaimBeforeRow(message: message, baseUrl: "https://home.example"))
    }
}
