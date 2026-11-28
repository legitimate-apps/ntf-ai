// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import CoreData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The parts every message surface shares (DIRECTIONS 1.5): Inbox rows, topic cards, the message
// page and search results. One family, so the same question reads the same wherever it shows.

/// Answer buttons and Send draw from `AnswerColor` (AnswerButton.swift).
enum InboxColor {
    /// Links, the unread dot, "Show more", the waiting mark: the app tint.
    static let ink = Color("AccentColor")
    /// "Agent got it": blue, the iOS colour for delivered and read, so it never looks like the person's own
    /// answer, which wears the emerald accent (design review 2026-11-15: two greens measured 1.05:1 in dark).
    static let agentGot = Color(uiColor: agentGotUIColor)
    static let agentGotUIColor = UIColor.systemBlue
}

// MARK: - Text

/// What a message shows as its headline and its body. A message without a title lends its first
/// line to the headline, so every card leads with something in the same place.
struct MessageDisplay: Equatable {
    var title: String?
    var body: String
    var markdown: Bool

    /// A body this short and on one line reads as a headline.
    static let headlineLength = 120

    static func of(title rawTitle: String?, body rawBody: String, contentType: String?) -> MessageDisplay {
        let markdown = contentType == "text/markdown"
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawTitle, !rawTitle.isEmpty {
            return MessageDisplay(title: rawTitle, body: body, markdown: markdown)
        }
        if let newline = body.firstIndex(of: "\n") {
            let first = String(body[..<newline]).trimmingCharacters(in: .whitespaces)
            let rest = String(body[body.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !first.isEmpty, first.count <= headlineLength, !first.hasPrefix("```") {
                return MessageDisplay(title: markdown ? headingText(first) : first, body: rest, markdown: markdown)
            }
            return MessageDisplay(title: nil, body: body, markdown: markdown)
        }
        if body.count <= headlineLength {
            return MessageDisplay(title: markdown ? headingText(body) : body, body: "", markdown: markdown)
        }
        return MessageDisplay(title: nil, body: body, markdown: markdown)
    }

    /// "## What I found" as a headline is "What I found".
    static func headingText(_ line: String) -> String {
        guard let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { return line }
        return String(line[range.upperBound...])
    }

    var titleText: AttributedString? {
        guard let title else { return nil }
        if markdown, let parsed = try? AttributedString(markdown: title, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return parsed
        }
        return AttributedString(title)
    }

    /// The body for a card: Markdown headings become bold lines, since a card has no room for a
    /// heading's size and must not show the raw `##`.
    var cardBody: AttributedString {
        guard markdown else { return renderMessageBody(body, contentType: nil) }
        let lines = body.components(separatedBy: "\n").map { line -> String in
            guard let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { return line }
            return "**" + line[range.upperBound...] + "**"
        }
        return renderMessageBody(lines.joined(separator: "\n"), contentType: "text/markdown")
    }
}

extension Notification {
    var display: MessageDisplay {
        // An old full settle shows the question as it was; its appended line becomes the receipt.
        // A typed question drops the plain-text hint `ntf` added for older apps (SPEC 2).
        // An answer whose question is gone (expired, cleared) keeps its row, in words, never raw JSON.
        if AnswerMessage.answeredSequence(tags: parseAllTags(tags)) != nil {
            return MessageDisplay.of(title: formatTitle(), body: AnswerMessage.readable(formatMessage()), contentType: nil)
        }
        return MessageDisplay.of(title: formatTitle(),
                                 body: agentSettle?.question ?? AskSchema.strippingHint(formatMessage(), hint: askDetection.schema?.hint),
                                 contentType: contentType)
    }

    /// The question re-sent by ntf 0.1/0.2 to settle it: no buttons, the outcome line appended.
    var agentSettle: AgentAck.Settle? {
        guard (actions ?? "").isEmpty || actions == "[]" else { return nil }
        return AgentAck.settle(body: formatMessage(), tags: parseAllTags(tags), hasActions: false)
    }

    /// The fine print under a picture: "87 KB · expires Nov 26". Name first on the page. A link that
    /// expires today shows the time: on ntf-ai.app files last 3 hours, and "expires Nov 24" read on
    /// Nov 24 doesn't say the picture is gone by the afternoon.
    func attachmentFinePrint(includeName: Bool, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let attachment = messageAttachment() else { return nil }
        var parts: [String] = []
        if includeName { parts.append(attachment.displayName()) }
        if let size = attachment.size, size > 0 { parts.append(formatBytes(size)) }
        if let expires = attachment.expires {
            let date = Date(timeIntervalSince1970: TimeInterval(expires))
            if date > now, calendar.isDate(date, inSameDayAs: now) {
                let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
                parts.append(String(localized: "expires at \(time)", comment: "Attachment fine print: a time later today"))
            } else if date > now {
                let day = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
                parts.append(String(localized: "expires \(day)"))
            } else {
                parts.append(String(localized: "expired"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The text to copy or share: title, then body.
    var shareText: String {
        [formatTitle(), formatMessage()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

// MARK: - Small parts

/// Monogram circles: a light tint outside, the letter in the dark of the same colour (operator,
/// 2026-11-17: "the light part is on the outside and dark part is the text inside"). The agent's is
/// the secondary answer button's Forest tint and label; a topic's is the same inversion in grey, so
/// both read as one family. Each letter clears 4.5:1 on its own fill over the row backgrounds
/// (`ThemeColorTests`). A picture, when there is one, covers the circle.
enum MonogramColor {
    static let agentFill = "AnswerTint"
    static let agentLetter = "AnswerTintLabel"
    static let topicFill = "MonogramTint"
    static let topicLetter = "MonogramInk"
}

struct TopicAvatar: View {
    let name: String
    var iconUrl: URL? = nil
    var size: CGFloat = 40

    private var letter: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(MonogramColor.topicFill))
            if let iconUrl {
                AsyncImage(url: iconUrl) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    monogram
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        Text(letter)
            .font(size <= 28 ? .caption.weight(.semibold) : .title3.weight(.semibold))
            .foregroundColor(Color(MonogramColor.topicLetter))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(size <= 28 ? 2 : 4)
    }
}

struct PriorityMark: View {
    let priority: Int16

    var body: some View {
        if priority == 5 {
            Image(systemName: "exclamationmark.2").foregroundColor(.red)
                .accessibilityLabel(String(localized: "Urgent"))
        } else if priority == 4 {
            Image(systemName: "exclamationmark").foregroundColor(.orange)
                .accessibilityLabel(String(localized: "High priority"))
        }
    }
}

/// Priority, then the title with its emoji tags in front (DIRECTIONS 1.5).
struct MessageTitleLine: View {
    @Environment(\.sizeCategory) private var sizeCategory
    @ObservedObject var notification: Notification
    var font: Font = .headline
    var lineLimit: Int? = 2

    /// The text after the priority mark. The emoji tags are already at its front: the title comes from
    /// formatTitle(), or from formatMessage() when there is none, and both put them there. Drawing them
    /// again here showed every tagged message as, for example, two check marks.
    static func text(for notification: Notification) -> AttributedString? {
        notification.display.titleText
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            PriorityMark(priority: notification.priority)
            if let title = Self.text(for: notification) {
                // At accessibility sizes a title wraps in full instead of truncating.
                Text(title).lineLimit(sizeCategory.isAccessibilityCategory ? nil : lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(font)
        .foregroundColor(.primary)
    }
}

struct TagLine: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            Text(tags.joined(separator: " · "))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

struct DayHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.secondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A day label as a list row: plain words, no fold. It scrolls away with its rows (see `ListHeaderRow`).
struct DayHeaderRow: View {
    let day: Date

    var body: some View {
        DayHeader(title: Notification.daySectionTitle(for: day))
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .modifier(ListHeaderRow())
    }
}

struct UnreadDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(InboxColor.ink).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Body text capped at `lines`, reporting whether the cap cut it short so the card can offer
/// "Show more". The full text is laid out hidden at the same width to compare heights.
struct LineCappedText: View {
    let text: AttributedString
    let lines: Int
    var color: Color = .primary
    @Binding var truncated: Bool

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundColor(color)
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { capped in
                Text(text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: capped.size.width, alignment: .leading)
                    .hidden()
                    .background(GeometryReader { full in
                        Color.clear.preference(key: TruncationKey.self, value: full.size.height > capped.size.height + 1)
                    })
            })
            .onPreferenceChange(TruncationKey.self) { truncated = $0 }
    }
}

private struct TruncationKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// MARK: - Answers

/// Where a message's buttons stand for this device: being sent, just sent, answered, or failed.
struct AnswerState: Equatable {
    var entry: AnswerEntry?
    var sendingActionId: String?
    /// An agent's question takes one answer and then shows it (`showsReceipt`). Any other message
    /// (`false`) gets its buttons back after the check, to press again (operator, 2026-11-18).
    var locks: Bool

    init(entry: AnswerEntry?, sendingActionId: String?, locks: Bool = true) {
        self.entry = entry
        self.sendingActionId = sendingActionId
        self.locks = locks
    }

    init(notification: Notification, log: AnswerLog, acks: AckLog = .shared) {
        let key = AnswerKey(notification: notification)
        entry = log.entry(for: key, seen: acks)
        sendingActionId = log.sendingActionId(key)
        locks = notification.locksAfterAnswer
    }

    var sending: Bool { sendingActionId != nil }
    /// Only a request that reached the server shows a check. "Not needed" isn't an answer.
    var answered: Bool { !sending && entry?.ok == true && entry?.kind != .dismissed }
    var failed: Bool { !sending && entry?.ok == false }

    /// How long a button that just sent its answer shows its check before the answered state takes its place.
    /// A Debug launch argument (`-ntfyDebugSentHold <seconds>`) holds it longer for screenshots.
    static var sentHold: TimeInterval {
        #if DEBUG
        let debug = UserDefaults.standard.double(forKey: "ntfyDebugSentHold")
        if debug > 0 { return debug }
        #endif
        return 1.3
    }

    /// How long the check shows. A repeatable button keeps it until `ActionExecutor` would run the
    /// same button again: back any sooner, a second press would be dropped as a double tap.
    static func hold(locks: Bool) -> TimeInterval {
        locks ? sentHold : max(sentHold, ActionExecutor.repeatTapWindow)
    }

    /// The answer just landed: its button still shows the check, and the answered state waits.
    func showsSent(now: Date = Date()) -> Bool {
        guard answered, let entry else { return false }
        return now.timeIntervalSince(entry.at) < Self.hold(locks: locks)
    }

    /// An agent's question, answered, past the moment of the check: the answer takes the buttons'
    /// place. Never on a repeatable message, whose buttons always come back.
    func showsReceipt(now: Date = Date()) -> Bool { locks && answered && !showsSent(now: now) }

    /// The tapped answer showing its check, by label.
    func sentLabel(now: Date = Date()) -> String? {
        showsSent(now: now) && entry?.kind == .tap ? entry?.label : nil
    }

    /// The tapped answer that didn't reach the agent, by label.
    var failedLabel: String? { failed && entry?.kind == .tap ? entry?.label : nil }

    /// The typed reply's phase, for its Send button. `replyActionId` is the question's own reply
    /// action, when it has one; a reply without one goes out as `AgentReply`.
    func replyPhase(replyActionId: String?, now: Date = Date()) -> AnswerPhase {
        if let sendingActionId {
            return sendingActionId == AgentReply.sendingId || sendingActionId == replyActionId ? .sending : .idle
        }
        if showsSent(now: now) && entry?.kind == .reply { return .sent }
        if failed && entry?.kind == .reply { return .failed }
        return .idle
    }
}

/// A send that didn't get through (DECISION change 8: a failure never shows a check). On an agent's
/// question it names the agent; on any other message the button simply didn't go through.
struct AnswerFailedLine: View {
    /// The answer that didn't get through, so the error names it: the buttons themselves look idle again.
    var failedLabel: String? = nil
    /// An agent's question (`AnswerState.locks`), or a plain message's repeatable button.
    var toAgent = true

    static func failedText(_ label: String?, toAgent: Bool = true) -> String {
        if let label, !label.isEmpty {
            return toAgent ? String(localized: "\(label) didn't reach the agent. Try again.")
                           : String(localized: "\(label) didn't go through. Try again.")
        }
        return toAgent ? String(localized: "Didn't reach the agent. Try again.") : String(localized: "Didn't go through. Try again.")
    }

    var body: some View {
        // Icon on the text edge, 6 pt from the words. A Label here took the list's icon column
        // (21.7 pt gap, DESIGN-REVIEW F3).
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
            Text(Self.failedText(failedLabel, toAgent: toAgent)).foregroundColor(.primary)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("answer-failed")
    }
}

/// The receipt on an agent's question (ACK-SPEC): the person's answer on this device, then the
/// agent's confirmation, from its ack or from an old full settle. Built from what the app already
/// has; the agent never sends the question again.
struct AgentReceipt: Equatable {
    enum Agent: Equatable {
        case got(Date, note: String?)
        /// No answer came in time, or the agent stopped waiting: quieter than a confirmation.
        case movedOn(Date)
        /// `ntf withdraw` took the question back (SPEC 7). Shown whatever the confirmations setting.
        case withdrawn(Date)
    }

    /// The person's answer here, when it reached the agent.
    var answer: AnswerEntry?
    /// The answer as the ack or settle names it, for a question answered on another device.
    var namedAnswer: String?
    /// When that answer was seen on the topic, if it was.
    var namedAt: Date?
    /// The agent's side. Nil without an ack, and with "Show agent confirmations" off.
    var agent: Agent?
    /// Acked or settled: the question is done and takes no more answers, whatever the setting.
    var resolved: Bool

    init(notification: Notification, log: AnswerLog, acks: AckLog = .shared, shows: Bool) {
        let key = AnswerKey(notification: notification)
        var entry = log.entry(for: key, seen: acks)
        var agent: Agent?
        var named: String?
        if let key, let record = acks.record(forKey: key.id, version: key.version) {
            let at = Date(timeIntervalSince1970: TimeInterval(record.time))
            agent = record.withdrawn == true ? .withdrawn(at) : .got(at, note: record.note)
            named = record.answer
        } else if let settle = notification.agentSettle {
            // The settle replaced the question's row, so the answer was logged on the version before it.
            entry = entry ?? key.flatMap { log.entry(for: AnswerKey(baseUrl: $0.baseUrl, topic: $0.topic, sequence: $0.sequence)) }
            switch settle.outcome {
            case .got(let label): agent = .got(notification.date(), note: nil); named = label
            case .movedOn: agent = .movedOn(notification.date())
            }
        }
        if let seen = entry, seen.seen == true {
            // Seen on the topic, not made here: the page names it, it doesn't claim it was you.
            named = named ?? (seen.kind == .tap ? seen.label : seen.text)
            namedAt = seen.at
            entry = nil
        }
        answer = entry.flatMap { $0.ok && $0.kind != .dismissed ? $0 : nil }
        namedAnswer = named
        resolved = agent != nil
        if case .withdrawn = agent { self.agent = agent } else { self.agent = shows ? agent : nil }
    }

    /// What the card names as the answer: the button, the typed text, or what the agent says it got.
    var answerText: String? {
        if let answer {
            if answer.kind == .tap { return answer.label }
            if let text = answer.text, !text.isEmpty { return "\u{201C}\(text)\u{201D}" }
        }
        return namedAnswer
    }

    /// The page's first step when this device has no answer but the ack names one (M2): it may
    /// have come from another device or a compose reply, so it never says where.
    var namedStep: String? { answer == nil ? namedAnswer : nil }

    /// Resolved with nothing else to show (confirmations off, no answer here): the question's own
    /// state as one quiet "Closed" line, never a dead end (M3).
    var showsClosed: Bool { resolved && answer == nil && agent == nil }
}

/// "Closed", or "Closed · <answer>" when the ack named one (M3).
struct ReceiptClosedLine: View {
    let receipt: AgentReceipt
    var font: Font = .footnote

    var body: some View {
        Label {
            if let named = receipt.namedAnswer {
                Text("Closed · \(named)")
            } else {
                Text("Closed")
            }
        } icon: {
            Image(systemName: "checkmark")
        }
        .font(font)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("receipt-closed")
    }
}

/// An answered agent question, the same on the card, in Waiting on you and on the page
/// (operator, 2026-11-18: the old "You answered Approve" line read as a copy of the button just
/// pressed). The chosen answer stays where the buttons were, as the selected choice with a check;
/// beside it, quietly, what happened to it: "Sent · 11:31 AM", then "Agent got it · 11:32 AM"
/// with the agent's note. Each thing is said once.
struct AnswerSummary: Equatable {
    enum Choice: Equatable {
        /// A button (or a typed pick) chosen on this device: shown as the selected choice.
        case picked(String)
        /// A written reply or form sent from this device: its words.
        case replied(String)
        /// An answer seen on the topic or named by the agent, which may not have come from this
        /// device: "Answered X", never claimed as yours.
        case named(String, at: Date?)
    }

    enum Status: Equatable {
        /// The server accepted the answer (not yet the agent's word).
        case sent(Date)
        case replySent(Date)
        case agentGot(Date, note: String?)
        case movedOn(Date)
        case withdrawn(Date)

        var isAgent: Bool {
            switch self {
            case .sent, .replySent: return false
            case .agentGot, .movedOn, .withdrawn: return true
            }
        }
    }

    var choice: Choice?
    /// Yours first (sent), then the agent's, oldest first.
    var statuses: [Status]

    init(choice: Choice?, statuses: [Status]) {
        self.choice = choice
        self.statuses = statuses
    }

    init(receipt: AgentReceipt) {
        var statuses: [Status] = []
        if let answer = receipt.answer {
            if answer.kind == .tap {
                choice = .picked(answer.label)
                statuses.append(.sent(answer.at))
            } else {
                let text = answer.text ?? ""
                choice = text.isEmpty ? nil : .replied(text)
                statuses.append(.replySent(answer.at))
            }
        } else if let named = receipt.namedAnswer, !named.isEmpty {
            choice = .named(named, at: receipt.namedAt)
        } else {
            choice = nil
        }
        switch receipt.agent {
        case .got(let at, let note): statuses.append(.agentGot(at, note: note))
        case .movedOn(let at): statuses.append(.movedOn(at))
        case .withdrawn(let at): statuses.append(.withdrawn(at))
        case nil: break
        }
        self.statuses = statuses
    }

    var isEmpty: Bool { choice == nil && statuses.isEmpty }

    /// The status's words without its time, for large text sizes where the time takes its own line.
    static func title(_ status: Status) -> String {
        switch status {
        case .sent: return String(localized: "Sent")
        case .replySent: return String(localized: "Reply sent")
        case .agentGot: return String(localized: "Agent got it")
        case .movedOn: return String(localized: "Agent stopped waiting")
        case .withdrawn: return String(localized: "Withdrawn by the agent")
        }
    }

    /// The status's line: "Sent · 11:31 AM", "Agent got it · 11:32 AM".
    static func text(_ status: Status) -> String {
        switch status {
        case .sent(let at): return String(localized: "Sent · \(Notification.shortTime(for: at))")
        case .replySent(let at): return String(localized: "Reply sent · \(Notification.shortTime(for: at))")
        case .agentGot(let at, _): return String(localized: "Agent got it · \(Notification.shortTime(for: at))")
        case .movedOn(let at): return String(localized: "Agent stopped waiting · \(Notification.shortTime(for: at))")
        case .withdrawn(let at): return String(localized: "Withdrawn by the agent · \(Notification.shortTime(for: at))")
        }
    }

    static func time(_ status: Status) -> Date {
        switch status {
        case .sent(let at), .replySent(let at), .agentGot(let at, _), .movedOn(let at), .withdrawn(let at): return at
        }
    }

    /// What VoiceOver reads for the chosen answer.
    static func spokenChoice(_ choice: Choice) -> String {
        switch choice {
        case .picked(let label): return String(localized: "Your answer: \(label)")
        case .replied(let text): return String(localized: "Your reply: \(text)")
        case .named(let label, _): return String(localized: "Answered \(label)")
        }
    }
}

/// Draws an `AnswerSummary`. On a card the agent's note is held to a few lines; on the page it
/// shows in full, since it has nowhere else to be read (VERDICT 48b).
struct AnsweredView: View {
    enum Place { case card, page }

    /// The selected choice's check: a plain check in the answer's own Forest. The agent's word
    /// keeps the green filled check (VERDICT-ack-48 M1), so the two never read as one.
    static let choiceIcon = "checkmark"
    static let agentIcon = "checkmark.circle.fill"

    static func noteLineLimit(_ place: Place) -> Int? { place == .page ? nil : 3 }
    static func replyLineLimit(_ place: Place) -> Int { place == .page ? 6 : 3 }

    let summary: AnswerSummary
    var place: Place = .card

    @Environment(\.sizeCategory) private var sizeCategory
    /// At accessibility sizes the time takes its own line, so "·" never wraps alone (S4).
    private var stacksTime: Bool { sizeCategory.isAccessibilityCategory }
    private var font: Font { place == .page ? .subheadline : .footnote }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let mine = summary.statuses.filter { !$0.isAgent }
            let agent = summary.statuses.filter(\.isAgent)
            if summary.choice != nil || !mine.isEmpty {
                choiceRow(status: mine.first)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(place == .page ? "receipt-you" : "answer-receipt")
            }
            ForEach(Array(agent.enumerated()), id: \.offset) { _, status in
                agentLine(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The answer

    @ViewBuilder private func choiceRow(status: AnswerSummary.Status?) -> some View {
        switch summary.choice {
        case .picked(let label):
            // The chip and its status side by side when they fit, else the status under it.
            if #available(iOS 16.0, *), !stacksTime {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 10) { chip(label); status.map(quietLine).fixedSize() }
                    VStack(alignment: .leading, spacing: 6) { chip(label); status.map(quietLine) }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) { chip(label); status.map(quietLine) }
            }
        case .replied(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(font)
                    .foregroundColor(.primary)
                    .lineLimit(Self.replyLineLimit(place))
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(AnswerColor.tintLabel.opacity(0.55)).frame(width: 3)
                    }
                    .accessibilityLabel(AnswerSummary.spokenChoice(.replied(text)))
                status.map(quietLine)
            }
        case .named(let label, let at):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.choiceIcon).font(font.weight(.bold)).foregroundColor(AnswerColor.tintLabel)
                    .accessibilityHidden(true)
                // Seen on the topic or named by the agent, not made here: it may not have been you.
                let named = Text("Answered \(Text(label).fontWeight(.semibold))")
                ((at.map { named + Text(verbatim: " · \(Notification.shortTime(for: $0))") }) ?? named)
                    .font(font)
                    .foregroundColor(.primary)
            }
        case nil:
            status.map(quietLine)
        }
    }

    /// The chosen answer: the selected, non-tappable choice, in the answer's Forest wash with a check.
    /// It hugs its label, so it reads as a value, not as a full-width button to press again.
    private func chip(_ label: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return HStack(spacing: 6) {
            Image(systemName: Self.choiceIcon).font(font.weight(.bold)).accessibilityHidden(true)
            Text(label).font(font.weight(.semibold)).lineLimit(2)
        }
        .foregroundColor(AnswerColor.tintLabel)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(shape.fill(AnswerColor.tint))
        .overlay(shape.strokeBorder(AnswerColor.tintLabel.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AnswerSummary.spokenChoice(.picked(label)))
        .accessibilityIdentifier("answer-chosen")
    }

    /// Your side: quiet, secondary.
    private func quietLine(_ status: AnswerSummary.Status) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stacksTime ? AnswerSummary.title(status) : AnswerSummary.text(status))
            if stacksTime { Text(Notification.shortTime(for: AnswerSummary.time(status))) }
        }
        .font(font)
        // Quieter than the chip, still 4.5:1 at footnote size: .secondary measured 3.45:1 on white.
        .foregroundColor(Color.primary.opacity(0.62))
        .accessibilityIdentifier("answer-status")
    }

    // MARK: The agent's side

    @ViewBuilder private func agentLine(_ status: AnswerSummary.Status) -> some View {
        let got: Bool = { if case .agentGot = status { return true } else { return false } }()
        let icon: String = {
            switch status {
            case .agentGot: return Self.agentIcon
            case .movedOn: return "clock"
            default: return "arrow.uturn.backward.circle"
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundColor(got ? InboxColor.agentGot : .secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stacksTime ? AnswerSummary.title(status) : AnswerSummary.text(status))
                    .fontWeight(got ? .medium : .regular)
                    .foregroundColor(got ? .primary : .secondary)
                if stacksTime { Text(Notification.shortTime(for: AnswerSummary.time(status))).foregroundColor(.secondary) }
                if case .agentGot(_, let note) = status, let note, !note.isEmpty {
                    // The agent's note is its only content, so it reads as primary text (S2).
                    Text(note).foregroundColor(.primary)
                        .lineLimit(Self.noteLineLimit(place))
                        .accessibilityIdentifier("receipt-note")
                }
            }
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(Self.agentIdentifier(status, place: place))
    }

    /// The identifiers UI tests look for, kept from 1.26.
    static func agentIdentifier(_ status: AnswerSummary.Status, place: Place) -> String {
        switch status {
        case .agentGot: return place == .page ? "receipt-agent" : "card-agent-got"
        case .movedOn: return place == .page ? "receipt-moved-on" : "card-agent-moved-on"
        case .withdrawn: return place == .page ? "receipt-withdrawn" : "card-agent-withdrawn"
        case .sent, .replySent: return "answer-status"
        }
    }
}

/// One button in an action bar: an answer (`http`), a link (`view`, or the message's click URL),
/// a copy, or the reply action shown as a button that opens the page's reply field.
enum ActionBarItem: Identifiable {
    case answer(Action)
    case link(Action)
    case copy(Action)
    case reply(Action)
    case click(URL)

    var id: String {
        switch self {
        case .answer(let a), .link(let a), .copy(let a): return a.id
        case .reply(let a): return "reply-" + a.id
        case .click: return "click"
        }
    }

    var label: String {
        switch self {
        case .answer(let a), .link(let a), .copy(let a): return a.label
        case .reply: return String(localized: "Reply")
        case .click: return String(localized: "Open link")
        }
    }

    enum Context { case waiting, card, page }

    /// Which buttons a surface shows, in the agent's order. In the Inbox's waiting rows only
    /// answers; on cards everything, with the reply as a button; on the page the reply is the
    /// field instead, and the message's click URL joins as a link.
    static func items(actions: [Action], click: URL?, context: Context) -> [ActionBarItem] {
        var items: [ActionBarItem] = []
        for action in actions {
            if BannerReply.destination(for: action) != nil {
                if context != .page { items.append(.reply(action)) }
            } else if action.action == "http" {
                items.append(.answer(action))
            } else if context == .waiting {
                continue
            } else if action.action == "view" {
                if ClickURL.allows(action) { items.append(.link(action)) }
            } else if action.action == "copy" {
                items.append(.copy(action))
            }
        }
        if context == .page, let click { items.append(.click(click)) }
        return items
    }
}

struct ActionBar: View {
    let items: [ActionBarItem]
    /// The first answer of a waiting question is the one prominent button (DIRECTIONS 1.5).
    var prominentId: String? = nil
    /// Answers the agent marked as doing damage: red, never the green fill.
    var destructiveIds: Set<String> = []
    var sendingId: String? = nil
    /// The answer that just reached the agent (`AnswerState.sentLabel`): it shows its check.
    var sentLabel: String? = nil
    /// The answer that didn't reach the agent (`AnswerState.failedLabel`): it shakes once.
    var failedLabel: String? = nil
    /// Who gets the answer, for VoiceOver's hint: "Sends Approve to Coding agent".
    var recipient: String? = nil
    let run: (ActionBarItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func phase(_ item: ActionBarItem) -> AnswerPhase {
        AnswerPhase.of(id: item.id, label: item.label, sendingId: sendingId, sentLabel: item.isAnswer ? sentLabel : nil,
                       failedLabel: item.isAnswer ? failedLabel : nil)
    }

    /// While an answer is on its way or just landed, the other choices fold away.
    private var shown: [ActionBarItem] {
        let active = items.filter { [.sending, .sent].contains(phase($0)) }
        return active.isEmpty ? items : active
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                ViewThatFits(in: .horizontal) {
                    EqualWidthHStack(spacing: 10) { buttons }
                    VStack(spacing: 10) { buttons }
                }
            } else {
                VStack(spacing: 10) { buttons }
            }
        }
        .animation(AnswerMetrics.phaseAnimation(reduceMotion: reduceMotion), value: shown.map(\.id))
    }

    @ViewBuilder private var buttons: some View {
        ForEach(shown) { item in
            let phase = phase(item)
            ActionBarButton(item: item, role: role(item), phase: phase, recipient: recipient) { run(item) }
                .disabled(sendingId != nil && phase != .sending)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    private func role(_ item: ActionBarItem) -> AnswerRole {
        switch item {
        case .answer(let action):
            if destructiveIds.contains(action.id) { return .destructive }
            return item.id == prominentId ? .primary : .secondary
        case .reply: return .secondary
        case .link, .copy, .click: return .link
        }
    }
}

private struct ActionBarMissedTapKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// What a tap near, but outside, an answer button does: the row's own tap (open the message).
    var actionBarMissedTap: (() -> Void)? {
        get { self[ActionBarMissedTapKey.self] }
        set { self[ActionBarMissedTapKey.self] = newValue }
    }
}

private struct ActionBarButton: View {
    let item: ActionBarItem
    let role: AnswerRole
    let phase: AnswerPhase
    var recipient: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.actionBarMissedTap) private var missedTap
    @Environment(\.answerHaptics) private var haptics
    @GestureState private var touching = false
    @State private var tracker = AnswerFeedbackTracker()
    @State private var shakes = 0

    private var label: some View {
        HStack(spacing: 6) {
            if case .reply = item {
                Image(systemName: "arrowshape.turn.up.left").accessibilityHidden(true)
            }
            Text(item.label).lineLimit(1)
            switch item {
            case .link, .click:
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
            default:
                EmptyView()
            }
        }
    }

    private var interactive: Bool { isEnabled && phase != .sending && phase != .sent }

    /// iOS 26 delivers a tap to the nearest small tap target even when the finger lands well
    /// outside it: on iPad a tap on the message text 16 pt above the bar reached the answer button
    /// and answered the agent (build 45; the same with a plain tap gesture in place of the Button).
    /// So the face is only the picture, the tap reports where it landed, and only a tap inside the
    /// button answers. One that lands outside does what the row does there: it opens the message,
    /// which can't send anything. A long press that never completes tracks the finger for the press
    /// look and its tick; it fails as soon as the finger moves, so the list still scrolls.
    var body: some View {
        AnswerButtonFace(role: role, phase: phase, pressed: touching && interactive, shakes: shakes) { label }
            .allowsHitTesting(false)
            .overlay {
                GeometryReader { geometry in
                    let shape = RoundedRectangle(cornerRadius: AnswerMetrics.cornerRadius, style: .continuous)
                    if #available(iOS 16.0, *) {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                if shape.path(in: CGRect(origin: .zero, size: geometry.size)).contains(tap.location) {
                                    fire()
                                } else {
                                    #if DEBUG
                                    NSLog("PROBE answer tap %d,%d outside %dx%d: opens instead", Int(tap.location.x),
                                          Int(tap.location.y), Int(geometry.size.width), Int(geometry.size.height))
                                    #endif
                                    missedTap?()
                                }
                            })
                            .simultaneousGesture(LongPressGesture(minimumDuration: 30, maximumDistance: 10)
                                .updating($touching) { current, state, _ in state = current })
                    } else {
                        Color.clear.contentShape(shape).onTapGesture(perform: fire)
                    }
                }
            }
            .onChange(of: touching) { down in
                if down && interactive { haptics.play(.press) }
            }
            .onChange(of: phase) { next in
                if let feedback = tracker.move(to: next) {
                    haptics.play(feedback)
                    if feedback == .failure { shakes += 1 }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint)
            .accessibilityValue(phase == .sending ? String(localized: "Sending") : phase == .sent ? String(localized: "Sent") : "")
            .accessibilityAction(.default, fire)
    }

    private var hint: String {
        guard item.isAnswer, let recipient, !recipient.isEmpty else { return "" }
        return String(localized: "Sends \(item.label) to \(recipient)")
    }

    private func fire() {
        guard interactive else { return }
        if item.isAnswer { tracker.fired() }
        action()
    }
}

extension ActionBarItem {
    /// An answer to the agent (an `http` button), as opposed to a link, a copy or the reply opener.
    var isAnswer: Bool {
        if case .answer = self { return true }
        return false
    }
}

/// An HStack whose ideal width is the widest child times the count, giving every child the same
/// width, so `ViewThatFits` keeps a row only when every label fits at an equal share.
@available(iOS 16.0, *)
struct EqualWidthHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let count = CGFloat(subviews.count)
        let ideal = (ideals.map(\.width).max() ?? 0) * count + spacing * max(0, count - 1)
        let height = ideals.map(\.height).max() ?? 0
        return CGSize(width: proposal.width ?? ideal, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = CGFloat(subviews.count)
        let width = (bounds.width - spacing * max(0, count - 1)) / max(count, 1)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (width + spacing), y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

/// Runs a message's actions the way both action paths do, logging answers for the receipt and
/// the Waiting rule, and opening links in the in-app browser when that setting is on.
struct MessageActionRunner {
    let notification: Notification
    let openURL: (URL) -> Void
    var onCopy: () -> Void = {}
    var answerLog: AnswerLog = .shared

    func run(_ action: Action, replyText: String? = nil) {
        // A card or page drawn before the question's deadline: past it the tap sends nothing (the
        // agent no longer takes it) and the views redraw to "Expired".
        if AgentQuestion.isAnswerAction(action), notification.isPastDeadline() {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            notification.objectWillChange.send()
            WaitingObservable.shared.refresh()
            return
        }
        _ = ActionExecutor.execute(
            action,
            notificationId: notification.id,
            baseUrl: notification.subscription?.baseUrl,
            openURL: openURL,
            replyText: replyText,
            answer: AnswerKey(notification: notification),
            repeatable: !notification.locksAfterAnswer,
            answerLog: answerLog
        )
        if action.copiesText {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCopy()
        }
    }
}

/// Opens a link as the app's setting says: in the in-app browser, or the default browser.
struct LinkOpener: ViewModifier {
    @Binding var url: URL?

    func body(content: Content) -> some View {
        content.background(InAppBrowser(url: $url))
    }

    static func open(_ target: URL, browserURL: Binding<URL?>, openURL: OpenURLAction) {
        if InAppBrowser.shouldOpen(target, enabled: UserDefaults.standard.bool(forKey: InAppBrowser.preferenceKey)) {
            browserURL.wrappedValue = target
        } else {
            openURL(target)
        }
    }
}

// MARK: - Attachments in cards and on the page

struct MessageAttachmentBlock: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var notification: Notification
    /// 300 pt in cards, 520 pt on the page (DIRECTIONS C5).
    let maxHeight: CGFloat
    var onCopy: () -> Void = {}
    @StateObject private var controller = NotificationAttachmentController()
    @State private var presentation: NotificationRowView.AttachmentPresentation?
    @State private var shareRequest: ShareRequest?

    var body: some View {
        if let attachment = notification.messageAttachment() {
            VStack(alignment: .leading, spacing: 6) {
                NotificationAttachmentSectionView(
                    notification: notification,
                    attachment: attachment,
                    authorizationHeader: authorizationHeader,
                    controller: controller,
                    onOpen: { presentation = .init(url: $0, mode: .preview) },
                    onShare: { shareRequest = .file($0) },
                    onSave: { url in Task { @MainActor in NotificationRowView.AttachmentExportPresenter.shared.present(url: url) } },
                    onCopy: onCopy
                )
                .padding(.top, -8)
                .environment(\.attachmentImageMaxHeight, maxHeight)
                .shareSheet($shareRequest)
                if attachment.isImageAttachment(), notification.attachmentLocalFileUrl() != nil,
                   let fine = notification.attachmentFinePrint(includeName: maxHeight > 300) {
                    Text(fine).font(.footnote).foregroundColor(.secondary)
                }
            }
            .sheet(item: $presentation) { item in
                switch item.mode {
                case .preview: NotificationRowView.AttachmentPreviewView(url: item.url)
                case .share: NotificationRowView.ActivityView(activityItems: [item.url])
                }
            }
        }
    }

    private var authorizationHeader: String? {
        guard let baseUrl = notification.subscription?.baseUrl, let user = store.getBasicUser(baseUrl: baseUrl) else { return nil }
        return user.toHeader()
    }
}

/// A 44 pt rounded thumbnail for the waiting rows: home is a queue, not a gallery (C5).
struct AttachmentThumbnailSmall: View {
    @ObservedObject var notification: Notification
    var size: CGFloat = 44
    @StateObject private var loader = NotificationAttachmentImageLoader()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if let image = loader.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                shape.fill(.quaternary).overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .accessibilityHidden(true)
        .task(id: notification.attachmentLocalFileUrl()?.path) {
            await loader.load(from: notification.attachmentLocalFileUrl())
        }
    }
}

