import XCTest
import CryptoKit
import UIKit
import SwiftUI
import UserNotifications
@testable import ntfy

/// Answers every request from `reply` and records what was sent. No real network.
private final class BridgeStubProtocol: URLProtocol {
    struct Sent { let request: URLRequest; let body: Data? }
    static var sent: [Sent] = []
    static var reply: (URLRequest) -> Result<(Int, [String: String], String), URLError> = { _ in
        .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
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

/// A fresh directory for a bridge's shared state files, so tests never touch the app group's.
enum BridgeTestState {
    static func directory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-state-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class NtfyShBridgeTests: XCTestCase {
    private var stateDirectory: URL!
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
        stateDirectory = BridgeTestState.directory()
        BridgeStubProtocol.sent = []
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
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
                            appBaseUrl: "https://ntfy-me.com", now: { [unowned self] in self.clock }, stateDirectory: stateDirectory)
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
            return .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
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

    /// The server's own `unwatchable` list (S1) names topics it couldn't watch. Since fix round 2
    /// (review-130b #12) that reads as a refusal, not as "needs a login": the cause isn't given.
    func testUnwatchableFromThePostAndStatusIsShownAsRefused() {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "phil")
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":0,"expires":1900000000,"unwatchable":["phil"]}"#)) }
        sync()
        XCTAssertEqual(bridge.currentRecord.unwatchable, ["phil"])
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "phil", wakes: nil), .held(.refused))
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"connected":true,"unwatchable":[]}"#)) }
        let done = expectation(description: "status")
        bridge.fetchStatus { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(bridge.currentRecord.unwatchable, [])
        // review-130 #4: the refusal is cached, so it stays out until a fresh anonymous 200.
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "phil", wakes: nil), .held(.refused))
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
        let wakes = SelfHostedWakeCheck(defaults: wakeDefaults, network: false, now: { [unowned self] in self.clock },
                                        stateDirectory: BridgeTestState.directory())
        for (base, topic) in [("https://ntfy.sh", "alerts"), ("http://www.ntfy.sh", "lights"), ("https://ntfy.sh", "bad name"),
                              ("https://home.example", "garage"), ("https://home.example", "backups"), ("https://ntfy-me.com", "own")] {
            save(base, topic)
        }
        sync()
        let garage = topicHash(baseUrl: "https://home.example", topic: "garage")
        // A "Check again" miss with the connection confirmed.
        wakeDefaults.set(try JSONEncoder().encode([garage: SelfHostedWakeCheck.Entry(misses: 1, lastWake: nil, lastCheck: clock, watchedSince: clock)]),
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
                            appBaseUrl: "https://ntfy-me.com", now: { [unowned self] in self.clock },
                            stateDirectory: stateDirectory, isExtension: true)
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
        let first = NtfyShBridge(store: store, defaults: defaults, network: false, lock: SharedFileLock(path: path), stateDirectory: stateDirectory)
        let second = NtfyShBridge(store: store, defaults: defaults, network: false, lock: SharedFileLock(path: path), stateDirectory: stateDirectory)
        var ids = [String](repeating: "", count: 64)
        let idsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let id = (i % 2 == 0 ? first : second).deviceId ?? "lock timed out"
            idsLock.lock(); ids[i] = id; idsLock.unlock()
        }
        XCTAssertEqual(Set(ids).count, 1)
        XCTAssertEqual(first.existingDeviceId, ids[0])
    }

    /// Red on 0c3563e: the reply to an older registration overwrote the record of a newer one
    /// (another process or a rerun had started since).
    func testAReplyToAnOlderRegistrationIsDropped() throws {
        save("https://ntfy.sh", "a")
        let file = bridge.recordFile
        BridgeStubProtocol.reply = { _ in
            // A newer registration starts elsewhere while this one is on the wire.
            file.update { record -> (write: Bool, result: Void) in
                var next = record ?? BridgeRecord()
                next.revision = (next.revision ?? 0) + 1
                record = next
                return (true, ())
            }
            return .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
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
            request.httpMethod == "GET" ? .success((404, [:], "")) : .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
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
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .held(.upstreamPending))
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
                : .success((200, [:], #"{"watching":0,"expires":1900000000,"unwatchable":["a_q7x"]}"#))
        }
        sync()
        // Red on 15669a0 (review-130b #12): any refusal read as "needs a login".
        XCTAssertEqual(bridge.access["a_q7x"]?.state, .refused)
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, [])
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a_q7x", fcmBound: true), .held(.refused))
    }

    /// Red on 0c3563e: a 200 cached for a week kept a name in the set after it was made private.
    /// Red on 15669a0 (review-130b #4): a name the server already held stayed in every full
    /// replacement while its recheck was outstanding, with no bound. Now, with a login, a 200 is
    /// sendable for 36 hours (rechecked from 24), and past that the name is held, accepted or not.
    func testAPositiveIsSendableFor36HoursThenHeldUntilRechecked() throws {
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        save("https://ntfy.sh", "a_q7x")
        save("https://ntfy.sh", "b_q7x")
        sync()
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, ["a_q7x", "b_q7x"])
        let subs: [(baseUrl: String, topic: String, hasLogin: Bool)] = [("https://ntfy.sh", "a_q7x", true)]
        let checked = clock
        func at(_ hours: Double) -> BridgeWatchSet {
            BridgeWatchSet.compute(subscriptions: subs, access: ["a_q7x": NtfyShAccess(state: .open, checked: checked)],
                                   now: checked.addingTimeInterval(hours * 3600), appBaseUrl: "https://ntfy-me.com")
        }
        XCTAssertEqual(at(23).needsProbe, [])
        XCTAssertEqual(at(25).ntfyShTopics, ["a_q7x"], "inside 36 h: still sent")
        XCTAssertEqual(at(25).needsProbe, ["a_q7x"], "from 24 h: rechecked")
        XCTAssertEqual(at(35.9).ntfyShTopics, ["a_q7x"])
        XCTAssertEqual(at(36.1).ntfyShTopics, [], "past 36 h: never sent on an old answer")
        XCTAssertEqual(at(36.1).held.map(\.hold), [.checkingAccess])
        XCTAssertEqual(at(36.1).needsProbe, ["a_q7x"])
        // Without a login nothing is withheld: ntfy.sh's own answer decides.
        let anonymous = BridgeWatchSet.compute(subscriptions: [("https://ntfy.sh", "a_q7x", false)], access: [:],
                                               now: clock, appBaseUrl: "https://ntfy-me.com")
        XCTAssertEqual(anonymous.ntfyShTopics, ["a_q7x"])
        clock += 2 * 24 * 3600
        // The recheck says private now: it goes.
        BridgeStubProtocol.reply = { request in
            request.url?.path == "/a_q7x/auth" ? .success((401, [:], "")) : .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
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
            default: return .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
            }
        }
        sync()
        XCTAssertEqual(bridge.access["a_q7x"]?.state, .open)
        // Since fix round 2 (review-130b #4) a rate-limited check is recorded as a failure: with a
        // login saved, the name then waits for a fresh 200.
        XCTAssertEqual(bridge.access["b_q7x"]?.state, .unknown)
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
                                        schedule: { _, work in work() }, now: { [unowned self] in self.clock }, stateDirectory: stateDirectory)
        XCTAssertNil(wakes.plan(hash: topicHash(baseUrl: "https://home.example", topic: "g"), messageTime: clock))
        let status = expectation(description: "status")
        // Since fix round 2 (review-130b #7) it says when it will ask again, not "Couldn't check".
        bridge.fetchStatus { result in
            if case .waiting = result {} else { XCTFail("\(result)") }
            status.fulfill()
        }
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
        XCTAssertEqual(NtfyMeHostCooldown.read(bridge.lock).notBefore(now: clock), clock.addingTimeInterval(30))
        clock += 31
        sync()
        XCTAssertEqual(NtfyMeHostCooldown.read(bridge.lock).notBefore(now: clock), clock.addingTimeInterval(60))
        let sent = BridgeStubProtocol.sent.count
        clock += 30
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, sent, "inside the backoff")
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
        let user = expectation(description: "user")
        bridge.sync(reason: "setting", userInitiated: true) { user.fulfill() }
        wait(for: [user], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.count, sent + 1)
        XCTAssertNil(NtfyMeHostCooldown.read(bridge.lock).notBefore(now: clock), "a success clears it")
        for _ in 0..<20 { NtfyMeHostCooldown.note(status: 500, retryAfter: nil, lock: bridge.lock, now: clock) }
        XCTAssertEqual(NtfyMeHostCooldown.read(bridge.lock).notBefore(now: clock), clock.addingTimeInterval(3600), "capped at an hour")
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
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
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
            return .success((200, [:], #"{"watching":2,"expires":1900000000,"connected":true}"#))
        }
        _ = bridge.deviceId
        var statuses: [NtfyShBridge.Status] = []
        let first = expectation(description: "status")
        bridge.fetchStatus { statuses.append($0); first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertEqual(BridgeStubProtocol.sent.last?.request.url?.query, "device=\(bridge.deviceId ?? "none")")
        BridgeStubProtocol.reply = { _ in .success((404, [:], "")) }
        let second = expectation(description: "unknown")
        bridge.fetchStatus { statuses.append($0); second.fulfill() }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(statuses, [.connected(watching: 2), .unknownDevice])
    }

    func testDiagnosticSummaryHasNoTopicNamesOrDeviceId() throws {
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "secret_topic_name")
        sync()
        let summary = bridge.diagnosticSummary
        XCTAssertFalse(summary.contains("secret_topic_name"))
        XCTAssertFalse(summary.contains(try XCTUnwrap(bridge.deviceId)))
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
        "On, NTF-AI sends %@ an installation ID made only for this, the names of your ntfy.sh topics, and a hash of each topic address on your other servers. %@ watches those topics on ntfy.sh and wakes this device when a message arrives; it sees messages in passing and keeps no message text. If you saved credentials for ntfy.sh, or NTF-AI can't tell whether you did, it first asks ntfy.sh, without your credentials, whether anyone can read each topic, and sends only topics anyone can read. Without saved credentials, a topic name is sent without that check when it is first registered. About a day after %@ says it can't watch a topic, NTF-AI checks once more whether anyone can read it, with or without a login. When a topic stops qualifying, or you turn this off, NTF-AI asks %@ to stop watching it. When you tap Check again for a topic on your other servers, NTF-AI asks %@ whether a wake-up for its hash went through. Off, once %@ has removed them, ntfy.sh topics and topics on servers whose upstream is ntfy.sh stop getting instant banners and show new messages only when you open the app or refresh.",
        "For these topics, opening the app lets it set up or repair banners. NTF-AI also keeps this device's list current in the background when the system allows it, which isn't guaranteed.",
        "A server whose upstream is %@ can still wake this device directly, if that server is set up for it and push works on this device.",
        "Instant banners", "Watching %lld", "Show %lld more",
        "This topic on ntfy.sh can't be read without a login, so it gets no instant banners. With your login saved, its messages show when you open the app or refresh.",
        "Checking whether this topic is public on ntfy.sh. NTF-AI checks when it next runs, about once a day. Until then, new messages show when you open the app.",
        "Waiting to check whether this topic is public on ntfy.sh. NTF-AI checks a few topics each time it runs, and this one is waiting its turn. Until then, new messages show when you open the app.",
        "%@ couldn't watch this topic on ntfy.sh, so it gets no instant banners for now. NTF-AI checks again when it next runs, about once a day. Until then, new messages show when you open the app.",
        "This address or topic name can't be watched on ntfy.sh, so new messages show when you open the app.",
        "Over the limit of 100 topics per list, so new messages show when you open the app.",
        "Instant banners through ntfy.sh are off in Settings. Messages that would come through ntfy.sh show when you open the app.",
        "Asking %@ to stop watching this device's topics. If it hasn't confirmed yet, NTF-AI asks again the next time it runs.",
        "%@ couldn't take this device's list. NTF-AI tries again the next time it runs. Until then, messages that would come through ntfy.sh show when you open the app.",
        "Being added to what %@ watches. Once it accepts the list, a message to this topic can wake this device.",
        "%@ no longer has this device's list. NTF-AI sends it again the next time it runs; if banners don't return, open NTF-AI.",
        "%@ may not be watching all of this device's ntfy.sh topics right now. It may be reconnecting, or waiting until ntfy.sh accepts more requests. Until then, some new messages may show only when you open the app.",
        "This device hasn't finished push setup for this topic yet. Until then, new messages show when you open the app.",
        "No recent forwarding confirmed for this server. If banners don't come, its upstream-base-url may not be https://ntfy.sh, or its base-url may not be exactly %@. Check again to test with the next message.",
        "Check again", "NTF-AI checks the next eligible message from this server that arrives within 24 hours.", "Pending", "Unavailable, will retry",
        "This message isn't available from %@ right now. It may have expired, the server may not keep messages, or it may not have arrived there yet.",
        "No wake-up arrived for recent messages, so this server isn't set up for instant banners. Ask its admin to set upstream-base-url to https://ntfy.sh and base-url to exactly %@, the address this app uses. Until then, new messages show when you open the app.",
        "Last registration", "Never", "Bridge connection",
        "Checking…", "Accepted", "Rejected by the server", "Rate limited, will retry", "Bridge full, will retry",
        "Server error, will retry", "No connection, will retry", "Connected", "Some topics may be waiting for push", "Waiting to retry", "Waiting to retry after %@",
        "Removing %lld topics from %@", "%@ hasn't confirmed yet. NTF-AI asks again the next time it runs.", "Watch limit reached, will retry",
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
                        "%@ is busy or unreachable and will retry on its own. Until then, new messages show when you open the app.",
                        // Retired in fix round 2 (review-130b #10, #11, #12).
                        "Reconnecting to ntfy.sh", "%@ is reconnecting to ntfy.sh. Until it is back, new messages show when you open the app.",
                        "A server whose upstream is %@ still wakes this device.", "The next message from this server will be checked.",
                        "This message is no longer on %@, or the server doesn't keep messages.",
                        "Being added to what %@ watches. Instant banners start once it accepts the list.",
                        "Checking with ntfy.sh whether anyone can read this topic. Until then, new messages show when you open the app.",
                        "Instant banners start once NTF-AI has been opened after installing or updating. NTF-AI keeps this device's list current in the background when the system allows it, which isn't guaranteed; if banners stop, open NTF-AI.",
                        // Retired in fix round 3 (review-130c C8, C9).
                        "ntfy.sh didn't let NTF-AI check this topic, so it gets no instant banners for now. NTF-AI checks again when it next runs, about once a day. Until then, new messages show when you open the app.",
                        "Removing this device's topics from %@. NTF-AI tries again the next time it runs.",
                        "%@ isn't watching ntfy.sh for this device right now. It may be reconnecting, or waiting until ntfy.sh accepts more requests. Until then, new messages show when you open the app.",
                        "Not watching ntfy.sh right now", "Will check again shortly",
                        "NTF-AI checks the next message from this server that arrives within a day.",
                        // Retired in fix round 4 (review-130d D6, D8).
                        "Topics added as http://ntfy.sh or www.ntfy.sh get instant banners too.",
                        "Notification status lists each topic that won't get instant banners and why, including a self-hosted server that isn't set up for them.",
                        "Background wake-ups now renew instant banners, so you rarely need to open the app to keep them."] {
            XCTAssertFalse(keys.contains(retired), retired)
        }
        XCTAssertFalse(keys.contains { $0.hasPrefix("%@ watches your ntfy.sh topics") })
        XCTAssertFalse(keys.contains { $0.contains("within about a day") })
        XCTAssertFalse(keys.contains { $0.contains("For your other servers, NTF-AI may ask") })
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
        XCTAssertEqual(missing.body, String(localized: "This message isn't available from \("home.example") right now. It may have expired, the server may not keep messages, or it may not have arrived there yet."))
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
    private var dir: URL!

    override func setUp() {
        super.setUp()
        suite = "SelfHostedWakeCheckTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        dir = BridgeTestState.directory()
        check = SelfHostedWakeCheck(defaults: defaults, relayBaseUrl: "https://ntfy-me.com", read: { [unowned self] request, done in
            self.sent.append(request)
            let (status, body) = self.replies.isEmpty ? (200, #"{"relayed":false,"relayed_at":null,"window_seconds":120}"#) : self.replies.removeFirst()
            done(Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil), nil)
        }, schedule: { [unowned self] delay, work in self.clock = self.clock.addingTimeInterval(delay); work() },
           now: { [unowned self] in self.clock }, stateDirectory: dir)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var garageHash: String { topicHash(baseUrl: base, topic: "garage") }

    /// One fresh message found by a poll after "Check again" (`armed`), for the watch that began at
    /// `watchStart`; the verdict, if a check ran.
    @discardableResult
    private func arrive(age: TimeInterval = 2, topic: String = "garage", strong: Bool = true, armed: Bool = true,
                        watch: @escaping () -> Date? = { .distantPast }) -> SelfHostedWakeCheck.Verdict? {
        if armed { check.arm(hash: topicHash(baseUrl: base, topic: topic)) }
        var verdict: SelfHostedWakeCheck.Verdict?? = .none
        check.messageArrivedByPoll(baseUrl: base, topic: topic, messageTime: clock.addingTimeInterval(-age),
                                   watch: watch, evidence: { strong }) { verdict = .some($0) }
        return verdict ?? nil
    }

    /// Red on b0f4a48: a server that never forwarded looked the same as a working one. Since fix
    /// round 4 the hard state comes only from a "Check again" miss with the connection confirmed.
    func testACheckAgainMissFlagsNotSetUpAndAWakeClearsIt() throws {
        XCTAssertEqual(arrive(), .missed)
        XCTAssertEqual(sent.count, 1)
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy-me.com/v1/ntfyme/relay-check")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String], ["hash": garageHash])
        XCTAssertTrue(check.isNotSetUp(hash: garageHash))
        XCTAssertFalse(check.isArmed(hash: garageHash), "one message per tap")
        check.recordWake(hash: garageHash)
        XCTAssertFalse(check.isNotSetUp(hash: garageHash))
    }

    /// Red on 0c3563e (review-130 #8): misses while the bridge's connection wasn't confirmed told
    /// the admin to fix a server that may be fine. Weak evidence says only "not confirmed".
    func testMissesWithoutConfirmedForwardingAreOnlyUnconfirmed() {
        for _ in 0..<3 {
            XCTAssertEqual(arrive(strong: false), .missed)
            clock = clock.addingTimeInterval(SelfHostedWakeCheck.globalInterval)
        }
        XCTAssertEqual(check.diagnosis(hash: garageHash), .unconfirmed)
        XCTAssertFalse(check.isNotSetUp(hash: garageHash))
    }

    /// Red on 0c3563e: a wake recorded by the extension while the check was on the wire was
    /// overwritten by the miss computed before it.
    func testAWakeThatLandsDuringTheCheckWins() {
        let lateWake = SelfHostedWakeCheck(defaults: defaults, relayBaseUrl: "https://ntfy-me.com", read: { [unowned self] request, done in
            self.clock = self.clock.addingTimeInterval(1)
            SelfHostedWakeCheck(defaults: self.defaults, network: false, now: { self.clock }, stateDirectory: self.dir).recordWake(hash: self.garageHash)
            done(Data(#"{"relayed":false,"relayed_at":null,"window_seconds":120}"#.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }, schedule: { _, work in work() }, now: { [unowned self] in self.clock }, stateDirectory: dir)
        check = lateWake
        _ = arrive()
        XCTAssertEqual(check.entry(hash: garageHash)?.misses, 0)
        XCTAssertNil(check.entry(hash: garageHash)?.weakMisses)
    }

    /// At most one relay check a minute across all topics, so many taps can't burst the relay.
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
            clock = clock.addingTimeInterval(NtfyMeHostCooldown.maxRetryAfter + 1)
        }
        XCTAssertEqual(check.entry(hash: garageHash)?.misses, 0)
    }

    /// Fix round 4 (review-130d D6): nothing is looked up that "Check again" didn't ask for.
    func testNoCheckUnlessArmedOrForOldMessages() {
        XCTAssertNil(arrive(armed: false), "nobody asked")
        XCTAssertNil(arrive(age: 300), "the relay keeps 120 s")
        XCTAssertEqual(sent.count, 0)
        clock = clock.addingTimeInterval(SelfHostedWakeCheck.globalInterval)
        XCTAssertEqual(arrive(), .missed)
        XCTAssertEqual(sent.count, 1)
    }

    func testWaitsUntilTheForwardHadTimeToLand() {
        var waited: TimeInterval = 0
        check = SelfHostedWakeCheck(defaults: defaults, relayBaseUrl: "https://ntfy-me.com", read: { _, done in
            done(Data(#"{"relayed":false,"relayed_at":null,"window_seconds":120}"#.utf8),
                 HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }, schedule: { delay, work in waited = delay; work() }, now: { [unowned self] in self.clock }, stateDirectory: dir)
        arrive(age: 1)
        XCTAssertGreaterThan(waited, 0)
        XCTAssertEqual(waited, SelfHostedWakeCheck.minMessageAge - 1, accuracy: 0.001)
    }

    /// Only polled self-hosted messages, and only for a hash the bridge's last accepted list holds.
    func testOnlyPolledSelfHostedMessagesTheBridgeHoldsAreChecked() throws {
        let m = Message(id: "m", time: Int64(clock.timeIntervalSince1970) - 2, event: "message", topic: "garage")
        let bridge = NtfyShBridge(store: Store(inMemory: true, credentialStore: InMemoryCredentialStore()), defaults: defaults,
                                  network: false, appBaseUrl: "https://ntfy-me.com", now: { [unowned self] in self.clock },
                                  stateDirectory: BridgeTestState.directory())
        check.arm(hash: garageHash)
        for server in ["https://ntfy.sh", "https://ntfy-me.com", base] {
            SubscriptionManager.checkWakeUps(baseUrl: server, messages: [m], check: check, bridge: bridge, appBaseUrl: "https://ntfy-me.com",
                                             subscribed: { _, _ in true })
        }
        XCTAssertEqual(sent.count, 0, "not admitted: the bridge never accepted this hash")
        var record = BridgeRecord()
        record.acceptedSignature = "t:|h:" + garageHash
        record.lastOutcome = .ok
        bridge.recordFile.update { stored -> (write: Bool, result: Void) in stored = record; return (true, ()) }
        SubscriptionManager.checkWakeUps(baseUrl: base, messages: [m], check: check, bridge: bridge, appBaseUrl: "https://ntfy-me.com",
                                         subscribed: { _, _ in true })
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

// MARK: - 1.30 fix round 2 (review-130b)

extension NtfyShBridgeTests {
    private func spin(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private var watchPosts: Int {
        BridgeStubProtocol.sent.filter { $0.request.httpMethod == "POST" && $0.request.url?.path == "/v1/ntfai/watch" }.count
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeStubProtocol.self]
        return URLSession(configuration: config)
    }

    private func until(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { spin(0.05) }
        return condition()
    }

    // A: observer recursion

    /// Red on 15669a0 (review-130b A): `reload()` posted the notification that the status screen
    /// and Topic details answer with `reload()`.
    func testReloadNeverPostsTheChangeNotification() {
        save("https://ntfy.sh", "a")
        sync()
        spin()
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: .ntfyShBridgeStateChanged, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        bridge.reload()
        let other = makeBridge()
        other.reload()
        spin()
        XCTAssertEqual(posts, 0)
    }

    /// Red on 15669a0 (review-130b A): the first change posted while the screen was open recursed
    /// until the stack overflowed. Hosted unseeded: a post terminates, and a real change written
    /// by another writer on the same files (as the extension is) reaches the open screen.
    func testTheHostedStatusScreenSurvivesAChangeAndShowsIt() {
        save("https://ntfy.sh", "a")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: List { NtfyShBridgeStatusRows(bridge: bridge, subscriptionCount: 1) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        spin(0.3)
        NotificationCenter.default.post(name: .ntfyShBridgeStateChanged, object: nil)
        spin(0.3)
        // Another writer registers; the Darwin signal brings the open screen's bridge up to date.
        BridgeStateSignal.observeOtherProcesses()
        let other = makeBridge()
        let done = expectation(description: "other writer")
        other.sync(reason: "other process") { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(other.currentRecord.acceptedSignature)
        XCTAssertTrue(until { self.bridge.record == other.currentRecord }, "the open screen re-read the other writer's record")
    }

    // E: unreadable store

    /// Red on 15669a0 (review-130b E): an unreadable store read as no subscriptions, and the empty
    /// replacement removed every name the server held.
    func testAnUnreadableStoreSendsNoReplacement() throws {
        save("https://ntfy.sh", "a")
        sync()
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["a"])
        let posts = watchPosts
        bridge.readSubscriptions = { nil }
        clock += 2 * 24 * 3600
        sync("store unreadable")
        XCTAssertEqual(watchPosts, posts, "no replacement from an unreadable store")
        XCTAssertNotNil(bridge.currentRecord.acceptedSignature)
        XCTAssertEqual(bridge.subscribedSet(), .empty, "the screens show nothing rather than a guess")
    }

    // #4: names that may be protected

    /// Red on 15669a0 (review-130b #4): a Keychain read failure read as "no headers", so the name
    /// went out unchecked. Unknown credentials count as a login, and a failed check withholds it.
    func testAnUnreadableKeychainCountsAsALogin() throws {
        let credentials = try XCTUnwrap(store.credentialStore as? InMemoryCredentialStore)
        credentials.setHeaderReadsFail(true)
        save("https://ntfy.sh", "a_q7x")
        BridgeStubProtocol.reply = { request in
            request.url?.path == "/a_q7x/auth" ? .success((429, [:], "")) : .success((200, [:], #"{"watching":0,"expires":1900000000}"#))
        }
        sync()
        XCTAssertTrue(BridgeStubProtocol.sent.contains { $0.request.url?.path == "/a_q7x/auth" }, "checked first")
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, [])
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a_q7x", fcmBound: true), .held(.checkingAccess))
    }

    /// Red on 15669a0 (review-130b #4): a name the server already held stayed in every
    /// replacement while its recheck failed. A failed or rate-limited recheck withholds it until a fresh 200.
    func testAFailedRecheckWithholdsTheNameUntilAFresh200() throws {
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        save("https://ntfy.sh", "a_q7x")
        sync()
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["a_q7x"])
        clock += 25 * 3600
        BridgeStubProtocol.reply = { request in
            request.url?.path == "/a_q7x/auth" ? .success((429, ["Retry-After": "60"], "")) : .success((200, [:], #"{"watching":0,"expires":1900000000}"#))
        }
        sync()
        XCTAssertEqual(bridge.subscribedSet().ntfyShTopics, [])
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a_q7x", fcmBound: true), .held(.checkingAccess))
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], [], "the replacement drops it")
        clock += 2 * 3600
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
        sync()
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["a_q7x"], "a fresh 200 brings it back")
    }

    /// Red on 15669a0 (review-130b #4): the last answer saved won, so a check that started before
    /// the relay's refusal could undo it.
    func testNewerAccessEvidenceWins() {
        let refusal = NtfyShAccess(state: .refused, checked: clock)
        let olderCheck = NtfyShAccess(state: .open, checked: clock.addingTimeInterval(-5))
        XCTAssertEqual(refusal.merged(with: olderCheck), refusal)
        XCTAssertEqual(olderCheck.merged(with: refusal), refusal)
        let failed = NtfyShAccess(state: .unknown, checked: clock.addingTimeInterval(10))
        XCTAssertEqual(refusal.merged(with: failed).state, .refused, "a failed check isn't evidence")
        XCTAssertEqual(refusal.merged(with: failed).failedAt, clock.addingTimeInterval(10))
        XCTAssertFalse(refusal.merged(with: failed).mayCheck(now: clock.addingTimeInterval(20)))
    }

    /// Red on 15669a0 (review-130b #4): saving, editing or removing a credential changed nothing
    /// until some later trigger, so a name could go out unchecked meanwhile.
    func testACredentialChangeReevaluatesTheList() {
        save("https://ntfy.sh", "a_q7x")
        let watcher = NtfyShBridge(store: store, defaults: defaults, session: stubSession(), appBaseUrl: "https://ntfy-me.com",
                                   now: { [unowned self] in self.clock }, stateDirectory: stateDirectory,
                                   isExtension: false, observesCredentialChanges: true)
        let done = expectation(description: "first")
        watcher.sync(reason: "first") { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertFalse(BridgeStubProtocol.sent.contains { $0.request.url?.path == "/a_q7x/auth" }, "no login: no check")
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        ServerCredentialChange.announce()
        XCTAssertTrue(until { BridgeStubProtocol.sent.contains { $0.request.url?.path == "/a_q7x/auth" } }, "re-evaluated: now checked")
        withExtendedLifetime(watcher) {}
    }

    // #1 and D: shared state

    /// Red on 15669a0 (review-130b #1): the shared lock waited without bound. Now a busy lock skips
    /// the operation after its timeout, never running it unlocked.
    func testABusySharedLockSkipsTheOperation() {
        let path = NSTemporaryDirectory() + "bridge-lock-\(UUID()).lock"
        let holder = SharedFileLock(path: path)
        let waiter = SharedFileLock(path: path)
        let held = expectation(description: "held")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { holder.withLock { held.fulfill(); release.wait() } }
        wait(for: [held], timeout: 2)
        let started = Date()
        var ran = false
        XCTAssertNil(waiter.withLock(timeout: 0.2) { ran = true })
        XCTAssertFalse(ran)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        release.signal()
        XCTAssertNotNil(waiter.withLock(timeout: 2) { ran = true })
        XCTAssertTrue(ran)
    }

    /// Red on 15669a0 (review-130b D): a renewal answer was applied to whatever registration was
    /// current when it landed, so a 40400 for an older one asked a newer one for repair.
    func testARenewalAnswerForAnOlderRegistrationIsDropped() {
        let nse = extensionBridge()
        save("https://ntfy.sh", "a")
        sync()
        clock += 8 * 24 * 3600
        let file = bridge.recordFile
        BridgeStubProtocol.reply = { _ in
            file.update { stored -> (write: Bool, result: Void) in
                var next = stored ?? BridgeRecord()
                next.revision = (next.revision ?? 0) + 1
                stored = next
                return (true, ())
            }
            return .success((404, [:], #"{"code":40400,"error":"no such device"}"#))
        }
        renew(nse)
        XCTAssertNil(bridge.currentRecord.repairRequested, "the answer belonged to the registration it replaced")
        XCTAssertNil(bridge.currentRecord.lastRenewAttempt.flatMap { _ in bridge.currentRecord.renewMissed })
    }

    /// Red on 15669a0 (review-130b, generic 404): a 404 without S8's code deferred renewal until
    /// the app next registered, which a banner-only user may never do. Now it retries about daily.
    func testAGeneric404RenewalIsRetriedAboutOnceADay() {
        let nse = extensionBridge()
        save("https://ntfy.sh", "a")
        sync()
        clock += 8 * 24 * 3600
        BridgeStubProtocol.reply = { _ in .success((404, [:], #"{"error":"page not found"}"#)) }
        renew(nse)
        XCTAssertEqual(bridge.currentRecord.renewMissed, true)
        let count = BridgeStubProtocol.sent.count
        clock += 2 * 3600
        renew(nse)
        XCTAssertEqual(BridgeStubProtocol.sent.count, count, "not hourly")
        clock += NtfyShBridge.renewMissedRetryInterval
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"expires":1900000000}"#)) }
        renew(nse)
        XCTAssertEqual(BridgeStubProtocol.sent.count, count + 1, "retried after a day")
        XCTAssertNil(bridge.currentRecord.renewMissed)
    }

    // #7: status truth

    /// Red on 15669a0 (review-130b #7): an answer overtaken by a newer status read still landed,
    /// in the record and on screen. Since fix round 3 (review-130c C7) reads are coalesced, so a
    /// read is overtaken only when the screen cancels it (left, or the setting changed) and asks anew.
    func testAnOvertakenStatusAnswerIsDropped() {
        save("https://ntfy.sh", "a")
        sync()
        let bridge = self.bridge!
        var first: NtfyShBridge.Status?
        let second = expectation(description: "newest")
        var newest: NtfyShBridge.Status?
        var asked = 0
        BridgeStubProtocol.reply = { request in
            guard request.httpMethod == "GET" else { return .success((200, [:], "{}")) }
            asked += 1
            if asked == 1 {
                // The screen drops the read on the wire and starts a newer one.
                bridge.cancelStatus()
                bridge.fetchStatus { newest = $0; second.fulfill() }
                return .success((200, [:], #"{"watching":1,"connected":false}"#))
            }
            return .success((200, [:], #"{"watching":1,"connected":true}"#))
        }
        bridge.fetchStatus { first = $0 }
        wait(for: [second], timeout: 5)
        spin(0.3)
        XCTAssertEqual(newest, .connected(watching: 1))
        XCTAssertNil(first, "the overtaken answer never reaches the screen")
        XCTAssertEqual(bridge.currentRecord.statusConnected, true)
    }

    /// Red on 15669a0 (review-130b #7): an expired registration still read as watched, and a topic
    /// on the app's own server read as direct before its push binding was confirmed.
    func testWatchingRespectsExpiryAndDirectNeedsPush() {
        save("https://ntfy.sh", "a")
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1800003600}"#)) }
        sync()
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .watched)
        clock += 3601
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "a", fcmBound: true), .held(.notRegistered))
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy-me.com", topic: "x", fcmBound: false), .held(.pushNotReady))
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy-me.com", topic: "x", fcmBound: true), .direct)
    }

    /// Red on 15669a0 (review-130b #7): a status read skipped for the cooldown showed
    /// "Couldn't check" for the rest of the visit. It says when it will ask again.
    func testAStatusReadInTheCooldownWaits() {
        save("https://ntfy.sh", "a")
        sync()
        NtfyMeHostCooldown.note(status: 429, retryAfter: "120", lock: bridge.lock, now: clock)
        var status: NtfyShBridge.Status?
        let read = expectation(description: "status")
        bridge.fetchStatus { status = $0; read.fulfill() }
        wait(for: [read], timeout: 5)
        XCTAssertEqual(status, .waiting(until: clock.addingTimeInterval(120)))
        XCTAssertEqual(NtfyShBridgeCopy.status(.waiting(until: .distantPast)), String(localized: "Waiting to retry"))
    }

    // #8: forwarding evidence

    /// Red on 15669a0 (review-130b #8): a connected status up to a day old, for any registration,
    /// made a miss strong. Now it must be within 10 minutes and for the current registration.
    func testStrongEvidenceNeedsARecentStatusForThisRegistration() {
        let base = "http://192.168.1.20:8099"
        save(base, "garage")
        sync()
        let hash = topicHash(baseUrl: base, topic: "garage")
        BridgeStubProtocol.reply = { request in
            request.httpMethod == "GET" ? .success((200, [:], #"{"watching":1,"connected":true}"#))
                : .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
        }
        let read = expectation(description: "status")
        bridge.fetchStatus { _ in read.fulfill() }
        wait(for: [read], timeout: 5)
        XCTAssertTrue(bridge.forwardingEvidence(hash: hash))
        clock += 11 * 60
        XCTAssertFalse(bridge.forwardingEvidence(hash: hash), "over 10 minutes old")
        clock -= 11 * 60
        bridge.recordFile.update { stored -> (write: Bool, result: Void) in
            var next = stored ?? BridgeRecord()
            next.revision = (next.revision ?? 0) + 1
            next.acceptedRevision = next.revision
            stored = next
            return (true, ())
        }
        XCTAssertFalse(bridge.forwardingEvidence(hash: hash), "read for an earlier registration")
    }

    // #9: cooldown scope

    /// Red on 15669a0 (review-130b #9): an unrelated success ended a pause the server asked for, and
    /// a later failure without Retry-After could shorten it.
    func testTheStrongestCooldownWins() {
        let lock = SharedFileLock(path: NSTemporaryDirectory() + "cd-\(UUID()).lock")
        NtfyMeHostCooldown.note(status: 429, retryAfter: "600", lock: lock, now: clock)
        NtfyMeHostCooldown.note(status: 200, retryAfter: nil, lock: lock, now: clock.addingTimeInterval(1))
        XCTAssertEqual(NtfyMeHostCooldown.blockedUntil(lock, now: clock.addingTimeInterval(2)), clock.addingTimeInterval(600))
        NtfyMeHostCooldown.note(status: 503, retryAfter: nil, lock: lock, now: clock.addingTimeInterval(3))
        XCTAssertEqual(NtfyMeHostCooldown.blockedUntil(lock, now: clock.addingTimeInterval(4)), clock.addingTimeInterval(600))
        XCTAssertEqual(NtfyMeHostCooldown.blockedUntil(lock, now: clock.addingTimeInterval(4), userInitiated: true),
                       clock.addingTimeInterval(600), "the server's pause holds even for the user")
        XCTAssertNil(NtfyMeHostCooldown.blockedUntil(lock, now: clock.addingTimeInterval(601)))
    }

    /// Red on 15669a0 (review-130b #9): 42912 (this network's watch admission limit) paused every
    /// request to the server. It pauses only lists that add entries; removals still go out.
    func testAdmissionLimitHoldsAdditionsButNotRemovals() throws {
        save("https://ntfy.sh", "a")
        sync()
        let b = save("https://ntfy.sh", "b")
        BridgeStubProtocol.reply = { _ in .success((429, ["Retry-After": "3600"], #"{"code":42912,"error":"admission limit"}"#)) }
        sync()
        XCTAssertEqual(bridge.currentRecord.lastOutcome, .admissionLimited)
        XCTAssertNil(NtfyMeHostCooldown.blockedUntil(bridge.lock, now: clock), "not a pause for every request")
        let posts = watchPosts
        clock += 60
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":0,"expires":1900000000}"#)) }
        sync()
        XCTAssertEqual(watchPosts, posts, "still adds b: waits")
        XCTAssertTrue(store.delete(subscription: b))
        XCTAssertTrue(store.delete(subscription: try XCTUnwrap(store.getSubscription(baseUrl: "https://ntfy.sh", topic: "a"))))
        sync()
        XCTAssertEqual(watchPosts, posts + 1, "a removal goes out")
        // Since fix round 3 a removal's 200 says nothing about admission (it is exempt, S9).
        XCTAssertNotNil(bridge.currentRecord.admissionBlockedUntil)
    }

    // #2: the ~poll wake budget

    /// Red on 15669a0 (review-130b #2): the wake's watchdog ran on main, so a busy main thread
    /// could push the completion past the system's limit. Maintenance needs enough budget left.
    func testTheWakeWatchdogFiresWhileMainIsBusy() {
        let lock = NSLock()
        var result: UIBackgroundFetchResult?
        let wake = BackgroundWakeCompletion(deadline: 0.2) { outcome in lock.lock(); result = outcome; lock.unlock() }
        Thread.sleep(forTimeInterval: 0.6)
        lock.lock(); let got = result; lock.unlock()
        XCTAssertEqual(got, .noData)
        XCTAssertFalse(wake.isPending)
        XCTAssertFalse(wake.admitsMaintenance)
        XCTAssertFalse(BackgroundWakeCompletion(deadline: BackgroundWakeCompletion.maintenanceMinimum - 1) { _ in }.admitsMaintenance)
        XCTAssertTrue(BackgroundWakeCompletion(deadline: BackgroundWakeCompletion.budget) { _ in }.admitsMaintenance)
    }

    /// Red on 6b139b8 (review-130c C4): the content polls, presentation and bridge maintenance each
    /// kept their own clock. They share the wake's context, which ends with the wake's deadline.
    func testTheWakeDeadlineEndsTheSharedContext() {
        let finish = BackgroundWakeCompletion(deadline: 0.2) { _ in }
        XCTAssertFalse(finish.wake.isCancelled)
        XCTAssertGreaterThan(finish.wake.remaining, 0)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(finish.wake.isCancelled)
        XCTAssertEqual(finish.wake.remaining, 0)
    }
}

extension SelfHostedWakeCheckTests {
    /// Red on 15669a0 (review-130b #8): "Check again" was view state, so an inconclusive check left
    /// it armed forever. It clears on any verdict and lapses after a day.
    func testCheckAgainClearsOnAnyVerdictAndLapses() {
        let hash = topicHash(baseUrl: "http://192.168.1.20:8099", topic: "garage")
        check.arm(hash: hash)
        XCTAssertTrue(check.isArmed(hash: hash))
        replies = [(500, "")]
        XCTAssertEqual(check.messageArrivedByPollVerdict(baseUrl: "http://192.168.1.20:8099", topic: "garage", at: clock), .unknown)
        XCTAssertFalse(check.isArmed(hash: hash), "an inconclusive check ends the arm")
        check.arm(hash: hash)
        clock = clock.addingTimeInterval(SelfHostedWakeCheck.armLifetime + 1)
        XCTAssertFalse(check.isArmed(hash: hash), "lapsed")
    }

    /// Red on 15669a0 (review-130b #9): the cooldown and admission were checked when a check was
    /// planned, not when it ran after its wait.
    func testACheckRechecksTheCooldownWhenItRuns() {
        var sent = 0
        let defaults = UserDefaults(suiteName: "SelfHostedWakeCheckTests.dispatch.\(UUID())")!
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let dir = BridgeTestState.directory()
        let lock = SharedFileLock.at(dir, NtfyShBridge.lockName)
        let check = SelfHostedWakeCheck(defaults: defaults, relayBaseUrl: "https://ntfy-me.com", read: { request, done in
            sent += 1
            done(Data(#"{"relayed":false}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }, schedule: { delay, work in
            now = now.addingTimeInterval(delay)
            // The server asks for a pause while the check waits.
            NtfyMeHostCooldown.note(status: 429, retryAfter: "600", lock: lock, now: now)
            work()
        }, now: { now }, stateDirectory: dir)
        var verdict: SelfHostedWakeCheck.Verdict?? = .none
        let hash = topicHash(baseUrl: "http://192.168.1.20:8099", topic: "garage")
        check.arm(hash: hash)
        check.messageArrivedByPoll(baseUrl: "http://192.168.1.20:8099", topic: "garage", messageTime: now.addingTimeInterval(-2)) { verdict = .some($0) }
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(verdict, .some(nil))
        var admittedVerdict: SelfHostedWakeCheck.Verdict?? = .none
        let other = SelfHostedWakeCheck(defaults: UserDefaults(suiteName: "SelfHostedWakeCheckTests.admit.\(UUID())")!, relayBaseUrl: "https://ntfy-me.com",
                                        read: { _, _ in sent += 1 }, schedule: { _, work in work() }, now: { now },
                                        stateDirectory: BridgeTestState.directory())
        other.arm(hash: hash)
        var watched = true
        other.messageArrivedByPoll(baseUrl: "http://192.168.1.20:8099", topic: "garage", messageTime: now.addingTimeInterval(-2),
                                   watch: { defer { watched = false }; return watched ? .distantPast : nil }) { admittedVerdict = .some($0) }
        XCTAssertEqual(sent, 0, "no longer admitted when it runs: not asked")
        XCTAssertEqual(admittedVerdict, .some(nil))
    }
}

extension SelfHostedWakeCheck {
    /// Test helper: one poll arrival with the schedule the test installed; the verdict, if any.
    func messageArrivedByPollVerdict(baseUrl: String, topic: String, at time: Date) -> Verdict? {
        var verdict: Verdict?? = .none
        messageArrivedByPoll(baseUrl: baseUrl, topic: topic, messageTime: time.addingTimeInterval(-2)) { verdict = .some($0) }
        return verdict ?? nil
    }
}

extension PresentationClaimTests {
    /// Red on 15669a0 (review-130b D): claims were keyed by the row's normalized URL, so two
    /// spellings of ntfy.sh could each alert the same message.
    func testAliasRowsShareOneClaim() {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        let message = Message(id: "m4_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "open")
        XCTAssertEqual(Store.claimTopicUrl(baseUrl: "http://ntfy.sh", topic: "door"), Store.claimTopicUrl(baseUrl: "https://ntfy.sh/", topic: "door"))
        store.recordPresentation(message: message, baseUrl: "http://ntfy.sh")
        XCTAssertTrue(store.hasClaimBeforeRow(message: message, baseUrl: "https://ntfy.sh"))
        XCTAssertTrue(store.wasAlerted(message: message, baseUrl: "https://ntfy.sh"))
    }

    /// Red on 15669a0 (review-130b #5): at expiry the extension sounded its fallback without
    /// claiming the message, so the app's next poll alerted it again; and it ignored an app
    /// holding the alert lock for it. Now: claim, or stay passive.
    /// Fix after the 41a2a18 full run: expiry treated a held alert lock as "someone else alerted",
    /// and the lock was usually the extension's own claim in flight, so a loaded device gave an
    /// unseen message a silent banner. Only a fresh claim on disk is evidence; the rest alerts.
    func testTheExtensionsExpiryClaimsOrStaysPassive() {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        _ = store.saveSubscription(baseUrl: "https://home.example", topic: "door")
        let message = Message(id: "m5_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "open")
        XCTAssertEqual(store.claimAtExpiry(message: message, baseUrl: "https://home.example"), .alert)
        XCTAssertTrue(store.wasAlerted(message: message, baseUrl: "https://home.example"), "a later app poll stays quiet")
        XCTAssertEqual(store.claimAtExpiry(message: message, baseUrl: "https://home.example"), .alreadyAlerted)
        // The alert lock is held (by whoever) with no claim written for this message: uncertain, alerts.
        let other = Message(id: "m6_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "x")
        let holding = expectation(description: "alert lock held")
        let release = DispatchSemaphore(value: 0)
        _ = store.deliverAlert(message: Message(id: "m7_q7x", time: 1_800_000_000, event: "message", topic: "door"),
                               baseUrl: "https://home.example", delivery: { done in
            holding.fulfill()
            DispatchQueue.global().async { release.wait(); done(true) }
        })
        wait(for: [holding], timeout: 5)
        XCTAssertEqual(store.claimAtExpiry(message: other, baseUrl: "https://home.example"), .alert)
        // A claim the app wrote for this message is confirmed evidence: passive.
        let alerted = Message(id: "m8_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "y")
        store.recordPresentation(message: alerted, baseUrl: "https://home.example")
        XCTAssertEqual(store.claimAtExpiry(message: alerted, baseUrl: "https://home.example"), .alreadyAlerted)
        release.signal()
    }
}

final class NotificationBestAttemptTests: XCTestCase {
    /// Red on 15669a0 (review-130b #5): the best attempt was the live object a running step kept
    /// changing, so what an expiry handed iOS could change after the handoff.
    func testTheBestAttemptIsASnapshot() {
        let content = UNMutableNotificationContent()
        content.body = "ready"
        let attempt = NotificationBestAttempt(content)
        content.body = "changed later"
        XCTAssertEqual(attempt.content.body, "ready")
        let read = attempt.content
        read.body = "changed by a reader"
        XCTAssertEqual(attempt.content.body, "ready")
    }
}

final class NotificationServiceExpiryTests: XCTestCase {
    private func request(_ id: String, baseUrl: String, topic: String, sound: Bool = true) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = topic
        content.body = "alive"
        if sound { content.sound = .default }
        content.userInfo = Message(id: id, time: 1_800_000_000, event: "message", topic: topic, message: "alive").toUserInfo()
        content.userInfo["base_url"] = baseUrl
        return UNNotificationRequest(identifier: id, content: content, trigger: nil)
    }

    /// Red on 15669a0 (review-130b #5): the deadline and its watchdog started after the store
    /// opened, so a slow open pushed the handoff past the system's limit. No wall clock: the store
    /// open blocks until the handoff has happened, which only an entry-time watchdog can do.
    func testTheDeadlineStartsBeforeTheStoreOpens() {
        let store = Store(inMemory: true)
        _ = store.saveSubscription(baseUrl: "https://slow-open.example", topic: "door")
        let service = NotificationService()
        service.processingBudget = 0.05
        let handed = DispatchSemaphore(value: 0)
        var openedAfterHandoff = false
        service.makeStore = { openedAfterHandoff = handed.wait(timeout: .now() + 30) == .success; return store }
        let lock = NSLock()
        var outputs: [UNNotificationContent] = []
        let done = expectation(description: "didReceive returned")
        DispatchQueue.global().async {
            service.didReceive(self.request("slow_q7x", baseUrl: "https://slow-open.example", topic: "door", sound: false)) { output in
                lock.lock(); outputs.append(output); lock.unlock()
                handed.signal()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        XCTAssertTrue(openedAfterHandoff, "the handoff came while the store was still opening")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        lock.lock(); let delivered = outputs; lock.unlock()
        XCTAssertEqual(delivered.count, 1)
        // Fix after the 41a2a18 full run: the entry fallback alerts even when the payload has no sound.
        XCTAssertNotNil(delivered.first?.sound)
        XCTAssertNotEqual(delivered.first?.interruptionLevel, .passive)
        withExtendedLifetime(service) {}
    }

    /// Fix after the 41a2a18 full run: an expiry while the alert lock is held (the extension's own
    /// claim, or the app alerting something) and no claim on disk alerts; it is not evidence.
    func testExpiryWhileTheAlertLockIsHeldStillAlerts() {
        let store = Store(inMemory: true)
        let baseUrl = "https://expiry-claim.example"
        _ = store.saveSubscription(baseUrl: baseUrl, topic: "door")
        let holding = expectation(description: "alert lock held")
        let release = DispatchSemaphore(value: 0)
        let other = Message(id: "held_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "x")
        _ = store.deliverAlert(message: other, baseUrl: baseUrl, delivery: { done in
            holding.fulfill()
            DispatchQueue.global().async { release.wait(); done(true) }
        })
        wait(for: [holding], timeout: 5)
        let service = NotificationService(); service.makeStore = { store }
        var outputs: [UNNotificationContent] = []
        service.didReceive(request("claim_q7x", baseUrl: baseUrl, topic: "door")) { outputs.append($0) }
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(outputs.count, 1, "expiry hands off synchronously")
        XCTAssertNotNil(outputs.first?.sound)
        XCTAssertNotEqual(outputs.first?.interruptionLevel, .passive)
        release.signal()
        withExtendedLifetime(service) {}
    }

    /// Only a claim on disk for this message (the app alerted it) makes the expiry passive.
    func testExpiryAfterTheAppAlertedTheMessageIsPassive() {
        let store = Store(inMemory: true)
        let baseUrl = "https://expiry-claim.example"
        _ = store.saveSubscription(baseUrl: baseUrl, topic: "door")
        store.recordPresentation(message: Message(id: "seen_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "alive"), baseUrl: baseUrl)
        let service = NotificationService(); service.makeStore = { store }
        var outputs: [UNNotificationContent] = []
        service.didReceive(request("seen_q7x", baseUrl: baseUrl, topic: "door")) { outputs.append($0) }
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(outputs.count, 1)
        XCTAssertNil(outputs.first?.sound)
        XCTAssertEqual(outputs.first?.interruptionLevel, .passive)
        withExtendedLifetime(service) {}
    }
}

extension NtfyShBridgeTests {
    /// Red on e46c1d6 (security review of fix round 2): a refusal that arrived while the shared
    /// lock was busy was dropped (the status path read it inside the skipped record write, and
    /// `saveAccess` skipped silently), so the earlier 200 stayed and the protected name went out in
    /// the next list. Now the refusal is kept in force in the process and saved with the next write.
    func testALockTimeoutWhileSavingARefusalKeepsTheNameOutOfTheNextPost() throws {
        let path = NSTemporaryDirectory() + "bridge-refusal-\(UUID()).lock"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeStubProtocol.self]
        bridge = NtfyShBridge(store: store, defaults: defaults, session: URLSession(configuration: config),
                              appBaseUrl: "https://ntfy-me.com", now: { [unowned self] in self.clock },
                              lock: SharedFileLock(path: path), stateDirectory: stateDirectory)
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        save("https://ntfy.sh", "a_q7x")
        save("https://ntfy.sh", "b_q7x")
        BridgeStubProtocol.reply = { request in
            request.url?.path.hasSuffix("/auth") == true ? .success((200, [:], ""))
                : .success((200, [:], #"{"watching":2,"expires":1900000000}"#))
        }
        sync()
        XCTAssertEqual(Set(try lastBody()["ntfy_sh_topics"] as? [String] ?? []), ["a_q7x", "b_q7x"])

        // Another process takes the lock while the status read is on the wire and holds it past the
        // answer (since fix round 3 a read that can't register itself first isn't sent at all).
        let holder = SharedFileLock(path: path)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        BridgeStubProtocol.reply = { _ in
            DispatchQueue.global().async { holder.withLock { held.signal(); release.wait() } }
            held.wait()
            return .success((200, [:], #"{"watching":1,"connected":true,"unwatchable":["a_q7x"]}"#))
        }
        let status = expectation(description: "status")
        bridge.fetchStatus { _ in status.fulfill() }
        wait(for: [status], timeout: 10)
        XCTAssertEqual(bridge.access["a_q7x"]?.state, .refused, "in force although it couldn't be saved")
        release.signal()

        // The next registration leaves the name out, and asks ntfy.sh nothing (the refusal is fresh).
        let before = BridgeStubProtocol.sent.count
        BridgeStubProtocol.reply = { request in
            request.url?.path.hasSuffix("/auth") == true ? .success((200, [:], ""))
                : .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
        }
        sync()
        let newer = BridgeStubProtocol.sent.dropFirst(before)
        XCTAssertFalse(newer.contains { $0.request.url?.path.hasSuffix("/auth") == true })
        let post = try XCTUnwrap(newer.last { $0.request.url?.path.hasSuffix("/v1/ntfai/watch") == true })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: post.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["ntfy_sh_topics"] as? [String], ["b_q7x"])

        // And it was written with that save, so a fresh process sees it too.
        let fresh = NtfyShBridge(store: store, defaults: defaults, network: false, now: { [unowned self] in self.clock },
                                 lock: SharedFileLock(path: path), stateDirectory: stateDirectory)
        XCTAssertEqual(fresh.access["a_q7x"]?.state, .refused)
    }
}

// MARK: - 1.30 fix round 3 (review-130c)

extension NtfyShBridgeTests {
    private func credentialed(_ topics: String...) {
        _ = store.saveUser(baseUrl: "https://ntfy.sh", username: "u", password: "p")
        for topic in topics { save("https://ntfy.sh", topic) }
    }

    /// Anonymous checks answer `answer(topic)`; everything else accepts.
    private func authReplies(_ answer: @escaping (String) -> Int) {
        BridgeStubProtocol.reply = { request in
            if request.url?.path.hasSuffix("/auth") == true {
                return .success((answer(request.url?.pathComponents.dropLast().last ?? ""), [:], ""))
            }
            return .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
        }
    }

    private func probes(after index: Int = 0) -> [String] {
        BridgeStubProtocol.sent.dropFirst(index).compactMap { sent in
            sent.request.url?.path.hasSuffix("/auth") == true ? sent.request.url?.pathComponents.dropLast().last : nil
        }
    }

    private func status() -> NtfyShBridge.Status? {
        var result: NtfyShBridge.Status?
        let done = expectation(description: "status")
        bridge.fetchStatus { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return result
    }

    // C1: privacy evidence survives restarts

    /// Red on 6b139b8 (review-130c C1): a refusal that couldn't be saved lived only in the dying
    /// process, so after a restart the earlier anonymous 200 sent the protected name again. The
    /// read's barrier is on disk before it is sent: a fresh process re-checks and holds the name.
    func testARefusalLostWithItsProcessStillKeepsTheNameOutAfterARestart() throws {
        credentialed("a_q7x", "b_q7x")
        authReplies { _ in 200 }
        sync()
        XCTAssertEqual(Set(try lastBody()["ntfy_sh_topics"] as? [String] ?? []), ["a_q7x", "b_q7x"])
        clock += 1
        let holder = SharedFileLock(path: bridge.lock.path)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        BridgeStubProtocol.reply = { _ in
            DispatchQueue.global().async { holder.withLock { held.signal(); release.wait() } }
            held.wait()
            return .success((200, [:], #"{"watching":2,"connected":true,"unwatchable":["a_q7x"]}"#))
        }
        _ = status()
        XCTAssertEqual(bridge.access["a_q7x"]?.state, .refused, "in force in this process")
        // The process is killed before the lock frees: what it learned is gone, its barrier isn't.
        bridge = makeBridge()
        release.signal()
        XCTAssertNotEqual(bridge.access["a_q7x"]?.state, .refused)
        clock += 1
        authReplies { $0 == "a_q7x" ? 403 : 200 }
        let before = BridgeStubProtocol.sent.count
        sync()
        XCTAssertEqual(Set(probes(after: before)), ["a_q7x", "b_q7x"], "the barrier makes every earlier 200 unconfirmed")
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["b_q7x"])
    }

    /// Red on 6b139b8 (review-130c C1, C7): a newer status read that then timed out discarded the
    /// refusal the older one reported, because the older read was superseded.
    func testASupersededStatusReadStillAppliesItsRefusals() throws {
        credentialed("a_q7x", "b_q7x")
        authReplies { _ in 200 }
        sync()
        clock += 1
        var asked = 0
        let bridge = self.bridge!
        BridgeStubProtocol.reply = { request in
            guard request.httpMethod == "GET" else { return .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
            asked += 1
            if asked == 1 {
                bridge.cancelStatus()
                bridge.fetchStatus { _ in }
                return .success((200, [:], #"{"watching":2,"connected":true,"unwatchable":["a_q7x"]}"#))
            }
            return .failure(URLError(.timedOut))
        }
        bridge.fetchStatus { _ in XCTFail("superseded: never shown") }
        waitUntil { asked >= 2 }
        spin(0.3)
        XCTAssertEqual(bridge.access["a_q7x"]?.state, .refused)
        clock += 3601
        authReplies { _ in 200 }
        sync()
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["b_q7x"])
    }

    /// Red on 6b139b8 (review-130c C1): the set was computed before the access checks ran, so a
    /// refusal another process committed meanwhile still went out in the body. Eligibility is now
    /// decided in the same lock hold that builds and starts the request.
    func testARefusalCommittedWhileTheChecksRunLeavesTheBody() throws {
        credentialed("a_q7x")
        authReplies { _ in 200 }
        sync()
        save("https://ntfy.sh", "b_q7x")
        let other = NtfyShBridge(store: store, defaults: defaults, network: false, now: { [unowned self] in self.clock },
                                 stateDirectory: stateDirectory)
        BridgeStubProtocol.reply = { [unowned self] request in
            if request.url?.path.hasSuffix("/auth") == true {
                // Another process learns, while this one checks b, that a is refused.
                XCTAssertTrue(other.recordRefusals(["a_q7x"], asked: self.clock))
                return .success((200, [:], ""))
            }
            return .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
        }
        let before = BridgeStubProtocol.sent.count
        sync()
        XCTAssertEqual(probes(after: before), ["b_q7x"])
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["b_q7x"])
    }

    /// Red on 6b139b8 (review-130c C1): when the recheck mark couldn't be written, the cycle still
    /// sent its list. Now it sends nothing.
    func testNoListGoesOutWhenTheRecheckMarkCantBeWritten() throws {
        credentialed("a_q7x")
        authReplies { _ in 200 }
        sync()
        clock += 25 * 3600 // due for a recheck
        try Data("{not json".utf8).write(to: stateDirectory.appendingPathComponent(NtfyShAccessLedger.fileName))
        let before = BridgeStubProtocol.sent.count
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, before, "an unreadable ledger sends nothing and asks nothing")
    }

    /// Load (review-130c): at most five anonymous checks per sync, the oldest evidence first.
    func testAtMostFiveAccessChecksPerSync() throws {
        credentialed("t1_q7x", "t2_q7x", "t3_q7x", "t4_q7x", "t5_q7x", "t6_q7x", "t7_q7x")
        authReplies { _ in 200 }
        sync()
        XCTAssertEqual(probes().count, NtfyShBridge.maxProbesPerSync)
        XCTAssertEqual((try lastBody()["ntfy_sh_topics"] as? [String])?.count, 5, "only checked names go out")
        let before = BridgeStubProtocol.sent.count
        clock += 3601
        sync()
        XCTAssertEqual(probes(after: before).count, 2, "the rest next time")
        XCTAssertEqual((try lastBody()["ntfy_sh_topics"] as? [String])?.count, 7)
    }

    // C2: durable removal and opt-out

    /// Red on 6b139b8 (review-130c C2): under the admission limit (42912) a list that removes b
    /// but adds c waited, so b stayed watched. The shrink-only part (what is still wanted of what
    /// the server holds) goes out; c waits.
    func testUnderTheAdmissionLimitTheShrinkOnlyPartGoesOut() throws {
        save("https://ntfy.sh", "a")
        let b = save("https://ntfy.sh", "b")
        sync()
        save("https://ntfy.sh", "c")
        BridgeStubProtocol.reply = { _ in .success((429, ["Retry-After": "3600"], #"{"code":42912,"error":"admission limit"}"#)) }
        sync()
        XCTAssertEqual(bridge.currentRecord.lastOutcome, .admissionLimited)
        XCTAssertTrue(store.delete(subscription: b))
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
        clock += 60
        let before = watchPosts
        sync()
        XCTAssertEqual(watchPosts, before + 1)
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["a"])
        XCTAssertEqual(bridge.report(wakes: nil).removing, 0, "b acknowledged")
    }

    /// Red on 6b139b8 (review-130c C2): a removal or opt-out the server hadn't acknowledged was
    /// invisible, and with no rows left the status screen showed nothing at all.
    func testStatusCountsRemovalsUntilTheServerAcknowledges() throws {
        save("https://ntfy.sh", "a")
        let b = save("https://ntfy.sh", "b")
        sync()
        XCTAssertTrue(store.delete(subscription: b))
        BridgeStubProtocol.reply = { _ in .success((500, [:], "")) }
        sync()
        var report = bridge.report(wakes: nil)
        XCTAssertEqual(report.removing, 1)
        XCTAssertFalse(report.optOutPending)
        // Turned off, with no rows left, and the server still unreachable.
        defaults.set(false, forKey: NtfyShBridge.enabledKey)
        XCTAssertTrue(store.delete(subscription: try XCTUnwrap(store.getSubscription(baseUrl: "https://ntfy.sh", topic: "a"))))
        clock += 3601
        sync()
        report = bridge.report(wakes: nil)
        XCTAssertTrue(report.optOutPending)
        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.removing, 2)
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":0}"#)) }
        clock += 3601
        sync()
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], [])
        report = bridge.report(wakes: nil)
        XCTAssertFalse(report.optOutPending)
        XCTAssertEqual(report.removing, 0)
    }

    // C3: renewal from committed state

    /// Red on 6b139b8 (review-130c C3): an unreadable record was read as empty, so the next sync
    /// registered from scratch and the extension renewed with nothing to go on.
    func testAnUnreadableRecordSendsNothingAndRenewsNothing() throws {
        save("https://ntfy.sh", "a")
        sync()
        try Data("{not json".utf8).write(to: bridge.recordFile.url)
        let before = BridgeStubProtocol.sent.count
        clock += 8 * 24 * 3600
        renew(extensionBridge())
        save("https://ntfy.sh", "b")
        sync()
        XCTAssertEqual(BridgeStubProtocol.sent.count, before)
        XCTAssertEqual(try Data(contentsOf: bridge.recordFile.url), Data("{not json".utf8), "never overwritten as if empty")
    }

    /// Red on 6b139b8 (review-130c C3): renewal ran while a replacement list was on the wire, so it
    /// could renew, or report missing, the list being replaced.
    func testRenewalWaitsWhileAReplacementIsUnresolved() {
        save("https://ntfy.sh", "a")
        sync()
        clock += 8 * 24 * 3600
        var record = bridge.currentRecord
        XCTAssertTrue(bridge.extensionShouldRenew(record))
        record.attempting = record.revision
        record.lastAttempt = clock
        XCTAssertFalse(bridge.extensionShouldRenew(record))
        clock += NtfyShBridge.attemptLifetime + 1
        XCTAssertTrue(bridge.extensionShouldRenew(record), "a process that died mid-attempt doesn't block renewal")
        record.optedOut = true
        XCTAssertFalse(bridge.extensionShouldRenew(record), "the committed opt-out, not the defaults, decides")
    }

    // C4: one wake context

    /// Red on 6b139b8 (review-130c C4): a foreground request queued behind a background wake
    /// inherited its deadline, so it died with the wake.
    func testAForegroundRequestQueuedBehindAWakeIsntBoundByIt() {
        save("https://ntfy.sh", "a")
        let wake = WakeContext(deadline: 25)
        let bridge = self.bridge!
        var posts = 0
        let foreground = expectation(description: "foreground")
        BridgeStubProtocol.reply = { request in
            guard request.httpMethod == "POST" else { return .success((200, [:], "{}")) }
            posts += 1
            if posts == 1 {
                bridge.sync(reason: "setting", userInitiated: true) { foreground.fulfill() }
                wake.cancel()
            }
            return .success((200, [:], #"{"watching":1,"expires":1900000000}"#))
        }
        bridge.sync(reason: "background wake", wake: wake)
        save("https://ntfy.sh", "b") // so the queued request has something to send
        wait(for: [foreground], timeout: 10)
        XCTAssertEqual(posts, 2, "the queued foreground request went out after the wake ended")
        XCTAssertEqual(Set(try XCTUnwrap(lastBody()["ntfy_sh_topics"] as? [String])), ["a", "b"])
    }

    /// The wake installs a request's cancellation before it checks the time left, and ends every
    /// request it started.
    func testAWakeStartsNothingOnceEndedAndCancelsWhatItStarted() {
        var uptime: TimeInterval = 100
        let wake = WakeContext(deadline: 10, uptime: { uptime })
        let task = RecordingTask()
        XCTAssertTrue(wake.start(task, minimum: 1))
        XCTAssertEqual(task.calls, ["resume"])
        wake.cancel()
        XCTAssertEqual(task.calls, ["resume", "cancel"], "cancelled with the wake")
        let late = RecordingTask()
        XCTAssertFalse(wake.start(late, minimum: 1))
        XCTAssertEqual(late.calls, ["cancel"], "cancelled, never resumed")
        let other = WakeContext(deadline: 10, uptime: { uptime })
        uptime += 9.5
        let short = RecordingTask()
        XCTAssertFalse(other.start(short, minimum: 1), "too little time left")
        XCTAssertEqual(short.calls, [], "never resumed")
        var ended = 0
        other.onCancel { ended += 1 }
        other.cancel(); other.cancel()
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(other.remaining, 0)
    }

    // C7: status reads

    /// Red on 6b139b8 (review-130c C7): two status calls made two reads, and a read went out with
    /// the setting off.
    func testStatusReadsAreCoalescedAndNeverAskedWhileOff() {
        save("https://ntfy.sh", "a")
        sync()
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"connected":true}"#)) }
        let before = BridgeStubProtocol.sent.count
        var answers: [NtfyShBridge.Status] = []
        let both = expectation(description: "both")
        both.expectedFulfillmentCount = 2
        bridge.fetchStatus { answers.append($0); both.fulfill() }
        bridge.fetchStatus { answers.append($0); both.fulfill() }
        wait(for: [both], timeout: 5)
        XCTAssertEqual(answers, [.connected(watching: 1), .connected(watching: 1)])
        XCTAssertEqual(BridgeStubProtocol.sent.count, before + 1)
        defaults.set(false, forKey: NtfyShBridge.enabledKey)
        XCTAssertEqual(status(), .off)
        XCTAssertEqual(BridgeStubProtocol.sent.count, before + 1)
    }

    /// Red on 6b139b8 (review-130c C7): a real 429 on the status read showed "Couldn't check"
    /// instead of waiting until the deadline the server returned.
    func testARateLimitedStatusReadWaitsForTheServersDeadline() {
        save("https://ntfy.sh", "a")
        sync()
        BridgeStubProtocol.reply = { _ in .success((429, ["Retry-After": "300"], "{}")) }
        XCTAssertEqual(status(), .waiting(until: clock.addingTimeInterval(300)))
        XCTAssertNotEqual(NtfyShBridgeCopy.status(.waiting(until: clock.addingTimeInterval(300))), NtfyShBridgeCopy.status(.unavailable))
    }

    // C10: separate deadlines

    /// Red on 6b139b8 (review-130c C10): one deadline held both the server's Retry-After and the
    /// client's backoff, so the user's own action could skip the server's pause, or a success end it.
    func testTheServersPauseAndTheClientsBackoffAreSeparate() {
        let lock = bridge.lock
        NtfyMeHostCooldown.note(status: 500, retryAfter: nil, lock: lock, now: clock)
        XCTAssertEqual(NtfyMeHostCooldown.blockedUntil(lock, now: clock), clock.addingTimeInterval(30))
        XCTAssertNil(NtfyMeHostCooldown.blockedUntil(lock, now: clock, userInitiated: true), "the user skips the client's backoff")
        NtfyMeHostCooldown.note(status: 429, retryAfter: "600", lock: lock, now: clock)
        XCTAssertEqual(NtfyMeHostCooldown.blockedUntil(lock, now: clock, userInitiated: true), clock.addingTimeInterval(600))
        NtfyMeHostCooldown.note(status: 200, retryAfter: nil, lock: lock, now: clock)
        let stored = NtfyMeHostCooldown.read(lock)
        XCTAssertNil(stored.clientNotBefore, "a success ends the backoff")
        XCTAssertEqual(stored.serverNotBefore, clock.addingTimeInterval(600), "but not the server's pause")
    }
}

extension SelfHostedWakeCheckTests {
    /// Load (review-130c): an armed relay lookup at most once a minute across all topics.
    func testArmedRelayLookupsAreAtMostOnceAMinute() {
        XCTAssertEqual(SelfHostedWakeCheck.globalInterval, 60)
    }
}

// MARK: C5, C6: alert ownership and the policy snapshot

extension PresentationClaimTests {
    private func pair() -> (Store, Message) {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        _ = store.saveSubscription(baseUrl: "https://home.example", topic: "door")
        return (store, Message(id: "c5_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "open"))
    }

    /// Red on 6b139b8 (review-130c C5): the app checked for duplicates, then presented; the
    /// extension, held between those steps, alerted too. Now the app reserves first: the
    /// extension's normal path is passive; its expiry still alerts (fail open).
    func testTheAppsReservationKeepsTheExtensionPassiveUntilExpiry() {
        let (store, message) = pair()
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://home.example", token: "app", by: .app), .reserved)
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://home.example", token: "nse", by: .nse), .reservedElsewhere)
        XCTAssertEqual(store.claimAtExpiry(message: message, baseUrl: "https://home.example", token: "nse"), .alert,
                       "the app hasn't delivered: a rare duplicate beats a lost alert")
        XCTAssertTrue(store.hasClaimBeforeRow(message: message, baseUrl: "https://home.example"))
    }

    /// Red on 6b139b8 (review-130c C5): the extension, held after its reservation, then expiring,
    /// stayed quiet while the app presented nothing. Its own reservation alerts; the app is passive.
    func testTheExtensionsOwnReservationAlertsAtExpiryAndTheAppStaysPassive() {
        let (store, message) = pair()
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://home.example", token: "nse", by: .nse), .reserved)
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://home.example", token: "app", by: .app), .reservedElsewhere)
        XCTAssertEqual(store.claimAtExpiry(message: message, baseUrl: "https://home.example", token: "nse"), .alert)
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://home.example", token: "app2", by: .app), .passive)
        // Delivered by the app first: the extension's expiry is passive.
        let other = Message(id: "c5b_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "x")
        store.recordPresentation(message: other, baseUrl: "https://home.example", by: .app, token: "app")
        XCTAssertEqual(store.claimAtExpiry(message: other, baseUrl: "https://home.example", token: "nse"), .alreadyAlerted)
    }

    /// The documented C5 tradeoff: the extension killed after marking but before its handoff
    /// leaves iOS to show the original payload, and a later app poll stays quiet.
    func testAnExtensionKilledAfterMarkingLeavesTheLaterPollQuiet() {
        let (store, message) = pair()
        store.recordPresentation(message: message, baseUrl: "https://home.example", by: .nse, token: "nse")
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://home.example", token: "poll", by: .app), .passive)
        _ = store.ingest(pushedMessage: message, baseUrl: "https://home.example", topic: "door")
        XCTAssertTrue(store.alertCandidates(from: [message], baseUrl: "https://home.example").isEmpty)
    }

    /// A reservation older than 30 s is from a delivery that died: another may take it over.
    func testAStaleReservationCanBeTakenOver() throws {
        let (store, message) = pair()
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://home.example", token: "dead", by: .nse), .reserved)
        let url = store.legacyClaimFile.url.deletingLastPathComponent().appendingPathComponent(Store.alertClaimsFile)
        var claims = try JSONDecoder().decode([String: Store.AlertClaim].self, from: Data(contentsOf: url))
        for key in claims.keys { claims[key]?.at = Date().addingTimeInterval(-(Store.reservationLifetime + 1)) }
        try JSONEncoder().encode(claims).write(to: url)
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://home.example", token: "app", by: .app), .reserved)
    }

    /// Red on 6b139b8 (review-130c C6): beta claims kept the row's spelling of ntfy.sh, so a claim
    /// under http://ntfy.sh missed the canonical key and the message alerted again.
    func testLegacyClaimKeysAreCanonicalizedKeepingTheNewestStamp() throws {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        _ = store.saveSubscription(baseUrl: "http://ntfy.sh", topic: "door")
        let older = Date().addingTimeInterval(-600), newer = Date().addingTimeInterval(-60)
        try JSONEncoder().encode(["http://ntfy.sh/door#c6_q7x": older, "https://www.ntfy.sh/door#c6_q7x": newer])
            .write(to: store.legacyClaimFile.url)
        let message = Message(id: "c6_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "x")
        XCTAssertTrue(store.hasClaimBeforeRow(message: message, baseUrl: "https://ntfy.sh"))
        XCTAssertEqual(store.reserveAlert(message: message, baseUrl: "https://ntfy.sh", token: "app", by: .app), .passive)
        XCTAssertEqual(Store.canonicalClaimKey("http://www.ntfy.sh/door#m1"), "https://ntfy.sh/door#m1")
    }

    /// Red on 6b139b8 (review-130c C6): removing one alias of a topic cleared the claims the other
    /// alias still relies on.
    func testClaimsStayWhileAnotherAliasOfTheTopicRemains() throws {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        let http = store.saveSubscription(baseUrl: "http://ntfy.sh", topic: "door")
        _ = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "door")
        let message = Message(id: "c6b_q7x", time: 1_800_000_000, event: "message", topic: "door", message: "x")
        store.recordPresentation(message: message, baseUrl: "https://ntfy.sh")
        XCTAssertTrue(store.delete(subscription: http))
        XCTAssertTrue(store.hasClaimBeforeRow(message: message, baseUrl: "https://ntfy.sh"), "the other alias remains")
        XCTAssertTrue(store.delete(subscription: try XCTUnwrap(store.getSubscription(baseUrl: "https://ntfy.sh", topic: "door"))))
        XCTAssertFalse(store.hasClaimBeforeRow(message: message, baseUrl: "https://ntfy.sh"))
    }

    /// Red on 6b139b8 (review-130c C6): the extension's entry fallback ignored a topic's mute and
    /// its quiet-hours exception for a hash-only wake-up (it can't open the store to map the hash).
    func testThePolicySnapshotResolvesAHashToTheTopicsMuteAndException() {
        let hash = topicHash(baseUrl: "https://home.example", topic: "door")
        var snapshot = NotificationPolicySnapshot(topics: [
            .init(baseUrl: "https://home.example", topic: "door", hash: hash, mutedUntil: nil),
            .init(baseUrl: "https://home.example", topic: "quiet", hash: topicHash(baseUrl: "https://home.example", topic: "quiet"),
                  mutedUntil: Date().addingTimeInterval(3600)),
        ])
        var hours = QuietHours()
        hours.enabled = true
        hours.start = 0; hours.end = 0 // the whole day
        let push: [AnyHashable: Any] = ["topic": hash, "base_url": "https://ntfy-me.com"]
        XCTAssertTrue(snapshot.isQuiet(userInfo: push, quietHours: hours))
        hours.exceptions = [topicUrl(baseUrl: "https://home.example", topic: "door")]
        XCTAssertFalse(snapshot.isQuiet(userInfo: push, quietHours: hours), "the exception holds for a hash wake-up")
        let muted: [AnyHashable: Any] = ["topic": topicHash(baseUrl: "https://home.example", topic: "quiet")]
        XCTAssertTrue(snapshot.isQuiet(userInfo: muted, quietHours: QuietHours()), "muted, quiet hours off")
        snapshot.topics = []
        XCTAssertFalse(snapshot.isQuiet(userInfo: push, quietHours: QuietHours()), "unknown and no quiet hours: alerts")
    }
}

// MARK: Device check of build 62: A4 diagnosis from one app open, and the status note

extension SelfHostedWakeCheckTests {
    private func admittedBridge(watchStart: Date?, expires: Date? = nil) -> NtfyShBridge {
        let bridge = NtfyShBridge(store: Store(inMemory: true, credentialStore: InMemoryCredentialStore()), defaults: defaults,
                                  network: false, appBaseUrl: "https://ntfy-me.com", now: { [unowned self] in self.clock },
                                  stateDirectory: BridgeTestState.directory())
        var record = BridgeRecord()
        record.acceptedSignature = "t:|h:" + garageHash
        record.lastOutcome = .ok
        record.lastSuccess = watchStart
        record.watchStarts = watchStart.map { ["h:" + garageHash: $0] }
        record.expires = expires
        bridge.recordFile.update { stored -> (write: Bool, result: Void) in stored = record; return (true, ()) }
        return bridge
    }

    private func open(_ messages: [Message], bridge: NtfyShBridge, subscribed: @escaping () -> Bool = { true }) {
        SubscriptionManager.checkWakeUps(baseUrl: base, topic: "garage", messages: messages, check: check, bridge: bridge,
                                         appBaseUrl: "https://ntfy-me.com", subscribed: { _, _ in subscribed() })
    }

    private func messages(agedSeconds ages: [Int64], prefix: String = "bg") -> [Message] {
        let now = Int64(clock.timeIntervalSince1970)
        return ages.map { Message(id: "\(prefix)\($0)", time: now - $0, event: "message", topic: "garage") }
    }

    /// Red on 1050490 (review-130d D6): three messages no push brought, then the first open since
    /// the bridge took the topic, showed nothing: that first poll only set where evidence starts.
    /// Evidence now starts at the bridge's accepted watch, so the first open counts them.
    func testThreeMissesThenTheFirstOpenShowTheWeakDiagnosis() throws {
        let bridge = admittedBridge(watchStart: clock)
        clock += 3600
        let three = messages(agedSeconds: [1800, 1200, 600])
        open(three, bridge: bridge)
        XCTAssertEqual(check.diagnosis(hash: garageHash), .unconfirmed, "weak copy only, never notSetUp")
        XCTAssertEqual(sent.count, 0, "no request: ntfy.sh doesn't keep forwarded poll_requests")
        open(three, bridge: bridge)
        XCTAssertEqual(check.entry(hash: garageHash)?.weakMisses, 3, "each message counts once, by ID")
        check.recordWake(hash: garageHash)
        XCTAssertNil(check.diagnosis(hash: garageHash), "a wake-up clears it")
    }

    /// Red on 1050490 (review-130d D6): counted by time, two messages in the same second, or one
    /// polled out of order, counted once or not at all.
    func testMissesCountByMessageIdNotTime() {
        let start = clock
        clock += 3600
        let now = Int64(clock.timeIntervalSince1970)
        XCTAssertEqual(check.messagesFoundByPoll(hash: garageHash, watchStart: start, messages: [
            ("a", Date(timeIntervalSince1970: TimeInterval(now - 600))), ("b", Date(timeIntervalSince1970: TimeInterval(now - 600)))]), 2)
        XCTAssertEqual(check.messagesFoundByPoll(hash: garageHash, watchStart: start, messages: [
            ("c", Date(timeIntervalSince1970: TimeInterval(now - 1200)))]), 1, "older than the last counted, still new")
        XCTAssertEqual(check.messagesFoundByPoll(hash: garageHash, watchStart: start, messages: [
            ("a", Date(timeIntervalSince1970: TimeInterval(now - 600)))]), 0)
    }

    /// Red on 1050490 (review-130d D6): evidence of an earlier watch carried into the next one.
    func testANewWatchStartsTheEvidenceOver() {
        let first = clock
        clock += 3600
        let three = messages(agedSeconds: [1800, 1200, 600]).map { ($0.id, Date(timeIntervalSince1970: TimeInterval($0.time))) }
        XCTAssertEqual(check.messagesFoundByPoll(hash: garageHash, watchStart: first, messages: three), 3)
        XCTAssertEqual(check.diagnosis(hash: garageHash), .unconfirmed)
        let second = clock
        XCTAssertEqual(check.messagesFoundByPoll(hash: garageHash, watchStart: second, messages: three), 0, "sent before this watch")
        XCTAssertNil(check.diagnosis(hash: garageHash))
        check.notWatched(hash: garageHash)
        XCTAssertNil(check.entry(hash: garageHash)?.watchedSince)
    }

    /// History from before the watch, fresh messages and messages from before the last wake-up
    /// say nothing about forwarding; at most three count per poll.
    func testPollEvidenceSkipsHistoryFreshMessagesAndAnythingBeforeAWake() {
        let start = clock
        func found(_ ages: [TimeInterval]) -> Int {
            check.messagesFoundByPoll(hash: garageHash, watchStart: start,
                                      messages: ages.map { ("m\(clock.timeIntervalSince1970 - $0)", clock.addingTimeInterval(-$0)) })
        }
        XCTAssertEqual(found([600]), 0, "a new topic's history")
        clock += 3600
        XCTAssertEqual(found([5, 50, 1800]), 1)
        check.recordWake(hash: garageHash)
        clock += 600
        XCTAssertEqual(found([900]), 0, "before the wake-up")
        clock += 3600
        XCTAssertEqual(found((1...5).map { TimeInterval(200 * $0) }), SelfHostedWakeCheck.pollEvidenceLimit)
    }

    /// Red on 1050490 (review-130d D6): every fresh polled message asked ntfy-me.com about its hash.
    func testThePollPathMakesNoRelayCheckRequest() {
        let bridge = admittedBridge(watchStart: clock.addingTimeInterval(-3600))
        open(messages(agedSeconds: [20]), bridge: bridge)
        clock += 600
        open(messages(agedSeconds: [20], prefix: "n"), bridge: bridge)
        XCTAssertEqual(sent.count, 0)
        check.arm(hash: garageHash)
        clock += 600
        open(messages(agedSeconds: [20], prefix: "x"), bridge: bridge)
        XCTAssertEqual(sent.count, 1, "Check again is the one lookup")
    }

    /// Red on 1050490 (review-130d D6): an answer that landed after the topic was removed wrote a
    /// new entry (and a miss) for it.
    func testALateCheckAgainAnswerAfterUnsubscribeChangesNothing() {
        var answer: (() -> Void)?
        check = SelfHostedWakeCheck(defaults: defaults, relayBaseUrl: "https://ntfy-me.com", read: { request, done in
            answer = {
                done(Data(#"{"relayed":false,"relayed_at":null,"window_seconds":120}"#.utf8),
                     HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
            }
        }, schedule: { _, work in work() }, now: { [unowned self] in self.clock }, stateDirectory: dir)
        let bridge = admittedBridge(watchStart: clock.addingTimeInterval(-3600))
        var subscribed = true
        check.arm(hash: garageHash)
        open(messages(agedSeconds: [20]), bridge: bridge, subscribed: { subscribed })
        XCTAssertNotNil(answer)
        subscribed = false
        check.forget(hash: garageHash)
        answer?()
        XCTAssertNil(check.entry(hash: garageHash), "not recreated")
        // Still subscribed, but forgotten meanwhile (the unsubscribe's own order): still not recreated.
        subscribed = true
        check.arm(hash: garageHash)
        clock += SelfHostedWakeCheck.globalInterval
        open(messages(agedSeconds: [20], prefix: "y"), bridge: bridge)
        check.forget(hash: garageHash)
        answer?()
        XCTAssertNil(check.entry(hash: garageHash))
    }

    /// Red on 1050490 (review-130d D6): an expired watch still counted as admitted.
    func testAnExpiredWatchIsNotAdmitted() {
        let bridge = admittedBridge(watchStart: clock.addingTimeInterval(-3600), expires: clock.addingTimeInterval(60))
        XCTAssertNotNil(bridge.watchStart(hash: garageHash))
        clock += 61
        XCTAssertFalse(bridge.isAdmitted(hash: garageHash))
        clock += 3600
        open(messages(agedSeconds: [1800, 1200, 600]), bridge: bridge)
        XCTAssertNil(check.diagnosis(hash: garageHash))
    }

    /// Red on 1050490 (review-130d D6): going inactive cancelled a waiting status read, and
    /// returning left it idle.
    func testReturningToTheAppRestartsAWaitingStatusRead() {
        typealias Rows = NtfyShBridgeStatusRows
        XCTAssertEqual(Rows.onActive(status: .waiting(until: clock), visible: true, enabled: true), .reschedule)
        XCTAssertEqual(Rows.onActive(status: nil, visible: true, enabled: true), .read)
        XCTAssertEqual(Rows.onActive(status: .waiting(until: clock), visible: false, enabled: true), .none)
        XCTAssertEqual(Rows.onActive(status: .waiting(until: clock), visible: true, enabled: false), .none)
    }
}

extension NtfyShBridgeTests {
    /// Red on 6b139b8 (device check of build 62): "For these topics, opening the app lets it set
    /// up or repair banners" showed with no topic listed above it.
    func testTheRenewalNoteNeedsAListedTopic() {
        save("https://ntfy.sh", "a")
        sync()
        XCTAssertFalse(bridge.report(wakes: nil).listsTopics, "every topic watched: nothing listed")
        save("https://ntfy.sh", "bad name")
        XCTAssertTrue(bridge.report(wakes: nil).listsTopics)
    }
}

/// A data task that records what was asked of it, never touching the network.
private final class RecordingTask: URLSessionDataTask {
    private(set) var calls: [String] = []
    override init() {}
    override func resume() { calls.append("resume") }
    override func cancel() { calls.append("cancel") }
}

// MARK: Fix round 4 (review-130d D6): the watch start the self-hosted evidence is keyed by

extension NtfyShBridgeTests {
    /// Red on 1050490: the record kept no per-hash start, so evidence started at the first
    /// admitted poll. A hash keeps its start across registrations that keep it; a new watch
    /// (removed and added again, or after a repair) starts anew.
    func testEachAcceptedHashKeepsItsWatchStart() {
        let garage = sha("http://192.168.1.20:8099/garage")
        save("http://192.168.1.20:8099", "garage")
        sync()
        let first = clock
        XCTAssertEqual(bridge.watchStart(hash: garage), first)
        clock += 3600
        save("http://192.168.1.20:8099", "porch")
        sync()
        XCTAssertEqual(bridge.watchStart(hash: garage), first, "still watched: same watch")
        XCTAssertEqual(bridge.watchStart(hash: sha("http://192.168.1.20:8099/porch")), clock)
        clock += 3600
        _ = store.delete(subscription: store.getSubscription(baseUrl: "http://192.168.1.20:8099", topic: "garage")!)
        sync()
        XCTAssertNil(bridge.watchStart(hash: garage))
        clock += 3600
        save("http://192.168.1.20:8099", "garage")
        sync()
        XCTAssertEqual(bridge.watchStart(hash: garage), clock, "a new watch")
    }
}

// MARK: Fix round 4 (review-130d D1, D2, D9, D10)

extension NtfyShBridgeTests {
    private func syncInWake(seconds: TimeInterval) {
        let done = expectation(description: "wake")
        bridge.sync(reason: "wake", deadline: clock.addingTimeInterval(seconds)) { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private var renewals: Int {
        BridgeStubProtocol.sent.filter { $0.request.url?.path == "/v1/ntfai/watch/renew" }.count
    }

    private var ledgerURL: URL { stateDirectory.appendingPathComponent(NtfyShAccessLedger.fileName) }

    /// Holds `path`'s lock from another descriptor (as another process would) until `release` fires.
    private func holdLock(_ path: String) -> DispatchSemaphore {
        let holder = SharedFileLock(path: path)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { holder.withLock { held.signal(); release.wait() } }
        held.wait()
        return release
    }

    // D2: removals

    /// Red on e573bc4 (review-130d D2): the server applied a+b but the 200 was lost; after b was
    /// removed the app compared a with the acknowledged a, showed nothing pending and skipped as
    /// up to date, so b stayed watched. What an unacknowledged POST may have installed counts.
    func testADroppedReplyThenARemovalSendsTheShrink() throws {
        save("https://ntfy.sh", "a")
        sync()
        let b = save("https://ntfy.sh", "b")
        BridgeStubProtocol.reply = { _ in .failure(URLError(.networkConnectionLost)) }
        sync()
        XCTAssertEqual(bridge.currentRecord.unconfirmed, ["t:b"])
        XCTAssertTrue(store.delete(subscription: b))
        XCTAssertEqual(bridge.report(wakes: nil).removing, 1, "b may still be watched")
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":1,"expires":1900000000}"#)) }
        clock += 31 // past the client's backoff
        let before = watchPosts
        sync()
        XCTAssertEqual(watchPosts, before + 1)
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["a"])
        XCTAssertNil(bridge.currentRecord.unconfirmed, "acknowledged")
        XCTAssertEqual(bridge.report(wakes: nil).removing, 0)
    }

    /// Red on e573bc4 (review-130d D2): an empty removal required the access ledger, so after a
    /// failed first removal an unreadable ledger held it (and an opt-out) indefinitely. An empty
    /// list has no names to decide or to be refused.
    func testAnEmptyStoreRetriesAFailedRemovalWithoutTheAccessLedger() throws {
        let a = save("https://ntfy.sh", "a")
        sync()
        XCTAssertTrue(store.delete(subscription: a))
        BridgeStubProtocol.reply = { _ in .success((500, [:], "")) }
        sync()
        XCTAssertEqual(bridge.report(wakes: nil).removing, 1)
        try Data("{not json".utf8).write(to: ledgerURL)
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":0}"#)) }
        clock += 3601
        let before = watchPosts
        sync()
        XCTAssertEqual(watchPosts, before + 1)
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], [])
        XCTAssertEqual(bridge.report(wakes: nil).removing, 0)
        XCTAssertFalse(bridge.currentRecord.mayHaveEntries)
    }

    /// Red on e573bc4 (review-130d D2): turning off with the ledger unreadable sent nothing.
    func testTurningOffWithAnUnreadableLedgerStillRemoves() throws {
        save("https://ntfy.sh", "a")
        sync()
        try Data("{not json".utf8).write(to: ledgerURL)
        defaults.set(false, forKey: NtfyShBridge.enabledKey)
        BridgeStubProtocol.reply = { _ in .success((200, [:], #"{"watching":0}"#)) }
        let before = watchPosts
        sync()
        XCTAssertEqual(watchPosts, before + 1)
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], [])
    }

    /// Red on e573bc4 (review-130d D2): the extension's opt-out bit was written only when the
    /// empty POST was about to go, so a wake while the server's pause held it renewed the old list.
    func testAWakeBetweenTurningOffAndTheFirstPostDoesntRenew() {
        save("https://ntfy.sh", "a")
        sync()
        clock += 8 * 24 * 3600 // renewal due
        NtfyMeHostCooldown.note(status: 429, retryAfter: "60", lock: bridge.lock, now: clock)
        defaults.set(false, forKey: NtfyShBridge.enabledKey)
        let before = watchPosts
        sync()
        XCTAssertEqual(watchPosts, before, "the server's pause holds the empty list")
        XCTAssertEqual(bridge.currentRecord.optedOut, true, "committed before any gate")
        clock += 61
        renew(extensionBridge())
        XCTAssertEqual(renewals, 0)
    }

    /// Red on e573bc4 (review-130d D2): a known removal waited behind the anonymous checks, which
    /// can use up a wake. It goes first; the checks then change nothing, so no second list goes.
    func testAKnownRemovalGoesOutBeforeTheAccessChecks() throws {
        credentialed("a_q7x", "b_q7x")
        authReplies { _ in 200 }
        sync()
        clock += 25 * 3600 // both due for a recheck, still sendable
        XCTAssertTrue(store.delete(subscription: try XCTUnwrap(store.getSubscription(baseUrl: "https://ntfy.sh", topic: "b_q7x"))))
        let before = BridgeStubProtocol.sent.count
        let posts = watchPosts
        sync()
        let paths = BridgeStubProtocol.sent.dropFirst(before).map { $0.request.url?.path ?? "" }
        let post = try XCTUnwrap(paths.firstIndex(of: "/v1/ntfai/watch"))
        let check = try XCTUnwrap(paths.firstIndex { $0.hasSuffix("/auth") })
        XCTAssertLessThan(post, check, "the removal first")
        let body = try XCTUnwrap(BridgeStubProtocol.sent.dropFirst(before)[before + post].body)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["ntfy_sh_topics"] as? [String], ["a_q7x"])
        XCTAssertEqual(watchPosts, posts + 1)
    }

    // D1: the refusal barrier

    /// Red on e573bc4 (review-130d D1): with no saved login the restart barrier was ignored, so a
    /// refusal lost with its process let the next replacement resend the name. The status read
    /// records the names it can report on; each needs a fresh public answer first.
    func testWithoutALoginALostRefusalStillKeepsTheNameOutAfterARestart() throws {
        save("https://ntfy.sh", "a_q7x")
        save("https://ntfy.sh", "b_q7x")
        sync()
        XCTAssertEqual(Set(try lastBody()["ntfy_sh_topics"] as? [String] ?? []), ["a_q7x", "b_q7x"])
        XCTAssertTrue(probes().isEmpty, "no login: no check")
        clock += 1
        let holder = SharedFileLock(path: bridge.lock.path)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        BridgeStubProtocol.reply = { _ in
            DispatchQueue.global().async { holder.withLock { held.signal(); release.wait() } }
            held.wait()
            return .success((200, [:], #"{"watching":2,"connected":true,"unwatchable":["a_q7x"]}"#))
        }
        _ = status()
        XCTAssertEqual(bridge.access["a_q7x"]?.state, .refused, "in force in this process")
        bridge = makeBridge() // killed before the lock freed
        release.signal()
        XCTAssertNotEqual(bridge.access["a_q7x"]?.state, .refused)
        clock += 1
        authReplies { $0 == "a_q7x" ? 403 : 200 }
        save("https://ntfy.sh", "c_q7x")
        let before = BridgeStubProtocol.sent.count
        sync()
        XCTAssertEqual(Set(probes(after: before)), ["a_q7x", "b_q7x"], "only the names the read could report on")
        XCTAssertEqual(Set(try lastBody()["ntfy_sh_topics"] as? [String] ?? []), ["b_q7x", "c_q7x"])
    }

    /// Red on e573bc4 (review-130d D1): the barrier was the oldest unresolved request, so an old
    /// orphan before the last 200 masked a newer one after it. The latest one decides.
    func testTwoPendingRequestsStraddlingTheLast200() throws {
        credentialed("a_q7x")
        authReplies { _ in 200 }
        sync()
        let checked = clock
        var ledger = try JSONDecoder().decode(NtfyShAccessLedger.self, from: Data(contentsOf: ledgerURL))
        ledger.pending = ["dead-run/1": checked.addingTimeInterval(-10), "dead-run/2": checked.addingTimeInterval(5)]
        ledger.pendingNames = ["dead-run/1": ["a_q7x"], "dead-run/2": ["a_q7x"]]
        try JSONEncoder().encode(ledger).write(to: ledgerURL)
        clock += 10
        authReplies { $0 == "a_q7x" ? 403 : 200 }
        save("http://192.168.1.20:8099", "garage")
        let before = BridgeStubProtocol.sent.count
        sync()
        XCTAssertEqual(probes(after: before), ["a_q7x"])
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], [])
        XCTAssertEqual(try lastBody()["hashes"] as? [String], [sha("http://192.168.1.20:8099/garage")])
    }

    // D9: the cooldown file

    /// Red on e573bc4 (review-130d D9): an unreadable cooldown file read as no pause at all.
    func testAnUnreadableCooldownIsAShortPauseThenRecovers() throws {
        let lock = SharedFileLock(path: NSTemporaryDirectory() + "cooldown-\(UUID()).lock")
        try Data("{not json".utf8).write(to: NtfyMeHostCooldown.file(lock).url)
        XCTAssertEqual(NtfyMeHostCooldown.blockedUntil(lock, now: clock), clock.addingTimeInterval(60))
        XCTAssertEqual(NtfyMeHostCooldown.blockedUntil(lock, now: clock.addingTimeInterval(30), userInitiated: true),
                       clock.addingTimeInterval(60), "from when it was first found, for every request")
        XCTAssertNil(NtfyMeHostCooldown.blockedUntil(lock, now: clock.addingTimeInterval(61)), "then requests resume")
        NtfyMeHostCooldown.note(status: 429, retryAfter: "600", lock: lock, now: clock.addingTimeInterval(62))
        XCTAssertEqual(NtfyMeHostCooldown.file(lock).read()?.serverNotBefore, clock.addingTimeInterval(662), "the next answer rewrites the file")
    }

    /// Red on e573bc4 (review-130d D9): a pause this process couldn't save stayed in its memory
    /// only, so the other process kept sending. It is written before this process's next request.
    func testAPauseThatCouldntBeSavedIsWrittenBeforeTheNextRequest() {
        let lock = SharedFileLock(path: NSTemporaryDirectory() + "cooldown-\(UUID()).lock")
        let release = holdLock(lock.path)
        NtfyMeHostCooldown.note(status: 429, retryAfter: "600", lock: lock, now: clock)
        release.signal()
        XCTAssertNil(NtfyMeHostCooldown.file(lock).read()?.serverNotBefore, "not saved yet")
        XCTAssertEqual(NtfyMeHostCooldown.blockedUntil(lock, now: clock), clock.addingTimeInterval(600))
        XCTAssertEqual(NtfyMeHostCooldown.file(lock).read()?.serverNotBefore, clock.addingTimeInterval(600), "now the other process sees it")
    }

    /// Red on e573bc4 (review-130d D9): a save cleared this process's whole unsaved slot after
    /// releasing the lock, erasing a newer pause noted (and not saved) meanwhile.
    func testASaveClearsOnlyThePauseItWrote() {
        let lock = SharedFileLock(path: NSTemporaryDirectory() + "cooldown-\(UUID()).lock")
        defer { NtfyMeHostCooldown.afterSaveForTesting = nil }
        NtfyMeHostCooldown.afterSaveForTesting = { [unowned self] in
            NtfyMeHostCooldown.afterSaveForTesting = nil
            let release = self.holdLock(lock.path)
            NtfyMeHostCooldown.note(status: 429, retryAfter: "900", lock: lock, now: self.clock)
            release.signal()
        }
        NtfyMeHostCooldown.note(status: 500, retryAfter: nil, lock: lock, now: clock)
        XCTAssertEqual(NtfyMeHostCooldown.read(lock, now: clock).serverNotBefore, clock.addingTimeInterval(900))
    }

    // D10: probe scheduling

    /// Red on e573bc4 (review-130d D10): all five names were marked as rechecking before the first
    /// check, so when a 429 stopped the round after one, the others lost their valid 200s too.
    func testEachNameIsMarkedJustBeforeItsOwnCheck() throws {
        credentialed("t1_q7x", "t2_q7x", "t3_q7x")
        authReplies { _ in 200 }
        sync()
        clock += 25 * 3600 // all due, all still sendable
        BridgeStubProtocol.reply = { request in
            request.url?.path.hasSuffix("/auth") == true ? .success((429, ["Retry-After": "3600"], ""))
                : .success((200, [:], #"{"watching":2,"expires":1900000000}"#))
        }
        let before = BridgeStubProtocol.sent.count
        sync()
        XCTAssertEqual(probes(after: before), ["t1_q7x"], "the 429 stops the round")
        XCTAssertEqual(Set(try lastBody()["ntfy_sh_topics"] as? [String] ?? []), ["t2_q7x", "t3_q7x"])
    }

    /// Red on e573bc4 (review-130d D10): checks could use the last seconds of a wake, leaving no
    /// time for the list. With too little left for both, the checks wait and the list goes.
    func testAWakeKeepsTimeForTheListBeforeChecking() throws {
        credentialed("a_q7x")
        authReplies { _ in 200 }
        sync()
        clock += 25 * 3600
        save("http://192.168.1.20:8099", "garage")
        let before = BridgeStubProtocol.sent.count
        syncInWake(seconds: 6)
        XCTAssertEqual(probes(after: before), [])
        XCTAssertEqual(try lastBody()["ntfy_sh_topics"] as? [String], ["a_q7x"])
        XCTAssertEqual(try lastBody()["hashes"] as? [String], [sha("http://192.168.1.20:8099/garage")])
    }

    /// Review-130d D10: names past the five checked per run say they are waiting their turn.
    func testTopicsQueuedBehindTheCapSayWaitingToCheck() {
        credentialed("t1_q7x", "t2_q7x", "t3_q7x", "t4_q7x", "t5_q7x", "t6_q7x", "t7_q7x")
        let set = bridge.subscribedSet()
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "t1_q7x", set: set, wakes: nil, fcmBound: true), .held(.checkingAccess))
        XCTAssertEqual(bridge.topicState(baseUrl: "https://ntfy.sh", topic: "t6_q7x", set: set, wakes: nil, fcmBound: true), .held(.waitingToCheck))
        let held = bridge.report(wakes: nil).groups.first?.held ?? []
        XCTAssertEqual(held.filter { $0.hold == .waitingToCheck }.map(\.topic), ["t6_q7x", "t7_q7x"])
        XCTAssertTrue(NtfyShBridge.TopicHold.waitingToCheck.isPending)
    }
}
