import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One message in full (DIRECTIONS A3/A4/A5, C3/C4/C5): title, time and tags, the whole body,
/// the picture, and the answers pinned under the thumb however long the message is.
struct MessagePageView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openURL) private var openURL
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.sizeCategory) private var sizeCategory
    @ObservedObject var notification: Notification
    var focusReply = false
    @ObservedObject private var log = AnswerLog.shared
    @ObservedObject private var acks = AckLog.shared
    @AppStorage(AgentAck.showKey, store: AgentAck.defaults) private var showsAcks = true
    @ObservedObject private var waiting = WaitingObservable.shared
    @State private var browserURL: URL?
    @State private var showCopied = false
    @State private var scrollToReply = UUID()
    @State private var replyTyped = false

    private var display: MessageDisplay { notification.display }
    /// At accessibility sizes a pinned bar would take most of the screen, so the answers follow
    /// the text instead.
    /// Answers pin to the bottom so they stay reachable; a receipt is status, so once the question
    /// is settled it sits in the flow under the question (VERDICT-ack-48 S1).
    private var answersInline: Bool { sizeCategory.isAccessibilityCategory || isSettled }
    private var topicName: String { notification.subscription?.shortDisplayName() ?? "" }

    var body: some View {
        if notification.isDeleted || notification.managedObjectContext == nil {
            Color.clear
        } else {
            page
        }
    }

    private var page: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                messageBody
                if notification.encryptionState == .unencrypted {
                    Label(String(localized: "Not encrypted"), systemImage: "lock.open")
                        .font(.footnote).foregroundColor(.orange)
                }
                MessageAttachmentBlock(notification: notification, maxHeight: 520, onCopy: copied)
                if hasAnswerArea && answersInline {
                    answerArea.padding(.top, 12).id("answers")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            // About 45 to 80 characters a line on iPad too.
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        // At accessibility sizes the answers sit at the end of the text: bring the reply field
        // above the keyboard when it takes focus.
        .onChange(of: scrollToReply) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation { proxy.scrollTo("answers", anchor: .bottom) }
            }
        }
        }
        .background(Color(.systemBackground))
        .modifier(PinnedAnswerBar(enabled: hasAnswerArea && !answersInline) {
            answerArea
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        })
        .navigationTitle(topicName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if #available(iOS 16.0, *) {
                    ShareLink(item: notification.shareText)
                        .accessibilityLabel(String(localized: "Share"))
                }
                Menu {
                    Button {
                        UIPasteboard.general.setValue(notification.shareText, forPasteboardType: UTType.plainText.identifier)
                        copied()
                    } label: {
                        Label(String(localized: "Copy text"), systemImage: AppSymbol.copyText)
                    }
                    Button {
                        store.setRead(false, forNotification: notification)
                    } label: {
                        Label(String(localized: "Mark unread"), systemImage: AppSymbol.markUnread())
                    }
                    Button(role: .destructive) {
                        presentationMode.wrappedValue.dismiss()
                        let row = notification
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { store.delete(notification: row) }
                    } label: {
                        Label(String(localized: "Delete"), systemImage: AppSymbol.delete())
                    }
                } label: {
                    Image(systemName: AppSymbol.more)
                }
                .accessibilityLabel(String(localized: "Message actions"))
                .accessibilityIdentifier("message-actions")
            }
        }
        .modifier(LinkOpener(url: $browserURL))
        .overlay(Group {
            if showCopied {
                CopiedToast()
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        })
        .onAppear {
            if !notification.read { store.setRead(true, forNotification: notification) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            MessageTitleLine(notification: notification, font: .title3.weight(.semibold), lineLimit: nil)
                .accessibilityAddTraits(.isHeader)
            let tags = notification.nonEmojiTags()
            let when = Self.pageDate(notification.date())
            Text(([when] + tags).joined(separator: " · "))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    /// "Today at 3:42 PM", "Yesterday at 9:05 AM", "Nov 3, 2026 at 8:00 AM", in the reader's language.
    static func pageDate(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    @ViewBuilder private var messageBody: some View {
        if display.markdown {
            MarkdownBlocksView(source: display.body)
        } else if !display.body.isEmpty {
            Text(renderMessageBody(display.body, contentType: nil))
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Answers

    private var items: [ActionBarItem] {
        ActionBarItem.items(actions: notification.answerableActions(), click: clickURL, context: .page)
    }

    private var replyAction: Action? {
        notification.answerableActions().first { BannerReply.destination(for: $0) != nil }
    }

    /// An agent's question with buttons only: a written reply goes to its topic (AgentReply).
    private var offersAgentReply: Bool {
        replyAction == nil && waiting.contains(notification)
            && AgentReply.offersField(tags: parseAllTags(notification.tags), actions: notification.answerableActions())
    }

    private var clickURL: URL? {
        guard let click = notification.click, !click.isEmpty else { return nil }
        return URL(string: click)
    }

    private var receipt: AgentReceipt {
        AgentReceipt(notification: notification, log: log, acks: acks, shows: showsAcks)
    }

    /// Links still open after answering; answers are done.
    private var links: [ActionBarItem] {
        items.filter { if case .answer = $0 { return false } else { return true } }
    }

    /// Answered here, or the agent confirmed (or settled) the question: the receipt replaces the answers.
    private var isSettled: Bool {
        AnswerState(notification: notification, log: log).showsReceipt() || receipt.resolved
    }

    private var hasAnswerArea: Bool {
        if isSettled {
            let receipt = receipt
            return receipt.answer != nil || receipt.agent != nil || receipt.showsClosed || !links.isEmpty
        }
        return !items.isEmpty || replyAction != nil || offersAgentReply
    }

    @ViewBuilder private var answerArea: some View {
        let state = AnswerState(notification: notification, log: log)
        VStack(spacing: 10) {
            if isSettled {
                let receipt = receipt
                if receipt.showsClosed {
                    ReceiptClosedLine(receipt: receipt, font: .subheadline)
                } else if receipt.answer != nil || receipt.agent != nil {
                    AgentReceiptTimeline(receipt: receipt)
                }
                if !links.isEmpty {
                    ActionBar(items: links, run: run)
                }
            } else {
                if state.failed { AnswerReceiptView(failed: true, failedLabel: state.failedLabel) }
                if !items.isEmpty {
                    ActionBar(items: items, prominentId: Self.prominentAnswer(firstAnswerId: prominentId,
                                                                         replyTyped: replyTyped && state.sendingActionId == nil && state.sentLabel() == nil),
                              sendingId: state.sendingActionId,
                              sentLabel: state.sentLabel(), failedLabel: state.failedLabel, recipient: topicName, run: run)
                }
                if replyAction != nil || offersAgentReply {
                    let row = Self.replyRow(answerSent: state.sentLabel() != nil)
                    ReplyField(placeholder: String(localized: "Reply to \(topicName)"),
                               phase: state.replyPhase(replyActionId: replyAction?.id),
                               disabled: state.sending, held: row == .held, focusOnAppear: focusReply,
                               onFocus: { if answersInline { scrollToReply = UUID() } },
                               onTyped: { replyTyped = $0 }) { text in
                        if let replyAction {
                            runner.run(replyAction, replyText: text)
                        } else {
                            AgentReply.send(text, to: notification, store: store)
                        }
                    }
                }
            }
        }
    }

    /// How the reply row sits once a tapped answer shows its check.
    enum ReplyRow: Equatable {
        case shown
        /// Invisible but still in the layout through the sent hold, so the answer row above it confirms
        /// in place instead of dropping into its slot (DESIGN-REVIEW F2). It goes when the receipt
        /// replaces both.
        case held
    }

    static func replyRow(answerSent: Bool) -> ReplyRow { answerSent ? .held : .shown }

    /// While a reply is being typed, Send is the one solid button: the agent's lead answer steps down
    /// to the tint until the field is empty again (DESIGN-REVIEW S1).
    static func prominentAnswer(firstAnswerId: String?, replyTyped: Bool) -> String? {
        replyTyped ? nil : firstAnswerId
    }

    private var prominentId: String? {
        guard waiting.contains(notification) else { return nil }
        return items.first { if case .answer = $0 { return true } else { return false } }?.id
    }

    private var runner: MessageActionRunner {
        MessageActionRunner(notification: notification,
                            openURL: { LinkOpener.open($0, browserURL: $browserURL, openURL: openURL) },
                            onCopy: copied)
    }

    private func run(_ item: ActionBarItem) {
        switch item {
        case .answer(let action), .link(let action), .copy(let action): runner.run(action)
        case .reply: break
        case .click(let url): LinkOpener.open(url, browserURL: $browserURL, openURL: openURL)
        }
    }

    private func copied() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { showCopied = false } }
    }
}

/// The answer area pinned to the bottom. Opaque, so body text never shows through behind the
/// buttons (DECISION change 8); the keyboard pushes it up with the field.
struct PinnedAnswerBar<Bar: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) {
                bar().background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    bar()
                }
                .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
            }
        }
    }
}