// MARK: - Row menus

/// Long-press and swipes on a message wherever it appears in a list (DIRECTIONS 1.5).
struct MessageRowActions: ViewModifier {
    @EnvironmentObject private var store: Store
    @ObservedObject var notification: Notification
    var heldUnread = false
    var onReleaseHeldUnread: () -> Void = {}
    var onCopy: () -> Void = {}
    @State private var shareRequest: ShareRequest?

    private var showsUnread: Bool { !notification.read || heldUnread }

    func body(content: Content) -> some View {
        content
            .shareSheet($shareRequest)
            .contextMenu {
                Button {
                    UIPasteboard.general.setValue(notification.shareText, forPasteboardType: UTType.plainText.identifier)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCopy()
                } label: {
                    Label(String(localized: "Copy text"), systemImage: AppSymbol.copyText)
                }
                if notification.encryptionState != .locked {
                    Button {
                        shareRequest = .message(notification, onCopied: onCopy)
                    } label: {
                        Label(String(localized: "Share"), systemImage: AppSymbol.share)
                    }
                }
                Button(action: toggleRead) { readLabel(swipe: false) }
                Button(role: .destructive) {
                    store.delete(notification: notification)
                } label: {
                    Label(String(localized: "Delete"), systemImage: AppSymbol.delete())
                }
            }
            .swipeActions(edge: .leading) {
                Button(action: toggleRead) { readLabel(swipe: true) }
                    .tint(Color("BrandControlFill"))
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    store.delete(notification: notification)
                } label: {
                    Label(String(localized: "Delete"), systemImage: AppSymbol.delete(swipe: true))
                }
                .tint(.red)
            }
    }

    private func readLabel(swipe: Bool) -> some View {
        Label(showsUnread ? String(localized: "Mark read") : String(localized: "Mark unread"),
              systemImage: showsUnread ? AppSymbol.markRead(swipe: swipe) : AppSymbol.markUnread(swipe: swipe))
    }

    private func toggleRead() {
        let read = showsUnread
        onReleaseHeldUnread()
        store.setRead(read, forNotification: notification)
    }
}

