import AVFoundation
import CoreImage
import UIKit
import XCTest
@testable import ntfy

final class TopicLinkTests: XCTestCase {
    private func link(_ path: String) -> TopicLink? {
        TopicLink(url: URL(string: "https://ntfy-me.com" + path)!)
    }

    func testValidTopicAlphabetAndLength() {
        for topic in ["a", "_", "-", "A-Z_a-z_0123456789", String(repeating: "a", count: 64)] {
            XCTAssertEqual(link("/" + topic)?.topic, topic)
        }
    }

    func testRejectsInvalidTopicsAndMultipleSegments() {
        for path in ["", "/", "//", "/a/b", "//a", "/a//", "/a.json", "/a,b", "/a+b", "/a b",
                     "/é", "/a%0A", "/a%00", "/%2E", "/%2E%2E", "/a%2Fb", "/" + String(repeating: "a", count: 65)] {
            XCTAssertNil(link(path), path)
        }
    }

    func testTrailingSlashQueryAndFragmentDoNotChangeTopic() {
        XCTAssertEqual(link("/Alerts-42"), link("/Alerts-42/"))
        XCTAssertEqual(link("/Alerts-42"), link("/Alerts-42/?topic=other&subscribe=true#different"))
    }

    func testTopicCaseIsPreserved() {
        XCTAssertEqual(link("/Alerts")?.topic, "Alerts")
        XCTAssertNotEqual(link("/Alerts"), link("/alerts"))
    }

    func testExactServerReservedList() {
        let reserved = ["docs", "static", "file", "app", "metrics", "account", "settings", "signup", "login", "v1"]
        XCTAssertEqual(TopicLink.reservedNames, Set(reserved))
        for name in reserved {
            XCTAssertNil(link("/" + name), name)
            XCTAssertNil(link("/" + name + "/?q=x#fragment"), name)
            XCTAssertNotNil(link("/" + name.uppercased()), name)
        }
        XCTAssertNotNil(link("/docs-alerts"))
    }

    func testDecodedPathsStillObeyTopicAndReservedRules() {
        XCTAssertEqual(link("/%41lerts")?.topic, "Alerts")
        XCTAssertNil(link("/%61pp"))
        XCTAssertNil(link("/alerts%252Fother"))
    }

    func testOnlyTheHTTPSOriginIsAccepted() {
        for url in ["http://ntfy-me.com/alerts", "https://ntfy.sh/alerts", "https://www.ntfy-me.com/alerts",
                    "https://ntfy-me.com.evil.test/alerts", "https://ntfy-me.com:8443/alerts",
                    "https://user@ntfy-me.com/alerts", "https://user:password@ntfy-me.com/alerts",
                    "ntfy://ntfy-me.com/alerts"] {
            XCTAssertNil(TopicLink(url: URL(string: url)!), url)
        }
        XCTAssertEqual(TopicLink(url: URL(string: "HTTPS://NTFY-ME.COM:443/Alerts")!), link("/Alerts"))
    }

    func testNewTopicRoutesToConfirmationWithExplicitServer() {
        let url = URL(string: "https://ntfy-me.com/alerts")!
        XCTAssertEqual(TopicLinkRoute.resolve(url, subscriptionURLs: []), .add(TopicLink(url: url)!))
        XCTAssertEqual(TopicLink.baseURL, "https://ntf-ai.app")
    }

    func testSubscribedTopicRoutesToTheStoredNavigationURL() {
        let stored = "https://NTFY-ME.COM:443/Alerts"
        XCTAssertEqual(TopicLinkRoute.resolve(URL(string: "https://ntfy-me.com/Alerts/?q=x#fragment")!,
                                              subscriptionURLs: [stored]), .open(stored))
    }

    func testSameNameOnAnotherServerAndDifferentCaseAreDifferentTopics() {
        let url = URL(string: "https://ntfy-me.com/Alerts")!
        XCTAssertEqual(TopicLinkRoute.resolve(url, subscriptionURLs: ["https://ntfy.sh/Alerts", "https://ntfy-me.com/alerts"]),
                       .add(TopicLink(url: url)!))
    }

