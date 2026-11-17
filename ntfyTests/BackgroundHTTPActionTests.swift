import XCTest
import UserNotifications
import CryptoKit
import Network
import UIKit
import CoreData
@testable import ntfy

final class BackgroundHTTPActionTests: XCTestCase {
    private func action(_ type: String = "http", id: String = UUID().uuidString, url: String? = nil) -> Action {
        Action(id: id, action: type, label: "Approve", url: url, method: "POST", headers: nil, body: nil, clear: nil)
    }

    private func userInfo(_ actions: [Action]) throws -> [AnyHashable: Any] {
        ["id": UUID().uuidString, "time": "1700000000", "event": "message", "topic": "background-actions",
         "message": "Approve request", "actions": String(decoding: try JSONEncoder().encode(actions), as: UTF8.self)]
    }

    func testRegisteredIOSOptionsAndLegacyCategoryMigration() throws {
        // A view action needs an openable URL to be offered on the banner (ClickURL.allows).
        let actions = [action(), action("view", url: "https://example.com/pr/1"), action("copy")]
        let message = try XCTUnwrap(Message.from(userInfo: userInfo(actions)))
        let content = UNMutableNotificationContent()
        let oldCanonical = actions.map { "\($0.id)\u{1f}\($0.label)" }.joined(separator: "\u{1e}")
        let oldID = "ntfyActions." + SHA256.hash(data: Data(oldCanonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let registered = expectation(description: "registered on worker")
        DispatchQueue.global().async {
            UNMutableNotificationContent.registerCategorySynchronously(UNNotificationCategory(identifier: oldID,
                actions: actions.map { UNNotificationAction(identifier: $0.id, title: $0.label, options: .foreground) },
                intentIdentifiers: [], options: .customDismissAction))
            content.modify(message: message, baseUrl: "http://127.0.0.1")
            registered.fulfill()
        }
        wait(for: [registered], timeout: 10)
        XCTAssertNotEqual(content.categoryIdentifier, oldID, "new deliveries must not reuse the legacy foreground id")
        let read = expectation(description: "category options")
        UNUserNotificationCenter.current().getNotificationCategories { categories in
            let options = categories.first { $0.identifier == content.categoryIdentifier }?.actions.map(\.options)
            XCTAssertEqual(options, [.authenticationRequired, .foreground, .foreground])
            XCTAssertFalse(categories.contains { $0.identifier == oldID }, "prune unused legacy registrations")
            read.fulfill()
        }
        wait(for: [read], timeout: 5)
    }

    func testOptionsOnIOSAndMacAndDeterministicCategoryIDs() {
        let buttons = [action(id: "http"), action("view", id: "view"), action("copy", id: "copy")]
        XCTAssertEqual(UNMutableNotificationContent.notificationActions(for: buttons, onMac: false).map(\.options),
                       [.authenticationRequired, .foreground, .foreground])
        XCTAssertEqual(UNMutableNotificationContent.notificationActions(for: buttons, onMac: true).map(\.options),
                       [.foreground, .foreground, .foreground])
        for mac in [true, false] {
            let canonical = UNMutableNotificationContent.notificationActions(for: buttons, onMac: mac)
                .map { "\($0.identifier)\u{1f}\($0.title)\u{1f}\($0.options.rawValue)" }.joined(separator: "\u{1e}")
            let expected = "ntfyActions." + SHA256.hash(data: Data(canonical.utf8)).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: buttons, onMac: mac), expected)
        }
        XCTAssertNotEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: buttons, onMac: false),
                          UNMutableNotificationContent.actionCategoryIdentifier(for: buttons, onMac: true))
        var changed = buttons; changed[0].action = "view"
        XCTAssertNotEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: buttons, onMac: false),
                          UNMutableNotificationContent.actionCategoryIdentifier(for: changed, onMac: false))
        XCTAssertEqual(UNMutableNotificationContent.notificationActions(for: buttons + buttons, onMac: false).count, 4)
    }

    private func replyLinkAction() -> Action {
        Action(id: "reply-link", action: "view", label: "Reply in NTF-AI",
               url: "https://ntfy-me.com/docs/agents#reply-v1=https%3A%2F%2Fntfy-me.com%2Freply-secret",
               method: nil, headers: nil, body: nil, clear: nil)
    }

    func testReplyLinkRegistersNativeTextInput() throws {
        let reply = try XCTUnwrap(UNMutableNotificationContent.notificationActions(for: [replyLinkAction()], onMac: false).first)
        XCTAssertTrue(reply is UNTextInputNotificationAction)
        XCTAssertEqual(reply.options, [.authenticationRequired])
        XCTAssertEqual(reply.identifier, "reply-link")
        XCTAssertEqual(reply.title, "Reply in NTF-AI")
    }

    func testReplyAndOrdinaryViewCannotShareACategory() {
        let reply = replyLinkAction()
        var ordinary = reply
        ordinary.url = "https://example.com/"
        XCTAssertNotEqual(UNMutableNotificationContent.actionCategoryIdentifier(for: [reply], onMac: false),
                          UNMutableNotificationContent.actionCategoryIdentifier(for: [ordinary], onMac: false))
    }

    @MainActor
    private func checkCompletion(status: Int) throws {
        let server = try ActionLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let received = expectation(description: "real HTTP request received")
        server.received = { received.fulfill() }
        let button = action(url: "http://127.0.0.1:\(server.port)/approve")
        let delegate = AppDelegate()
        var starts = 0, ends = 0, completions = 0
        delegate.beginNotificationBackgroundTask = { _ in starts += 1; return UIBackgroundTaskIdentifier(rawValue: 42) }
        delegate.endNotificationBackgroundTask = { task in XCTAssertEqual(task.rawValue, 42); ends += 1 }
        let done = expectation(description: "delegate completes after HTTP response")
        delegate.handleNotificationResponse(userInfo: try userInfo([button]), actionIdentifier: button.id,
            notificationId: UUID().uuidString) {
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(server.didRespond, "delegate finished while the request was still waiting for its response")
                completions += 1
                done.fulfill()
            }
        XCTAssertEqual(completions, 0, "HTTP completion must not run at dispatch")
        XCTAssertEqual(starts, 1, "hold process alive before dispatch")
        XCTAssertEqual(ends, 0)
        wait(for: [received], timeout: 5)
        XCTAssertEqual(completions, 0, "server has not responded yet")
        server.respond(status: status)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(ends, 1)
    }

    @MainActor func testSuccessfulHTTPResponseFinishesBeforeDelegateCompletion() throws { try checkCompletion(status: 200) }
    @MainActor func testFailedHTTPResponseFinishesBeforeDelegateCompletion() throws { try checkCompletion(status: 401) }

    @MainActor
    func testRepeatTapAndCooldownRefusalComplete() throws {
        let button = action(url: "http://127.0.0.1:\(UInt16.random(in: 40000...60000))/approve")
        let info = try userInfo([button])
        let server = ActionExecutor.cooldownServer(for: try XCTUnwrap(ActionExecutor.makeHTTPRequest(button, baseUrl: nil)), baseUrl: nil)
        ServerCooldown.shared.limit(server: server, retryAfter: "60", condition: "time", kind: .action)
        XCTAssertNil(ServerCooldown.shared.claimAttempt(server: server, manual: true, kind: .action))
        let done = expectation(description: "refusal and executor repeat both complete")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            AppDelegate().handleNotificationResponse(userInfo: info, actionIdentifier: button.id,
                notificationId: UUID().uuidString) { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
    }
    @MainActor
    func testExpirationCancelsPendingRequestAndEndsOnlyOnce() throws {
        let server = try ActionLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let received = expectation(description: "request waiting for response")
        server.received = { received.fulfill() }
        let button = action(url: "http://127.0.0.1:\(server.port)/approve")
        let delegate = AppDelegate()
        var expire: (() -> Void)!, ends = 0, completions = 0
        delegate.beginNotificationBackgroundTask = { expire = $0; return UIBackgroundTaskIdentifier(rawValue: 43) }
        delegate.endNotificationBackgroundTask = { _ in ends += 1 }
        let duplicate = expectation(description: "no second completion after cancellation callback")
        duplicate.isInverted = true
        delegate.handleNotificationResponse(userInfo: try userInfo([button]), actionIdentifier: button.id,
            notificationId: UUID().uuidString) {
                completions += 1
                if completions > 1 { duplicate.fulfill() }
            }
        wait(for: [received], timeout: 5)
        XCTAssertEqual(completions, 0)
        expire()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(ends, 1)
        server.respond(status: 200)
        wait(for: [duplicate], timeout: 0.5)
        XCTAssertEqual(ends, 1)
    }

    func testCompletionWaitsThroughRetry() throws {
        let server = try ActionLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }; wait(for: [ready], timeout: 5)
        let first = expectation(description: "first request"), second = expectation(description: "retry request")
        var requests = 0
        server.received = { requests += 1; (requests == 1 ? first : second).fulfill() }
        let button = action(url: "http://127.0.0.1:\(server.port)/approve")
        let done = expectation(description: "completed after retry response")
        var completed = false
        ActionExecutor.execute(button) { completed = true; done.fulfill() }
        wait(for: [first], timeout: 5)
        server.respond(status: 503)
        wait(for: [second], timeout: 5)
        XCTAssertFalse(completed)
        server.respond(status: 200)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(requests, 2)
    }

    func testCancellationWhileWaitingToRetryPreventsAnotherRequest() throws {
        let server = try ActionLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "listener ready")
        server.start { ready.fulfill() }; wait(for: [ready], timeout: 5)
        let first = expectation(description: "first request"), extra = expectation(description: "no request after cancel")
        extra.isInverted = true
        var requests = 0
        server.received = { requests += 1; (requests == 1 ? first : extra).fulfill() }
        let button = action(url: "http://127.0.0.1:\(server.port)/approve")
        let done = expectation(description: "cancelled retry completes")
        let execution = ActionExecutor.execute(button) { done.fulfill() }
        wait(for: [first], timeout: 5)
        server.respond(status: 503)
        // Give URLSession its refusal so cancellation exercises the scheduled retry, not the socket.
        let pause = expectation(description: "response consumed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pause.fulfill() }
        wait(for: [pause], timeout: 2)
        execution.cancel()
        wait(for: [done, extra], timeout: 1.5)
    }

    @MainActor
    func testInvalidHTTPAndCopyCompleteWithoutLeakingBackgroundTask() throws {
        for button in [action(), action("copy")] {
            let delegate = AppDelegate()
            var starts = 0, ends = 0
            delegate.beginNotificationBackgroundTask = { _ in starts += 1; return UIBackgroundTaskIdentifier(rawValue: 44) }
            delegate.endNotificationBackgroundTask = { _ in ends += 1 }
            let done = expectation(description: "invalid or foreground action completes")
            delegate.handleNotificationResponse(userInfo: try userInfo([button]), actionIdentifier: button.id,
                notificationId: UUID().uuidString) { done.fulfill() }
            wait(for: [done], timeout: 5)
            XCTAssertEqual(starts, button.action == "http" ? 1 : 0)
            XCTAssertEqual(ends, starts)
        }
    }

}