// MARK: - The card (C2) and the waiting row (C1)

/// The vertical rhythm of a message card (Waiting on you, Activity, a topic's messages, Search), on
/// the 4 pt grid. A card has sections (where it came from, the title, the words, the answers), and
/// the gap between two sections is larger than the lines inside one, so they read apart; the gap
/// between cards is the largest. At 6 pt throughout, the body sat almost on the answer button
/// (operator, 2026-11-16: "our vertical margins between sections is super tight").
enum CardSpacing {
    /// Between the parts of a card's words: title, body, tags, attachment.
    static let line: CGFloat = 8
    /// Added after the source row (agent and time), so it sits 12 above the title.
    static let afterSource: CGFloat = 4
    /// Added above the answers or the receipt, so they sit 16 below the words.
    static let beforeControls: CGFloat = 8
    /// Above and below a card inside its list row: two of these part one card from the next.
    static let rowEdge: CGFloat = 14
    static let rowInsets = EdgeInsets(top: rowEdge, leading: 16, bottom: rowEdge, trailing: 16)

    static var sourceToTitle: CGFloat { line + afterSource }
    static var wordsToControls: CGFloat { line + beforeControls }
    static var betweenCards: CGFloat { rowEdge * 2 }
}

/// A message as a card: the whole short message with its answers in place. Long text stops at
/// eight lines with "Show more", which opens the page. With `showsTopic` (Inbox Activity, Search)
/// a topic line on top says which agent spoke.
struct MessageCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.editMode) private var editMode
    @ObservedObject var notification: Notification
    @ObservedObject private var log = AnswerLog.shared
    @ObservedObject private var acks = AckLog.shared
    @AppStorage(AgentAck.showKey, store: AgentAck.defaults) private var showsAcks = true
    @ObservedObject private var waiting = WaitingObservable.shared
    var showsTopic = false
    /// Inbox Activity: a question already listed in Waiting on you says so instead of showing its
    /// answers a second time on the same screen.
    var defersToWaiting = false
    var heldUnread = false
    let open: (_ focusReply: Bool) -> Void
    var onCopy: () -> Void = {}
    @State private var truncated = false
    @State private var browserURL: URL?

    private var display: MessageDisplay { notification.display }
    private var showsUnread: Bool { !notification.read || heldUnread }

    var body: some View {
        let state = AnswerState(notification: notification, log: log, acks: acks)
        let receipt = AgentReceipt(notification: notification, log: log, acks: acks, shows: showsAcks)
        let detection = notification.askDetection
        let items = ActionBarItem.items(actions: notification.shownActions(detection), click: nil, context: .card)
        VStack(alignment: .leading, spacing: CardSpacing.line) {
            if showsTopic, let subscription = notification.subscription {
                HStack(spacing: 8) {
                    if let agent = notification.agentName {
                        AgentAvatar(notification: notification, name: agent, size: 24)
                    } else {
                        TopicAvatar(name: subscription.shortDisplayName(), iconUrl: notification.iconUrl(), size: 24)
                    }
                    Text(notification.agentName.map { "\($0) · \(subscription.shortDisplayName())" } ?? subscription.shortDisplayName())
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    time
                }
            }
            // At accessibility sizes the time takes its own line so the title keeps the width.
            let timeAbove = !showsTopic && sizeCategory.isAccessibilityCategory
            if timeAbove { time }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showsUnread { UnreadDot().alignmentGuide(.firstTextBaseline) { $0[.bottom] } }
                MessageTitleLine(notification: notification, lineLimit: 2)
                Spacer(minLength: 8)
                if !showsTopic && !timeAbove { time }
            }
            .padding(.top, showsTopic ? CardSpacing.afterSource : 0)
            if !display.body.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    LineCappedText(text: display.cardBody, lines: 8, truncated: $truncated)
                    if truncated {
                        Button(String(localized: "Show more")) { open(false) }
                            .disabled(editing)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(InboxColor.ink)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("card-show-more")
                    }
                }
            }
            if notification.encryptionState == .unencrypted {
                Label(String(localized: "Not encrypted"), systemImage: "lock.open")
                    .font(.footnote).foregroundColor(.orange)
            }
            TagLine(tags: notification.nonEmojiTags())
            MessageAttachmentBlock(notification: notification, maxHeight: 300, onCopy: onCopy)
            if receipt.agent != nil || state.showsReceipt() {
                AnsweredView(summary: AnswerSummary(receipt: receipt)).padding(.top, CardSpacing.beforeControls)
            } else if receipt.showsClosed {
                // Confirmations are off: the agent got it, so the question takes no more answers.
                ReceiptClosedLine(receipt: receipt).padding(.top, CardSpacing.beforeControls)
            } else if defersToWaiting && waiting.contains(notification) {
                Label(String(localized: "Waiting on you"), systemImage: "hand.raised.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(InboxColor.ink)
                    .accessibilityIdentifier("card-waiting-line")
                    .padding(.top, CardSpacing.beforeControls)
            } else if let schema = detection.schema {
                AskStatusLine(notification: notification, detection: detection)
                    .padding(.top, CardSpacing.beforeControls)
                let links = items.filter { !$0.isAnswer }
                if !links.isEmpty { AskLinks(items: links, run: run).disabled(editing) }
                if waiting.contains(notification) {
                    if state.failed { AnswerFailedLine(failedLabel: state.failedLabel) }
                    AskAnswerView(notification: notification, schema: schema, place: .card, disabled: editing,
                                  sending: state.sending, openPage: { open(false) }) { body, summary, written in
                        AgentReply.sendAnswer(body, summary: summary, written: written, to: notification)
                    }
                }
            } else if !items.isEmpty || detection != .none || notification.questionDeadline != nil {
                if detection != .none || notification.questionDeadline != nil {
                    // A typed question this build can't render: the update line, then its old answers
                    // exactly as a 1.26 question shows them (REVIEW MINOR 11, DESIGN-REVIEW-v2 S8).
                    // From 1.33 a question with plain buttons and an `exp-` deadline: "Expires in"
                    // above them, and "Expired" with no answers left once it has passed.
                    AskStatusLine(notification: notification, detection: detection)
                        .padding(.top, CardSpacing.beforeControls)
                }
                if state.failed {
                    AnswerFailedLine(failedLabel: state.failedLabel, toAgent: state.locks).padding(.top, CardSpacing.beforeControls)
                }
                if !items.isEmpty {
                    ActionBar(items: items, prominentId: prominentId(items), sendingId: state.sendingActionId,
                              sentLabel: state.sentLabel(), failedLabel: state.failedLabel,
                              recipient: notification.subscription?.shortDisplayName(), run: run)
                        // While selecting, a tap picks the row; it must not answer the agent.
                        .disabled(editing)
                        .environment(\.actionBarMissedTap) { if !editing { open(false) } }
                        .padding(.top, state.failed || detection != .none || notification.questionDeadline != nil ? 0 : CardSpacing.beforeControls)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !editing { open(false) } }
        .modifier(LinkOpener(url: $browserURL))
        .accessibilityElement(children: .contain)
        .accessibilityValue(showsUnread ? String(localized: "Unread") : "")
        .accessibilityAction(named: Text(String(localized: "Open message"))) { open(false) }
    }

    private var editing: Bool { editMode?.wrappedValue.isEditing == true }

    private var time: some View {
        Text(Notification.shortTime(for: notification.date()))
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func prominentId(_ items: [ActionBarItem]) -> String? {
        guard waiting.contains(notification) else { return nil }
        return items.first { if case .answer = $0 { return true } else { return false } }?.id
    }

    private func run(_ item: ActionBarItem) {
        let runner = MessageActionRunner(notification: notification,
                                         openURL: { LinkOpener.open($0, browserURL: $browserURL, openURL: openURL) },
                                         onCopy: onCopy)
        switch item {
        case .answer(let action), .link(let action), .copy(let action): runner.run(action)
        case .reply: open(true)
        case .click(let url): LinkOpener.open(url, browserURL: $browserURL, openURL: openURL)
        }
    }
}

/// A question in Waiting on you: which agent asks, how long it has waited, the question, and
/// its answers. Links are left to the page; here every button is an answer.
struct WaitingRow: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var notification: Notification
    @ObservedObject private var log = AnswerLog.shared
    @ObservedObject private var acks = AckLog.shared
    @AppStorage(AgentAck.showKey, store: AgentAck.defaults) private var showsAcks = true
    let open: (_ focusReply: Bool) -> Void
    var now = Date()
    @State private var browserURL: URL?

    var body: some View {
        let state = AnswerState(notification: notification, log: log, acks: acks)
        let detection = notification.askDetection
        let items = ActionBarItem.items(actions: notification.shownActions(detection), click: nil, context: .waiting)
        let display = notification.display
        VStack(alignment: .leading, spacing: CardSpacing.line) {
            HStack(spacing: 8) {
                let name = notification.agentName ?? notification.subscription?.shortDisplayName() ?? ""
                if let agent = notification.agentName {
                    AgentAvatar(notification: notification, name: agent, size: 24)
                } else {
                    TopicAvatar(name: name, iconUrl: notification.iconUrl(), size: 24)
                }
                Text(name).font(.subheadline.weight(.semibold)).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(WaitedTime.text(since: notification.date(), now: now))
                    .font(.subheadline).foregroundColor(.secondary).lineLimit(1).fixedSize()
                    .accessibilityLabel(String(localized: "Waiting \(WaitedTime.text(since: notification.date(), now: now, style: .full))"))
                    .accessibilityIdentifier("waiting-time")
                if notification.messageAttachment()?.isImageAttachment() == true {
                    AttachmentThumbnailSmall(notification: notification)
                }
            }
            MessageTitleLine(notification: notification, lineLimit: 2)
                .padding(.top, CardSpacing.afterSource)
            if !display.body.isEmpty {
                Text(display.cardBody).font(.body).foregroundColor(.secondary).lineLimit(3)
            }
            let receipt = AgentReceipt(notification: notification, log: log, acks: acks, shows: showsAcks)
            if receipt.agent != nil || state.showsReceipt() {
                AnsweredView(summary: AnswerSummary(receipt: receipt)).padding(.top, CardSpacing.beforeControls)
            } else if receipt.showsClosed {
                ReceiptClosedLine(receipt: receipt).padding(.top, CardSpacing.beforeControls)
            } else if !receipt.resolved, let schema = detection.schema {
                if state.failed { AnswerFailedLine(failedLabel: state.failedLabel) }
                AskStatusLine(notification: notification, detection: detection, now: now)
                AskAnswerView(notification: notification, schema: schema, place: .card, sending: state.sending,
                              openPage: { open(false) }) { body, summary, written in
                    AgentReply.sendAnswer(body, summary: summary, written: written, to: notification)
                }
                .environment(\.actionBarMissedTap) { open(false) }
            } else if !receipt.resolved {
                if detection != .none || notification.questionDeadline != nil {
                    // Needs a newer app: say so above the old answers (DESIGN-REVIEW-v2 S8). From 1.33,
                    // or the deadline an `exp-` tag gives a question with plain buttons.
                    AskStatusLine(notification: notification, detection: detection, now: now)
                }
                if state.failed {
                    AnswerFailedLine(failedLabel: state.failedLabel, toAgent: state.locks).padding(.top, CardSpacing.beforeControls)
                }
                ActionBar(items: items, prominentId: items.first(where: \.isAnswer)?.id, sendingId: state.sendingActionId,
                          sentLabel: state.sentLabel(), failedLabel: state.failedLabel,
                          recipient: notification.subscription?.shortDisplayName()) { item in
                    switch item {
                    case .answer(let action):
                        MessageActionRunner(notification: notification,
                                            openURL: { LinkOpener.open($0, browserURL: $browserURL, openURL: openURL) }).run(action)
                    case .reply: open(true)
                    default: break
                    }
                }
                .environment(\.actionBarMissedTap) { open(false) }
                .padding(.top, state.failed ? 0 : CardSpacing.beforeControls)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(false) }
        .modifier(LinkOpener(url: $browserURL))
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(String(localized: "Open message"))) { open(false) }
    }
}

