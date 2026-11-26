// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import UIKit
import XCTest
@testable import ntfy

/// What the share sheet hands out for a topic, the app and a message.
final class ShareSheetTests: XCTestCase {
    private func hosted(encrypted: Bool = false, needsLogin: Bool = false,
                        auth: PublishCommand.Auth = .none) -> ShareContent.Topic {
        ShareContent.topic(baseUrl: "https://ntfy-me.com", topic: "alerts-abc", displayName: "Alerts",
                           encrypted: encrypted, needsLogin: needsLogin, auth: auth)!
    }

    // MARK: Topic link

    func testTheBuiltInServersLinkIsTheNtfAiUniversalLink() {
        let topic = hosted()
        XCTAssertEqual(topic.link, "https://ntf-ai.app/alerts-abc")
        XCTAssertEqual(TopicLink(url: URL(string: topic.link)!), TopicLink(scanned: "https://ntfy-me.com/alerts-abc"),
                       "the link must open this topic in the app")
        XCTAssertEqual(topic.link, TopicQRCode.payload(baseUrl: "https://ntfy-me.com", topic: "alerts-abc"),
                       "the shared link and the QR code are one address")
    }

    func testASelfHostedTopicSharesItsOwnServersAddress() {
        let topic = ShareContent.topic(baseUrl: "https://ntfy.home.io/", topic: "garage", displayName: "garage",
                                       encrypted: false, needsLogin: false)!
        XCTAssertEqual(topic.link, "https://ntfy.home.io/garage")
        XCTAssertTrue(topic.curl!.hasSuffix(" 'https://ntfy.home.io/garage'"), topic.curl!)
        XCTAssertEqual(topic.ntf, "ntf send --server 'https://ntfy.home.io' --topic 'garage' 'Hello from NTF-AI'")
    }

    func testAServerWithAPathPrefixKeepsItInTheNtfServer() {
        let topic = ShareContent.topic(baseUrl: "http://lan.box:8080/ntfy", topic: "t", displayName: "t",
                                       encrypted: false, needsLogin: false)!
        XCTAssertEqual(topic.link, "http://lan.box:8080/ntfy/t")
        XCTAssertEqual(topic.ntf, "ntf send --server 'http://lan.box:8080/ntfy' --topic 't' 'Hello from NTF-AI'")
    }

    func testAnUnsafeServerAddressSharesNothing() {
        XCTAssertNil(ShareContent.topic(baseUrl: "https://user:pw@ntfy.home.io", topic: "t", displayName: "t",
                                        encrypted: false, needsLogin: false),
                     "a base URL with credentials in it must never become a shared link")
        XCTAssertNil(ShareContent.topic(baseUrl: "ftp://ntfy.home.io", topic: "t", displayName: "t",
                                        encrypted: false, needsLogin: false))
    }

    // MARK: Commands

    func testTheHostedNtfCommandLeavesOutTheDefaultServer() {
        XCTAssertEqual(hosted().ntf, "ntf send --topic 'alerts-abc' 'Hello from NTF-AI'")
        XCTAssertEqual(hosted().curl, "curl -d 'Hello from NTF-AI' 'https://ntf-ai.app/alerts-abc'")
    }

    func testAnEncryptedTopicHasNoCurlAndItsNtfCommandFailsWithoutThePassword() {
        let topic = hosted(encrypted: true)
        XCTAssertNil(topic.curl, "curl would send plaintext to an encrypted topic")
        XCTAssertEqual(topic.ntf, "ntf send --topic 'alerts-abc' --password-env NTF_TOPIC_PASSWORD 'Hello from NTF-AI'")
    }

    func testCredentialsNeverReachTheSharedTextOrCommands() {
        let auth = PublishCommand.Auth(username: "phil", accessToken: true, headerNames: ["X-Secret"])
        let topic = hosted(needsLogin: true, auth: auth)
        for text in [topic.text, topic.words, topic.title, topic.link] {
            XCTAssertFalse(text.contains("phil"), text)
            XCTAssertFalse(text.contains("X-Secret"), text)
            XCTAssertFalse(text.contains("Bearer"), text)
        }
        XCTAssertTrue(topic.text.contains(String(localized: "This server needs a login.")), topic.text)
        XCTAssertFalse(topic.ntf.contains("--user") || topic.ntf.contains("--token"), topic.ntf)
        // The copied curl names what it needs and holds no secret value.
        let curl = topic.curl!
        XCTAssertTrue(curl.contains("--user 'phil'") && !curl.contains("phil:"), curl)
        XCTAssertTrue(curl.contains("Bearer <token>") && curl.contains("X-Secret: <value>"), curl)
    }

    // MARK: Text

