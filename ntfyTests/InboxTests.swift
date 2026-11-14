import XCTest
import CoreData
@testable import ntfy

/// The Waiting on you rule (DIRECTIONS 1.6) on its own.
final class WaitingRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func act(_ type: String, url: String? = "https://agent.example/answers") -> Action {
        Action(id: UUID().uuidString, action: type, label: "Approve", url: url, method: "POST", headers: nil, body: nil, clear: nil)
    }

    private var replyLink: Action {
        Action(id: UUID().uuidString, action: "view", label: "Reply",
               url: "https://ntfy-me.com/docs/agents#reply-v1=https%3A%2F%2Fntfy-me.com%2Freply-secret",
               method: nil, headers: nil, body: nil, clear: nil)
    }

    private func waits(_ actions: [Action], age: TimeInterval = 60, entry: AnswerEntry? = nil, cleared: Bool = false) -> Bool {
        WaitingRule.isWaiting(actions: actions, time: now.addingTimeInterval(-age), entry: entry, cleared: cleared, now: now)
    }

    func testHTTPAndReplyActionsWaitButLinksAndCopyDoNot() {
        XCTAssertTrue(waits([act("http")]))
        XCTAssertTrue(waits([replyLink]), "a reply action asks for an answer")
        XCTAssertTrue(waits([act("view"), act("http")]))
        XCTAssertFalse(waits([act("view")]), "a link is not a question")
        XCTAssertFalse(waits([act("copy", url: nil)]))
        XCTAssertFalse(waits([]), "a message without actions never waits")
    }

    func testAnsweredLeavesButAFailedAnswerStays() {
        let ok = AnswerEntry(kind: .tap, label: "Approve", text: nil, at: now, ok: true)
        let failed = AnswerEntry(kind: .tap, label: "Approve", text: nil, at: now, ok: false)
        let replied = AnswerEntry(kind: .reply, label: "Reply", text: "Ship it", at: now, ok: true)
        XCTAssertFalse(waits([act("http")], entry: ok))
        XCTAssertFalse(waits([replyLink], entry: replied))
        XCTAssertTrue(waits([act("http")], entry: failed), "the agent never got it, so it still waits")
    }

    func testDismissedLeaves() {
        XCTAssertFalse(waits([act("http")], entry: AnswerEntry(kind: .dismissed, label: "", text: nil, at: now, ok: true)))
    }

    func testSevenDaysIsTheLimit() {
        XCTAssertTrue(waits([act("http")], age: WaitingRule.maxAge - 1))
        XCTAssertFalse(waits([act("http")], age: WaitingRule.maxAge))
        XCTAssertEqual(WaitingRule.maxAge, 7 * 24 * 3600)
    }

    func testClearedLeaves() {
        XCTAssertFalse(waits([act("http")], cleared: true))
    }

    func testUrgentThenHighThenNewest() {
        let old = now.addingTimeInterval(-3600)
        XCTAssertTrue(WaitingRule.precedes(priority: 5, time: old, 3, now), "urgent leads even when older")
        XCTAssertTrue(WaitingRule.precedes(priority: 4, time: old, 3, now))
        XCTAssertTrue(WaitingRule.precedes(priority: 5, time: old, 4, now))
        XCTAssertTrue(WaitingRule.precedes(priority: 3, time: now, 1, old), "default and low share a rank")
        XCTAssertFalse(WaitingRule.precedes(priority: 3, time: old, 3, now))
    }
}