/// The waiting section's header: the hand, the words, and the count.
struct WaitingHeader: View {
    let count: Int
    @Environment(\.foldHeaderAction) private var headerAction

    var body: some View {
        HStack {
            Label {
                Text(String(localized: "Waiting on you")).foregroundColor(.primary)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundColor(InboxColor.ink)
            }
            Spacer()
            Text(count.formatted()).foregroundColor(.secondary)
        }
        .font(.headline)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("waiting-header")
        .modifier(FoldHeaderActionModifier(action: headerAction))
    }
}

/// A notification-style empty screen that works back to iOS 15: symbol, title, one line, and an
/// optional prominent button.
struct InboxEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionIdentifier = "empty-action"
    var action: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    if let actionTitle {
                        Button(actionTitle, action: action)
                            .brandProminentButton()
                            .padding(.top, 4)
                            .accessibilityIdentifier(actionIdentifier)
                    }
                }
                .padding(40)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
    }
}

/// Pushes a message page from a list without a visible link: the card's own tap sets `opened`.
struct OpenedMessage: Equatable {
    let notification: Notification
    var focusReply = false
}

struct MessagePageLink: ViewModifier {
    @Binding var opened: OpenedMessage?

    func body(content: Content) -> some View {
        content.background(
            NavigationLink(isActive: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
                if let opened {
                    MessagePageView(notification: opened.notification, focusReply: opened.focusReply)
                }
            } label: {
                EmptyView()
            }
            .hidden()
        )
    }
}

