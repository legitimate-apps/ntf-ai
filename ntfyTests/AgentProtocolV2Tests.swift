// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import CoreData
import UserNotifications
import XCTest
@testable import ntfy

/// Agent protocol v2 (SPEC.md, 2026-11-15), O2-O6: typed questions, answers, hidden old paths and
/// deadlines. Red on 7bb2cca (build 52).
final class AgentProtocolV2Tests: XCTestCase {
    // MARK: fixtures

    private struct Fixture {
        let name: String
        let schema: [String: Any]
        let answers: [[String: Any]]
    }

    private func fixtures() throws -> [String: Fixture] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ask-v2", withExtension: "json"), "fixture bundled")
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: list.map { item in
            let fixture = Fixture(name: item["name"] as! String, schema: item["schema"] as! [String: Any],
                                  answers: item["answers"] as? [[String: Any]] ?? [])
            return (fixture.name, fixture)
        })
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func carrier(_ schema: [String: Any], id: String = "ask", host: String = "ntf-ai.app") -> Action {
        carrier(data: json(schema), id: id, host: host)
    }

    private func carrier(data: Data, id: String = "ask", host: String = "ntf-ai.app") -> Action {
        Action(id: id, action: "view", label: "Answer in NTF-AI",
               url: "https://\(host)/docs/agents#ask-v2=" + TopicEncryption.base64urlEncode(data),
               method: nil, headers: nil, body: nil, clear: nil)
    }

    private func schema(_ object: [String: Any]) -> AskSchema? { AskSchema.decode(json: json(object)) }

    // MARK: schema decoding (SPEC 2)

    func testFixtureSchemasA1ToA6DecodeAndA7A8AreUnknown() throws {
        let all = try fixtures()
        let expected: [String: AskSchema.Kind] = ["A1": .choice, "A2": .choice, "A3": .number, "A4": .date, "A5": .text, "A6": .form]
        for (name, kind) in expected {
            let decoded = try XCTUnwrap(schema(try XCTUnwrap(all[name]).schema), "\(name) decodes")
            XCTAssertEqual(decoded.kind, kind, name)
        }
        XCTAssertNil(schema(try XCTUnwrap(all["A7"]).schema), "v:3 is unknown")
        XCTAssertNil(schema(try XCTUnwrap(all["A8"]).schema), "an unknown kind is unknown")

        let a1 = try XCTUnwrap(schema(all["A1"]!.schema))
        XCTAssertEqual(a1.expires, 1794780000)
        guard case .choice(let choice) = a1.input else { return XCTFail("A1 is a choice") }
        XCTAssertEqual(choice.options.map(\.key), ["staging", "prod", "both"])
        XCTAssertEqual(choice.options.map(\.destructive), [false, true, false])
        XCTAssertFalse(choice.multi)
        let a2 = try XCTUnwrap(schema(all["A2"]!.schema))
        guard case .choice(let multi) = a2.input else { return XCTFail("A2 is a choice") }
        XCTAssertEqual([multi.minCount, multi.maxCount], [1, 2])
        let a3 = try XCTUnwrap(schema(all["A3"]!.schema))
        XCTAssertEqual(a3.hint, "Reply with a number from 1 to 64 (GB).")
        guard case .number(let number) = a3.input else { return XCTFail("A3 is a number") }
        XCTAssertEqual(number.step, Decimal(string: "0.5"))
        XCTAssertEqual(number.unit, "GB")
        let a6 = try XCTUnwrap(schema(all["A6"]!.schema))
        guard case .form(let fields) = a6.input else { return XCTFail("A6 is a form") }
        XCTAssertEqual(fields.map(\.key), ["branch", "replicas", "when"])
        XCTAssertEqual(fields.map(\.optional), [false, false, true])
    }

    func testSchemasBreakingALimitAreUnknown() {
        let options: [[String: Any]] = [["k": "a", "l": "A"], ["k": "b", "l": "B"]]
        XCTAssertNotNil(schema(["v": 2, "kind": "choice", "options": options, "future": ["x": 1]]), "unknown keys are ignored")
        XCTAssertNil(schema(["v": 3, "kind": "choice", "options": options]))
        XCTAssertNil(schema(["v": 2, "kind": "slider"]))
        XCTAssertNil(schema(["v": "2", "kind": "choice", "options": options]), "wrong type")
        XCTAssertNil(schema(["v": 2, "kind": "choice", "options": [["k": "a,b", "l": "A"], ["k": "c", "l": "C"]]]), "bad option key")
        XCTAssertNil(schema(["v": 2, "kind": "choice", "options": [["k": "a", "l": "A"]]]), "one option")
        XCTAssertNil(schema(["v": 2, "kind": "choice", "options": [["k": "a", "l": String(repeating: "x", count: 41)], ["k": "b", "l": "B"]]]))
        XCTAssertNil(schema(["v": 2, "kind": "number", "step": 0]))
        XCTAssertNil(schema(["v": 2, "kind": "text", "max": 1001]))
        XCTAssertNil(schema(["v": 2, "kind": "text", "rem": 4]))
        XCTAssertNil(schema(["v": 2, "kind": "form", "fields": [["k": "a", "l": "A", "kind": "choice", "multi": true,
                                                                 "options": options]]]), "no multi choice in a form")

        // Exactly 1536 bytes decodes; 1537 does not.
        func padded(to size: Int) -> Data {
            let base = json(["v": 2, "kind": "text", "pad": ""])
            return json(["v": 2, "kind": "text", "pad": String(repeating: "p", count: size - base.count)])
        }
        XCTAssertEqual(padded(to: 1536).count, 1536)
        XCTAssertNotNil(AskSchema.decode(json: padded(to: 1536)))
        XCTAssertEqual(padded(to: 1537).count, 1537)
        XCTAssertNil(AskSchema.decode(json: padded(to: 1537)))
    }

    func testOnlyTheGuideLinkOnEitherHostedNameCarriesASchema() throws {
        let object: [String: Any] = ["v": 2, "kind": "text"]
        XCTAssertNotNil(AskSchema.detect(in: [carrier(object)]).schema)
        XCTAssertNotNil(AskSchema.detect(in: [carrier(object, host: "ntfy-me.com")]).schema)
        XCTAssertEqual(AskSchema.detect(in: [carrier(object, host: "evil.example")]), .none)
        XCTAssertEqual(AskSchema.detect(in: [carrier(["v": 3, "kind": "text"])]), .unsupported(carrier: "ask"))
    }

    // MARK: answers (SPEC 2, appendix A)

    /// Free replies are `ntf`'s to read ("3" for the third option, a label, "Branch: main"); the app
    /// never sends them as typed answers, so it doesn't parse them either.
    private let freeReplies: Set<String> = ["A1|3", "A1|Production", "A6|Branch: main\nReplicas: 2"]

    func testFixtureAnswerBodiesMatchTheSchema() throws {
        for (name, fixture) in try fixtures() where !fixture.answers.isEmpty {
            let decoded = try XCTUnwrap(schema(fixture.schema), name)
            for answer in fixture.answers {
                let body = answer["body"] as! String
                guard !freeReplies.contains("\(name)|\(body)") else { continue }
                let parsed = decoded.answer(fromBody: body)
                if answer["valid"] as! Bool {
                    let value = try XCTUnwrap(parsed, "\(name) accepts \(body)")
                    let canonical = try XCTUnwrap(decoded.body(for: value))
                    // The app always writes the canonical form: keys in option order.
                    XCTAssertEqual(decoded.answer(fromBody: canonical), value, "\(name) \(body)")
                    XCTAssertEqual(try answerJSON(value), try normalized(answer["value"]!), "\(name) \(body)")
                } else {
                    XCTAssertNil(parsed, "\(name) rejects \(body)")
                }
            }
        }
    }

    private func answerJSON(_ answer: AskAnswer) throws -> NSObject {
        switch answer {
        case .choice(let keys): return keys.count == 1 ? keys[0] as NSObject : keys as NSObject
        case .number(let n): return NSDecimalNumber(decimal: n)
        case .date(let t), .text(let t): return t as NSObject
        case .form(let values): return try values.mapValues { try answerJSON($0) } as NSObject
        }
    }

    private func normalized(_ value: Any) throws -> NSObject {
        if let number = value as? NSNumber { return NSDecimalNumber(string: number.stringValue) }
        if let object = value as? [String: Any] { return try object.mapValues { try normalized($0) } as NSObject }
        return value as! NSObject
    }

    func testAnswerBodiesAreTheWireFormatInEveryLanguage() throws {
        let all = try fixtures()
        let a1 = try XCTUnwrap(schema(all["A1"]!.schema))
        XCTAssertEqual(a1.body(for: .choice(["prod"])), "prod")
        XCTAssertNil(a1.body(for: .choice(["prod", "both"])), "single choice")
        let a2 = try XCTUnwrap(schema(all["A2"]!.schema))
        XCTAssertEqual(a2.body(for: .choice(["c", "a"])), "a,c", "options order")
        XCTAssertNil(a2.body(for: .choice(["a", "b", "c"])), "over max")

        // A German phone shows and reads 12,5 and still sends 12.5.
        let german = Locale(identifier: "de_DE")
        let a3 = try XCTUnwrap(schema(all["A3"]!.schema))
        let typed = try XCTUnwrap(AskNumbers.parseTyped("12,5", locale: german))
        XCTAssertEqual(a3.body(for: .number(typed)), "12.5")
        XCTAssertEqual(AskNumbers.display(typed, locale: german), "12,5")
        XCTAssertEqual(a3.summary(.number(typed), locale: german), "12,5 GB")
        XCTAssertNil(a3.body(for: .number(Decimal(string: "12.25")!)), "off step")
        XCTAssertNil(a3.body(for: .number(65)), "over max")
        XCTAssertEqual(a3.body(for: .number(64)), "64")

        let a4 = try XCTUnwrap(schema(all["A4"]!.schema))
        let utc = TimeZone(identifier: "UTC")!
        let picked = try XCTUnwrap(AskDates.pickerDate("2026-11-16", mode: .date, timeZone: utc))
        XCTAssertEqual(AskDates.wire(picked, mode: .date, timeZone: utc), "2026-11-16")
        XCTAssertEqual(a4.body(for: .date("2026-11-16")), "2026-11-16")
        XCTAssertNil(a4.body(for: .date("2027-01-01")))
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let instant = Date(timeIntervalSince1970: 1_794_816_000) // 2026-11-16T08:00:00Z
        XCTAssertEqual(AskDates.wire(instant, mode: .datetime, timeZone: berlin), "2026-11-16T09:00:00+01:00")
        XCTAssertEqual(AskDates.wire(instant, mode: .time, timeZone: berlin), "09:00")

        let a5 = try XCTUnwrap(schema(all["A5"]!.schema))
        XCTAssertEqual(a5.body(for: .text("  release/1.27 \n")), "release/1.27", "trimmed")
        XCTAssertNil(a5.body(for: .text("   ")))

        let a6 = try XCTUnwrap(schema(all["A6"]!.schema))
        XCTAssertEqual(a6.body(for: .form(["branch": .text("main"), "replicas": .number(2)])),
                       #"{"branch":"main","replicas":2}"#, "compact, numbers as numbers, empty optional omitted")
        XCTAssertNil(a6.body(for: .form(["branch": .text("main")])), "a required field is missing")
        XCTAssertEqual(a6.body(for: .form(["branch": .text("a\"b"), "replicas": .number(Decimal(string: "1")!),
                                           "when": .date("2026-11-16T09:30:00-08:00")])),
                       #"{"branch":"a\"b","replicas":1,"when":"2026-11-16T09:30:00-08:00"}"#)
    }

    // MARK: what a 1.27 page hides (SPEC 4, version rules)

    func testANativeQuestionHidesItsOldAnswerPathsButKeepsOtherLinks() throws {
        let topic = "https://ntfy-me.com/deploys"
        let schemaObject = try XCTUnwrap(try fixtures()["A1"]).schema
        let ask = carrier(schemaObject)
        let prod = Action(id: "h1", action: "http", label: "Production", url: "https://ntf-ai.app/deploys-answers",
                          method: "POST", headers: nil, body: "reply:q7:prod", clear: nil)
        let other = Action(id: "h2", action: "http", label: "Other topic", url: "https://ntfy-me.com/elsewhere-answers",
                           method: "POST", headers: nil, body: "reply:q7:prod", clear: nil)
        let reply = Action(id: "r1", action: "view", label: "Reply",
                           url: "https://ntf-ai.app/docs/agents#reply-v1=" + topic.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
                           method: nil, headers: nil, body: nil, clear: nil)
        let pr = Action(id: "v1", action: "view", label: "Open PR", url: "https://github.com/x/y/pull/1",
                        method: nil, headers: nil, body: nil, clear: nil)
        let actions = [ask, prod, other, reply, pr]
        guard case .native(_, let carrierID) = AskSchema.detect(in: actions) else { return XCTFail("native") }
        let visible = AskSchema.visibleActions(actions, carrier: carrierID, sequence: "q7", topicURL: topic)
        XCTAssertNotNil(BannerReply.destination(for: reply), "fixture is a real reply link")
        XCTAssertEqual(visible.map(\.id), ["h2", "v1"])
        // The banner keeps every old path; only the ask-v2 link goes.
        XCTAssertEqual(UNMutableNotificationContent.bannerActions(actions).map(\.id), ["h1", "h2", "r1", "v1"])
        // A link this build can't render stays where 1.26 shows it.
        let unknown = carrier(["v": 3, "kind": "choice"], id: "ask3")
        XCTAssertEqual(UNMutableNotificationContent.bannerActions([unknown, prod]).map(\.id), ["ask3", "h1"])
    }

    func testTheHintIsStrippedOnlyFromTheEndOfTheBody() {
        let hint = "Reply with a number from 1 to 64 (GB)."
        XCTAssertEqual(AskSchema.strippingHint("How much memory?\n\n" + hint, hint: hint), "How much memory?")
        XCTAssertEqual(AskSchema.strippingHint("How much memory?\n" + hint, hint: hint), "How much memory?\n" + hint)
        XCTAssertEqual(AskSchema.strippingHint(hint + "\n\nHow much?", hint: hint), hint + "\n\nHow much?")
        XCTAssertEqual(AskSchema.strippingHint("Body", hint: nil), "Body")
    }

    func testProtocolTagsAreHidden() {
        XCTAssertTrue(ProtocolTag.isHidden("ans"))
        XCTAssertTrue(ProtocolTag.isHidden("@Claude Code"))
        XCTAssertTrue(ProtocolTag.isHidden("re-q7"))
        XCTAssertFalse(ProtocolTag.isHidden("@"))
        XCTAssertFalse(ProtocolTag.isHidden("agent"))
    }

    // MARK: publishing an answer (SPEC 2)

    func testTheAnswerGoesToTheMainTopicTaggedReplyAndAns() throws {
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        let subscription = store.saveSubscription(baseUrl: "https://ntfy-me.com", topic: "deploys")
        let key = AnswerKey(baseUrl: "https://ntfy-me.com", topic: "deploys", sequence: "q7")
        XCTAssertEqual(AgentReply.answerTags(for: key), "re-q7,ans")

        let plain = try XCTUnwrap(ApiService.shared.publishRequest(subscription: subscription, user: nil, message: "12.5",
                                                                    title: "", priority: 3, tags: parseAllTags("re-q7,ans")))
        XCTAssertEqual(plain.url?.absoluteString, "https://ntfy-me.com/deploys", "the main topic, not -answers")
        XCTAssertEqual(plain.value(forHTTPHeaderField: "Tags"), "re-q7,ans")
        XCTAssertEqual(plain.value(forHTTPHeaderField: "Priority"), "3")
        XCTAssertEqual(plain.httpBody, Data("12.5".utf8))

        let secret = Data(repeating: 9, count: 32)
        let sealed = try XCTUnwrap(ApiService.shared.publishRequest(subscription: subscription, user: nil, message: "12.5",
                                                                     title: "", priority: 3, tags: ["re-q7", "ans", "phone"],
                                                                     encryptionKey: secret))
        XCTAssertEqual(sealed.value(forHTTPHeaderField: "Tags"), "re-q7,ans", "protocol tags outside, nothing else")
        let payload = try TopicEncryption.decryptPayload(String(decoding: try XCTUnwrap(sealed.httpBody), as: UTF8.self), key: secret)
        XCTAssertEqual(payload.tags, ["re-q7", "ans", "phone"], "and inside")
        XCTAssertEqual(payload.message, "12.5")
    }

    // MARK: deadlines (SPEC 7)

    func testAQuestionPastItsDeadlineStopsWaiting() {
        let exp: Int64 = 1_800_000_000
        let actions = [carrier(["v": 2, "kind": "text", "exp": exp])]
        let asked = Date(timeIntervalSince1970: TimeInterval(exp) - 3600)
        XCTAssertTrue(WaitingRule.isWaiting(actions: actions, time: asked, entry: nil, tags: ["agent"],
                                            now: Date(timeIntervalSince1970: TimeInterval(exp) - 1)))
        XCTAssertFalse(WaitingRule.isWaiting(actions: actions, time: asked, entry: nil, tags: ["agent"],
                                             now: Date(timeIntervalSince1970: TimeInterval(exp))))
    }

    // MARK: fix round (REVIEW-app-independent MINOR 1, 2, 4; interop)

    /// MINOR 2: a picked date and time goes out on the minute.
    func testDatetimeAnswersAreWholeMinutes() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let picked = Date(timeIntervalSince1970: 1_794_816_047) // 2026-11-16T00:00:47-08:00
        XCTAssertEqual(AskDates.wire(picked, mode: .datetime, timeZone: la), "2026-11-16T00:00:00-08:00")
    }

    /// MINOR 1: a date row nobody picked sends nothing, so a required one keeps Send off; Choose
    /// opens on now, inside the schema's range.
    func testADateNobodyPickedIsNotSent() {
        let utc = TimeZone(identifier: "UTC")!
        let spec = AskSchema.DateSpec(mode: .date, min: "2026-12-01", max: nil)
        let fields = [AskSchema.Field(key: "when", label: "When", optional: false, input: .date(spec))]
        let empty = AskForm.answer(fields: fields, texts: [:], dates: [:], picks: [:], timeZone: utc)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(AskSchema.validated(.form(empty), input: .form(fields)), "Send stays off")
        let start = AskDates.initial(spec, now: Date(timeIntervalSince1970: 1_794_816_047), timeZone: utc)
        let picked = AskForm.answer(fields: fields, texts: [:], dates: ["when": start], picks: [:], timeZone: utc)
        XCTAssertEqual(picked["when"], .date("2026-12-01"), "now moved up to the minimum")
        XCTAssertNotNil(AskSchema.validated(.form(picked), input: .form(fields)))
    }

    /// MINOR 4: a range that allows negatives gets a keyboard with a minus key.
    func testNegativeRangesGetAMinusKey() {
        XCTAssertEqual(AskNumbers.keyboard(for: .init(min: 0, max: 10, step: 1, unit: nil)), .decimalPad)
        XCTAssertEqual(AskNumbers.keyboard(for: .init(min: -5, max: 10, step: 1, unit: nil)), .numbersAndPunctuation)
        XCTAssertEqual(AskNumbers.keyboard(for: .init(min: nil, max: 10, step: 1, unit: nil)), .numbersAndPunctuation)
    }

    /// Interop: an encrypted payload sealed again keeps the action keys and types this build
    /// doesn't know (`scripts/e2e-interop`, "swift raw actions survive").
    func testAResealedPayloadKeepsActionsItDoesNotKnow() throws {
        let sent = #"{"message":"schema","actions":[{"action":"view","label":"Answer","url":"https://ntf-ai.app/docs/agents#ask-v2=e30","future":true},{"action":"broadcast","label":"Future","extras":{"x":"y"}}]}"#
        let payload = try JSONDecoder().decode(EncryptedPayload.self, from: Data(sent.utf8))
        let again = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        let expected = try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any]
        XCTAssertEqual(again as NSDictionary?, expected as NSDictionary?)
        let typed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EncryptedPayload(message: "m", actions: [
            .init(action: "view", label: "Open", url: "https://example.com")]))) as? [String: Any]
        XCTAssertEqual((typed?["actions"] as? [[String: Any]])?.first?["label"] as? String, "Open", "control: typed actions still encode")
    }
}

