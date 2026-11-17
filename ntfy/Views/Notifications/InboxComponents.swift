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
        MessageDisplay.of(title: formatTitle(), body: agentSettle?.question ?? formatMessage(), contentType: contentType)
    }

    /// The question re-sent by ntf 0.1/0.2 to settle it: no buttons, the outcome line appended.
    var agentSettle: AgentAck.Settle? {
        guard (actions ?? "").isEmpty || actions == "[]" else { return nil }
        return AgentAck.settle(body: formatMessage(), tags: parseAllTags(tags), hasActions: false)
    }

    /// The fine print under a picture: "87 KB · expires Nov 26". Name first on the page.
    func attachmentFinePrint(includeName: Bool) -> String? {
        guard let attachment = messageAttachment() else { return nil }
        var parts: [String] = []
        if includeName { parts.append(attachment.displayName()) }
        if let size = attachment.size, size > 0 { parts.append(formatBytes(size)) }
        if let expires = attachment.expires {
            let date = Date(timeIntervalSince1970: TimeInterval(expires))
            if date > Date() {
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

struct TopicAvatar: View {
    let name: String
    var iconUrl: URL? = nil
    var size: CGFloat = 40

    private var letter: String {
        name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "#"
    }

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
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
            .foregroundStyle(.secondary)
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

/// Where a question stands for this device: being sent, answered, or failed to reach the agent.
struct AnswerState: Equatable {
    var entry: AnswerEntry?
    var sendingActionId: String?

    init(entry: AnswerEntry?, sendingActionId: String?) {
        self.entry = entry
        self.sendingActionId = sendingActionId
    }

    init(notification: Notification, log: AnswerLog) {
        let key = AnswerKey(notification: notification)
        entry = log.entry(for: key)
        sendingActionId = log.sendingActionId(key)
    }

    var sending: Bool { sendingActionId != nil }
    /// Only a request that reached the agent shows a check. "Not needed" isn't an answer.
    var answered: Bool { !sending && entry?.ok == true && entry?.kind != .dismissed }
    var failed: Bool { !sending && entry?.ok == false }

    /// How long a button that just sent its answer shows its check before the receipt takes its place.
    /// A Debug launch argument (`-ntfyDebugSentHold <seconds>`) holds it longer for screenshots.
    static var sentHold: TimeInterval {
        #if DEBUG
        let debug = UserDefaults.standard.double(forKey: "ntfyDebugSentHold")
        if debug > 0 { return debug }
        #endif
        return 1.3
    }

    /// The answer just landed: its button still shows the check, and the receipt waits.
    func showsSent(now: Date = Date()) -> Bool {
        guard answered, let entry else { return false }
        return now.timeIntervalSince(entry.at) < Self.sentHold
    }

    /// Answered, and past the moment of the check: show the receipt.
    func showsReceipt(now: Date = Date()) -> Bool { answered && !showsSent(now: now) }

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

/// After answering: what you told the agent, or that it didn't get it (DECISION change 8: a
/// failure never shows a check).
struct AnswerReceiptView: View {
    /// "You" answered: the page's up-arrow, never the agent's green check (VERDICT-ack-48 M1).
    static let answeredIcon = "arrow.up.circle.fill"

    var entry: AnswerEntry? = nil
    var failed = false
    /// The answer that didn't get through, so the error names it: the buttons themselves look idle again.
    var failedLabel: String? = nil

    static func failedText(_ label: String?) -> String {
        if let label, !label.isEmpty { return String(localized: "\(label) didn't reach the agent. Try again.") }
        return String(localized: "Didn't reach the agent. Try again.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if failed {
                // The same line as the answered receipt: icon on the text edge, 6 pt from the words.
                // A Label here took the list's icon column (21.7 pt gap, DESIGN-REVIEW F3).
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
                    Text(Self.failedText(failedLabel)).foregroundColor(.primary)
                }
                .font(.footnote)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("answer-failed")
            } else if let entry, entry.ok, entry.kind != .dismissed {
                let time = Notification.shortTime(for: entry.at)
                // Not a Label: it centres the icon on a two-line title; the arrow belongs on the first line.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: Self.answeredIcon).foregroundColor(InboxColor.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        (entry.kind == .tap ? Text("You answered \(Text(entry.label).fontWeight(.semibold)) · \(time)")
                                            : Text("You replied · \(time)"))
                            .foregroundColor(.primary)
                        if let text = entry.text, !text.isEmpty {
                            Text(text).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                }
                .font(.footnote)
                .accessibilityIdentifier("answer-receipt")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    /// The person's answer here, when it reached the agent.
    var answer: AnswerEntry?
    /// The answer as the ack or settle names it, for a question answered on another device.
    var namedAnswer: String?
    /// The agent's side. Nil without an ack, and with "Show agent confirmations" off.
    var agent: Agent?
    /// Acked or settled: the question is done and takes no more answers, whatever the setting.
    var resolved: Bool

    init(notification: Notification, log: AnswerLog, acks: AckLog = .shared, shows: Bool) {
        let key = AnswerKey(notification: notification)
        var entry = log.entry(for: key)
        var agent: Agent?
        var named: String?
        if let key, let record = acks.record(forKey: key.id, version: key.version) {
            agent = .got(Date(timeIntervalSince1970: TimeInterval(record.time)), note: record.note)
            named = record.answer
        } else if let settle = notification.agentSettle {
            // The settle replaced the question's row, so the answer was logged on the version before it.
            entry = entry ?? key.flatMap { log.entry(for: AnswerKey(baseUrl: $0.baseUrl, topic: $0.topic, sequence: $0.sequence)) }
            switch settle.outcome {
            case .got(let label): agent = .got(notification.date(), note: nil); named = label
            case .movedOn: agent = .movedOn(notification.date())
            }
        }
        answer = entry.flatMap { $0.ok && $0.kind != .dismissed ? $0 : nil }
        namedAnswer = named
        resolved = agent != nil
        self.agent = shows ? agent : nil
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

/// The message page's receipt (ACK-SPEC): a two-step timeline under the question. First what you
/// answered, then that the agent got it, with its note.
struct AgentReceiptTimeline: View {
    @Environment(\.sizeCategory) private var sizeCategory
    let receipt: AgentReceipt

    /// The agent's note is its only content and has nowhere else to be read, so it shows in full; the
    /// person's own reply keeps a limit (VERDICT 48b).
    static func detailLineLimit(id: String) -> Int? { id == "receipt-agent" ? nil : 4 }

    /// At accessibility sizes the time takes its own line, so "·" never wraps alone (S4).
    private var stacksTime: Bool { sizeCategory.isAccessibilityCategory }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let answer = receipt.answer {
                let time = Notification.shortTime(for: answer.at)
                let label = Text(answer.label).fontWeight(.semibold)
                let title: Text = answer.kind == .tap
                    ? (stacksTime ? Text("You answered \(label)") : Text("You answered \(label) · \(time)"))
                    : (stacksTime ? Text("You replied") : Text("You replied · \(time)"))
                step(icon: AnswerReceiptView.answeredIcon, tint: InboxColor.ink, title: title, time: stacksTime ? time : nil,
                     detail: answer.kind == .reply ? answer.text : nil, connects: receipt.agent != nil, id: "receipt-you")
            } else if let named = receipt.namedStep {
                step(icon: AnswerReceiptView.answeredIcon, tint: InboxColor.ink,
                     title: Text("Answered \(Text(named).fontWeight(.semibold))"), time: nil,
                     detail: nil, connects: receipt.agent != nil, id: "receipt-named")
            }
            switch receipt.agent {
            case .got(let at, let note):
                let time = Notification.shortTime(for: at)
                step(icon: "checkmark.circle.fill", tint: InboxColor.agentGot,
                     title: stacksTime ? Text("Agent got it") : Text("Agent got it · \(time)"), time: stacksTime ? time : nil,
                     detail: note, connects: false, id: "receipt-agent")
            case .movedOn(let at):
                let time = Notification.shortTime(for: at)
                step(icon: "clock", tint: .secondary,
                     title: stacksTime ? Text("Agent stopped waiting") : Text("Agent stopped waiting · \(time)"),
                     time: stacksTime ? time : nil, detail: nil, connects: false, id: "receipt-moved-on", quiet: true)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(icon: String, tint: Color, title: Text, time: String?, detail: String?, connects: Bool, id: String,
                      quiet: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundColor(tint)
                    .accessibilityHidden(true)
                if connects {
                    Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.subheadline.weight(quiet ? .regular : .medium))
                    .foregroundColor(quiet ? .secondary : .primary)
                if let time {
                    Text(time).font(.subheadline).foregroundColor(.secondary)
                }
                if let detail, !detail.isEmpty {
                    // The agent's note is its only content, so it reads as primary text (S2); the
                    // person's own typed reply stays secondary.
                    Text(detail).font(.subheadline).foregroundColor(id == "receipt-agent" ? .primary : .secondary)
                        .lineLimit(Self.detailLineLimit(id: id))
                        .accessibilityIdentifier(id == "receipt-agent" ? "receipt-note" : "receipt-text")
                }
            }
            .padding(.bottom, connects ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// The list card's receipt (ACK-SPEC): one line, "Agent got it · <answer> · time".
struct AgentReceiptLine: View {
    let receipt: AgentReceipt

    var body: some View {
        switch receipt.agent {
        case .got(let at, _):
            let time = Notification.shortTime(for: at)
            Label {
                (receipt.answerText.map { Text("Agent got it · \(Text($0).fontWeight(.semibold)) · \(time)") }
                     ?? Text("Agent got it · \(time)"))
                    .foregroundColor(.primary)
                    .lineLimit(2)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundColor(InboxColor.agentGot)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("card-agent-got")
        case .movedOn(let at):
            Label(String(localized: "Agent stopped waiting · \(Notification.shortTime(for: at))"), systemImage: "clock")
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("card-agent-moved-on")
        case nil:
            EmptyView()
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
                items.append(.link(action))
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
        _ = ActionExecutor.execute(
            action,
            notificationId: notification.id,
            baseUrl: notification.subscription?.baseUrl,
            openURL: openURL,
            replyText: replyText,
            answer: AnswerKey(notification: notification),
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

    var body: some View {
        if let attachment = notification.messageAttachment() {
            VStack(alignment: .leading, spacing: 6) {
                NotificationAttachmentSectionView(
                    notification: notification,
                    attachment: attachment,
                    authorizationHeader: authorizationHeader,
                    controller: controller,
                    onOpen: { presentation = .init(url: $0, mode: .preview) },
                    onShare: { presentation = .init(url: $0, mode: .share) },
                    onSave: { url in Task { @MainActor in NotificationRowView.AttachmentExportPresenter.shared.present(url: url) } },
                    onCopy: onCopy
                )
                .padding(.top, -8)
                .environment(\.attachmentImageMaxHeight, maxHeight)
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

    private var showsUnread: Bool { !notification.read || heldUnread }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    UIPasteboard.general.setValue(notification.shareText, forPasteboardType: UTType.plainText.identifier)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCopy()
                } label: {
                    Label(String(localized: "Copy text"), systemImage: AppSymbol.copyText)
                }
                if #available(iOS 16.0, *) {
                    ShareLink(item: notification.shareText) {
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
        let state = AnswerState(notification: notification, log: log)
        let receipt = AgentReceipt(notification: notification, log: log, acks: acks, shows: showsAcks)
        let items = ActionBarItem.items(actions: notification.answerableActions(), click: nil, context: .card)
        VStack(alignment: .leading, spacing: CardSpacing.line) {
            if showsTopic, let subscription = notification.subscription {
                HStack(spacing: 8) {
                    TopicAvatar(name: subscription.shortDisplayName(), iconUrl: notification.iconUrl(), size: 24)
                    Text(subscription.shortDisplayName())
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
            if receipt.agent != nil {
                AgentReceiptLine(receipt: receipt).padding(.top, CardSpacing.beforeControls)
            } else if state.showsReceipt() {
                AnswerReceiptView(entry: state.entry).padding(.top, CardSpacing.beforeControls)
            } else if receipt.showsClosed {
                // Confirmations are off: the agent got it, so the question takes no more answers.
                ReceiptClosedLine(receipt: receipt).padding(.top, CardSpacing.beforeControls)
            } else if defersToWaiting && waiting.contains(notification) {
                Label(String(localized: "Waiting on you"), systemImage: "hand.raised.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(InboxColor.ink)
                    .accessibilityIdentifier("card-waiting-line")
                    .padding(.top, CardSpacing.beforeControls)
            } else if !items.isEmpty {
                if state.failed {
                    AnswerReceiptView(failed: true, failedLabel: state.failedLabel).padding(.top, CardSpacing.beforeControls)
                }
                ActionBar(items: items, prominentId: prominentId(items), sendingId: state.sendingActionId,
                          sentLabel: state.sentLabel(), failedLabel: state.failedLabel,
                          recipient: notification.subscription?.shortDisplayName(), run: run)
                    // While selecting, a tap picks the row; it must not answer the agent.
                    .disabled(editing)
                    .environment(\.actionBarMissedTap) { if !editing { open(false) } }
                    .padding(.top, state.failed ? 0 : CardSpacing.beforeControls)
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
        let state = AnswerState(notification: notification, log: log)
        let items = ActionBarItem.items(actions: notification.answerableActions(), click: nil, context: .waiting)
        let display = notification.display
        VStack(alignment: .leading, spacing: CardSpacing.line) {
            HStack(spacing: 8) {
                let name = notification.subscription?.shortDisplayName() ?? ""
                TopicAvatar(name: name, iconUrl: notification.iconUrl(), size: 24)
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
            if receipt.agent != nil {
                AgentReceiptLine(receipt: receipt).padding(.top, CardSpacing.beforeControls)
            } else if state.showsReceipt() {
                AnswerReceiptView(entry: state.entry).padding(.top, CardSpacing.beforeControls)
            } else if receipt.showsClosed {
                ReceiptClosedLine(receipt: receipt).padding(.top, CardSpacing.beforeControls)
            } else if !receipt.resolved {
                if state.failed {
                    AnswerReceiptView(failed: true, failedLabel: state.failedLabel).padding(.top, CardSpacing.beforeControls)
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
