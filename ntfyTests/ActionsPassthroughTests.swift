import CoreData
import XCTest
@testable import ntfy

/// Agent protocol v2, O1 (SPEC 4): actions are stored as sent, unknown types and keys included,
/// and `expires` is read. Red on 7bb2cca (build 52).
final class ActionsPassthroughTests: XCTestCase {

    private let wire = #"""
    {"id":"m1","time":1794700000,"expires":1794743200,"event":"message","topic":"deploys","message":"Deploy?",
     "tags":["agent"],"actions":[
      {"id":"a1","action":"view","label":"Open PR","url":"https://example.com/pr/1","x_future":{"k":[1,2]}},
      {"id":"a2","action":"broadcast","label":"Tell Tasker","extras":{"cmd":"deploy"}},
      {"id":"a3","action":"http","label":"Go","url":"https://ntfy.sh/deploys-answers","body":"reply:m1:go"}]}
    """#

    func testMessageDecodesExpiresAndKeepsEveryActionAsSent() throws {
        let message = try JSONDecoder().decode(Message.self, from: Data(wire.utf8))
        XCTAssertEqual(message.expires, 1794743200)
        XCTAssertEqual(message.actions?.map(\.id), ["a1", "a3"], "only known types are shown")
        let raw = try XCTUnwrap(message.rawActions)
        XCTAssertTrue(raw.contains(#""action":"broadcast""#))
        XCTAssertTrue(raw.contains(#""x_future":{"k":[1,2]}"#))

        // Through the extension's hand-off (userInfo) and back.
        let info = message.toUserInfo()
        XCTAssertEqual(info["expires"] as? String, "1794743200")
        let back = try XCTUnwrap(Message.from(userInfo: info))
        XCTAssertEqual(back.expires, 1794743200)
        XCTAssertEqual(back.rawActions, raw)
        XCTAssertEqual(back.actions?.map(\.id), ["a1", "a3"])

        // Into storage and back out: the row keeps the broadcast and the unknown key.
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        let subscription = store.saveSubscription(baseUrl: "https://ntfy.sh", topic: "deploys")
        store.save(notificationsFromMessages: [message], withSubscription: subscription)
        let request = ntfy.Notification.fetchRequest()
        let row = try XCTUnwrap(try store.context.fetch(request).first)
        XCTAssertEqual(row.actions, raw)
        XCTAssertEqual(row.actionsList().map(\.id), ["a1", "a3"])
    }

    func testAnUnreadableActionNoLongerHidesTheOthers() throws {
        let json = #"[{"id":"x","action":"view"},{"id":"y","action":"copy","label":"Copy","value":"v"}]"#
        XCTAssertEqual(Actions.shared.parse(json)?.map(\.id), ["y"], "the view without label or url is skipped alone")
    }

    func testEncryptedActionsKeepUnknownTypesAndKeys() throws {
        let payload = try JSONDecoder().decode(EncryptedPayload.self, from: Data(#"""
        {"message":"Deploy?","actions":[{"action":"broadcast","label":"Tasker","extras":{"a":"b"}},
         {"action":"view","label":"Open","url":"https://example.com","x_future":true}]}
        """#.utf8))
        let outer = Message(id: "e1", time: 1, event: "message", topic: "t")
        let merged = TopicEncryption.merge(payload, into: outer)
        let raw = try XCTUnwrap(merged.rawActions)
        XCTAssertTrue(raw.contains(#""action":"broadcast""#))
        XCTAssertTrue(raw.contains(#""x_future":true"#))
        XCTAssertTrue(raw.contains(#""id":"e1-e2e1""#), "ids derived as before")
        XCTAssertEqual(Actions.shared.parse(raw)?.map(\.id), ["e1-e2e1"])
    }
}
