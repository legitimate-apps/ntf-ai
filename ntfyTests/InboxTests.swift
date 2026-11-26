// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import XCTest
import CoreData
import UserNotifications
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

    private func waits(_ actions: [Action], age: TimeInterval = 60, entry: AnswerEntry? = nil, tags: [String] = ["agent"]) -> Bool {
        WaitingRule.isWaiting(actions: actions, time: now.addingTimeInterval(-age), entry: entry, tags: tags, now: now)
    }

    /// Only an agent's question waits: a plain ntfy message with a button ("Toggle light" from Home
    /// Assistant) is not a question, so it stays under Activity and doesn't badge the Inbox tab.
    func testOnlyAnAgentsQuestionWaits() {
        XCTAssertFalse(waits([act("http")], tags: []), "a plain http button is not an agent's question")
        XCTAssertFalse(waits([replyLink], tags: ["house"]), "nor is a plain reply link")
        XCTAssertTrue(waits([act("http")], tags: ["agent"]))
        XCTAssertTrue(waits([act("http")], tags: ["Agent"]), "the agent tag in any case")
        let typed = Action(id: "ask", action: "view", label: "Answer",
                           url: "https://ntf-ai.app/docs/agents#ask-v2=" + TopicEncryption.base64urlEncode(Data(#"{"v":2,"kind":"text"}"#.utf8)),
                           method: nil, headers: nil, body: nil, clear: nil)
        XCTAssertNotEqual(AskSchema.detect(in: [typed]), .none, "fixture: a typed question")
        XCTAssertTrue(waits([typed], tags: []), "a typed question waits without the agent tag")
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


    func testNewestFirstWhateverThePriority() {
        let old = now.addingTimeInterval(-6 * 86_400)
        XCTAssertTrue(WaitingRule.precedes(time: now, id: "b", old, "a"), "a newer ask leads an older one")
        XCTAssertFalse(WaitingRule.precedes(time: old, id: "a", now, "b"), "an old urgent ask no longer jumps ahead")
        XCTAssertTrue(WaitingRule.precedes(time: now, id: "b", now, "a"), "same second: the id breaks the tie")
        XCTAssertFalse(WaitingRule.precedes(time: now, id: "a", now, "a"))
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
                         text: String? = "Deploy v2?", actions: [Action]? = nil, tags: [String]? = ["agent"]) -> Message {
        var message = Message(id: id, time: Int64(now.addingTimeInterval(-age).timeIntervalSince1970), event: event, topic: "deploys",
                              message: text, actions: actions, sequenceID: sequence)
        message.tags = tags
        return message
    }

    private func save(_ messages: Message...) {
        _ = store.save(notificationsFromMessages: messages, withSubscription: subscription)
        store.context.processPendingChanges()
    }

    private var waitingIDs: [String] {
        store.waitingNotifications(log: log, now: now).compactMap(\.id)
    }

    /// A Home Assistant style alert with a button is not waiting on you; an agent's question beside it is.
    func testAPlainButtonMessageIsNotWaiting() {
        let toggle = Action(id: "toggle", action: "http", label: "Toggle light", url: "https://ha.example/api/light",
                            method: "POST", headers: nil, body: nil, clear: nil)
        save(message("ha-1", sequence: "ha-1", age: 30, text: "Motion in the hallway", actions: [toggle], tags: nil),
             message("q-1", sequence: "q-1", age: 60, actions: [http()]))
        XCTAssertEqual(waitingIDs, ["q-1"], "only the agent's question waits")
    }

    /// The queue reads newest to oldest. Ranked by priority, a six-day-old urgent prompt sat above
    /// a six-hour-old high one and the list looked shuffled (operator's screenshot, 2026-11-21).
    func testWaitingIsNewestFirstWhateverThePriority() {
        var urgentOld = message("urgent-old", sequence: "urgent-old", age: 6 * 86_400, actions: [http()])
        urgentOld.priority = 5
        var highNew = message("high-new", sequence: "high-new", age: 6 * 3600, actions: [http()])
        highNew.priority = 4
        var lowNewest = message("low-newest", sequence: "low-newest", age: 60, actions: [http()])
        lowNewest.priority = 2
        save(urgentOld, highNew, lowNewest)
        XCTAssertEqual(waitingIDs, ["low-newest", "high-new", "urgent-old"])
    }

    /// `re-<sequence>` marks the person's own written answer: never a question, even with buttons.
    func testAReplyTaggedMessageIsNeverWaiting() {
        var reply = message("r-1", sequence: "r-1", age: 60, text: "Use main", actions: [http()])
        reply.tags = ["re-deploy-1"]
        save(reply)
        XCTAssertEqual(waitingIDs, [], "a re- message is the person's reply, not a question")
        var question = message("q-9", sequence: "q-9", age: 60, actions: [http()])
        question.tags = ["agent", "no-reply"]
        save(question)
        XCTAssertEqual(waitingIDs, ["q-9"], "no-reply still waits on its buttons")
    }

    /// The reply names the question by its sequence_id, or by its message id when it has none.
    func testTheReplyTagNamesTheQuestionsSequence() throws {
        save(message("q-a", sequence: "deploy-7", age: 60, actions: [http()]))
        var plain = message("q-b", sequence: "", age: 30, actions: [http()])
        plain.sequenceID = nil
        save(plain)
        let rows = store.waitingNotifications(log: log, now: now)
        let a = try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(rows.first { $0.id == "q-a" })))
        let b = try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(rows.first { $0.id == "q-b" })))
        XCTAssertEqual(AgentReply.replyTags(for: a), "re-deploy-7")
        XCTAssertEqual(AgentReply.replyTags(for: b), "re-q-b")
    }

    func testAQuestionWaitsUntilItsSequenceIsUpdatedWithoutActions() {
        save(message("q1", sequence: "deploy-1", age: 600, actions: [http()]))
        XCTAssertEqual(waitingIDs, ["q1"])
        // What `ntf ask` does once it has its answer from elsewhere: the same sequence, no buttons.
        save(message("q1-done", sequence: "deploy-1", age: 300, text: "Deploy v2? Approved in the terminal."))
        XCTAssertEqual(waitingIDs, [], "a sequence update without actions settles the question")
    }

    /// In ntfy a clear means "read and dismissed", and this app sends one when the person opens the
    /// question (here or on another device). Reading a question is not answering it.
    func testAClearKeepsTheQuestionWaiting() {
        save(message("q2", sequence: "deploy-2", age: 600, actions: [http()]))
        XCTAssertEqual(waitingIDs, ["q2"])
        save(message("c2", sequence: "deploy-2", age: 300, event: "message_clear", text: nil))
        XCTAssertEqual(waitingIDs, ["q2"], "a read question still waits for its answer")
    }

    func testReadingTheQuestionHereThenItsClearEchoKeepsItWaiting() throws {
        save(message("q4", sequence: "deploy-4", age: 600, actions: [http()]))
        let row = try XCTUnwrap(store.waitingNotifications(log: log, now: now).first)
        store.setRead(true, forNotification: row)
        store.context.processPendingChanges()
        save(message("c4", sequence: "deploy-4", age: 1, event: "message_clear", text: nil))
        XCTAssertEqual(waitingIDs, ["q4"], "the server's echo of our own mark-read is not a withdrawal")
    }

    func testADeleteTakesTheQuestionOut() {
        save(message("q5", sequence: "deploy-5", age: 600, actions: [http()]))
        save(message("d5", sequence: "deploy-5", age: 300, event: "message_delete", text: nil))
        XCTAssertEqual(waitingIDs, [], "a deleted question is withdrawn")
    }

    /// An answer belongs to the version it was made on: a new question under the same sequence waits again.
    func testANewQuestionReusingAnAnsweredSequenceWaitsAgain() throws {
        save(message("r1", sequence: "approval", age: 900, actions: [http()]))
        let first = try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(store.waitingNotifications(log: log, now: now).first)))
        log.record(first, AnswerEntry(kind: .tap, label: "Approve", text: nil, at: now, ok: true))
        XCTAssertEqual(waitingIDs, [])
        save(message("r2", sequence: "approval", age: 60, text: "Deploy v3?", actions: [http()]))
        XCTAssertEqual(waitingIDs, ["r2"], "the new question waits")
        let row = try XCTUnwrap(store.waitingNotifications(log: log, now: now).first)
        XCTAssertFalse(AnswerState(notification: row, log: log).answered, "its buttons show, not the old receipt")
    }

    func testANewQuestionReusingADismissedSequenceWaitsAgain() throws {
        save(message("n1", sequence: "nightly", age: 900, actions: [http()]))
        log.dismiss(try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(store.waitingNotifications(log: log, now: now).first))), now: now)
        XCTAssertEqual(waitingIDs, [])
        save(message("n2", sequence: "nightly", age: 60, actions: [http()]))
        XCTAssertEqual(waitingIDs, ["n2"])
    }

    func testAnAnswerLoggedBeforeVersionsStillCounts() throws {
        save(message("l1", sequence: "legacy", age: 600, actions: [http()]))
        let key = try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(store.waitingNotifications(log: log, now: now).first)))
        log.record(AnswerKey(baseUrl: key.baseUrl, topic: key.topic, sequence: key.sequence),
                   AnswerEntry(kind: .tap, label: "Approve", text: nil, at: now, ok: true))
        XCTAssertEqual(waitingIDs, [], "an entry without a message id applies to any version")
    }

    func testABusyBotDoesNotPushQuestionsOutOfWaiting() throws {
        let bot = (0..<520).map { message("b\($0)", sequence: "b\($0)", age: 60 + Double($0), actions: [http()]) }
        _ = store.save(notificationsFromMessages: bot, withSubscription: subscription)
        save(message("old-q", sequence: "old-q", age: 3600, actions: [http()]))
        for row in store.waitingNotifications(log: log, now: now) where row.id != "old-q" {
            log.dismiss(try XCTUnwrap(AnswerKey(notification: row)), now: now)
        }
        XCTAssertEqual(waitingIDs, ["old-q"], "the older question is still listed after 520 newer ones")
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

    /// "Clear all" (operator, 2026-11-19, 55 stale broker prompts): every listed question leaves
    /// Waiting and the tab badge, and stays gone after a relaunch; the messages stay in their topic
    /// with live buttons; a question that arrives afterwards waits as normal; Undo puts them back.
    func testClearAllEmptiesWaitingSurvivesRelaunchAndKeepsTheMessages() throws {
        let live = Date()
        func question(_ id: String, age: TimeInterval) -> Message {
            var m = Message(id: id, time: Int64(live.addingTimeInterval(-age).timeIntervalSince1970), event: "message",
                            topic: "deploys", message: "Approve \(id)?", actions: [http()], sequenceID: id)
            m.tags = ["agent"]
            return m
        }
        save(question("q1", age: 900), question("q2", age: 600), question("q3", age: 300))
        let waiting = WaitingObservable(store: store, log: log)
        XCTAssertEqual(waiting.notifications.compactMap(\.id), ["q3", "q2", "q1"])

        waiting.clearAll()
        XCTAssertEqual(waiting.notifications.count, 0, "Waiting and the tab badge (its count) are empty")
        XCTAssertEqual(waiting.lastClear?.count, 3, "Undo is offered for the three")
        XCTAssertEqual(subscription.notificationCount(), 3, "no message is deleted")
        for row in try XCTUnwrap(subscription.notifications?.allObjects as? [ntfy.Notification]) {
            XCTAssertFalse(AnswerState(notification: row, log: log).answered, "\(row.id ?? "") keeps its buttons in the topic and Activity")
        }

        let relaunched = AnswerLog(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(store.waitingNotifications(log: relaunched, now: live).count, 0, "cleared after a relaunch")

        save(question("q4", age: 10))
        waiting.refresh()
        XCTAssertEqual(waiting.notifications.compactMap(\.id), ["q4"], "a question after the clear waits")

        waiting.undoClear()
        XCTAssertNil(waiting.lastClear)
        XCTAssertEqual(waiting.notifications.compactMap(\.id), ["q4", "q3", "q2", "q1"], "Undo puts the cleared ones back")
        XCTAssertEqual(store.waitingNotifications(log: AnswerLog(defaults: UserDefaults(suiteName: suite)!), now: live).count, 4,
                       "and the undo is saved too")
    }

    /// Undo never takes back an answer made after the clear.
    func testUndoClearKeepsAnAnswerMadeSince() throws {
        save(message("u1", sequence: "u1", age: 600, actions: [http()]), message("u2", sequence: "u2", age: 300, actions: [http()]))
        let keys = try store.waitingNotifications(log: log, now: now).map { try XCTUnwrap(AnswerKey(notification: $0)) }
        let cleared = log.dismissAll(keys, now: now)
        XCTAssertEqual(waitingIDs, [])
        let u1 = try XCTUnwrap(keys.first { $0.sequence == "u1" })
        log.record(u1, AnswerEntry(kind: .tap, label: "Approve", text: nil, at: now.addingTimeInterval(5), ok: true))
        log.restore(cleared)
        XCTAssertEqual(waitingIDs, ["u2"], "u1 stays answered; u2 waits again")
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
        XCTAssertEqual(first.id, second.id)
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

/// The title line shows each emoji tag once: the title it draws already carries them.
final class MessageTitleLineTests: XCTestCase {
    private func line(title: String?, message: String, tags: String?) throws -> String {
        let n = ntfy.Notification(context: Store.shared.context)
        // Unsaved and incomplete: left in the shared context, it fails the next test's save.
        defer { Store.shared.context.delete(n) }
        n.title = title
        n.message = message
        n.tags = tags
        return String(try XCTUnwrap(MessageTitleLine.text(for: n)).characters)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testATitledMessageShowsItsEmojiOnce() throws {
        let text = try line(title: "Task finished", message: "All green", tags: "white_check_mark")
        XCTAssertEqual(count("\u{2705}", in: text), 1, text)
        XCTAssertEqual(text, "\u{2705} Task finished")
    }

    func testAShortBodyWithoutATitleShowsItsEmojiOnce() throws {
        let text = try line(title: nil, message: "Task finished", tags: "white_check_mark,ci")
        XCTAssertEqual(count("\u{2705}", in: text), 1, text)
        XCTAssertEqual(text, "\u{2705} Task finished")
    }

    func testNoEmojiTagsAddNothing() throws {
        XCTAssertEqual(try line(title: "Nightly backup", message: "Done", tags: "backup,ci"), "Nightly backup")
        XCTAssertEqual(try line(title: nil, message: "Done", tags: nil), "Done")
    }

    func testAnOldSettleShowsItsEmojiOnceInFrontOfTheQuestion() throws {
        // ntf 0.1/0.2 re-sent the question without a title and appended the outcome line.
        let text = try line(title: nil, message: "Front door is unlocked\n\n\u{2713} Agent got: Lock",
                            tags: "agent,white_check_mark")
        XCTAssertEqual(count("\u{2705}", in: text), 1, text)
        XCTAssertEqual(text, "\u{2705} Front door is unlocked")
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
        XCTAssertTrue(text.contains("over plain HTTPS"))
        XCTAssertTrue(text.contains("update it without actions or delete it"), "a clear is a read, not a withdrawal")
        XCTAssertFalse(text.contains("clear it"))
    }

    /// Every line must be true, also for a self-hosted server on plain HTTP.
    func testTheSchemeFollowsTheServer() {
        let text = AgentInstructions.text(baseUrl: "http://192.168.1.20:8080", topic: "lab")
        XCTAssertTrue(text.contains("over plain HTTP:"))
        XCTAssertFalse(text.contains("HTTPS"))
    }
}

/// Which agent questions get the written-reply field (build 46): `ntf ask` and the agent guide take
/// a message on the topic without the `agent` tag as the person's written answer.
final class AgentReplyTests: XCTestCase {
    private func action(_ type: String, url: String = "https://agents.example/t-answers") -> Action {
        Action(id: UUID().uuidString, action: type, label: "Approve", url: url, method: "POST", headers: nil, body: nil, clear: nil)
    }
    private var viewReply: Action {
        Action(id: UUID().uuidString, action: "view", label: "Reply",
               url: "https://ntfy-me.com/docs/agents#reply-v1=https%3A%2F%2Fntfy-me.com%2Freply-secret",
               method: nil, headers: nil, body: nil, clear: nil)
    }

    func testAnAgentQuestionWithButtonsGetsTheField() {
        XCTAssertTrue(AgentReply.offersField(tags: ["agent"], actions: [action("http"), action("http")]))
        XCTAssertTrue(AgentReply.offersField(tags: ["warning", "agent"], actions: [action("http")]))
    }

    func testAMessageWithoutTheAgentTagDoesNot() {
        XCTAssertFalse(AgentReply.offersField(tags: [], actions: [action("http")]))
        XCTAssertFalse(AgentReply.offersField(tags: ["agents"], actions: [action("http")]))
    }

    func testAnAgentNoticeWithoutAnswersDoesNot() {
        XCTAssertFalse(AgentReply.offersField(tags: ["agent"], actions: []))
        XCTAssertFalse(AgentReply.offersField(tags: ["agent"], actions: [action("view", url: "https://example.com")]))
        XCTAssertFalse(AgentReply.offersField(tags: ["agent"], actions: [action("copy")]))
    }

    func testANoReplyQuestionGetsNoField() {
        XCTAssertFalse(AgentReply.offersField(tags: ["agent", "no-reply"], actions: [action("http")]))
        XCTAssertFalse(AgentReply.offersField(tags: ["No-Reply", "agent"], actions: [action("http")]))
    }

    func testTheReplyTagIsExactlyOneTag() {
        let key = AnswerKey(baseUrl: "https://agents.example", topic: "deploys", sequence: "abc123XYZ")
        XCTAssertEqual(AgentReply.replyTags(for: key), "re-abc123XYZ")
        XCTAssertEqual(parseAllTags(AgentReply.replyTags(for: key)), ["re-abc123XYZ"], "one tag, never agent")
    }

    /// Protocol tags steer behaviour and never show, as chips or as emoji; `agent` still shows.
    func testProtocolTagsAreNeverShown() {
        XCTAssertEqual(parseNonEmojiTags("agent,re-abc123,no-reply,deploy,RE-X1,No-Reply"), ["agent", "deploy"])
        XCTAssertEqual(parseEmojiTags("re-abc123,thumbsup,no-reply"), ["👍"])
        XCTAssertEqual(parseNonEmojiTags("re-,reply,review"), ["re-", "reply", "review"], "only re-<something> is a reply tag")
    }

    func testTheViewActionReplyKeepsItsOwnField() {
        XCTAssertNotNil(BannerReply.destination(for: viewReply), "fixture is a real view-action reply")
        XCTAssertFalse(AgentReply.offersField(tags: ["agent"], actions: [action("http"), viewReply]),
                       "the reply action posts to its own target, so the page uses that instead")
    }
}

/// Agent confirmations (ACK-SPEC, build 48): an ack on the question's sequence resolves it without
/// replacing it, never alerts, and hides behind "Show agent confirmations" without losing its effect.
final class AgentAckTests: XCTestCase {
    private var store: Store!
    private var log: AnswerLog!
    private var acks: AckLog!
    private var suites: [String] = []
    private var subscription: Subscription!
    private var removals: [SequenceRemoval] = []
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        let name = "ack-tests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func setUp() {
        super.setUp()
        store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        store.saveNotificationRetention(.forever)
        log = AnswerLog(defaults: defaults())
        acks = AckLog(defaults: defaults())
        store.ackLog = acks
        removals = []
        store.notificationRemover = { [weak self] in self?.removals.append($0) }
        subscription = store.saveSubscription(baseUrl: "https://agents.example", topic: "home")
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        store = nil
        super.tearDown()
    }

    private func http() -> Action {
        Action(id: UUID().uuidString, action: "http", label: "Lock", url: "https://agents.example/ok",
               method: "POST", headers: nil, body: "lock", clear: nil)
    }

    private func question(age: TimeInterval = 600) -> Message {
        Message(id: "q-1", time: Int64(now.addingTimeInterval(-age).timeIntervalSince1970), event: "message", topic: "home",
                message: "Front door is unlocked", title: "Front door", priority: 4, tags: ["agent"], actions: [http()],
                sequenceID: "door")
    }

    private func ack(_ id: String, _ body: String, age: TimeInterval, priority: Int16 = 5) -> Message {
        Message(id: id, time: Int64(now.addingTimeInterval(-age).timeIntervalSince1970), event: "message", topic: "home",
                message: body, priority: priority, tags: ["agent", "ack"], sequenceID: "door")
    }

    @discardableResult
    private func save(_ messages: Message...) -> [Message] {
        let presented = store.save(notificationsFromMessages: messages, withSubscription: subscription)
        store.context.processPendingChanges()
        return presented
    }

    private var rows: [ntfy.Notification] {
        let request = ntfy.Notification.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: true)]
        return (try? store.context.fetch(request)) ?? []
    }

    private func receipt(shows: Bool = true) throws -> AgentReceipt {
        AgentReceipt(notification: try XCTUnwrap(rows.first), log: log, acks: acks, shows: shows)
    }

    // MARK: parsing

    func testADefaultBodyIsNeverANote() {
        for body in ["\u{2713} Got it", "Got it", "\u{2713} Got your reply", "\u{2713} Got: Lock", "\u{2713}", "", "  ", nil, "got it."] {
            XCTAssertNil(AgentAck.note(fromBody: body), "\(String(describing: body)) is a default, not a note")
        }
        XCTAssertEqual(AgentAck.note(fromBody: " Restarting now \n"), "Restarting now")
        XCTAssertEqual(AgentAck.note(fromBody: "Got it, restarting the router"), "Got it, restarting the router")
        XCTAssertEqual(AgentAck.answer(fromBody: "\u{2713} Got: Lock"), "Lock")
        XCTAssertNil(AgentAck.answer(fromBody: "\u{2713} Got it"))
        XCTAssertEqual(AgentAck.defaultBody, "\u{2713} Got it", "the default ntf sends")
        XCTAssertTrue(AgentAck.isDefaultBody(AgentAck.defaultBody))
    }

    func testTheOldFullSettleReadsAsResolved() {
        let agent = ["agent"]
        XCTAssertEqual(AgentAck.settle(body: "Front door is unlocked\n\n\u{2713} Agent got: Lock", tags: agent, hasActions: false),
                       AgentAck.Settle(question: "Front door is unlocked", outcome: .got("Lock")))
        XCTAssertEqual(AgentAck.settle(body: "Which branch?\n\n\u{2713} Agent got your reply", tags: agent, hasActions: false),
                       AgentAck.Settle(question: "Which branch?", outcome: .got(nil)))
        XCTAssertEqual(AgentAck.settle(body: "Deploy?\n\nNo answer in 10 min; the agent moved on", tags: agent, hasActions: false),
                       AgentAck.Settle(question: "Deploy?", outcome: .movedOn))
        XCTAssertEqual(AgentAck.settle(body: "Deploy?\n\nThe agent stopped waiting; no answer needed", tags: agent, hasActions: false),
                       AgentAck.Settle(question: "Deploy?", outcome: .movedOn))
        XCTAssertNil(AgentAck.settle(body: "Deploy?\n\n\u{2713} Agent got: Lock", tags: agent, hasActions: true), "still has buttons")
        XCTAssertNil(AgentAck.settle(body: "Deploy?\n\n\u{2713} Agent got: Lock", tags: [], hasActions: false), "not from an agent")
        XCTAssertNil(AgentAck.settle(body: "Build finished\n\nAll green", tags: agent, hasActions: false), "an ordinary message")
    }

    // MARK: resolution

    func testAnAckResolvesTheQuestionWithoutReplacingIt() throws {
        save(question())
        XCTAssertEqual(store.waitingNotifications(log: log, now: now).compactMap(\.id), ["q-1"])
        let presented = save(ack("a-1", "Locking it now", age: 60))
        XCTAssertEqual(presented.map(\.id), [], "an ack is never presented")
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"], "the question keeps its row")
        XCTAssertEqual(rows.first?.message, "Front door is unlocked")
        XCTAssertEqual(rows.first?.actionsList().count, 1, "the question keeps its buttons")
        XCTAssertEqual(store.waitingNotifications(log: log, now: now).compactMap(\.id), [], "out of Waiting on you")
        let record = try XCTUnwrap(acks.record(forKey: AckLog.key(baseUrl: "https://agents.example", topic: "home", sequence: "door"), version: "q-1"))
        XCTAssertEqual(record.note, "Locking it now")
        XCTAssertEqual(record.id, "a-1")
        XCTAssertTrue(removals.contains { $0.sequence == "door" && $0.keepingID == "a-1" }, "the question's banner goes")
    }

    func testTheNewestAckWins() throws {
        save(question())
        save(ack("a-1", "Restarting now", age: 120))
        save(ack("a-2", "Restarted, all good", age: 60))
        XCTAssertEqual(try receipt().agent, .got(now.addingTimeInterval(-60), note: "Restarted, all good"))
        save(ack("a-0", "An older note", age: 90))
        XCTAssertEqual(try receipt().agent, .got(now.addingTimeInterval(-60), note: "Restarted, all good"), "an older ack loses")
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"])
    }

    func testAnAckBeforeAnyAnswerHereStillShows() throws {
        save(question())
        save(ack("a-1", "\u{2713} Got: Lock", age: 60))
        let receipt = try receipt()
        XCTAssertNil(receipt.answer, "nothing answered on this device")
        XCTAssertEqual(receipt.agent, .got(now.addingTimeInterval(-60), note: nil), "a default body is no note")
        XCTAssertEqual(receipt.answerText, "Lock", "the ack names the answer given elsewhere")
        XCTAssertTrue(receipt.resolved)
    }

    func testANewQuestionOnTheSequenceWaitsAgain() {
        save(question(age: 600))
        save(ack("a-1", "ok then", age: 300))
        var next = question(age: 60)
        next.id = "q-2"
        save(next)
        XCTAssertEqual(store.waitingNotifications(log: log, now: now).compactMap(\.id), ["q-2"], "the ack was for the old version")
    }

    func testAnOrphanAckIsKeptQuietly() {
        let presented = save(ack("a-9", "Done", age: 60))
        XCTAssertEqual(presented.map(\.id), [], "no question here: stored, never presented")
        XCTAssertEqual(rows.first?.read, true)
    }

    func testAPushedAckIsAcknowledgedNotStored() throws {
        save(question())
        let result = store.ingest(pushedMessage: ack("a-1", "Locking it now", age: 60), baseUrl: "https://agents.example", topic: "home")
        guard case .acknowledged(let message, let title) = result else { return XCTFail("got \(String(describing: result))") }
        XCTAssertEqual(message.id, "a-1")
        XCTAssertEqual(title, "Front door")
    }

    func testTheOldSettleRowShowsTheQuestionAndAReceipt() throws {
        save(question(age: 600))
        let entry = AnswerEntry(kind: .tap, label: "Lock", text: nil, at: now.addingTimeInterval(-300), ok: true, messageId: "q-1")
        log.record(try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(rows.first))), entry)
        var settle = question(age: 200)
        settle.id = "s-1"
        settle.actions = nil
        settle.priority = 1
        settle.message = "Front door is unlocked\n\n\u{2713} Agent got: Lock"
        save(settle)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.display.body, "Front door is unlocked", "the appended line leaves the body")
        XCTAssertEqual(row.display.title, "Front door")
        let receipt = try receipt()
        XCTAssertEqual(receipt.agent, .got(now.addingTimeInterval(-200), note: nil))
        XCTAssertEqual(receipt.answer?.label, "Lock", "the answer logged on the question's version")
        var timeout = question(age: 100)
        timeout.id = "s-2"
        timeout.actions = nil
        timeout.message = "Front door is unlocked\n\nNo answer in 10 min; the agent moved on"
        save(timeout)
        XCTAssertEqual(try self.receipt().agent, .movedOn(now.addingTimeInterval(-100)))
    }

    // MARK: silence

    func testAnAckNeverAlertsAtAnyPriority() {
        for priority: Int16 in 1...5 {
            let content = UNMutableNotificationContent()
            content.configureInterruption(message: ack("a-\(priority)", "note", age: 1, priority: priority), soundName: "custom.wav",
                                          criticalEnabled: true, criticalAuthorized: true)
            XCTAssertNil(content.sound, "priority \(priority)")
            XCTAssertEqual(content.interruptionLevel, .passive, "priority \(priority)")
            XCTAssertEqual(content.relevanceScore, 0, "priority \(priority)")
        }
        let content = UNMutableNotificationContent()
        content.configureInterruption(message: question(), soundName: nil, criticalEnabled: false, criticalAuthorized: false)
        XCTAssertNotNil(content.sound, "a question still alerts")
    }

    func testInTheForegroundAnAckIsNeverABanner() {
        XCTAssertEqual(AgentAck.foregroundPresentation(shows: true), [.list])
        XCTAssertEqual(AgentAck.foregroundPresentation(shows: false), [])
        var info = ack("a-1", "x", age: 1).toUserInfo()
        XCTAssertTrue(AgentAck.isReceipt(info))
        info["tags"] = "agent"
        XCTAssertFalse(AgentAck.isReceipt(info))
    }

    // MARK: the setting

    func testWithConfirmationsOffTheAckStillResolvesButShowsNothing() throws {
        save(question())
        save(ack("a-1", "Locking it now", age: 60))
        let hidden = try receipt(shows: false)
        XCTAssertNil(hidden.agent, "no receipt line or note")
        XCTAssertTrue(hidden.resolved, "the question is still done")
        XCTAssertEqual(store.waitingNotifications(log: log, now: now).compactMap(\.id), [])
        XCTAssertNotNil(try receipt(shows: true).agent)
    }

    // VERDICT-ack-48 M1: green means the agent got it; your chosen answer wears a plain check in
    // its own Forest, never the agent's filled green one.
    func testYourAnswerNeverWearsTheAgentsCheck() {
        XCTAssertEqual(AnsweredView.choiceIcon, "checkmark")
        XCTAssertEqual(AnsweredView.agentIcon, "checkmark.circle.fill")
        XCTAssertNotEqual(AnsweredView.choiceIcon, AnsweredView.agentIcon)
    }

    // 2026-11-18: answered here, the chosen answer and "Sent"; then the agent's word with its note.
    func testTheAnsweredStateSaysEachThingOnce() throws {
        save(question())
        let row = try XCTUnwrap(rows.first)
        let key = try XCTUnwrap(AnswerKey(notification: row))
        let answeredAt = now.addingTimeInterval(-120)
        log.record(key, AnswerEntry(kind: .tap, label: "Lock", text: nil, at: answeredAt, ok: true))
        XCTAssertEqual(AnswerSummary(receipt: try receipt()), AnswerSummary(choice: .picked("Lock"), statuses: [.sent(answeredAt)]))
        save(ack("a-1", "Locking it now", age: 60))
        let summary = AnswerSummary(receipt: try receipt())
        XCTAssertEqual(summary.choice, .picked("Lock"))
        XCTAssertEqual(summary.statuses.count, 2)
        XCTAssertEqual(summary.statuses.first, .sent(answeredAt))
        guard case .agentGot(_, let note) = summary.statuses.last else { return XCTFail("the agent's word comes last") }
        XCTAssertEqual(note, "Locking it now")
    }

    // A written reply keeps its words: "Reply sent", with the text as the answer.
    func testAWrittenReplyKeepsItsText() throws {
        save(question())
        let key = try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(rows.first)))
        let at = now.addingTimeInterval(-30)
        log.record(key, AnswerEntry(kind: .reply, label: "", text: "After lunch", at: at, ok: true))
        XCTAssertEqual(AnswerSummary(receipt: try receipt()), AnswerSummary(choice: .replied("After lunch"), statuses: [.replySent(at)]))
    }

    // iPad check 48: an ack the extension records must redraw an open page in the app. Two logs
    // on one store stand in for the two processes.
    func testAnAckSavedElsewhereRedrawsTheApp() {
        let shared = defaults()
        let app = AckLog(defaults: shared, observesOtherProcesses: true)
        let extensionLog = AckLog(defaults: shared)
        let before = app.revision
        extensionLog.save(AgentAck.Record(id: "a-1", time: 1, note: nil, answer: nil, version: "q-1"), forKey: "k")
        // Only the cross-process post can reach the app's log; the extension's own redraw is its own.
        let redrawn = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.revision > before }, object: nil)
        wait(for: [redrawn], timeout: 3)
        XCTAssertGreaterThan(app.revision, before)
    }

    // 48b re-check: a long agent note was cut at 4 lines with no other place to read it.
    func testTheAgentsNoteIsNeverCutButYourReplyIs() {
        XCTAssertNil(AnsweredView.noteLineLimit(.page))
        XCTAssertNotNil(AnsweredView.noteLineLimit(.card))
        XCTAssertGreaterThanOrEqual(AnsweredView.replyLineLimit(.page), 4)
    }

    // M2: answered on another device or by a compose reply, the page still names the answer.
    func testAnAckNamingTheAnswerGivesThePageAFirstStep() throws {
        save(question())
        save(ack("a-1", "\u{2713} Got: Lock", age: 60))
        XCTAssertEqual(try receipt().namedStep, "Lock")
        let entry = AnswerEntry(kind: .tap, label: "Lock", text: nil, at: now.addingTimeInterval(-90), ok: true)
        log.record(try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(rows.first))), entry)
        XCTAssertNil(try receipt().namedStep, "the answer here is the first step")
    }

    // M3: with confirmations off, a question done elsewhere says Closed, never nothing.
    func testWithConfirmationsOffAQuestionDoneElsewhereSaysClosed() throws {
        save(question())
        XCTAssertFalse(try receipt(shows: false).showsClosed, "an open question isn't closed")
        save(ack("a-1", "\u{2713} Got: Lock", age: 60))
        let off = try receipt(shows: false)
        XCTAssertTrue(off.showsClosed)
        XCTAssertEqual(off.namedAnswer, "Lock", "Closed names the answer")
        XCTAssertFalse(try receipt(shows: true).showsClosed, "with confirmations on, the timeline says it")
        let entry = AnswerEntry(kind: .tap, label: "Lock", text: nil, at: now.addingTimeInterval(-90), ok: true)
        log.record(try XCTUnwrap(AnswerKey(notification: try XCTUnwrap(rows.first))), entry)
        XCTAssertFalse(try receipt(shows: false).showsClosed, "answered here: your own receipt shows instead")
    }

    func testConfirmationsShowByDefault() {
        let defaults = defaults()
        XCTAssertTrue(AgentAck.showsConfirmations(defaults))
        defaults.set(false, forKey: AgentAck.showKey)
        XCTAssertFalse(AgentAck.showsConfirmations(defaults))
    }

    // MARK: hiding

    func testTheAckTagIsNeverShown() {
        XCTAssertEqual(parseNonEmojiTags("agent,ack,deploy,ACK"), ["agent", "deploy"])
        XCTAssertEqual(parseEmojiTags("ack,thumbsup"), ["👍"])
        XCTAssertEqual(parseNonEmojiTags("acknowledged,backup"), ["acknowledged", "backup"], "only the exact tag")
    }
}