/// Runs `action` once no navigation controller in the app is mid-transition (polled every 0.1 s,
/// at most 3 s), for a push that must follow another programmatic push.
enum NavigationSettle {
    /// Polls every 0.1 s for up to `tries` polls. A push started inside a running transition is
    /// popped again by SwiftUI, so when the transition never ends the action is dropped rather than
    /// cut in: the person can still open the message from the list.
    static func after(_ action: @escaping () -> Void, tries: Int = 100) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let roots = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).compactMap(\.rootViewController)
            let busy = roots.flatMap(navigationControllers).contains { $0.transitionCoordinator != nil }
            if !busy { action() } else if tries > 0 { after(action, tries: tries - 1) }
        }
    }

    private static func navigationControllers(in controller: UIViewController) -> [UINavigationController] {
        var found = (controller as? UINavigationController).map { [$0] } ?? []
        for child in controller.children { found += navigationControllers(in: child) }
        if let presented = controller.presentedViewController { found += navigationControllers(in: presented) }
        return found
    }
}

/// On a wide screen (iPad) a card list keeps a readable measure, about as wide as the message
/// page, centred; on iPhone the list keeps its own margins.
struct ReadableCardWidth: ViewModifier {
    @State private var width: CGFloat = 0
    /// The message page's width, so every list and page on iPad shares one measure.
    private static let measure: CGFloat = 680