    func testReservedInvalidAndOtherHostHaveNoRoutingDecision() {
        for url in ["https://ntfy-me.com/docs", "https://ntfy-me.com/a/b", "https://ntfy.sh/alerts"] {
            XCTAssertNil(TopicLinkRoute.resolve(URL(string: url)!, subscriptionURLs: [url]))
        }
    }
}

/// QR codes: what the app encodes, and how a decoded code is parsed and routed (upstream ntfy #756).
final class TopicQRCodeTests: XCTestCase {
    private func scanned(_ text: String) -> TopicLink? { TopicLink(scanned: text) }

    func testUniversalLinkCarriesItsServer() {
        XCTAssertEqual(TopicLink(url: URL(string: "https://NTFY-ME.COM:443/Alerts")!)?.server, "https://ntfy-me.com")
    }

    func testScannedNtfyMeTopicMatchesTheUniversalLink() {
        let link = scanned("https://ntfy-me.com/Alerts-42")
        XCTAssertEqual(link?.server, "https://ntfy-me.com")
        XCTAssertEqual(link?.topic, "Alerts-42")
        XCTAssertEqual(link, TopicLink(url: URL(string: "https://ntfy-me.com/Alerts-42")!))
    }

    func testSelfHostedServerWithPortAndPathPrefix() {
        let link = scanned("https://Push.Example.org:8443/ntfy/sub/home_alerts?x=1#frag")
        XCTAssertEqual(link?.server, "https://push.example.org:8443/ntfy/sub")
        XCTAssertEqual(link?.topic, "home_alerts")
        XCTAssertEqual(scanned("http://192.168.1.20:8080/garage/")?.server, "http://192.168.1.20:8080")
        XCTAssertEqual(scanned("http://[fd00::5]:2586/garage")?.server, "http://[fd00::5]:2586")
        // Default ports are dropped so the stored URL and the scanned one compare equal.
        XCTAssertEqual(scanned("https://ntfy.sh:443/a")?.server, "https://ntfy.sh")
        XCTAssertEqual(scanned("http://ntfy.home:80/a")?.server, "http://ntfy.home")
    }

    func testAndroidDeepLinkFormat() {
        XCTAssertEqual(scanned("ntfy://ntfy.sh/alerts"), scanned("https://ntfy.sh/alerts"))
        XCTAssertEqual(scanned("ntfy://ntfy.home:2586/alerts?secure=false&display=Garage"),
                       scanned("http://ntfy.home:2586/alerts"))
        XCTAssertNil(scanned("ntfy://ntfy.sh/prefix/alerts"))
    }

    func testAddressWithoutSchemeMeansHTTPS() {
        XCTAssertEqual(scanned("  ntfy.sh/alerts\n"), scanned("https://ntfy.sh/alerts"))
    }

    func testNonTopicAddressesAreRejected() {
        for text in ["https://ntfy.sh/", "https://ntfy.sh", "https://ntfy.sh/docs/publish/", "https://ntfy.sh/app",
                     "https://ntfy.sh/alerts.json", "https://example.com/a/b.html", "https://ntfy.sh/a%2Fb",
                     "https://ntfy.sh//alerts", "https://user:pw@ntfy.sh/alerts", "ftp://ntfy.sh/alerts",
                     "mailto:someone@example.com", "tel:+15551234567", "ntfy://ntfy.sh/v1",
                     "https://ntfy.sh/" + String(repeating: "a", count: 65)] {
            XCTAssertNil(scanned(text), text)
        }
    }

    func testGarbageIsRejected() {
        for text in ["", "   ", "alerts", "hello world", "WIFI:S:Home;T:WPA;P:secret;;",
                     "BEGIN:VCARD\nFN:Someone\nEND:VCARD", "🙂/🙂", "://", "https://"] {
            XCTAssertNil(scanned(text), text)
        }
    }