/// Reminders, withdraw and the interruption table (SPEC 7), through the store as the app and the
/// extension use it.
final class AgentReminderTests: XCTestCase {
    private var store: Store!
    private var suites: [String] = []
    private var subscription: Subscription!
    private var clock = Date(timeIntervalSince1970: 1_794_700_000)
    private var shared: UserDefaults!

    private func defaults() -> UserDefaults {
        let name = "v2-tests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func setUp() {
        super.setUp()
        store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        store.saveNotificationRetention(.forever)
        shared = defaults()
        store.ackLog = AckLog(defaults: shared)
        store.reminderLog = ReminderLog(defaults: shared)
        store.reminderDefaults = shared
        store.reminderClock = { [unowned self] in self.clock }
        store.notificationRemover = { _ in }
        subscription = store.saveSubscription(baseUrl: "https://agents.example", topic: "home")
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        store = nil
        super.tearDown()
    }

    private func ask(rem: Int? = nil, exp: Int64? = nil) -> Action {
        var object: [String: Any] = ["v": 2, "kind": "choice", "options": [["k": "y", "l": "Yes"], ["k": "n", "l": "No"]]]
        if let rem { object["rem"] = rem }
        if let exp { object["exp"] = exp }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Action(id: "ask", action: "view", label: "Answer", url: "https://ntf-ai.app/docs/agents#ask-v2=" +
                      TopicEncryption.base64urlEncode(data), method: nil, headers: nil, body: nil, clear: nil)
    }