// Adapted from NSEAuthLoopbackServer's Network listener and complete-request-line framing.
// The original fixture is private in ntfyTests.swift; this fixture holds responses until released.
private final class ActionLoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ntfy.tests.action-http")
    private var connection: NWConnection?
    private let lock = NSLock()
    private var responded = false
    private var stopped = false
    var received: () -> Void = {}
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var didRespond: Bool { lock.lock(); defer { lock.unlock() }; return responded }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { if case .ready = $0 { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            guard !self.stopped else { return }
            var request = buffered
            request.append(data ?? Data())
            if let delimiter = request.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: request[..<delimiter.lowerBound], as: UTF8.self)
                XCTAssertEqual(line, "POST /approve HTTP/1.1")
                print("ACTION_HTTP_RECEIVED \(line)")
                self.received()
            } else if !complete, error == nil, let data, !data.isEmpty {
                self.receive(connection, buffered: request)
            }
        }
    }
    func respond(status: Int) {
        queue.async {
            self.lock.lock(); self.responded = true; self.lock.unlock()
            print("ACTION_HTTP_RESPONSE \(status)")
            let connection = self.connection
            connection?.send(content: Data("HTTP/1.1 \(status) Result\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                completion: .contentProcessed { _ in connection?.cancel() })
        }
    }
    func stop() {
        queue.sync { stopped = true; listener.cancel(); connection?.cancel() }
    }
}

final class BannerReplyTests: XCTestCase {
    private func reply(_ destination: String = "https://ntfy-me.com/reply-secret") -> Action {
        let fragment = destination.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return Action(id: UUID().uuidString, action: "view", label: "Reply in NTF-AI",
                      url: "https://ntfy-me.com/docs/agents#reply-v1=" + fragment,
                      method: nil, headers: nil, body: nil, clear: true)
    }

    func testStrictVersionedLinkAndTopicDestinations() {
        for url in ["https://ntfy-me.com/reply-secret", "http://127.0.0.1:8080/ntfy/reply_42"] {
            XCTAssertEqual(BannerReply.destination(for: reply(url))?.absoluteString, url)
        }
        for target in ["file:///tmp/reply", "javascript:alert(1)", "https://user:pass@ntfy-me.com/secret",
                       "https://ntfy-me.com/secret?q=x", "https://ntfy-me.com/secret#x", "https://ntfy-me.com/",
                       "https://ntfy-me.com/a%2Fb", "https://ntfy-me.com/with%20space", "https://ntfy-me.com/" + String(repeating: "a", count: 65)] {
            XCTAssertNil(BannerReply.destination(for: reply(target)), target)
        }
        let valid = reply()
        for raw in [valid.url!.replacingOccurrences(of: "reply-v1=", with: "reply-v2="),
                    valid.url!.replacingOccurrences(of: "https://ntfy-me.com/docs/agents", with: "http://ntfy-me.com/docs/agents"),
                    valid.url!.replacingOccurrences(of: "ntfy-me.com/docs", with: "ntfy-me.com.evil.test/docs"),
                    valid.url!.replacingOccurrences(of: "/docs/agents#", with: "/docs/agents?x=1#"),
                    valid.url!.replacingOccurrences(of: "/docs/agents#", with: "/docs/agents/#")] {
            var action = valid; action.url = raw
            XCTAssertNil(BannerReply.destination(for: action), raw)
        }
        var http = valid; http.action = "http"; http.body = "{{reply}}"
        XCTAssertNil(BannerReply.destination(for: http), "ordinary HTTP actions never opt in")
    }

    func testReplyRequestPreservesUnicodeQuotesAndNewlinesAndScopedCredentials() throws {
        let action = reply()
        let text = "  Wait for \"review\".\nGrüße 👋 & <ok>  "
        let http = try XCTUnwrap(BannerReply.httpAction(for: action, text: text))
        let credentials = InMemoryCredentialStore()
        XCTAssertTrue(credentials.setHTTPHeaders(["Authorization": "Bearer example-test-token"], baseUrl: "https://ntfy-me.com"))
        let request = try XCTUnwrap(ActionExecutor.makeHTTPRequest(http, baseUrl: "https://ntfy-me.com", credentialStore: credentials))
        XCTAssertEqual(request.url?.absoluteString, "https://ntfy-me.com/reply-secret")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data(text.utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer example-test-token")
        XCTAssertEqual(http.id, action.id)
        XCTAssertEqual(http.clear, true)
        let other = try XCTUnwrap(BannerReply.httpAction(for: reply("https://other.example/reply"), text: text))
        let crossOrigin = try XCTUnwrap(ActionExecutor.makeHTTPRequest(other, baseUrl: "https://ntfy-me.com", credentialStore: credentials))
        XCTAssertNil(crossOrigin.value(forHTTPHeaderField: "Authorization"))
    }

    func testBlankTextAndUnrecognizedActionCannotBecomeRequests() {
        for text in ["", " \n\t"] { XCTAssertNil(BannerReply.httpAction(for: reply(), text: text)) }
        var ordinary = reply(); ordinary.url = "https://example.com/"
        XCTAssertNil(BannerReply.httpAction(for: ordinary, text: "answer"))
        var http = reply(); http.action = "http"
        XCTAssertNil(BannerReply.httpAction(for: http, text: "answer"))
    }

    func testMacUsesTextInputWithForegroundRoutingAndCapRemainsFour() throws {
        let actions = UNMutableNotificationContent.notificationActions(for: Array(repeating: reply(), count: 5), onMac: true)
        XCTAssertEqual(actions.count, 4)
        for action in actions {
            let text = try XCTUnwrap(action as? UNTextInputNotificationAction)
            XCTAssertEqual(text.options, [.foreground])
            XCTAssertFalse(text.textInputButtonTitle.isEmpty)
            XCTAssertEqual(text.textInputPlaceholder, "Reply in NTF-AI")
        }
    }

    func testRelayPreservesTextAndDecodesPreFeatureQueue() throws {
        let suite = "BannerReplyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let response = RelayedNotificationResponse(notificationId: "n", actionIdentifier: "reply", userInfo: [:], receivedAt: now, userText: "Yes 👋\nTomorrow")
        NotificationResponseRelay(defaults: defaults).enqueue(response)
        XCTAssertEqual(NotificationResponseRelay(defaults: defaults).drain(now: now), [response])
        let old = RelayedNotificationResponse(notificationId: "old", actionIdentifier: "view", userInfo: [:], receivedAt: now)
        let data = try JSONEncoder().encode([old])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertNil(json[0]["userText"])
        defaults.set(data, forKey: NotificationResponseRelay.defaultsKey)
        XCTAssertEqual(NotificationResponseRelay(defaults: defaults).drain(now: now), [old])
    }

    @MainActor
    func testDelegatePostsSubmittedTextAndCompletesOnceAfterHTTP() throws {
        let server = try ReplyLoopbackServer()
        defer { server.stop() }
        let ready = expectation(description: "ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let text = "Review \"later\" 👋\nTomorrow at 9"
        let received = expectation(description: "verbatim HTTP reply")
        server.received = { header, body in
            XCTAssertTrue(header.hasPrefix("POST /reply HTTP/1.1\r\n"))
            XCTAssertTrue(header.lowercased().contains("content-type: text/plain; charset=utf-8"))
            XCTAssertEqual(body, Data(text.utf8))
            received.fulfill()
        }
        let button = reply("http://127.0.0.1:\(server.port)/reply")
        let info: [AnyHashable: Any] = ["id": UUID().uuidString, "time": "1700000000", "event": "message", "topic": "reply-fixture",
                                    "actions": String(decoding: try JSONEncoder().encode([button]), as: UTF8.self)]
        let delegate = AppDelegate()
        var starts = 0, ends = 0, completions = 0
        delegate.beginNotificationBackgroundTask = { _ in starts += 1; return UIBackgroundTaskIdentifier(rawValue: 47) }
        delegate.endNotificationBackgroundTask = { _ in ends += 1 }
        let done = expectation(description: "completed")
        let notificationID = UUID().uuidString
        var rejected = 0
        for invalid in [nil, "", " \n"] as [String?] {
            delegate.handleNotificationResponse(userInfo: info, actionIdentifier: button.id, notificationId: notificationID, userText: invalid) { rejected += 1 }
        }
        XCTAssertEqual(rejected, 3)
        XCTAssertEqual(starts, 0)
        delegate.handleNotificationResponse(userInfo: info, actionIdentifier: button.id, notificationId: notificationID, userText: text) {
            completions += 1
            done.fulfill()
        }
        wait(for: [received, done], timeout: 10)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testDelegateRefusesMissingBlankOrUnexpectedTextWithoutStartingHTTP() throws {
        for text in [nil, "", "  \n"] as [String?] {
            let button = reply("http://127.0.0.1:1/reply")
            let delegate = AppDelegate()
            var starts = 0, completed = 0
            delegate.beginNotificationBackgroundTask = { _ in starts += 1; return .invalid }
            let info: [AnyHashable: Any] = ["id": UUID().uuidString, "time": "1700000000", "event": "message", "topic": "reply-fixture",
                                         "actions": String(decoding: try JSONEncoder().encode([button]), as: UTF8.self)]
            delegate.handleNotificationResponse(userInfo: info, actionIdentifier: button.id, notificationId: UUID().uuidString, userText: text) { completed += 1 }
            XCTAssertEqual(starts, 0)
            XCTAssertEqual(completed, 1)
        }
        let delegate = AppDelegate()
        var starts = 0, completed = 0
        delegate.beginNotificationBackgroundTask = { _ in starts += 1; return .invalid }
        var button = reply(); button.action = "http"
        let info: [AnyHashable: Any] = ["id": UUID().uuidString, "time": "1700000000", "event": "message", "topic": "reply-fixture",
                                     "actions": String(decoding: try JSONEncoder().encode([button]), as: UTF8.self)]
        delegate.handleNotificationResponse(userInfo: info, actionIdentifier: button.id, notificationId: UUID().uuidString, userText: "wrong type") { completed += 1 }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(completed, 1)
    }
}

private final class ReplyLoopbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ntfy.tests.reply-http")
    private var connections: [NWConnection] = []
    var received: (String, Data) -> Void = { _, _ in }
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { if case .ready = $0 { ready() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var request = buffered
            request.append(data ?? Data())
            if let separator = request.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: request[..<separator.lowerBound], as: UTF8.self)
                let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = Data(request[separator.upperBound...])
                if body.count >= length {
                    self.received(header, body)
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if !complete && error == nil { self.receive(connection, buffered: request) }
        }
    }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() } } }
}