    func testScanOfANewTopicRoutesToTheAddSheetOnItsServer() {
        let route = TopicLinkRoute.resolve(scanned: "https://push.example.org:8443/ntfy/alerts",
                                           subscriptionURLs: ["https://ntfy-me.com/alerts", "https://push.example.org/ntfy/alerts"])
        XCTAssertEqual(route, .add(TopicLink(scanned: "https://push.example.org:8443/ntfy/alerts")!))
    }

    func testScanOfASubscribedTopicOpensTheStoredOne() {
        let stored = "https://Push.Example.org:443/ntfy/alerts"
        XCTAssertEqual(TopicLinkRoute.resolve(scanned: "ntfy://push.example.org/alerts", subscriptionURLs: [stored]),
                       .add(TopicLink(scanned: "https://push.example.org/alerts")!))
        XCTAssertEqual(TopicLinkRoute.resolve(scanned: "https://push.example.org/ntfy/alerts/", subscriptionURLs: [stored]),
                       .open(stored))
    }

    func testScanOfANonTopicHasNoRoute() {
        XCTAssertNil(TopicLinkRoute.resolve(scanned: "https://ntfy.sh/docs", subscriptionURLs: []))
        XCTAssertNil(TopicLinkRoute.resolve(scanned: "not a link", subscriptionURLs: []))
    }

    func testPayloadIsTheTopicURL() {
        XCTAssertEqual(TopicQRCode.payload(baseUrl: "https://ntfy-me.com/", topic: "Alerts"), "https://ntf-ai.app/Alerts")
        XCTAssertEqual(TopicQRCode.payload(baseUrl: "http://ntfy.home:2586/sub", topic: "a"), "http://ntfy.home:2586/sub/a")
    }

    func testPayloadRemovesAuthenticationAndURLMetadata() {
        for server in ["https://user:password@push.example:8443/prefix?token=secret#private",
                       "https://push.example:8443/prefix/?token=secret#private"] {
            XCTAssertEqual(TopicQRCode.payload(baseUrl: server, topic: "Alerts"),
                           "https://push.example:8443/prefix/Alerts")
        }
    }

    func testPayloadPreservesEncodedServerPrefix() {
        XCTAssertEqual(TopicQRCode.payload(baseUrl: "https://push.example/root%2Fproxy?token=secret", topic: "Alerts-42"),
                       "https://push.example/root%2Fproxy/Alerts-42")
    }

    func testPayloadRefusesAddressesThatCannotRoundTripAsTopics() {
        for server in ["", "https://", "file:///private", "ftp://push.example", "https://push.example/docs",
                       "https://push.example//prefix", "https://push.example:99999"] {
            XCTAssertNil(TopicQRCode.payload(baseUrl: server, topic: "Alerts"), server)
        }
        for topic in ["", "docs", "a/b", "a?token=secret", String(repeating: "a", count: 65)] {
            XCTAssertNil(TopicQRCode.payload(baseUrl: "https://push.example", topic: topic))
        }
    }

    func testHTTPScanUsesHTTPSOnlyForTheAppsOwnHost() {
        for code in ["http://NTFY-ME.COM/Alerts", "http://ntfy-me.com:80/Alerts",
                     "ntfy://ntfy-me.com/Alerts?secure=false"] {
            XCTAssertEqual(scanned(code)?.server, "https://ntfy-me.com")
            XCTAssertEqual(TopicLinkRoute.resolve(scanned: code, subscriptionURLs: ["https://ntfy-me.com/Alerts"]),
                           .open("https://ntfy-me.com/Alerts"))
        }
        XCTAssertEqual(scanned("http://ntfy-me.com.evil.test/Alerts")?.server, "http://ntfy-me.com.evil.test")
        XCTAssertEqual(scanned("http://ntfy.home/Alerts")?.server, "http://ntfy.home")
    }