    private func question(_ id: String, rem: Int? = nil, offset: TimeInterval = 0, priority: Int16 = 4,
                          tags: [String] = ["agent"]) -> Message {
        Message(id: id, time: Int64(clock.timeIntervalSince1970 + offset), event: "message", topic: "home",
                message: "Lock the door?", priority: priority, tags: tags, actions: [ask(rem: rem)], sequenceID: "door")
    }

    @discardableResult
    private func save(_ message: Message) -> [Message] {
        let presented = store.save(notificationsFromMessages: [message], withSubscription: subscription)
        store.context.processPendingChanges()
        return presented
    }

    private func level(_ message: Message) -> UNNotificationInterruptionLevel {
        let content = UNMutableNotificationContent()
        content.configureInterruption(message: message)
        return content.interruptionLevel
    }

    private var rows: [ntfy.Notification] { (try? store.context.fetch(ntfy.Notification.fetchRequest())) ?? [] }

    func testAReminderOnAWaitingQuestionAlertsAtItsPriority() throws {
        XCTAssertEqual(save(question("q1")).map(\.isUpdate), [false])
        clock += 600
        let reminded = save(question("q2", rem: 1, offset: 600))
        XCTAssertEqual(reminded.map(\.id), ["q2"])
        XCTAssertEqual(reminded.first?.isUpdate, false, "rem 1 > 0 alerts")
        XCTAssertEqual(level(try XCTUnwrap(reminded.first)), .timeSensitive, "priority 4")
        XCTAssertEqual(rows.first?.read, false)
        // The same version arriving again (push then poll) keeps its decision.
        XCTAssertEqual(store.alertCandidates(from: [question("q2", rem: 1, offset: 600)], baseUrl: "https://agents.example")
            .map(\.isUpdate), [false])
    }