    func body(content: Content) -> some View {
        let side: CGFloat? = width > Self.measure + 40 ? (width - Self.measure) / 2 : nil
        if #available(iOS 17.0, *) {
            content
                .contentMargins(.horizontal, side, for: .scrollContent)
                .background(GeometryReader { Color.clear.preference(key: ListWidthKey.self, value: $0.size.width) })
                .onPreferenceChange(ListWidthKey.self) { width = $0 }
        } else {
            content
        }
    }
}

private struct ListWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Plain lists

/// A message row in a plain list: the card's own vertical breathing room, and the system's
/// horizontal margin, so the words line up with the large title and the section headers on one
/// leading edge (16 pt on most phones, 20 pt on the widest). Before iOS 26 a row can't set only
/// its vertical insets, so the margin is spelled out as UIKit picks it.
struct CardRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .listRowInsets(.vertical, CardSpacing.rowEdge)
                .modifier(SeparatorAtTextEdge())
        } else {
            content
                .listRowInsets(CardSpacing.rowInsets)
                .modifier(SeparatorAtTextEdge())
        }
    }
}

/// The hairline between two rows starts where the words start, as in Mail. SwiftUI would otherwise
/// start it at the first SwiftUI `Text` it finds, which in a card is the agent's name after its avatar.
private struct SeparatorAtTextEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } else {
            content
        }
    }
}