    func testGeneratedCodeDecodesBackToTheSameTopic() throws {
        for (baseUrl, topic, expectedServer) in [
            ("https://ntfy-me.com", "Alerts-42", "https://ntfy-me.com"),
            ("http://push.example.org:8443/ntfy", "home_alerts", "http://push.example.org:8443/ntfy"),
            ("https://user:password@push.example.org/prefix?token=secret#private", "alerts", "https://push.example.org/prefix")
        ] {
            let payload = try XCTUnwrap(TopicQRCode.payload(baseUrl: baseUrl, topic: topic))
            let image = try XCTUnwrap(TopicQRCode.image(for: payload))
            let ciImage = try XCTUnwrap(CIImage(image: image))
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let decoded = detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(decoded, [payload])
            let link = try XCTUnwrap(TopicLink(scanned: decoded[0]))
            XCTAssertEqual(link.server, expectedServer)
            XCTAssertEqual(link.topic, topic)
        }
    }

    func testCodeIsLargeEnoughToReadAtArmsLength() throws {
        // 12 pixels per module; a short topic URL is a 25-module (version 2) code or larger.
        let image = try XCTUnwrap(TopicQRCode.image(for: "https://ntfy-me.com/alerts"))
        XCTAssertGreaterThanOrEqual(image.size.width, 25 * 12)
        XCTAssertEqual(image.size.width, image.size.height)
    }

    func testCameraStates() {
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: false, status: .authorized), .unavailable)
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: true, status: .authorized), .scanning)
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: true, status: .notDetermined), .needsPermission)
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: true, status: .denied), .denied)
        XCTAssertEqual(TopicQRCameraState.from(hasCamera: true, status: .restricted), .denied)
    }
}

final class TopicQRScannerTextTests: XCTestCase {
    func testRejectedCodesNeverExposeTheirContents() {
        XCTAssertEqual(TopicQRScannerView.rejectionText("https://ntfy.sh/docs"),
                       String(localized: "That code isn't an ntfy topic address."))
        for secret in ["https://user:password@example.org/topic", "http://example.org/docs?reset_token=abc#private",
                       "ntfy://example.org/docs?token=secret", "WIFI:S:Home;T:WPA;P:secret;;",
                       "BEGIN:VCARD\nFN:Someone\nEND:VCARD", "otpauth://totp/x?secret=ABC"] {
            XCTAssertEqual(TopicQRScannerView.rejectionText(secret), String(localized: "That code isn't an ntfy topic address."), secret)
        }
    }
}

final class TopicQRCameraLifecycleTests: XCTestCase {
    func testReturningFromSettingsRefreshesDeniedAuthorization() {
        let center = NotificationCenter()
        var status = AVAuthorizationStatus.denied
        let camera = TopicQRAuthorization(hasCamera: { true }, status: { status }, center: center)
        camera.appear()
        XCTAssertEqual(camera.state, .denied)
        status = .authorized
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(camera.state, .scanning)
        status = .denied
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(camera.state, .denied)
    }

    func testBackgroundStopsAndForegroundRestartsOnlyVisibleAuthorizedCapture() {
        let center = NotificationCenter()
        let queue = DispatchQueue(label: "test.qr.capture")
        var authorized = true
        var events = [String]()
        let capture = TopicQRCaptureLifecycle(queue: queue, center: center, isActive: true,
            authorized: { authorized }, start: { events.append("start") }, stop: { events.append("stop") })
        capture.appear()
        queue.sync {}
        XCTAssertEqual(events.last, "start")
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(events.last, "stop", "background capture must be explicitly stopped")
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(events.last, "start")
        capture.disappear()
        queue.sync {}
        let dismissedEvents = events
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(events, dismissedEvents, "a dismissed scanner must not restart")
        authorized = false
        capture.appear()
        queue.sync {}
        XCTAssertEqual(events.last, "stop", "revoked access must prevent a restart")
    }