    func testAPlainUpdateAndAnUnraisedReminderStaySilent() {
        save(question("q1"))
        clock += 600
        XCTAssertEqual(save(question("q2", offset: 600)).map(\.isUpdate), [true], "a plain update")
        clock += 600
        XCTAssertEqual(save(question("q3", rem: 1, offset: 1200)).map(\.isUpdate), [false])
        clock += 600
        XCTAssertEqual(save(question("q4", rem: 1, offset: 1800)).map(\.isUpdate), [true], "rem not raised")
    }

    func testRemindersArePacedAndCapped() {
        save(question("q1"))
        clock += 60
        XCTAssertEqual(save(question("q2", rem: 1, offset: 60)).map(\.isUpdate), [false])
        clock += 60
        XCTAssertEqual(save(question("q3", rem: 2, offset: 120)).map(\.isUpdate), [true], "under five minutes since the last")
        let now = Date()
        let three = [now.addingTimeInterval(-3600), now.addingTimeInterval(-2400), now.addingTimeInterval(-1200)]
        let next = AskSchema(input: .text(.init(placeholder: nil, max: 200)), reminder: 3)
        XCTAssertFalse(AgentReminder.alerts(next: next, previous: nil, waiting: true, priorAlerts: three, enabled: true, now: now),
                       "a fourth alert never comes")
        XCTAssertTrue(AgentReminder.alerts(next: next, previous: nil, waiting: true, priorAlerts: Array(three.prefix(2)),
                                           enabled: true, now: now), "control: the third does")
    }