// MARK: - Folding sections

/// A list header (a folding section header or a day label) as a row rather than a section header: a plain list pins its
/// headers while scrolling, and on iOS 26 a pinned header has no fill, so the rows scrolled through
/// its words. As a row it scrolls away with its section, as Mail's rows do. No hairline above or
/// below it; `topSpace` opens the break between sections.
struct ListHeaderRow: ViewModifier {
    var topSpace: CGFloat = 0

    func body(content: Content) -> some View {
        let row = content.padding(.top, topSpace).listRowSeparator(.hidden)
        if #available(iOS 26.0, *) {
            row.listRowInsets(.vertical, 0)
        } else {
            row.listRowInsets(EdgeInsets(top: 0, leading: CardSpacing.rowInsets.leading, bottom: 0,
                                         trailing: CardSpacing.rowInsets.trailing))
        }
    }
}

/// The list sections the person folded away, kept per section across launches. Only the two Inbox
/// sections fold; day labels are plain words (lead review, 2026-11-17: two chevrons in a row were
/// the extra UI the operator asked to remove).
final class SectionFold: ObservableObject {
    static let shared = SectionFold()
    static let storageKey = "sectionFold.collapsed"

    static let waiting = "inbox.waiting"
    static let activity = "inbox.activity"

    @Published private(set) var collapsed: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    func toggle(_ id: String) { setCollapsed(id, !isCollapsed(id)) }