    func testTheTopicTextInvitesThenLinksThenNotes() {
        let plain = hosted()
        XCTAssertEqual(plain.text, "Subscribe to “Alerts” in NTF-AI or any ntfy app.\nhttps://ntf-ai.app/alerts-abc")
        XCTAssertEqual(plain.words, "Subscribe to “Alerts” in NTF-AI or any ntfy app.")
        let encrypted = hosted(encrypted: true)
        let lines = encrypted.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], "https://ntf-ai.app/alerts-abc")
        XCTAssertTrue(lines[2].contains("end-to-end encrypted"), lines[2])
        XCTAssertFalse(encrypted.link.contains("#") || encrypted.link.contains("?"),
                       "no key or password rides in the link: \(encrypted.link)")
    }

    func testCopyGetsOneStringAirDropOnlyTheLinkMessagesBoth() {
        XCTAssertEqual(ShareContent.textRoute(for: .copyToPasteboard), .fullText)
        XCTAssertFalse(ShareContent.sendsLinkItem(for: .copyToPasteboard))
        XCTAssertEqual(ShareContent.textRoute(for: .airDrop), .nothing)
        XCTAssertTrue(ShareContent.sendsLinkItem(for: .airDrop))
        XCTAssertEqual(ShareContent.textRoute(for: .message), .wordsOnly)
        XCTAssertTrue(ShareContent.sendsLinkItem(for: .message))
    }

    func testTheTextItemServesEachActivityItsPart() {
        let topic = hosted()
        let item = ShareTextItem(words: topic.words, fullText: topic.text, link: URL(string: topic.link), title: topic.title)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertEqual(item.activityViewController(controller, itemForActivityType: .copyToPasteboard) as? String, topic.text)
        XCTAssertEqual(item.activityViewController(controller, itemForActivityType: .mail) as? String, topic.words)
        XCTAssertNil(item.activityViewController(controller, itemForActivityType: .airDrop))
        XCTAssertEqual(item.activityViewController(controller, subjectForActivityType: .mail), "Subscribe to Alerts")
        let link = ShareLinkItem(url: URL(string: topic.link)!)
        XCTAssertNil(link.activityViewController(controller, itemForActivityType: .copyToPasteboard))
        XCTAssertEqual(link.activityViewController(controller, itemForActivityType: .message) as? URL, URL(string: topic.link))
        XCTAssertEqual(item.activityViewControllerLinkMetadata(controller)?.url, URL(string: topic.link))
        XCTAssertNil(item.activityViewControllerLinkMetadata(controller)?.iconProvider, "the icon is the thumbnail, not a favicon")
    }

    func testTheTopicShareOffersCopyCommandsOnlyWhereTheyWork() {
        let plain = ShareRequest.topic(hosted()).activities.map { $0.activityType?.rawValue }
        XCTAssertEqual(plain, ["app.ntfai.copy-curl", "app.ntfai.copy-ntf"])
        let encrypted = ShareRequest.topic(hosted(encrypted: true)).activities.map { $0.activityType?.rawValue }
        XCTAssertEqual(encrypted, ["app.ntfai.copy-ntf"])
    }

    func testTheCopyActivityPutsItsCommandOnThePasteboard() {
        // No read of the old contents first: reading another app's copy shows the paste prompt and stalls.
        let activity = CopyTextActivity(type: "app.ntfai.copy-ntf", title: "Copy ntf command", symbol: "terminal",
                                        text: hosted().ntf)
        XCTAssertTrue(activity.canPerform(withActivityItems: []))
        XCTAssertEqual(CopyTextActivity.activityCategory, .action)
        activity.perform()
        XCTAssertEqual(UIPasteboard.general.string, hosted().ntf)
    }

    // MARK: App

    func testTheAppShareLinksTheSite() {
        let request = ShareRequest.app()
        XCTAssertEqual((request.items.last as? ShareLinkItem)?.url, URL(string: "https://ntf-ai.app"))
        let text = request.items.first as? ShareTextItem
        XCTAssertEqual(text?.words, ShareContent.appMessage)
        XCTAssertEqual(text?.fullText, ShareContent.appMessage + "\nhttps://ntf-ai.app")
    }

    // MARK: Message

    func testAMessageSharesTitleBodyAndClickLink() {
        XCTAssertEqual(ShareContent.message(title: "Deploy done", body: "All green", click: URL(string: "https://ci.example/42"),
                                            attachmentLink: nil, hasFile: false),
                       "Deploy done\n\nAll green\n\nhttps://ci.example/42")
        XCTAssertEqual(ShareContent.message(title: nil, body: "Just text", click: nil, attachmentLink: nil, hasFile: false),
                       "Just text")
    }

    func testAnAttachmentTravelsAsItsFileOrElseItsLink() {
        let link = "https://ntf-ai.app/file/abc.png"
        XCTAssertEqual(ShareContent.message(title: nil, body: "Screenshot", click: nil, attachmentLink: link, hasFile: false),
                       "Screenshot\n\n" + link)
        XCTAssertEqual(ShareContent.message(title: nil, body: "Screenshot", click: nil, attachmentLink: link, hasFile: true),
                       "Screenshot", "with the file shared, its link would be a duplicate")
        XCTAssertEqual(ShareContent.message(title: nil, body: "x", click: nil, attachmentLink: "javascript:alert(1)", hasFile: false),
                       "x")
    }

    func testAStoredMessageSharesItsDownloadedFile() throws {
        let store = Store(inMemory: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("share-test-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let notification = Notification(context: store.context)
        notification.id = "m1"
        notification.title = "Title"
        notification.message = "Body"
        notification.click = "https://example.com/c"
        notification.attachmentUrl = "https://share-tests.example/file/a.txt"
        notification.attachmentLocalPath = file.path
        let request = try XCTUnwrap(ShareRequest.message(notification))
        let text = try XCTUnwrap(request.items.first as? ShareTextItem)
        XCTAssertEqual(text.words, "Title\n\nBody\n\nhttps://example.com/c")
        XCTAssertEqual(text.title, "Title", "the sheet's header names the message, not the file")
        XCTAssertEqual(request.items.last as? URL, file)
        notification.attachmentLocalPath = nil
        XCTAssertEqual(ShareRequest.message(notification)?.items.count, 1, "no file: the link rides in the text")
    }
}