/// The rule against the real store: what the CLI does to a question takes it out of Waiting.
final class WaitingStoreTests: XCTestCase {
    private var store: Store!
    private var log: AnswerLog!
    private var suite: String!
    private var subscription: Subscription!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        store.saveNotificationRetention(.forever)
        suite = "inbox-tests-\(UUID().uuidString)"
        log = AnswerLog(defaults: UserDefaults(suiteName: suite)!)
        subscription = store.saveSubscription(baseUrl: "https://agents.example", topic: "deploys")
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        store = nil
        log = nil
        super.tearDown()
    }

    private func http() -> Action {
        Action(id: UUID().uuidString, action: "http", label: "Approve", url: "https://agents.example/deploys-answers",
               method: "POST", headers: nil, body: "reply:r1:approve", clear: nil)
    }

    private func message(_ id: String, sequence: String, age: TimeInterval = 600, event: String = "message",
                         text: String? = "Deploy v2?", actions: [Action]? = nil) -> Message {
        Message(id: id, time: Int64(now.addingTimeInterval(-age).timeIntervalSince1970), event: event, topic: "deploys",
                message: text, actions: actions, sequenceID: sequence)
    }

    private func save(_ messages: Message...) {
        _ = store.save(notificationsFromMessages: messages, withSubscription: subscription)
        store.context.processPendingChanges()
    }

    private var waitingIDs: [String] {
        store.waitingNotifications(log: log, now: now).compactMap(\.id)
    }

    func testAQuestionWaitsUntilItsSequenceIsUpdatedWithoutActions() {
        save(message("q1", sequence: "deploy-1", age: 600, actions: [http()]))
        XCTAssertEqual(waitingIDs, ["q1"])
        // What `ntf ask` does once it has its answer from elsewhere: the same sequence, no buttons.
        save(message("q1-done", sequence: "deploy-1", age: 300, text: "Deploy v2? Approved in the terminal."))
        XCTAssertEqual(waitingIDs, [], "a sequence update without actions settles the question")
    }

    func testAClearTakesTheQuestionOut() {
        save(message("q2", sequence: "deploy-2", age: 600, actions: [http()]))
        XCTAssertEqual(waitingIDs, ["q2"])
        save(message("c2", sequence: "deploy-2", age: 300, event: "message_clear", text: nil))
        XCTAssertEqual(waitingIDs, [], "a cleared question is withdrawn")
    }

    func testAnsweredAndDismissedLeaveAndAFailureStays() throws {
        save(message("a", sequence: "s-a", age: 900, actions: [http()]),
             message("b", sequence: "s-b", age: 800, actions: [http()]),
             message("c", sequence: "s-c", age: 700, actions: [http()]))
        XCTAssertEqual(waitingIDs, ["c", "b", "a"], "newest first")
        let rows = store.waitingNotifications(log: log, now: now)
        func key(_ id: String) throws -> AnswerKey { try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(rows.first { $0.id == id }))) }
        log.record(try key("a"), AnswerEntry(kind: .tap, label: "Approve", text: nil, at: now, ok: true))
        log.dismiss(try key("b"), now: now)
        log.record(try key("c"), AnswerEntry(kind: .tap, label: "Approve", text: nil, at: now, ok: false))
        XCTAssertEqual(waitingIDs, ["c"])
    }

    func testOlderThanSevenDaysDoesNotWait() {
        save(message("old", sequence: "s-old", age: WaitingRule.maxAge + 60, actions: [http()]))
        XCTAssertEqual(waitingIDs, [])
    }

    func testTheAnswerKeySurvivesAnUpdateThatKeepsTheQuestion() throws {
        save(message("v1", sequence: "deploy-3", age: 600, actions: [http()]))
        let first = try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(store.waitingNotifications(log: log, now: now).first)))
        save(message("v2", sequence: "deploy-3", age: 300, text: "Deploy v2 (rebuilt)?", actions: [http()]))
        let second = try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(store.waitingNotifications(log: log, now: now).first)))
        XCTAssertEqual(first, second)
        XCTAssertEqual(waitingIDs, ["v2"], "an update that still asks keeps waiting")
    }
}