    func testPermissionCompletionWhileInactiveCannotStartCapture() {
        let center = NotificationCenter()
        let queue = DispatchQueue(label: "test.qr.inactive")
        var events = [String]()
        let capture = TopicQRCaptureLifecycle(queue: queue, center: center, isActive: false,
            authorized: { true }, start: { events.append("start") }, stop: { events.append("stop") })
        capture.appear()
        queue.sync {}
        XCTAssertFalse(events.contains("start"))
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(events.last, "start")
        capture.disappear()
        queue.sync {}
    }
}


/// The public domain is an alias, not a new persistence or Firebase namespace.
@MainActor
final class HostedServerAliasTests: XCTestCase {
    private let internalBase = "https://ntfy-me.com"
    private let publicBase = "https://ntf-ai.app"

    func testBuiltInIdentityAndRelayRemainUnchanged() {
        XCTAssertEqual(Config.appBaseUrl, internalBase)
        XCTAssertEqual(Config.upstreamConfigLine, "upstream-base-url: https://ntfy-me.com")
        XCTAssertEqual(RetiredDefaultServerMigration.replacementBaseUrl, internalBase)
    }

    func testTypedAliasCanonicalizesOnlyTheHostedRoot() {
        for input in [publicBase, " HTTPS://NTF-AI.APP:443/// ", "http://ntf-ai.app", "http://ntf-ai.app:80/"] {
            XCTAssertEqual(normalizeBaseUrl(input), internalBase, input)
            XCTAssertEqual(SubscriptionAddServer.selectedBaseUrl(useAnother: true, input: input, defaultBaseUrl: internalBase), internalBase)
        }
        for input in ["https://ntf-ai.app:8443", "https://ntf-ai.app/prefix", "https://ntf-ai.app.evil.test", "https://user@ntf-ai.app", "https://ntf-ai.app?q=x"] {
            XCTAssertNotEqual(normalizeBaseUrl(input), internalBase, input)
        }
    }

    func testAliasUsesExistingRawFCMNameAndEncryptionIdentity() {
        // Literal values: a change that moves the identity to the public host must not pass by moving
        // both sides of a comparison. sha256("https://ntfy-me.com/Alerts"), what 1.24 phones computed.
        XCTAssertEqual(topicHash(baseUrl: internalBase, topic: "Alerts"), "0fd637bbe9be238094cd9711b8a62a33e9c795f2322803005bfb1beb3e789226")
        XCTAssertEqual(topicUrl(baseUrl: internalBase, topic: "Alerts"), "https://ntfy-me.com/Alerts")
        XCTAssertEqual(firebaseTopic(baseUrl: publicBase, topic: "Alerts"), "Alerts")
        XCTAssertEqual(topicHash(baseUrl: publicBase, topic: "Alerts"), topicHash(baseUrl: internalBase, topic: "Alerts"))
        XCTAssertEqual(topicUrl(baseUrl: publicBase, topic: "Alerts"), internalBase + "/Alerts")
        XCTAssertNotEqual(firebaseTopic(baseUrl: "https://ntf-ai.app:8443", topic: "Alerts"), "Alerts")
    }

    func testMixedInputsCannotCreateTwoRowsOrResetExistingState() {
        let store = Store(inMemory: true)
        let old = store.saveSubscription(baseUrl: internalBase, topic: "Alerts")
        old.pinned = true; old.customDisplayName = "My alerts"; old.fcmSubscribed = true
        let added = store.saveSubscription(baseUrl: publicBase, topic: "Alerts")
        XCTAssertEqual(old.objectID, added.objectID)
        XCTAssertEqual(store.getSubscriptions()?.count, 1)
        XCTAssertTrue(added.pinned); XCTAssertTrue(added.fcmSubscribed)
        XCTAssertEqual(added.customDisplayName, "My alerts")
        XCTAssertEqual(added.baseUrl, internalBase)
        XCTAssertEqual(store.getSubscription(baseUrl: publicBase, topic: "Alerts")?.objectID, old.objectID)
        XCTAssertTrue(old.matches(baseUrl: publicBase, topic: "Alerts"))
        XCTAssertEqual(store.findSubscriptionMatch(forPollRequestTopic: "Alerts", preferredBaseUrl: publicBase)?.baseUrl, internalBase)
    }