/// The person's answer to a typed question (`ans` plus `re-<sequence>`, agent protocol v2) is no
/// row of its own and never unread: its question shows it in words, whichever device sent it. Red
/// on 9da561b, where "prod" or form JSON showed as its own unread row.
final class AnswerRowTests: XCTestCase {
    private var store: Store!
    private var log: AnswerLog!
    private var acks: AckLog!
    private var suites: [String] = []
    private var subscription: Subscription!
    private var removals: [SequenceRemoval] = []
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() -> UserDefaults {
        let name = "answer-row-tests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func setUp() {
        super.setUp()
        // Topic passwords in memory, not the Keychain: an unsigned test host has no Keychain access
        // (-34018), so a stored password read back as nothing and the encrypted cases failed.
        store = Store(inMemory: true, credentialStore: InMemoryCredentialStore(), topicSecrets: InMemoryTopicSecretStore())
        store.saveNotificationRetention(.forever)
        log = AnswerLog(defaults: defaults())
        acks = AckLog(defaults: defaults())
        store.ackLog = acks
        store.reminderDefaults = defaults()
        removals = []
        store.notificationRemover = { [weak self] in self?.removals.append($0) }
        subscription = store.saveSubscription(baseUrl: "https://agents.example", topic: "ops")
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        store = nil
        super.tearDown()
    }

