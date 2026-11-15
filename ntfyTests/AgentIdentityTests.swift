import UIKit
import UserNotifications
import XCTest
@testable import ntfy

/// Agent protocol v2, O7 (SPEC 6): who is asking. Red on 7bb2cca (build 52).
final class AgentIdentityTests: XCTestCase {
    func testTheFirstValidNameTagNamesTheAgent() {
        XCTAssertEqual(AgentIdentity.name(tags: ["agent", "@", "@" + String(repeating: "x", count: 33), "@bad/name",
                                                 "@Claude Code", "@Other"]), "Claude Code")
        XCTAssertNil(AgentIdentity.name(tags: ["agent"]))
        XCTAssertEqual(AgentIdentity.monogram("claude"), "C")
        XCTAssertEqual(AgentIdentity.conversationIdentifier(topicURL: "https://ntfy-me.com/deploys", name: "Claude"),
                       "https://ntfy-me.com/deploys#Claude")
    }

    func testAnAgentsBannerIsThreadedByAgentAndKeepsItsFields() throws {
        let message = Message(id: "m1", time: 1, event: "message", topic: "deploys", message: "Deploy?", priority: 4,
                              tags: ["agent", "@Claude"])
        let content = UNMutableNotificationContent()
        content.modify(message: message, baseUrl: "https://ntfy-me.com", categoryRegistrationTimeout: 0)
        XCTAssertEqual(content.threadIdentifier, "https://ntfy-me.com/deploys#Claude")
        content.categoryIdentifier = "ntfyActions.test"
        let shown = AgentIdentity.communicationContent(content, name: "Claude", avatar: nil,
                                                       conversation: content.threadIdentifier, donate: false)
        // Without the Communication Notifications capability iOS refuses the intent; with it, the
        // content changes. Either way the app's own decisions survive.
        XCTAssertEqual(shown.threadIdentifier, "https://ntfy-me.com/deploys#Claude")
        XCTAssertEqual(shown.interruptionLevel, .timeSensitive)
        XCTAssertEqual(shown.categoryIdentifier, "ntfyActions.test")
        XCTAssertEqual(shown.userInfo["id"] as? String, "m1")
        XCTAssertEqual(shown.body, "Deploy?")
        XCTAssertNotNil(shown.sound)

        let plain = UNMutableNotificationContent()
        plain.modify(message: Message(id: "m2", time: 1, event: "message", topic: "deploys", message: "x"),
                     baseUrl: "https://ntfy-me.com", categoryRegistrationTimeout: 0)
        XCTAssertEqual(plain.threadIdentifier, "https://ntfy-me.com/deploys", "no name, topic thread as before")
    }

    /// The path the Communication Notifications capability turns on: the intent iOS draws the banner
    /// from, and the merge that keeps the app's decisions over whatever iOS changed.
    func testTheMessageIntentNamesTheAgentAndTheMergeKeepsTheAppsDecisions() throws {
        let png = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.pngData())
        let intent = AgentIdentity.messageIntent(body: "Deploy?", name: "Claude", avatar: png,
                                                 conversation: "https://ntfy-me.com/deploys#Claude")
        XCTAssertEqual(intent.sender?.displayName, "Claude")
        XCTAssertEqual(intent.sender?.customIdentifier, "https://ntfy-me.com/deploys#Claude")
        XCTAssertEqual(intent.conversationIdentifier, "https://ntfy-me.com/deploys#Claude")
        XCTAssertEqual(intent.content, "Deploy?")
        XCTAssertNotNil(intent.sender?.image)
        XCTAssertNotNil(intent.image(forParameterNamed: \.sender))
        XCTAssertNil(AgentIdentity.messageIntent(body: "x", name: "Claude", avatar: nil, conversation: "c").sender?.image)

        let mine = UNMutableNotificationContent()
        mine.body = "Deploy?"
        mine.interruptionLevel = .timeSensitive
        mine.relevanceScore = 0.8
        mine.sound = .default
        mine.categoryIdentifier = "ntfyActions.test"
        mine.threadIdentifier = "https://ntfy-me.com/deploys#Claude"
        mine.userInfo = ["id": "m1"]
        mine.badge = 3
        let changed = UNMutableNotificationContent()
        changed.body = "Deploy?"
        changed.title = "Claude"
        changed.interruptionLevel = .active
        changed.threadIdentifier = "other"
        let kept = AgentIdentity.keepingDecisions(of: mine, in: changed)
        XCTAssertEqual(kept.title, "Claude", "what iOS adds stays")
        XCTAssertEqual(kept.interruptionLevel, .timeSensitive)
        XCTAssertEqual(kept.relevanceScore, 0.8)
        XCTAssertNotNil(kept.sound)
        XCTAssertEqual(kept.categoryIdentifier, "ntfyActions.test")
        XCTAssertEqual(kept.threadIdentifier, "https://ntfy-me.com/deploys#Claude")
        XCTAssertEqual(kept.userInfo["id"] as? String, "m1")
        XCTAssertEqual(kept.badge, 3)
    }

    func testAvatarsComeOnlyFromTheTopicsOwnHostOrAnEncryptedTopic() {
        XCTAssertFalse(AgentIdentity.avatarAllowed(iconURL: "https://tracker.example/a.png", topicBaseURL: "https://ntfy.sh", encrypted: false))
        XCTAssertTrue(AgentIdentity.avatarAllowed(iconURL: "https://ntfy.sh/file/a.png", topicBaseURL: "https://ntfy.sh", encrypted: false))
        XCTAssertTrue(AgentIdentity.avatarAllowed(iconURL: "https://ntf-ai.app/a.png", topicBaseURL: "https://ntfy-me.com", encrypted: false))
        XCTAssertTrue(AgentIdentity.avatarAllowed(iconURL: "https://tracker.example/a.png", topicBaseURL: "https://ntfy.sh", encrypted: true))
        XCTAssertFalse(AgentIdentity.avatarAllowed(iconURL: "http://ntfy.sh/a.png", topicBaseURL: "https://ntfy.sh", encrypted: false))
        XCTAssertFalse(AgentIdentity.avatarAllowed(iconURL: "https://ntfy.sh:8443/a.png", topicBaseURL: "https://ntfy.sh", encrypted: false))
    }

    func testARefusedAvatarMakesNoRequest() {
        CountingProtocol.count = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]
        let avatars = AgentAvatarStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("avatars-\(UUID().uuidString)"), session: URLSession(configuration: configuration))
        let message = Message(id: "m1", time: 1, event: "message", topic: "deploys", tags: ["agent", "@Claude"],
                              icon: "https://tracker.example/a.png")
        let done = expectation(description: "refused")
        avatars.avatar(for: message, baseUrl: "https://ntfy.sh") { data in
            XCTAssertNil(data)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(CountingProtocol.count, 0, "the foreign host never sees the phone")

        let allowed = expectation(description: "allowed")
        var own = message
        own.icon = "https://ntfy.sh/file/a.png"
        avatars.avatar(for: own, baseUrl: "https://ntfy.sh") { _ in allowed.fulfill() }
        wait(for: [allowed], timeout: 5)
        XCTAssertEqual(CountingProtocol.count, 1, "control: the topic's own host is asked")
    }
}

private final class CountingProtocol: URLProtocol {
    static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