final class AnswerLogTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let key = AnswerKey(baseUrl: "https://agents.example", topic: "deploys", sequence: "s1")
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suite = "answer-log-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testEntriesPersistAcrossInstances() {
        let log = AnswerLog(defaults: defaults)
        log.record(key, AnswerEntry(kind: .reply, label: "Reply", text: "Ship it", at: at, ok: true))
        XCTAssertEqual(AnswerLog(defaults: defaults).entry(for: key)?.text, "Ship it",
                       "the banner and the app read the same log")
    }

    func testAFailureNeverReplacesASuccess() {
        let log = AnswerLog(defaults: defaults)
        log.record(key, AnswerEntry(kind: .tap, label: "Approve", text: nil, at: at, ok: true))
        log.record(key, AnswerEntry(kind: .tap, label: "Reject", text: nil, at: at, ok: false))
        XCTAssertEqual(log.entry(for: key)?.label, "Approve")
        XCTAssertEqual(log.entry(for: key)?.ok, true)
    }

    func testSendingClearsWhenRecorded() {
        let log = AnswerLog(defaults: defaults)
        log.begin(key, actionId: "a1")
        XCTAssertEqual(log.sendingActionId(key), "a1")
        log.record(key, AnswerEntry(kind: .tap, label: "Approve", text: nil, at: at, ok: false))
        XCTAssertNil(log.sendingActionId(key))
    }

    func testPruneDropsOnlyOlderEntries() {
        let log = AnswerLog(defaults: defaults)
        let other = AnswerKey(baseUrl: "https://agents.example/", topic: "deploys", sequence: "s2")
        log.record(key, AnswerEntry(kind: .tap, label: "Old", text: nil, at: at.addingTimeInterval(-100), ok: true))
        log.record(other, AnswerEntry(kind: .tap, label: "New", text: nil, at: at, ok: true))
        log.prune(before: at.addingTimeInterval(-50))
        XCTAssertNil(log.entry(for: key))
        XCTAssertEqual(AnswerLog(defaults: defaults).entry(for: other)?.label, "New")
    }

    func testKeyIgnoresATrailingSlashOnTheServer() {
        XCTAssertEqual(AnswerKey(baseUrl: "https://a.example/", topic: "t", sequence: "s").id,
                       AnswerKey(baseUrl: "https://a.example", topic: "t", sequence: "s").id)
    }
}

final class WaitedTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let en = Locale(identifier: "en_US")

    private func text(_ seconds: TimeInterval) -> String {
        WaitedTime.text(since: now.addingTimeInterval(-seconds), now: now, locale: en)
    }

    func testMinutesThenHoursThenDays() {
        XCTAssertEqual(text(5), "1 min", "under a minute still reads as a minute")
        XCTAssertEqual(text(12 * 60), "12 min")
        XCTAssertEqual(text(59 * 60), "59 min")
        XCTAssertEqual(text(2 * 3600 + 20 * 60), "2 hr")
        XCTAssertEqual(text(3 * 86_400 + 3600), "3 days")
    }

    func testOtherLanguagesGetTheirOwnUnits() {
        let de = WaitedTime.text(since: now.addingTimeInterval(-12 * 60), now: now, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(de.contains("12"))
        XCTAssertNotEqual(WaitedTime.text(since: now.addingTimeInterval(-3 * 86_400), now: now, locale: Locale(identifier: "fr_FR")), "3 days")
    }
}

final class MessageDisplayTests: XCTestCase {
    func testTitleWinsAndAShortBodyBecomesTheHeadline() {
        XCTAssertEqual(MessageDisplay.of(title: "Build", body: "passed", contentType: nil),
                       MessageDisplay(title: "Build", body: "passed", markdown: false))
        XCTAssertEqual(MessageDisplay.of(title: nil, body: "Build passed", contentType: nil),
                       MessageDisplay(title: "Build passed", body: "", markdown: false))
    }

    func testFirstLineLeadsAndAMarkdownHeadingLosesItsHashes() {
        let display = MessageDisplay.of(title: nil, body: "## What I found\nThree flaky tests.", contentType: "text/markdown")
        XCTAssertEqual(display.title, "What I found")
        XCTAssertEqual(display.body, "Three flaky tests.")
    }

    func testALongSingleLineStaysBody() {
        let long = String(repeating: "word ", count: 40)
        XCTAssertNil(MessageDisplay.of(title: nil, body: long, contentType: nil).title)
    }
}

final class AgentInstructionsTests: XCTestCase {
    func testEveryLineTheAgentNeeds() {
        let text = AgentInstructions.text(baseUrl: "https://ntfy.sh", topic: "my-agent")
        XCTAssertTrue(text.contains("Topic URL: https://ntfy.sh/my-agent"))
        XCTAssertTrue(text.contains("-H 'Tags: agent'"))
        XCTAssertTrue(text.contains("POST JSON to https://ntfy.sh with \"topic\": \"my-agent\""))
        XCTAssertTrue(text.contains("to https://ntfy.sh/my-agent-answers"))
        XCTAssertTrue(text.contains("https://ntfy.sh/my-agent-answers/json?poll=1&since=all"))
        XCTAssertTrue(text.hasSuffix(AgentInstructions.guideUrl))
        XCTAssertEqual(AgentInstructions.guideUrl, "https://ntf-ai.app/docs/agents")
        XCTAssertFalse(text.contains("login"), "no login line without saved credentials")
    }
}