/// Both ways of answering a question write the same answer log (DIRECTIONS 1.6): the banner's
/// button or reply field through the app delegate, and the card or page through MessageActionRunner.
extension BannerReplyTests {
    private func answerFixture() throws -> (ReplyLoopbackServer, AnswerLog, String) {
        let server = try ReplyLoopbackServer()
        let ready = expectation(description: "ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let suite = "answer-path-\(UUID().uuidString)"
        return (server, AnswerLog(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    private func waitForEntry(_ log: AnswerLog, _ key: AnswerKey, file: StaticString = #filePath, line: UInt = #line) -> AnswerEntry? {
        let logged = expectation(for: NSPredicate { _, _ in log.entry(for: key) != nil }, evaluatedWith: nil)
        wait(for: [logged], timeout: 10)
        return log.entry(for: key)
    }

    @MainActor
    func testBannerButtonAndBannerReplyWriteTheAnswerLog() throws {
        let (server, log, suite) = try answerFixture()
        defer { server.stop(); UserDefaults().removePersistentDomain(forName: suite) }
        let button = Action(id: UUID().uuidString, action: "http", label: "Approve", url: "http://127.0.0.1:\(server.port)/answers",
                            method: "POST", headers: nil, body: "reply:r1:approve", clear: nil)
        let replyAction = reply("http://127.0.0.1:\(server.port)/answers")
        for (action, text, sequence) in [(button, nil, "ask-1"), (replyAction, "Ship it", "ask-2")] as [(Action, String?, String)] {
            let info: [AnyHashable: Any] = ["id": UUID().uuidString, "time": "1700000000", "event": "message", "topic": "answers-fixture",
                                            "base_url": "https://agents.example", "sequence_id": sequence, "message": "Deploy?",
                                            "actions": String(decoding: try JSONEncoder().encode([action]), as: UTF8.self)]
            let delegate = AppDelegate()
            delegate.answerLog = log
            delegate.beginNotificationBackgroundTask = { _ in UIBackgroundTaskIdentifier(rawValue: 48) }
            delegate.endNotificationBackgroundTask = { _ in }
            let done = expectation(description: "completed")
            delegate.handleNotificationResponse(userInfo: info, actionIdentifier: action.id,
                                                notificationId: UUID().uuidString, userText: text) { done.fulfill() }
            wait(for: [done], timeout: 10)
            let key = AnswerKey(baseUrl: "https://agents.example", topic: "answers-fixture", sequence: sequence)
            let entry = try XCTUnwrap(waitForEntry(log, key))
            XCTAssertEqual(entry.kind, text == nil ? .tap : .reply)
            XCTAssertEqual(entry.label, action.label)
            XCTAssertEqual(entry.text, text)
            XCTAssertTrue(entry.ok)
        }
    }

    func testInAppAnswerWritesTheAnswerLogAndAFailureIsNotAnAnswer() throws {
        let (server, log, suite) = try answerFixture()
        defer { server.stop(); UserDefaults().removePersistentDomain(forName: suite) }
        let store = Store(inMemory: true, credentialStore: InMemoryCredentialStore())
        store.saveNotificationRetention(.forever)
        let subscription = store.saveSubscription(baseUrl: "https://agents.example", topic: "in-app")
        let good = Action(id: UUID().uuidString, action: "http", label: "Approve", url: "http://127.0.0.1:\(server.port)/answers",
                          method: "POST", headers: nil, body: "reply:r1:approve", clear: nil)
        // Nothing listens on port 9: the request fails and must not read as answered.
        let bad = Action(id: UUID().uuidString, action: "http", label: "Reject", url: "http://127.0.0.1:9/answers",
                         method: "POST", headers: nil, body: "reply:r2:reject", clear: nil)
        _ = store.save(notificationsFromMessages: [
            Message(id: "m1", time: 1_800_000_000, event: "message", topic: "in-app", message: "Deploy?", actions: [good], sequenceID: "q1"),
            Message(id: "m2", time: 1_800_000_001, event: "message", topic: "in-app", message: "Wipe?", actions: [bad], sequenceID: "q2"),
        ], withSubscription: subscription)
        let request = ntfy.Notification.fetchRequest() as NSFetchRequest<ntfy.Notification>
        request.sortDescriptors = [NSSortDescriptor(key: "time", ascending: true)]
        let rows = try store.context.fetch(request)
        XCTAssertEqual(rows.count, 2)
        for (row, action, ok) in [(rows[0], good, true), (rows[1], bad, false)] {
            let key = try XCTUnwrap(AnswerKey(notification: row))
            MessageActionRunner(notification: row, openURL: { _ in }, answerLog: log).run(action)
            XCTAssertTrue(log.isSending(key) || log.entry(for: key) != nil, "the tap shows Sending at once")
            let entry = try XCTUnwrap(waitForEntry(log, key))
            XCTAssertEqual(entry.kind, .tap)
            XCTAssertEqual(entry.label, action.label)
            XCTAssertEqual(entry.ok, ok)
        }
    }
}