    func testNoReminderAlertsOnceAnsweredOrWithTheSettingOff() throws {
        save(question("q1"))
        let key = AckLog.key(baseUrl: "https://agents.example", topic: "home", sequence: "door")
        let entry = AnswerEntry(kind: .reply, label: "", text: "Yes", at: clock, ok: true, messageId: "q1")
        shared.set(try JSONEncoder().encode([key: entry]), forKey: AnswerLog.defaultsKey)
        clock += 600
        XCTAssertEqual(save(question("q2", rem: 1, offset: 600)).map(\.isUpdate), [true], "after an answer")

        shared.removeObject(forKey: AnswerLog.defaultsKey)
        shared.set(false, forKey: AgentReminder.settingKey)
        clock += 600
        XCTAssertEqual(save(question("q3", rem: 2, offset: 1200)).map(\.isUpdate), [true], "Agent reminders off")
    }

    func testAcksAndOwnAnswersNeverAlert() {
        let ack = Message(id: "a", time: 1, event: "message", topic: "home", message: "Got it", priority: 5, tags: ["agent", "ack"])
        XCTAssertEqual(level(ack), .passive)
        let mine = Message(id: "r", time: 1, event: "message", topic: "home", message: "y", priority: 5, tags: ["re-door", "ans"])
        XCTAssertEqual(level(mine), .passive, "my answer, seen on another device")
        let control = Message(id: "c", time: 1, event: "message", topic: "home", message: "y", priority: 5, tags: ["agent"])
        XCTAssertNotEqual(level(control), .passive, "control")
    }

