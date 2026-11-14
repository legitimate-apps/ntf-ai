import CoreData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The parts every message surface shares (DIRECTIONS 1.5): Inbox rows, topic cards, the message
// page and search results. One family, so the same question reads the same wherever it shows.

/// Yellow is a fill, never text on a light surface (DIRECTIONS 1.1). Text and symbols on it are ink.
enum InboxColor {
    static let fill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 214.0 / 255, blue: 10.0 / 255, alpha: 1)
            : UIColor(red: 1, green: 204.0 / 255, blue: 0, alpha: 1)
    })
    static let onFill = Color.black.opacity(0.88)
    /// Links, the unread dot, "Show more", the waiting mark: the app tint.
    static let ink = Color("AccentColor")
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
        MessageDisplay.of(title: formatTitle(), body: formatMessage(), contentType: contentType)
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

/// Priority, emoji tags right against the title, and the title (DIRECTIONS 1.5).
struct MessageTitleLine: View {
    @ObservedObject var notification: Notification
    var font: Font = .headline
    var lineLimit: Int? = 2

    var body: some View {
        let display = notification.display
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            PriorityMark(priority: notification.priority)
            let emoji = notification.emojiTags().joined()
            if !emoji.isEmpty { Text(emoji).accessibilityHidden(true) }
            if let title = display.titleText {
                Text(title).lineLimit(lineLimit).fixedSize(horizontal: false, vertical: true)
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

    init(notification: Notification, log: AnswerLog) {
        let key = AnswerKey(notification: notification)
        entry = log.entry(for: key)
        sendingActionId = log.sendingActionId(key)
    }

    var sending: Bool { sendingActionId != nil }
    /// Only a request that reached the agent shows a check. "Not needed" isn't an answer.
    var answered: Bool { !sending && entry?.ok == true && entry?.kind != .dismissed }
    var failed: Bool { !sending && entry?.ok == false }
}

/// After answering: what you told the agent, or that it didn't get it (DECISION change 8: a
/// failure never shows a check).
struct AnswerReceiptView: View {
    var entry: AnswerEntry? = nil
    var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if failed {
                Label {
                    Text(String(localized: "Didn't reach the agent. Try again."))
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
                }
                .font(.footnote)
                .accessibilityIdentifier("answer-failed")
            } else if let entry, entry.ok, entry.kind != .dismissed {
                let time = Notification.shortTime(for: entry.at)
                Label {
                    Text(entry.kind == .tap ? String(localized: "You tapped \(entry.label) · \(time)")
                                            : String(localized: "You replied · \(time)"))
                        .foregroundColor(.primary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                }
                .font(.footnote)
                .accessibilityIdentifier("answer-receipt")
                if let text = entry.text, !text.isEmpty {
                    Text(text).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    var size: ControlSize = .regular
    var sendingId: String? = nil
    let run: (ActionBarItem) -> Void

    var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                EqualWidthHStack(spacing: 8) { buttons }
                VStack(spacing: 8) { buttons }
            }
        } else {
            VStack(spacing: 8) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(items) { item in
            let spinning = item.id == sendingId
            ActionBarButton(item: item, prominent: item.id == prominentId, size: size, spinning: spinning) { run(item) }
                .disabled(sendingId != nil && !spinning)
                .opacity(sendingId != nil && !spinning ? 0.4 : 1)
        }
    }
}

private struct ActionBarButton: View {
    let item: ActionBarItem
    let prominent: Bool
    let size: ControlSize
    let spinning: Bool
    let action: () -> Void

    private var label: some View {
        HStack(spacing: 4) {
            if case .reply = item {
                Image(systemName: "arrowshape.turn.up.left").accessibilityHidden(true)
            }
            Text(item.label).lineLimit(1)
            switch item {
            case .link, .click:
                Image(systemName: "arrow.up.right").font(.footnote).accessibilityHidden(true)
            default:
                EmptyView()
            }
        }
        .opacity(spinning ? 0 : 1)
        .overlay {
            if spinning { ProgressView().tint(prominent ? InboxColor.onFill : .secondary) }
        }
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        if prominent {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .tint(InboxColor.fill)
                .foregroundColor(InboxColor.onFill)
                .buttonBorderShape(.capsule)
                .controlSize(size)
                .allowsHitTesting(!spinning)
                .accessibilityValue(spinning ? String(localized: "Sending") : "")
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .foregroundColor(.primary)
                .buttonBorderShape(.capsule)
                .controlSize(size)
                .allowsHitTesting(!spinning)
                .accessibilityValue(spinning ? String(localized: "Sending") : "")
        }
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

/// A message as a card: the whole short message with its answers in place. Long text stops at
/// eight lines with "Show more", which opens the page. With `showsTopic` (Inbox Activity, Search)
/// a topic line on top says which agent spoke.
struct MessageCard: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var notification: Notification
    @ObservedObject private var log = AnswerLog.shared
    @ObservedObject private var waiting = WaitingObservable.shared
    var showsTopic = false
    var heldUnread = false
    let open: (_ focusReply: Bool) -> Void
    var onCopy: () -> Void = {}
    @State private var truncated = false
    @State private var browserURL: URL?

    private var display: MessageDisplay { notification.display }
    private var showsUnread: Bool { !notification.read || heldUnread }

    var body: some View {
        let state = AnswerState(notification: notification, log: log)
        let items = ActionBarItem.items(actions: notification.actionsList(), click: nil, context: .card)
        VStack(alignment: .leading, spacing: 8) {
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showsUnread { UnreadDot().alignmentGuide(.firstTextBaseline) { $0[.bottom] } }
                MessageTitleLine(notification: notification, lineLimit: 2)
                Spacer(minLength: 8)
                if !showsTopic { time }
            }
            if !display.body.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    LineCappedText(text: display.cardBody, lines: 8, truncated: $truncated)
                    if truncated {
                        Button(String(localized: "Show more")) { open(false) }
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
            if state.answered {
                AnswerReceiptView(entry: state.entry)
            } else if !items.isEmpty {
                if state.failed { AnswerReceiptView(failed: true) }
                ActionBar(items: items, prominentId: prominentId(items), size: .regular,
                          sendingId: state.sendingActionId, run: run)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(false) }
        .modifier(LinkOpener(url: $browserURL))
        .accessibilityElement(children: .contain)
        .accessibilityValue(showsUnread ? String(localized: "Unread") : "")
        .accessibilityAction(named: Text(String(localized: "Open message"))) { open(false) }
    }

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
    let open: (_ focusReply: Bool) -> Void
    var now = Date()
    @State private var browserURL: URL?

    var body: some View {
        let state = AnswerState(notification: notification, log: log)
        let items = ActionBarItem.items(actions: notification.actionsList(), click: nil, context: .waiting)
        let display = notification.display
        VStack(alignment: .leading, spacing: 6) {
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
            if !display.body.isEmpty {
                Text(display.cardBody).font(.body).foregroundColor(.secondary).lineLimit(3)
            }
            if state.answered {
                AnswerReceiptView(entry: state.entry)
            } else {
                if state.failed { AnswerReceiptView(failed: true) }
                ActionBar(items: items, prominentId: items.first { if case .answer = $0 { return true } else { return false } }?.id,
                          size: .regular, sendingId: state.sendingActionId) { item in
                    switch item {
                    case .answer(let action):
                        MessageActionRunner(notification: notification,
                                            openURL: { LinkOpener.open($0, browserURL: $browserURL, openURL: openURL) }).run(action)
                    case .reply: open(true)
                    default: break
                    }
                }
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
    static func after(_ action: @escaping () -> Void, tries: Int = 30) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let roots = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).compactMap(\.rootViewController)
            let busy = roots.flatMap(navigationControllers).contains { $0.transitionCoordinator != nil }
            if busy && tries > 0 { after(action, tries: tries - 1) } else { action() }
        }
    }

    private static func navigationControllers(in controller: UIViewController) -> [UINavigationController] {
        var found = (controller as? UINavigationController).map { [$0] } ?? []
        for child in controller.children { found += navigationControllers(in: child) }
        if let presented = controller.presentedViewController { found += navigationControllers(in: presented) }
        return found
    }
}