/// A typed answer for the agent: one line that grows to five, and a Send button that lights up in
/// the answer fill once there is something to send (DIRECTIONS 1.5). Send spins while the reply
/// is on its way, shows a check when the agent has it, and shakes if it didn't get there.
struct ReplyField: View {
    let placeholder: String
    var phase: AnswerPhase = .idle
    var disabled = false
    /// Kept in the layout but out of sight, reach and VoiceOver while an answer shows its check.
    var held = false
    var focusOnAppear = false
    /// Called when the field gains focus, so an inline answer area can scroll it above the keyboard.
    var onFocus: () -> Void = {}
    /// Whether the field holds something to send, as it changes.
    var onTyped: (Bool) -> Void = { _ in }
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var height = AnswerMetrics.height

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { phase == .sending || phase == .sent }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: height)
                .background(RoundedRectangle(cornerRadius: AnswerMetrics.cornerRadius, style: .continuous)
                    .fill(Color(.tertiarySystemFill)))
                .disabled(disabled || busy)
                .opacity(disabled && !busy ? 0.5 : 1)
                .accessibilityIdentifier("reply-field")
            Button {
                let value = trimmed
                guard !value.isEmpty else { return }
                // The text stays until the answer is through: on success the receipt replaces this
                // field; on failure the person can send it again without retyping.
                send(value)
                focused = false
            } label: {
                Text(phase == .sent ? String(localized: "Sent") : String(localized: "Send"))
                    .frame(minWidth: 52)
            }
            .answerButtonStyle(.primary, phase: phase, expands: false)
            .disabled(trimmed.isEmpty || disabled)
            .accessibilityLabel(String(localized: "Send"))
            .accessibilityValue(phase == .sending ? String(localized: "Sending") : phase == .sent ? String(localized: "Sent") : "")
            .accessibilityIdentifier("reply-send")
        }
        .modifier(HeldOut(held: held))
        .onAppear {
            if focusOnAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { focused = true } }
        }
        .onChange(of: focused) { isFocused in
            if isFocused { onFocus() }
        }
        .onChange(of: trimmed.isEmpty) { empty in onTyped(!empty) }
    }

    @ViewBuilder private var field: some View {
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: $text, axis: .vertical).lineLimit(1...5)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