    func testNewAliasRowIsCanonicalBeforeItCanBindOrReceive() {
        let store = Store(inMemory: true)
        let first = store.saveSubscription(baseUrl: publicBase, topic: "new-topic")
        let second = store.saveSubscription(baseUrl: internalBase, topic: "new-topic")
        XCTAssertEqual(first.objectID, second.objectID)
        XCTAssertEqual(first.baseUrl, internalBase)
        XCTAssertEqual(firebaseTopic(baseUrl: first.baseUrl!, topic: first.topic!), "new-topic")
        XCTAssertTrue(first.matches(baseUrl: internalBase, topic: "new-topic"))
    }

    func testBothUniversalLinksAndQRSpellingsOpenTheExistingRow() {
        let existing = internalBase + "/Alerts"
        for host in ["ntf-ai.app", "ntfy-me.com"] {
            let url = URL(string: "https://" + host + "/Alerts")!
            XCTAssertEqual(TopicLink(url: url)?.server, internalBase)
            XCTAssertEqual(TopicLinkRoute.resolve(url, subscriptionURLs: [existing]), .open(existing))
            for prefix in ["https://", "http://", "ntfy://", ""] {
                XCTAssertEqual(TopicLinkRoute.resolve(scanned: prefix + host + "/Alerts", subscriptionURLs: [existing]), .open(existing))
            }
        }
        XCTAssertNil(TopicLink(url: URL(string: publicBase + "/docs")!))
        XCTAssertNil(TopicLink(url: URL(string: "https://ntf-ai.app.evil.test/Alerts")!))
    }

    func testGeneratedShareQRAndPublishAddressesUseThePublicHost() {
        XCTAssertEqual(TopicQRCode.payload(baseUrl: internalBase, topic: "Alerts"), publicBase + "/Alerts")
        XCTAssertTrue(PublishCommand.simple(baseUrl: internalBase, topic: "Alerts").contains(publicBase + "/Alerts"))
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: internalBase, topic: "Alerts")
        XCTAssertEqual(sub.shortUrlString(), "ntf-ai.app/Alerts")
        XCTAssertEqual(sub.serverHost(), "ntf-ai.app")
    }

    func testOldAndNewReplyRecipesProduceTheSameInternalRequest() throws {
        for host in ["ntf-ai.app", "ntfy-me.com"] {
            let target = (publicBase + "/answers").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let action = Action(id: "reply", action: "view", label: "Reply", url: "https://" + host + "/docs/agents#reply-v1=" + target)
            let reply = try XCTUnwrap(BannerReply.httpAction(for: action, text: "yes"))
            let request = try XCTUnwrap(ActionExecutor.makeHTTPRequest(reply, baseUrl: nil))
            XCTAssertEqual(request.url?.absoluteString, internalBase + "/answers")
            XCTAssertEqual(request.httpBody, Data("yes".utf8))
        }
    }

    func testHTTPActionAliasUsesSameServerWithoutChangingForeignURLs() throws {
        let action = Action(id: "approve", action: "http", label: "Approve", url: publicBase + "/answers?x=1", method: "POST", body: "approved")
        XCTAssertEqual(try XCTUnwrap(ActionExecutor.makeHTTPRequest(action, baseUrl: nil)).url?.absoluteString, internalBase + "/answers?x=1")
        let foreign = Action(id: "approve", action: "http", label: "Approve", url: "https://ntf-ai.app.evil.test/answers")
        XCTAssertEqual(try XCTUnwrap(ActionExecutor.makeHTTPRequest(foreign, baseUrl: nil)).url?.absoluteString, foreign.url)
    }
}

// MARK: - Rows an older build stored under the alias

@MainActor
final class HostedAliasRowMigrationTests: XCTestCase {
    private let alias = "https://ntf-ai.app"
    private let canonical = "https://ntfy-me.com"