    private static let choice: [String: Any] = ["v": 2, "kind": "choice", "options": [
        ["k": "staging", "l": "Staging"], ["k": "prod", "l": "Production"], ["k": "both", "l": "Both"]]]
    private static let form: [String: Any] = ["v": 2, "kind": "form", "fields": [
        ["k": "branch", "l": "Branch", "kind": "text"], ["k": "replicas", "l": "Replicas", "kind": "number"]]]

    private func carrier(_ schema: [String: Any]) -> Action {
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return Action(id: "ask", action: "view", label: "Answer in NTF-AI",
                      url: "https://ntf-ai.app/docs/agents#ask-v2=" + TopicEncryption.base64urlEncode(data),
                      method: nil, headers: nil, body: nil, clear: nil)
    }

    private func question(_ schema: [String: Any] = AnswerRowTests.choice, id: String = "q-1", sequence: String = "deploy",
                          age: TimeInterval = 600) -> Message {
        Message(id: id, time: Int64(now.addingTimeInterval(-age).timeIntervalSince1970), event: "message", topic: "ops",
                message: "Where should this go?", title: "Deploy", priority: 4, tags: ["agent"], actions: [carrier(schema)],
                sequenceID: sequence)
    }

    private func reply(_ id: String, _ body: String, tags: [String], age: TimeInterval = 60) -> Message {
        Message(id: id, time: Int64(now.addingTimeInterval(-age).timeIntervalSince1970), event: "message", topic: "ops",
                message: body, priority: 3, tags: tags)
    }