    func testAWithdrawnQuestionStaysInHistoryMarkedWithdrawn() throws {
        save(question("q1"))
        let delete = Message(id: "d1", time: Int64(clock.timeIntervalSince1970 + 60), event: "message_delete", topic: "home",
                             sequenceID: "door")
        save(delete)
        XCTAssertEqual(rows.compactMap(\.id), ["q1"], "kept")
        let key = AckLog.key(baseUrl: "https://agents.example", topic: "home", sequence: "door")
        XCTAssertEqual(store.ackLog.record(forKey: key, version: "q1")?.withdrawn, true)
        XCTAssertEqual(store.waitingNotifications(log: AnswerLog(defaults: shared), now: clock).count, 0)
        let receipt = AgentReceipt(notification: try XCTUnwrap(rows.first), log: AnswerLog(defaults: shared),
                                   acks: store.ackLog, shows: false)
        XCTAssertEqual(receipt.agent, .withdrawn(Date(timeIntervalSince1970: clock.timeIntervalSince1970 + 60)),
                       "marked withdrawn, even with confirmations off")
        XCTAssertTrue(receipt.resolved, "it takes no more answers")

        // Control: an ordinary message deleted by sequence still goes.
        let note = Message(id: "n1", time: Int64(clock.timeIntervalSince1970), event: "message", topic: "home", message: "fyi",
                           sequenceID: "note")
        save(note)
        save(Message(id: "d2", time: Int64(clock.timeIntervalSince1970 + 60), event: "message_delete", topic: "home", sequenceID: "note"))
        XCTAssertEqual(rows.compactMap(\.id), ["q1"])
    }

