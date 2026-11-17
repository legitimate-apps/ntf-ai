import XCTest
import UserNotifications
@testable import ntfy

/// NTF-AI 1.27 finish round: click URLs, the fallback for a question this build can't render, the
/// typed-answer copy, and the What's New and Licenses entries.
final class AnswerFinishTests: XCTestCase {
    // MARK: click URLs

    func testATappedNotificationOpensOnlyWebAndComposerLinks() {
        for open in ["https://example.com/pr/1", "HTTP://example.com", "mailto:ops@example.com", "tel:+15551234567", "sms:+15551234567",
                     "  https://example.com  "] {
            XCTAssertNotNil(ClickURL.url(from: open), open)
        }
        for refused in ["shortcuts://run-shortcut?name=Wipe", "file:///etc/hosts", "javascript:alert(1)", "prefs:root=General",
                        "itms-services://?action=download-manifest&url=https://x", "https://", "", "   "] {
            XCTAssertNil(ClickURL.url(from: refused), refused)
        }
        XCTAssertNil(ClickURL.url(from: nil))
    }

    /// A `view` button opens with one tap too, so it gets the click URL's allowlist: the executor
    /// refuses the rest, and neither the action bar nor the banner offers a button that won't open.
    func testAViewActionOpensOnlyWhatATappedNotificationWould() {
        func view(_ url: String) -> Action {
            Action(id: "view-\(UUID().uuidString)", action: "view", label: "Open", url: url,
                   method: nil, headers: nil, body: nil, clear: nil)
        }
        let open = ["https://example.com/pr/1", "mailto:ops@example.com", "tel:+15551234567", "sms:+15551234567"]
        let refused = ["shortcuts://run-shortcut?name=Wipe", "file:///etc/hosts", "javascript:alert(1)",
                       "prefs:root=General", "https://", ""]
        for url in open + refused {
            var opened: [URL] = []
            ActionExecutor.execute(view(url), openURL: { opened.append($0) })
            XCTAssertEqual(opened.count, open.contains(url) ? 1 : 0, url)
        }
        let copy = Action(id: "c1", action: "copy", label: "Copy", url: nil, method: nil, headers: nil, body: nil, clear: nil, value: "x")
        let actions = [view("https://example.com"), view("shortcuts://run-shortcut?name=Wipe"), copy, view("file:///etc/hosts")]
        XCTAssertEqual(ActionBarItem.items(actions: actions, click: nil, context: .card).map(\.label), ["Open", "Copy"])
        XCTAssertEqual(UNMutableNotificationContent.bannerActions(actions).map(\.id), [actions[0].id, "c1"])
    }

    // MARK: a question this build can't render

    func testAQuestionThisBuildCantRenderDropsOnlyItsAnswerInNTFAILink() {
        let carrier = Action(id: "ask", action: "view", label: "Answer in NTF-AI",
                             url: "https://ntf-ai.app/docs/agents#ask-v2=eyJ2IjozfQ", method: nil, headers: nil, body: nil, clear: nil)
        let old = Action(id: "h1", action: "http", label: "Canary", url: "https://ntfy-me.com/deploys-answers",
                         method: "POST", headers: nil, body: "reply:q7:canary", clear: nil)
        let pr = Action(id: "v1", action: "view", label: "Open PR", url: "https://github.com/x/y/pull/1",
                        method: nil, headers: nil, body: nil, clear: nil)
        let shown = AskSchema.shownActions([carrier, old, pr], detection: .unsupported(carrier: "ask"),
                                           sequence: "q7", topicURL: "https://ntfy-me.com/deploys")
        XCTAssertEqual(shown.map(\.id), ["h1", "v1"])
        // A message with no ask-v2 link keeps everything.
        XCTAssertEqual(AskSchema.shownActions([old, pr], detection: .none, sequence: "q7", topicURL: nil).map(\.id), ["h1", "v1"])
    }

    // MARK: copy

    func testTheMultipleChoiceHintReadsAsOneRange() {
        XCTAssertEqual(AskMultiChoice.rangeText(min: 1, max: 2), "Choose up to 2")
        XCTAssertEqual(AskMultiChoice.rangeText(min: 0, max: 3), "Choose up to 3")
        XCTAssertEqual(AskMultiChoice.rangeText(min: 2, max: 2), "Choose 2")
        XCTAssertEqual(AskMultiChoice.rangeText(min: 2, max: 3), "Choose 2 to 3")
    }

    func testATimeQuestionIsNotCalledADate() {
        XCTAssertEqual(AskDateRow.modeLabel(.date), "Date")
        XCTAssertEqual(AskDateRow.modeLabel(.time), "Time")
        XCTAssertEqual(AskDateRow.modeLabel(.datetime), "Date and time")
    }
}

/// The Licenses screen leads with NTF-AI's own GPL-3.0 entry, Legitimate LLC as the copyright holder.
final class ThisAppLicenseTests: XCTestCase {
    func testTheAppsOwnGPLEntryLeadsTheLicenses() throws {
        let first = try XCTUnwrap(OpenSourceLicenses.components.first)
        XCTAssertTrue(first.isThisApp)
        XCTAssertEqual(first.name, "NTF-AI")
        XCTAssertEqual(first.licenseName, "GNU General Public License v3.0")
        XCTAssertTrue(first.fullText.contains("Copyright \u{00A9} 2026 Legitimate LLC"))
        XCTAssertTrue(first.fullText.contains("GNU GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(first.fullText.contains("END OF TERMS AND CONDITIONS"))
        XCTAssertEqual(OpenSourceLicenses.components.filter(\.isThisApp).count, 1)
        // The upstream MIT notice stays, as a project the app builds on.
        XCTAssertFalse(try XCTUnwrap(OpenSourceLicenses.components.first { $0.name == "ntfy for iOS" }).isThisApp)
    }
}