    private func defaults() -> UserDefaults {
        let name = "HostedAliasRowMigrationTests-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// What a 1.24 build left: the alias spelled in the row, with a hashed FCM binding it confirmed.
    private func olderBuildRow(_ store: Store, topic: String) -> Subscription {
        let row = store.saveSubscription(baseUrl: canonical, topic: topic)
        row.baseUrl = alias
        row.fcmSubscribed = true
        try! store.context.save()
        return row
    }

    func testRowMovesToRawFCMNameAndRebinds() throws {
        let store = Store(inMemory: true)
        let row = olderBuildRow(store, topic: "Alerts")
        XCTAssertNil(store.getSubscription(baseUrl: alias, topic: "Alerts"), "push lookup misses the stale spelling")
        let defaults = defaults()

        let outcome = HostedAliasRowMigration.run(store: store, defaults: defaults, reconciler: nil)

        XCTAssertEqual(outcome.moved, ["Alerts"])
        XCTAssertEqual(row.baseUrl, canonical)
        XCTAssertFalse(row.fcmSubscribed, "it holds the hashed binding, so it must bind the raw name")
        XCTAssertEqual(firebaseTopic(baseUrl: row.baseUrl!, topic: "Alerts"), "Alerts")
        XCTAssertEqual(store.getSubscription(baseUrl: alias, topic: "Alerts")?.objectID, row.objectID)
        XCTAssertTrue(store.getSubscriptionsPendingFcmSubscribe().contains { $0.objectID == row.objectID })
        // The queued name is the one the older build bound, not the canonical topic hash.
        let oldName = HostedAliasRowMigration.legacyFcmName(storedBaseUrl: alias, topic: "Alerts")
        XCTAssertNotEqual(oldName, topicHash(baseUrl: alias, topic: "Alerts"))
        XCTAssertEqual(FcmTeardownLedger(defaults: defaults).entries.map(\.name), [oldName],
                       "only the binding the older build made is torn down, never the raw name")
    }

    func testRowBesideACanonicalOneFoldsIntoIt() {
        let store = Store(inMemory: true)
        let existing = store.saveSubscription(baseUrl: canonical, topic: "Alerts")
        existing.fcmSubscribed = true
        let row = Subscription(context: store.context)
        row.baseUrl = alias; row.topic = "Alerts"; row.pinned = true; row.customDisplayName = "Mine"
        try! store.context.save()

        let outcome = HostedAliasRowMigration.run(store: store, defaults: defaults(), reconciler: nil)

        XCTAssertEqual(outcome.merged, ["Alerts"])
        XCTAssertEqual(store.getSubscriptions()?.count, 1, "the list must not show the topic twice")
        XCTAssertTrue(existing.pinned)
        XCTAssertTrue(existing.fcmSubscribed, "the surviving row's raw binding is still right")
        XCTAssertEqual(existing.customDisplayName, "Mine")
    }

    func testOtherServersAndEncryptedRowsStay() {
        let store = Store(inMemory: true)
        let foreign = store.saveSubscription(baseUrl: "https://ntf-ai.app:8443", topic: "Alerts")
        foreign.fcmSubscribed = true
        let legacySpelling = store.saveSubscription(baseUrl: "https://ntfy-me.com:443", topic: "Other")
        legacySpelling.fcmSubscribed = true
        let encrypted = olderBuildRow(store, topic: "Secret")
        encrypted.encrypted = true
        try! store.context.save()

        let outcome = HostedAliasRowMigration.run(store: store, defaults: defaults(), reconciler: nil)

        XCTAssertEqual(outcome, .init(moved: [], merged: [], skippedEncrypted: ["Secret"]))
        XCTAssertEqual(foreign.baseUrl, "https://ntf-ai.app:8443")
        XCTAssertTrue(foreign.fcmSubscribed)
        XCTAssertEqual(legacySpelling.baseUrl, "https://ntfy-me.com:443")
        XCTAssertTrue(legacySpelling.fcmSubscribed)
        XCTAssertEqual(encrypted.baseUrl, alias)
    }
}