/// Keeps a view's space while taking it out of sight, touch and VoiceOver. `.hidden()` does all three;
/// opacity 0 with `accessibilityHidden` left the field and Send in the accessibility tree.
private struct HeldOut: ViewModifier {
    let held: Bool
    func body(content: Content) -> some View {
        if held { content.hidden() } else { content }
    }
}

// MARK: - Markdown on the page (A4)

enum MarkdownBlock: Equatable {
    case heading(String)
    case paragraph(String)
    case numbered([String])
    case bulleted([String])
    case code(String)
}

/// A small block parser for the page: headings, paragraphs, numbered and bulleted lists, and
/// fenced code. Inline styles and links inside each block go through the message renderer.
enum MarkdownBlocks {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = [], numbered: [String] = [], bulleted: [String] = [], code: [String] = []
        var inCode = false
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !bulleted.isEmpty { blocks.append(.bulleted(bulleted)); bulleted = [] }
        }
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n"))); code = []; inCode = false
                } else {
                    flush(); inCode = true
                }
                continue
            }
            if inCode { code.append(line); continue }
            if let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); blocks.append(.heading(String(trimmed[range.upperBound...])))
            } else if let range = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                if !paragraph.isEmpty || !bulleted.isEmpty { flush() }
                numbered.append(String(trimmed[range.upperBound...]))
            } else if let range = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                if !paragraph.isEmpty || !numbered.isEmpty { flush() }
                bulleted.append(String(trimmed[range.upperBound...]))
            } else if trimmed.isEmpty {
                flush()
            } else {
                if !numbered.isEmpty || !bulleted.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        if inCode { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

struct MarkdownBlocksView: View {
    let source: String

    var body: some View {
        let blocks = MarkdownBlocks.parse(source)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let text):
                    Text(inline(text))
                        .font(.title3.weight(.semibold))
                        .padding(.top, index == 0 ? 0 : 4)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    Text(inline(text)).font(.body).textSelection(.enabled)
                case .numbered(let items):
                    list(items) { "\($0 + 1)." }
                case .bulleted(let items):
                    list(items) { _ in "•" }
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text).font(.callout.monospaced()).textSelection(.enabled).padding(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemBackground)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func list(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(marker(index)).font(.body.monospacedDigit()).frame(minWidth: 24, alignment: .leading)
                    Text(inline(item)).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        renderMessageBody(text, contentType: "text/markdown")
    }
}