    func setCollapsed(_ id: String, _ value: Bool) {
        if value { collapsed.insert(id) } else { collapsed.remove(id) }
        defaults.set(collapsed.sorted(), forKey: Self.storageKey)
    }
}

/// What VoiceOver hears for a folding header: its title (with the count, when it has one) as a
/// header button whose value says whether the section is open.
struct FoldHeaderAccessibility: Equatable {
    let label: String
    let value: String
    let traits: AccessibilityTraits
    /// The smallest height of the header's tap target, from the HIG.
    static let minimumHitHeight: CGFloat = 44

    init(title: String, count: Int?, collapsed: Bool) {
        label = count.map { "\(title), \($0.formatted())" } ?? title
        value = collapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        traits = [.isHeader, .isButton]
    }
}

/// A named VoiceOver action for the header's own button, set by a section that offers one
/// (`ClearWaitingMenu`), so it stays on the element VoiceOver lands on.
struct FoldHeaderAction {
    let name: String
    let run: () -> Void
}

private struct FoldHeaderActionKey: EnvironmentKey {
    static let defaultValue: FoldHeaderAction? = nil
}

extension EnvironmentValues {
    var foldHeaderAction: FoldHeaderAction? {
        get { self[FoldHeaderActionKey.self] }
        set { self[FoldHeaderActionKey.self] = newValue }
    }
}

/// Adds the section's named action, when it has one, so a header without one gets no empty action.
struct FoldHeaderActionModifier: ViewModifier {
    let action: FoldHeaderAction?
    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(named: Text(action.name)) { action.run() }
        } else {
            content
        }
    }
}

/// A section header that folds its section: tap it to hide or show the rows under it. The chevron
/// turns as it does; under Reduce Motion it cross-fades instead. A count stays in view while the
/// section is folded. An `accessory` (Waiting on you's "…") sits just left of the count (operator,
/// 2026-11-25: "move this to the left of the dropdowns"); the title side and the count side both
/// fold, and VoiceOver hears one header button, then the accessory.
struct FoldHeader: View {
    @ObservedObject var fold: SectionFold = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.foldHeaderAction) private var headerAction
    let id: String
    let title: String
    var symbol: String? = nil
    var count: Int? = nil
    var identifier: String? = nil
    var accessory: AnyView? = nil

    var body: some View {
        let collapsed = fold.isCollapsed(id)
        let a11y = FoldHeaderAccessibility(title: title, count: count, collapsed: collapsed)
        HStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol).foregroundColor(InboxColor.ink)
                    }
                    Text(title).foregroundColor(.primary)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: FoldHeaderAccessibility.minimumHitHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11y.label)
            .accessibilityValue(a11y.value)
            .accessibilityAddTraits(a11y.traits)
            .accessibilityIdentifier(identifier ?? id)
            .modifier(FoldHeaderActionModifier(action: headerAction))
            if let accessory { accessory }
            Button(action: toggle) {
                HStack(spacing: 8) {
                    if let count {
                        Text(count.formatted()).foregroundColor(.secondary)
                    }
                    chevron(collapsed: collapsed)
                }
                .padding(.leading, 8)
                .frame(minHeight: FoldHeaderAccessibility.minimumHitHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .font(.headline)
        .textCase(nil)
    }

    private func toggle() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.9)) { fold.toggle(id) }
    }

    @ViewBuilder private func chevron(collapsed: Bool) -> some View {
        let font = Font.footnote.weight(.semibold)
        if reduceMotion {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(font).foregroundColor(.secondary)
                .frame(width: 16)
                .id(collapsed)
                .transition(.opacity)
        } else {
            Image(systemName: "chevron.down")
                .font(font).foregroundColor(.secondary)
                .frame(width: 16)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
        }
    }
}