    @discardableResult
    private func save(_ messages: Message...) -> [Message] {
        let presented = store.save(notificationsFromMessages: messages, withSubscription: subscription)
        store.context.processPendingChanges()
        return presented
    }

    private var rows: [ntfy.Notification] {
        let request = ntfy.Notification.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: true)]
        return (try? store.context.fetch(request)) ?? []
    }

    private func row(_ id: String) throws -> ntfy.Notification { try XCTUnwrap(rows.first { $0.id == id }, id) }

    private func receipt(_ id: String = "q-1") throws -> AgentReceipt {
        AgentReceipt(notification: try row(id), log: log, acks: acks, shows: true)
    }

    // MARK: rows and unread counts

    func testAChoiceAnswerIsNoRowAndNeverUnread() throws {
        save(question())
        XCTAssertEqual(store.totalUnreadCount(), 1, "the question")
        let presented = save(reply("a-1", "prod", tags: ["re-deploy", "ans"]))
        XCTAssertEqual(presented.map(\.id), [], "the person's own answer never alerts")
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"], "the answer is not its own row")
        XCTAssertEqual(store.totalUnreadCount(), 1, "badge and Inbox: the answer adds nothing")
        XCTAssertEqual(store.unreadCount(baseUrl: "https://agents.example", topic: "ops"), 1, "the topic's count")
    }

    func testAnAnswerInTheSameBatchAsItsQuestionIsNoRow() {
        save(question(), reply("a-1", "prod", tags: ["ans", "re-deploy"]))
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"])
        XCTAssertEqual(store.totalUnreadCount(), 1, "only the question")
    }

    func testAPushedAnswerIsNotStoredOrPresented() {
        save(question())
        let result = store.ingest(pushedMessage: reply("a-1", "prod", tags: ["re-deploy", "ans"]),
                                  baseUrl: "https://agents.example", topic: "ops")
        XCTAssertNotNil(result)
        XCTAssertNil(result?.message, "nothing to present: \(String(describing: result))")
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"])
        XCTAssertEqual(store.totalUnreadCount(), 1, "only the question")
    }

    func testAnEncryptedAnswerIsNoRow() throws {
        _ = store.setEncryptionPassword("correct horse", for: subscription)
        let key = try XCTUnwrap(store.encryptionKey(baseUrl: "https://agents.example", topic: "ops"))
        save(question())
        let cipher = try TopicEncryption.encrypt(EncryptedPayload(message: "prod", tags: ["re-deploy", "ans"]), key: key)
        save(reply("a-1", cipher, tags: ["re-deploy", "ans"]))
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"], "decrypted, then folded into its question")
        XCTAssertEqual(store.totalUnreadCount(), 0, "an answer from someone with the password settles the question")
        XCTAssertEqual(try receipt().answerText, "Production")
        XCTAssertTrue(removals.contains { $0.sequence == "deploy" && $0.keepingID == "a-1" }, "its banner goes")
    }

    // MARK: the question shows the answer

    func testTheQuestionShowsTheChoiceLabelBeforeAndAfterTheAck() throws {
        save(question())
        save(reply("a-1", "prod", tags: ["re-deploy", "ans"]))
        var receipt = try receipt()
        XCTAssertNil(receipt.answer, "not recorded here: never \"You answered\"")
        XCTAssertEqual(receipt.namedAnswer, "Production", "\"Answered Production\": the label, never the key")
        XCTAssertEqual(receipt.answerText, "Production")
        XCTAssertNil(receipt.agent, "no ack yet")
        let state = AnswerState(notification: try row("q-1"), log: log, acks: acks)
        XCTAssertTrue(state.answered, "the controls give way to the receipt")
        XCTAssertEqual(state.entry?.seen, true, "the card says \"Answered\", not \"You answered\"")
        XCTAssertEqual(store.waitingNotifications(log: log, now: now).compactMap(\.id), [], "out of Waiting on you")
        // ntf 0.4's ack names no answer.
        save(Message(id: "k-1", time: Int64(now.addingTimeInterval(-30).timeIntervalSince1970), event: "message", topic: "ops",
                     message: "\u{2713} Got your reply", priority: 1, tags: ["agent", "ack"], sequenceID: "deploy"))
        receipt = try self.receipt()
        XCTAssertEqual(receipt.agent, .got(now.addingTimeInterval(-30), note: nil))
        XCTAssertEqual(receipt.answerText, "Production", "\"Agent got it · Production\"")
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"])
    }

    func testAFormAnswerReadsWithItsFieldLabels() throws {
        save(question(Self.form))
        save(reply("a-1", #"{"branch":"main","replicas":2}"#, tags: ["re-deploy", "ans"]))
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"])
        let receipt = try receipt()
        XCTAssertEqual(receipt.namedAnswer, "Branch: main · Replicas: 2")
        XCTAssertFalse(receipt.answerText?.contains("{") ?? true, "never raw JSON")
    }

    func testAnAnswerMadeHereKeepsItsOwnReceipt() throws {
        save(question())
        let key = try XCTUnwrap(AnswerKey(notification: try row("q-1")))
        log.record(key, AnswerEntry(kind: .tap, label: "Production", text: nil, at: now.addingTimeInterval(-61), ok: true))
        save(reply("a-1", "prod", tags: ["re-deploy", "ans"]))
        XCTAssertEqual(try receipt().answer?.at, now.addingTimeInterval(-61), "recorded here: \"You answered Production\"")
        XCTAssertNil(try receipt().answer?.seen)
        XCTAssertEqual(rows.compactMap(\.id), ["q-1"])
    }

    // MARK: what stays

    func testMessagesThatOnlyLookLikeAnswersStay() throws {
        save(question())
        save(reply("x-1", "ans is a word", tags: ["ans"]),
             reply("x-2", "prod", tags: ["re-deploy", "answer"]),
             reply("x-3", "prod", tags: ["ans", "re-other"]))
        XCTAssertEqual(Set(rows.compactMap(\.id)), ["q-1", "x-1", "x-2", "x-3"], "no `ans` with a `re-` naming a question here")
        XCTAssertEqual(try row("x-1").read, false, "`ans` without `re-` is an ordinary message")
        XCTAssertNil(try receipt().answer, "neither one answered the question")
    }

    func testAnAnswerWhoseQuestionIsGoneStaysReadable() throws {
        save(reply("a-1", #"{"branch":"main","replicas":2}"#, tags: ["re-expired", "ans"]))
        let orphan = try row("a-1")
        XCTAssertEqual(orphan.display.title, "branch: main · replicas: 2", "readable, never raw JSON")
        XCTAssertEqual(orphan.read, true, "the person's own answer is never unread")
        save(reply("a-2", "prod", tags: ["re-gone", "ans"]))
        XCTAssertEqual(try row("a-2").display.title, "prod")
    }

    func testAFreeReplyStaysVisibleAndRead() throws {
        save(question())
        let presented = save(reply("r-1", "Teal please", tags: ["re-deploy"]))
        XCTAssertEqual(presented.map(\.id), [])
        XCTAssertEqual(rows.compactMap(\.id), ["q-1", "r-1"], "the person's reply stays")
        XCTAssertEqual(try row("r-1").read, true, "never unread")
        XCTAssertEqual(try row("r-1").display.title, "Teal please")
    }

    // MARK: what an answer can't claim (security review, 2026-11-17)

    func testAnAnswerOlderThanTheQuestionIsAnOrdinaryRow() throws {
        save(question(age: 60))
        let presented = save(reply("f-1", "prod", tags: ["re-deploy", "ans"], age: 600))
        XCTAssertEqual(Set(rows.compactMap(\.id)), ["q-1", "f-1"], "sent before the question: no answer to it")
        XCTAssertEqual(presented.map(\.id), ["f-1"], "an ordinary message")
        XCTAssertEqual(try row("f-1").read, false)
        XCTAssertEqual(try row("q-1").read, false)
        XCTAssertNil(try receipt().namedAnswer, "the question stays unanswered")
        XCTAssertEqual(store.waitingNotifications(log: log, now: now).compactMap(\.id), ["q-1"])
    }

    func testAnUnverifiedAnswerKeepsTheQuestionsBannerAndUnread() throws {
        save(question())
        save(reply("a-1", "prod", tags: ["re-deploy", "ans"]))
        XCTAssertEqual(try row("q-1").read, false, "a plain topic's answer could be anyone's")
        XCTAssertFalse(removals.contains { $0.sequence == "deploy" }, "the question's banner stays")
    }

    private func remind(_ verifiedAnswer: Bool) throws -> [Message] {
        var clock = now
        store.reminderClock = { clock }
        store.reminderLog = ReminderLog(defaults: defaults())
        let reminded: [String: Any] = Self.choice.merging(["rem": 1]) { $1 }
        if verifiedAnswer {
            _ = store.setEncryptionPassword("correct horse", for: subscription)
        }
        save(question(age: 0))
        clock += 60
        if verifiedAnswer {
            let key = try XCTUnwrap(store.encryptionKey(baseUrl: "https://agents.example", topic: "ops"))
            let cipher = try TopicEncryption.encrypt(EncryptedPayload(message: "prod", tags: ["re-deploy", "ans"]), key: key)
            save(reply("a-1", cipher, tags: ["re-deploy", "ans"], age: -60))
        } else {
            save(reply("a-1", "prod", tags: ["re-deploy", "ans"], age: -60))
        }
        clock += 600
        return save(question(reminded, id: "q-2", age: -660))
    }

    func testAnUnverifiedAnswerDoesNotSilenceAReminder() throws {
        XCTAssertEqual(try remind(false).map(\.isUpdate), [false], "the reminder alerts")
    }

    func testAnEncryptedAnswerSilencesAReminder() throws {
        XCTAssertEqual(try remind(true).map(\.isUpdate), [true], "answered by someone with the password: stays quiet")
    }

    private func seen(_ id: String, at time: Int64, _ label: String, verified: Bool) -> AgentAck.SeenAnswer {
        AgentAck.SeenAnswer(id: id, time: time, label: label, written: false, version: "q-1", verified: verified ? true : nil)
    }

    func testALaterPlainAnswerDoesNotReplaceAnEncryptedOne() {
        XCTAssertTrue(acks.saveAnswer(seen("a1", at: 100, "Production", verified: true), forKey: "k"))
        XCTAssertFalse(acks.saveAnswer(seen("a2", at: 200, "Staging", verified: false), forKey: "k"))
        let kept = acks.answer(forKey: "k", version: "q-1")
        XCTAssertEqual(kept?.label, "Production")
        XCTAssertEqual(kept?.verified, true, "the reminder stays silenced")
    }

    func testAnEncryptedAnswerReplacesAPlainOneEvenIfOlder() {
        XCTAssertTrue(acks.saveAnswer(seen("a1", at: 200, "Staging", verified: false), forKey: "k"))
        XCTAssertTrue(acks.saveAnswer(seen("a2", at: 100, "Production", verified: true), forKey: "k"))
        XCTAssertEqual(acks.answer(forKey: "k", version: "q-1")?.label, "Production")
        XCTAssertTrue(acks.saveAnswer(seen("a3", at: 300, "Canary", verified: true), forKey: "k"), "a newer encrypted one still wins")
        XCTAssertFalse(acks.saveAnswer(seen("a4", at: 250, "Dev", verified: true), forKey: "k"), "an older encrypted one does not")
        XCTAssertEqual(acks.answer(forKey: "k", version: "q-1")?.label, "Canary")
    }
}

/// Folding the Inbox's two sections (operator, 2026-11-17: "it should be a dropdown tappable to
/// close hide, by the header"): each section's state is its own and outlives the app.
final class SectionFoldTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SectionFoldTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFoldedSectionStaysFoldedAfterRelaunchAndOnlyThatSection() {
        let first = SectionFold(defaults: defaults)
        XCTAssertFalse(first.isCollapsed(SectionFold.activity), "sections start open")
        first.toggle(SectionFold.activity)
        XCTAssertTrue(first.isCollapsed(SectionFold.activity))

        let relaunched = SectionFold(defaults: defaults)
        XCTAssertTrue(relaunched.isCollapsed(SectionFold.activity), "a folded section is still folded on the next launch")
        XCTAssertFalse(relaunched.isCollapsed(SectionFold.waiting), "folding Activity leaves Waiting on you open")

        relaunched.toggle(SectionFold.activity)
        XCTAssertFalse(SectionFold(defaults: defaults).isCollapsed(SectionFold.activity), "opening it again is kept too")
    }

    func testWaitingAndActivityFoldIndependently() {
        let fold = SectionFold(defaults: defaults)
        fold.setCollapsed(SectionFold.waiting, true)
        XCTAssertNotEqual(SectionFold.waiting, SectionFold.activity)
        XCTAssertFalse(fold.isCollapsed(SectionFold.activity), "folding Waiting on you leaves Activity open")
        fold.setCollapsed(SectionFold.activity, true)
        fold.setCollapsed(SectionFold.waiting, false)
        let relaunched = SectionFold(defaults: defaults)
        XCTAssertFalse(relaunched.isCollapsed(SectionFold.waiting))
        XCTAssertTrue(relaunched.isCollapsed(SectionFold.activity))
    }

    func testFoldedWaitingHeaderStillSaysHowManyAreWaiting() {
        let folded = FoldHeaderAccessibility(title: "Waiting on you", count: 3, collapsed: true)
        XCTAssertEqual(folded.label, "Waiting on you, 3")
        XCTAssertEqual(folded.value, String(localized: "Collapsed"))
        let open = FoldHeaderAccessibility(title: "Waiting on you", count: 3, collapsed: false)
        XCTAssertEqual(open.label, folded.label, "the count is said whether the section is open or folded")
        XCTAssertEqual(open.value, String(localized: "Expanded"))
        XCTAssertEqual(FoldHeaderAccessibility(title: "Activity", count: nil, collapsed: true).label, "Activity")
    }

    func testFoldHeaderIsAHeaderButtonWithAFullSizeTarget() {
        let a11y = FoldHeaderAccessibility(title: "Activity", count: nil, collapsed: false)
        XCTAssertTrue(a11y.traits.contains(.isHeader), "VoiceOver's headings rotor still finds it")
        XCTAssertTrue(a11y.traits.contains(.isButton), "VoiceOver says it can be activated")
        XCTAssertGreaterThanOrEqual(FoldHeaderAccessibility.minimumHitHeight, 44)
    }
}