    /// MINOR 8: an agent that acked the answer and then deleted the question keeps its ack.
    func testADeleteAfterAnAckKeepsTheAck() {
        save(question("q1"))
        let key = AckLog.key(baseUrl: "https://agents.example", topic: "home", sequence: "door")
        store.ackLog.save(AgentAck.Record(id: "a1", time: Int64(clock.timeIntervalSince1970 + 30), note: "Deploying",
                                          version: "q1"), forKey: key)
        save(Message(id: "d1", time: Int64(clock.timeIntervalSince1970 + 60), event: "message_delete", topic: "home",
                     sequenceID: "door"))
        let record = store.ackLog.record(forKey: key, version: "q1")
        XCTAssertEqual(record?.note, "Deploying")
        XCTAssertNil(record?.withdrawn)
    }

    /// MINOR 3: a card or page left open past the deadline sends nothing when tapped.
    @MainActor
    func testAnAnswerPastTheDeadlineIsNotSent() throws {
        let past = Message(id: "q9", time: Int64(clock.timeIntervalSince1970), event: "message", topic: "home",
                           message: "Lock the door?", priority: 4, tags: ["agent"], actions: [ask(exp: 1_700_000_000)],
                           sequenceID: "late")
        save(past)
        let row = try XCTUnwrap(rows.first { $0.id == "q9" })
        XCTAssertNotNil(row.subscription)
        let key = try XCTUnwrap(AnswerKey(notification: row))
        let log = AnswerLog(defaults: defaults())
        AgentReply.sendAnswer("y", summary: "Yes", to: row, store: store, log: log)
        XCTAssertFalse(log.isSending(key), "expired: nothing published")
    }
}
