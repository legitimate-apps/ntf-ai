import SwiftUI
import UIKit

// The same adaptive accent used by SwiftUI links: Forest (#047857) on light surfaces, Emerald
// (#34D399) on dark. Keep a matching dynamic fallback for contexts that do not load the asset catalog.
private let messageLinkColor = UIColor(named: "AccentColor") ?? UIColor { traits in
    if traits.userInterfaceStyle == .dark {
        return UIColor(red: 0x34 / 255.0, green: 0xD3 / 255.0, blue: 0x99 / 255.0, alpha: 1)
    }
    return UIColor(red: 0x04 / 255.0, green: 0x78 / 255.0, blue: 0x57 / 255.0, alpha: 1)
}

// MARK: Extensions

extension Notification {
    /// Body for display: rendered Markdown when the message is `text/markdown`
    /// (ntfy #1072), otherwise plain text with detected links made tappable.
    func renderedMessageAttributedString() -> AttributedString {
        return renderMessageBody(formatMessage(), contentType: contentType)
    }

    func linkifiedMessageAttributedString() -> AttributedString {
        return renderMessageBody(formatMessage(), contentType: nil)
    }

    /// The one line a list shows for this message: its title if it has one, else its body as
    /// plain text (Markdown resolved, line breaks folded), so a preview never shows `**`.
    /// A locked message previews as its placeholder only, never a title.
    func previewText() -> String {
        if encryptionState == .locked {
            return formatMessage()
        }
        if let title = formatTitle(), !title.isEmpty {
            return title
        }
        let plain = String(renderedMessageAttributedString().characters)
        return plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether a list preview of this message needs the row's orange "Not encrypted" mark: it
    /// arrived as plaintext on a topic with a password, so it must not pass as the encrypted
    /// sender's words in the topic list either.
    var previewIsMarkedNotEncrypted: Bool {
        encryptionState == .unencrypted
    }
}

/// Pure + testable. Parses Markdown (iOS 15+) when `contentType` is
/// `text/markdown`; otherwise linkifies plain text via `linkify()`. Markdown
/// failures fall back to the linkified plain text so a malformed body never
/// renders empty.
func renderMessageBody(_ source: String, contentType: String?) -> AttributedString {
    guard contentType == "text/markdown" else { return linkify(source) }
    var result = AttributedString()
    for segment in markdownSegments(source) {
        guard segment.isCode else { result.append(renderInlineMarkdown(segment.text)); continue }
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 8; paragraph.headIndent = 8; paragraph.tailIndent = -8
        paragraph.paragraphSpacingBefore = 6; paragraph.paragraphSpacing = 6
        var code = AttributedString(NSAttributedString(string: segment.text, attributes: [
            .backgroundColor: UIColor.secondarySystemBackground, .paragraphStyle: paragraph]))
        code.inlinePresentationIntent = .code
        result.append(code)
    }
    return result
}

struct MarkdownSegment: Equatable { let text: String; let isCode: Bool }

func markdownSegments(_ source: String) -> [MarkdownSegment] {
    let lines = source.components(separatedBy: "\n")
    var segments: [MarkdownSegment] = [], text = "", fence = "", count = 0
    func flush() {
        if !text.isEmpty { segments.append(MarkdownSegment(text: text, isCode: !fence.isEmpty)); text = "" }
    }
    for (index, line) in lines.enumerated() {
        let trimmed = line.drop(while: { $0 == " " })
        let marker = trimmed.first.map(String.init) ?? ""
        let length = trimmed.prefix(while: { String($0) == marker }).count
        let suffix = trimmed.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.count - trimmed.count <= 3, ["`", "~"].contains(marker), length >= 3 {
            if fence.isEmpty, marker != "`" || !suffix.contains("`") {
                flush(); fence = marker; count = length; continue
            } else if marker == fence, length >= count, suffix.isEmpty {
                flush(); fence = ""; continue
            }
        }
        text += line + (index < lines.count - 1 ? "\n" : "")
    }
    flush()
    return segments
}

private func renderInlineMarkdown(_ source: String) -> AttributedString {
    if #available(iOS 15.0, *) {
        if var attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible)) {
            // Foundation's markdown parser only links [text](url)/<url>, never a bare
            // "https://…", so a bare URL in a markdown message rendered dead while the
            // exact same text as plain text was tappable. Run the same detector pass the
            // plain-text path uses over the parsed runs to close that gap (ntfy #1743).
            linkifyBareUrls(in: &attributed)
            return attributed
        }
    }
    // Plain-text path: full-range link styling (ntfy #1743) via the shared linkify().
    return linkify(source)
}

private enum MessageLinkDetection {
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static let httpTokens = try? NSRegularExpression(pattern: #"https?://[^\s<>"`“”]+"#, options: .caseInsensitive)
}

/// NSDataDetector can stop at a query name before a long value (for example,
/// `?x` instead of `?x=...`). Retain its normal URL/punctuation rules, but extend
/// recognized HTTP(S) prefixes to the end of a long explicit URL token.
private func detectedMessageLinks(in source: String) -> [(range: NSRange, url: URL)] {
    let text = source as NSString
    let fullRange = NSRange(location: 0, length: text.length)
    var links = MessageLinkDetection.detector?.matches(in: source, range: fullRange).compactMap { match in
        match.url.map { (range: match.range, url: $0) }
    } ?? []
    // Short links keep the detector's behavior. Repetitive query values can
    // trigger prefix-only detection below 1 KB, so check tokens above 512 UTF-16 units.
    guard text.length > 512 else { return links }
    MessageLinkDetection.httpTokens?.enumerateMatches(in: source, range: fullRange) { match, _, _ in
        guard let match, match.range.length > 512,
              let prefix = links.first(where: { $0.range.location == match.range.location }),
              match.range.length > prefix.range.length else { return }
        var candidate = text.substring(with: match.range)
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        var counts: [Character: Int] = [:]
        for character in candidate where "()[]{}".contains(character) { counts[character, default: 0] += 1 }
        // Keep balanced URL parentheses/brackets, excluding sentence punctuation
        // and closing delimiters belonging to the surrounding prose.
        while let last = candidate.last {
            if ".,;:!?'’".contains(last) { candidate.removeLast(); continue }
            guard let opening = pairs[last], counts[last, default: 0] > counts[opening, default: 0] else { break }
            counts[last, default: 0] -= 1
            candidate.removeLast()
        }
        let range = NSRange(location: match.range.location, length: candidate.utf16.count)
        guard range.length > prefix.range.length, let url = URL(string: candidate),
              let host = url.host, !host.isEmpty, host == prefix.url.host else { return }
        links.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        links.append((range: range, url: url))
    }
    return links.sorted { $0.range.location < $1.range.location }
}

/// Add tappable + styled links to any bare URL in an already-parsed AttributedString
/// (e.g. markdown output), WITHOUT disturbing existing runs. Ranges that already carry
/// a `.link` (markdown-authored links) are left untouched so their target/label survive.
/// Operates purely on the Swift AttributedString so no markdown styling is ever lost.
func linkifyBareUrls(in attributed: inout AttributedString) {
    let text = String(attributed.characters)
    for match in detectedMessageLinks(in: text) {
        guard let strRange = Range(match.range, in: text) else { continue }
        let start = text.distance(from: text.startIndex, to: strRange.lowerBound)
        let length = text.distance(from: strRange.lowerBound, to: strRange.upperBound)
        let lower = attributed.index(attributed.startIndex, offsetByCharacters: start)
        let upper = attributed.index(lower, offsetByCharacters: length)
        let attrRange = lower..<upper
        guard attributed[attrRange].runs.allSatisfy({ $0.link == nil }) else { continue }
        attributed[attrRange].link = match.url
        attributed[attrRange].foregroundColor = messageLinkColor
        attributed[attrRange].underlineStyle = NSUnderlineStyle.single
    }
}

/// Detect links in `source` and return an AttributedString with each link made
/// tappable AND fully styled (color + underline) across its ENTIRE range.
///
/// Setting only `.link` and letting SwiftUI apply the implicit link styling
/// truncated the coloring/underline of long or line-wrapping URLs to the
/// recognized prefix (ntfy iOS #1743). Applying `.foregroundColor` and
/// `.underlineStyle` explicitly over the full detector match keeps the whole
/// URL visibly a link. Long explicit HTTP(S) tokens repair truncated detector
/// matches via the shared detectedMessageLinks(). Unit-testable without a
/// Core Data Notification.
func linkify(_ source: String) -> AttributedString {
    let mutable = NSMutableAttributedString(string: source)
    for match in detectedMessageLinks(in: source) {
        mutable.addAttribute(.link, value: match.url, range: match.range)
        mutable.addAttribute(.foregroundColor, value: messageLinkColor, range: match.range)
        mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
    }
    return AttributedString(mutable)
}

// MARK: Selectable message text

struct MessageRowTapPolicy: Equatable {
    let installsAncestorContentTap: Bool
    let installsRegionTaps: Bool
}

/// Keeps row-level tap ownership testable without constructing SwiftUI's view tree.
/// Text views route their own link/plain taps, so an ancestor recognizer must
/// never independently trigger the row action after UIKit opens a link.
func messageRowTapPolicy(isEditing: Bool) -> MessageRowTapPolicy {
    return MessageRowTapPolicy(
        installsAncestorContentTap: false,
        installsRegionTaps: !isEditing
    )
}

/// What a plain tap on a message row does. A click URL wins; otherwise a row cut at its line cap
/// expands or collapses. A tap never copies: copying a whole message by accident while scrolling
/// was easy and nothing advertised it, so copy lives in the long-press menu.
enum MessageRowTapAction: Equatable {
    case openClickURL
    case toggleExpansion
    case none
}

func messageRowTapAction(hasClickURL: Bool, exceedsLineCap: Bool) -> MessageRowTapAction {
    if hasClickURL { return .openClickURL }
    return exceedsLineCap ? .toggleExpansion : .none
}

/// The cue under a cut row: "more" while collapsed, "less" once expanded (so a row whose tap opens
/// a click URL can still be cut back), nothing when the whole message fits.
enum MessageRowExpansionCue: Equatable {
    case more
    case less
}

func messageRowExpansionCue(exceedsLineCap: Bool, isExpanded: Bool) -> MessageRowExpansionCue? {
    guard exceedsLineCap else { return nil }
    return isExpanded ? .less : .more
}

/// Collapsed rows show one line of title (three at accessibility sizes, where one line holds a
/// word or two) and six of body; a tap shows the rest.
enum MessageRowLineCap {
    static let title = 1
    static let accessibilityTitle = 3
    static let body = 6

    static func title(accessibilitySize: Bool) -> Int {
        accessibilitySize ? accessibilityTitle : title
    }
}

/// Unread markers held for one visit to a topic. Opening a topic marks it read at once (the badge
/// clears), but the rows that were unread keep their dot and weight until the user leaves, as in
/// Mail, so they can still see what was new. Generic over the id so it is testable without Core Data.
struct HeldUnreadMarkers<ID: Hashable> {
    private(set) var ids: Set<ID> = []

    /// The rows that were unread when the topic opened.
    mutating func hold(_ unread: Set<ID>) { ids.formUnion(unread) }

    /// The user marked this row read or unread themselves: their choice wins over the hold.
    mutating func release(_ id: ID) { ids.remove(id) }

    /// Leaving the topic.
    mutating func clear() { ids.removeAll() }

    func showsUnread(_ id: ID, read: Bool) -> Bool { !read || ids.contains(id) }
}

/// Message rows are set at `.subheadline` (15/20 at the default size): title and body differ by
/// weight, and the row reads as an inbox, not a page. Unread titles are semibold, read ones medium,
/// which is how a row says it is unread without another glyph.
enum MessageTextStyle {
    case body
    case title
    case titleRead

    /// Unread titles are semibold; once read they drop to medium, so the weight itself says
    /// which messages are new without a second color.
    static func title(read: Bool) -> MessageTextStyle {
        read ? .titleRead : .title
    }

    var uiTextStyle: UIFont.TextStyle {
        .subheadline
    }

    var weight: UIFont.Weight? {
        switch self {
        case .body:
            return nil
        case .title:
            return .semibold
        case .titleRead:
            return .medium
        }
    }

    var baseTraits: UIFontDescriptor.SymbolicTraits {
        []
    }

    /// The first line's baseline measured from the top of the text view, for aligning the
    /// row's trailing time with it. TextKit places the first baseline at the font's ascender
    /// when the container inset and padding are zero, as `configureMessageTextView` sets them.
    func firstBaseline(compatibleWith traitCollection: UITraitCollection?) -> CGFloat {
        UIFont.preferredFont(forTextStyle: uiTextStyle, compatibleWith: traitCollection).ascender
    }

    func lineHeight(compatibleWith traitCollection: UITraitCollection?) -> CGFloat {
        UIFont.preferredFont(forTextStyle: uiTextStyle, compatibleWith: traitCollection).lineHeight
    }
}

/// Title rendering shares the body's URL detector so links behave consistently
/// in both visible message fields.
func renderMessageTitle(_ source: String) -> AttributedString {
    return linkify(source)
}

/// Converts the SwiftUI-oriented attributed value into attributes UIKit can
/// render directly. UIKit's NSAttributedString bridge does not interpret
/// Markdown presentation intents, so resolve those intents into real fonts.
func makeMessageNSAttributedString(
    _ attributed: AttributedString,
    style: MessageTextStyle,
    compatibleWith traitCollection: UITraitCollection? = nil
) -> NSAttributedString {
    let bridged = NSAttributedString(attributed)
    let output = NSMutableAttributedString(
        string: bridged.string,
        attributes: [.foregroundColor: UIColor.label]
    )
    let fullRange = NSRange(location: 0, length: bridged.length)
    bridged.enumerateAttributes(in: fullRange) { attributes, range, _ in
        output.addAttributes(attributes, range: range)
    }

    let plainText = String(attributed.characters)
    for run in attributed.runs {
        let lowerOffset = attributed.characters.distance(
            from: attributed.startIndex,
            to: run.range.lowerBound
        )
        let upperOffset = attributed.characters.distance(
            from: attributed.startIndex,
            to: run.range.upperBound
        )
        let lower = plainText.index(plainText.startIndex, offsetBy: lowerOffset)
        let upper = plainText.index(plainText.startIndex, offsetBy: upperOffset)
        let range = NSRange(lower..<upper, in: plainText)

        var descriptor = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style.uiTextStyle, compatibleWith: traitCollection
        )
        var traits = descriptor.symbolicTraits.union(style.baseTraits)
        if let intent = run.inlinePresentationIntent {
            if intent.contains(.stronglyEmphasized) {
                traits.insert(.traitBold)
            }
            if intent.contains(.emphasized) {
                traits.insert(.traitItalic)
            }
            if intent.contains(.code) {
                descriptor = descriptor.withDesign(.monospaced) ?? descriptor
                traits.insert(.traitMonoSpace)
            }
        }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        // A weight is a trait attribute, not a symbolic trait, so it goes on after them. Markdown
        // bold inside a title stays bold rather than being lowered to the title's weight.
        if let weight = style.weight, !traits.contains(.traitBold) {
            descriptor = descriptor.addingAttributes([
                .traits: [
                    UIFontDescriptor.TraitKey.weight: weight.rawValue,
                    UIFontDescriptor.TraitKey.symbolic: traits.rawValue
                ]
            ])
        }
        output.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 0), range: range)
    }

    return output
}

/// Applies the canonical interaction and sizing configuration used by both the
/// title and body wrappers.
func configureMessageTextView(
    _ textView: UITextView,
    isInteractionEnabled: Bool
) {
    textView.isSelectable = true
    textView.isEditable = false
    textView.accessibilityTraits.insert(.staticText)
    textView.isScrollEnabled = false
    textView.adjustsFontForContentSizeCategory = true
    textView.isUserInteractionEnabled = isInteractionEnabled
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.tintColor = messageLinkColor
    textView.linkTextAttributes = [
        .foregroundColor: messageLinkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue
    ]
    textView.setContentCompressionResistancePriority(.required, for: .vertical)
    textView.setContentHuggingPriority(.required, for: .vertical)
}

// MARK: Wrapping without hyphenation

/// Keep word boundaries throughout the paragraph. TextKit 2's line-break delegate
/// rejects synthetic hyphens, allowing an oversized token to split without
/// forcing the neighboring prose into character wrapping.
@available(iOS 16.0, *)
private final class MessageLineBreakDelegate: NSObject, NSTextLayoutManagerDelegate {
    static let shared = MessageLineBreakDelegate()

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           shouldBreakLineBefore location: any NSTextLocation,
                           hyphenating: Bool) -> Bool {
        return !hyphenating
    }
}

/// Preserve Markdown paragraph attributes while disabling linguistic hyphenation.
func applyMessageWrapping(to attributed: NSAttributedString) -> NSAttributedString {
    guard attributed.length > 0 else {
        return attributed
    }
    let output = NSMutableAttributedString(attributedString: attributed)
    let text = output.string as NSString
    text.enumerateSubstrings(
        in: NSRange(location: 0, length: text.length),
        options: [.byParagraphs, .substringNotRequired]
    ) { _, _, enclosingRange, _ in
        guard enclosingRange.length > 0 else { return }
        let paragraph = output.attributedSubstring(from: enclosingRange)
        let existing = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let style = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.hyphenationFactor = 0
        if #available(iOS 15.0, *) {
            style.usesDefaultHyphenation = false
        }
        output.addAttribute(.paragraphStyle, value: style, range: enclosingRange)
    }
    return output
}

/// A self-sizing, non-scrolling text view that preserves word wrapping even
/// when a message contains oversized tokens.
final class MessageTextView: UITextView {
    private var lastLaidOutWidth: CGFloat = 0
    /// Space kept free on the first line, so a row's time (trailing) and priority glyph
    /// (leading) sit inside the text's first line and the lines below use the full width.
    private(set) var firstLineExclusion = FirstLineExclusion()
    private var messageText: NSAttributedString?
    private var messageSource: AttributedString?
    private var messageStyle: MessageTextStyle = .body
    /// The most lines shown while collapsed; 0 means no cap.
    private(set) var lineCap = 0
    private(set) var isCollapsed = true
    /// Whether the text needs more lines than `lineCap` at the current width.
    private(set) var exceedsLineCap = false
    var onExceedsLineCapChange: ((Bool) -> Void)?

    func setLineCap(_ cap: Int, collapsed: Bool) {
        // TextKit draws the "…" only with a truncating mode; word wrapping just stops at the cap.
        // Set on every update: `configureMessageTextView` resets the mode to word wrapping.
        let mode: NSLineBreakMode = collapsed && cap > 0 ? .byTruncatingTail : .byWordWrapping
        let modeChanged = textContainer.lineBreakMode != mode
        if modeChanged { textContainer.lineBreakMode = mode }
        guard modeChanged || cap != lineCap || collapsed != isCollapsed else {
            // `configureMessageTextView` also zeroes the container inset a one-line cap uses.
            applyFirstLineExclusion()
            return
        }
        lineCap = cap
        isCollapsed = collapsed
        textContainer.maximumNumberOfLines = collapsed ? cap : 0
        applyFirstLineExclusion()
        updateExceedsLineCap()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The height the text takes at `width` with the current cap and first-line exclusion, for
    /// SwiftUI's `sizeThatFits`. Measured at the width SwiftUI proposes rather than `bounds`, so
    /// the List gets the right height on its first pass instead of whatever `bounds` held then.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0, width.isFinite else { return 1 }
        applyFirstLineExclusion(width: width)
        updateExceedsLineCap(width: width)
        let size = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }

    private func updateExceedsLineCap(width: CGFloat? = nil) {
        let width = width ?? bounds.width
        let exceeds = lineCap > 0 && width > 0 && messageLineCount(
            of: attributedText,
            width: width,
            exclusionPaths: firstLineExclusion.rects(containerWidth: width).map { UIBezierPath(rect: $0) }
        ) > lineCap
        guard exceeds != exceedsLineCap else { return }
        exceedsLineCap = exceeds
        onExceedsLineCapChange?(exceeds)
    }

    func setMessageText(_ source: AttributedString, style: MessageTextStyle) {
        messageSource = source
        messageStyle = style
        setMessageText(makeMessageNSAttributedString(source, style: style, compatibleWith: traitCollection))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory,
              let source = messageSource else { return }
        // UIKit adjusts preferred fonts automatically, but derived monospaced
        // Markdown fonts need to be resolved again for the new category.
        setMessageText(source, style: messageStyle)
    }

    func setMessageText(_ next: NSAttributedString) {
        guard messageText?.isEqual(to: next) != true else {
            return
        }
        messageText = next
        if #available(iOS 16.0, *) {
            textLayoutManager?.delegate = MessageLineBreakDelegate.shared
        }
        let wrapped = applyMessageWrapping(to: next)
        guard !attributedText.isEqual(to: wrapped) else {
            return
        }
        let selection = selectedRange
        attributedText = wrapped
        if NSMaxRange(selection) <= wrapped.length {
            selectedRange = selection
        }
        updateExceedsLineCap()
        invalidateIntrinsicContentSize()
    }

    func setFirstLineExclusion(_ exclusion: FirstLineExclusion) {
        guard exclusion != firstLineExclusion else { return }
        firstLineExclusion = exclusion
        applyFirstLineExclusion()
        updateExceedsLineCap()
        invalidateIntrinsicContentSize()
    }

    /// A text cut to one line is all first line, and TextKit draws a truncated line's "…" across
    /// exclusion paths (the title ran under the time). So a one-line cap reserves the glyph and
    /// the time as container insets instead, which truncation respects.
    private var reservesFirstLineAsInsets: Bool {
        isCollapsed && lineCap == 1
    }

    private func applyFirstLineExclusion(width: CGFloat? = nil) {
        let insets = reservesFirstLineAsInsets
            ? UIEdgeInsets(top: 0, left: firstLineExclusion.leading, bottom: 0, right: firstLineExclusion.trailing)
            : .zero
        if textContainerInset != insets { textContainerInset = insets }
        let rects = reservesFirstLineAsInsets ? [] : firstLineExclusion.rects(containerWidth: width ?? bounds.width)
        let paths = rects.map { UIBezierPath(rect: $0) }
        if textContainer.exclusionPaths.map(\.bounds) != paths.map(\.bounds) {
            textContainer.exclusionPaths = paths
        }
    }

    override var intrinsicContentSize: CGSize {
        guard !isScrollEnabled else {
            return super.intrinsicContentSize
        }
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: 1)
        }
        let fittingSize = sizeThatFits(
            CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fittingSize.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - lastLaidOutWidth) > 0.5 else {
            return
        }
        lastLaidOutWidth = bounds.width
        applyFirstLineExclusion()
        updateExceedsLineCap()
        invalidateIntrinsicContentSize()
    }
}

/// Lines the text takes at `width`, counted on a private TextKit 1 stack so the answer does not
/// depend on the visible view's line cap. A first line split by exclusion paths counts once.
func messageLineCount(of text: NSAttributedString, width: CGFloat, exclusionPaths: [UIBezierPath] = []) -> Int {
    guard text.length > 0, width > 0 else { return 0 }
    let storage = NSTextStorage(attributedString: applyMessageWrapping(to: text))
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.exclusionPaths = exclusionPaths
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    var lineTops = Set<CGFloat>()
    layoutManager.enumerateLineFragments(
        forGlyphRange: layoutManager.glyphRange(for: container)
    ) { rect, _, _, _, _ in
        lineTops.insert(rect.minY.rounded())
    }
    return lineTops.count
}

/// Widths reserved at either end of a text view's first line. Pure, so the geometry is testable.
struct FirstLineExclusion: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    var lineHeight: CGFloat = 0

    func rects(containerWidth: CGFloat) -> [CGRect] {
        guard containerWidth > 0, lineHeight > 0 else { return [] }
        var rects: [CGRect] = []
        if leading > 0 {
            rects.append(CGRect(x: 0, y: 0, width: min(leading, containerWidth), height: lineHeight))
        }
        if trailing > 0 {
            let width = min(trailing, containerWidth)
            rects.append(CGRect(x: containerWidth - width, y: 0, width: width, height: lineHeight))
        }
        return rects
    }
}

@available(iOS 17.0, *)
func preservedDefaultLinkMenu(_ defaultMenu: UIMenu) -> UIMenu {
    return defaultMenu
}

// MARK: Modifiers

struct DisableAutocapitalizationModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content
                .textInputAutocapitalization(.never)
        } else {
            content
                .autocapitalization(.none)
        }
    }
}

extension View {
    func disableAutocapitalization() -> some View {
        modifier(DisableAutocapitalizationModifier())
    }
}

// MARK: Chrome vocabulary (1.26 small-elements pass)

/// One symbol per concept. Menus and context menus use the outline form, swipe actions the filled
/// one, and toolbar symbols are never circled: the glass capsule is already the container.
enum AppSymbol {
    static let more = "ellipsis"
    static let compose = "square.and.pencil"
    static let add = "plus"
    static func markRead(swipe: Bool = false) -> String { swipe ? "envelope.open.fill" : "envelope.open" }
    static func markUnread(swipe: Bool = false) -> String { swipe ? "envelope.badge.fill" : "envelope.badge" }
    static func pin(swipe: Bool = false) -> String { swipe ? "pin.fill" : "pin" }
    static func unpin(swipe: Bool = false) -> String { swipe ? "pin.slash.fill" : "pin.slash" }
    static func mute(swipe: Bool = false) -> String { swipe ? "bell.slash.fill" : "bell.slash" }
    static let alertIfQuiet = "timer"
    static let sound = "speaker.wave.2"
    /// Messages go: one message, a selection, or a topic's whole history.
    static func delete(swipe: Bool = false) -> String { swipe ? "trash.fill" : "trash" }
    /// Leaving a topic, which is not the same picture as deleting messages.
    static func unsubscribe(swipe: Bool = false) -> String { swipe ? "minus.circle.fill" : "minus.circle" }
    static let copyText = "doc.on.doc"
    static let copyLink = "link"
    static let share = "square.and.arrow.up"
    static let qrCode = "qrcode"
    static let test = "paperplane"
    static let rename = "pencil"
    static let encryption = "lock"
    static let details = "info.circle"
    static let select = "checkmark.circle"
    static let disclosure = "chevron.forward"
    static let externalLink = "arrow.up.forward"
    static let fieldClear = "xmark.circle.fill"
}

/// The trailing glyph of a row: a chevron for a push, an arrow for a link that leaves the app.
/// Same size and colour as the system NavigationLink chevron, so the accessory column is one width.
struct RowAccessoryGlyph: View {
    var systemName: String = AppSymbol.disclosure

    var body: some View {
        Image(systemName: systemName)
            .font(.footnote.weight(.semibold))
            .foregroundColor(Color(UIColor.tertiaryLabel))
            .accessibilityHidden(true)
    }
}

/// The close control of a sheet that saves as you go: the system Close button on iOS 26, "Done"
/// before it. Place it with `SheetCloseButton.placement`.
struct SheetCloseButton: View {
    let action: () -> Void

    static var placement: ToolbarItemPlacement {
        if #available(iOS 26.0, *) { return .cancellationAction }
        return .confirmationAction
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(String(localized: "Done"), action: action)
        }
    }
}

/// The in-content primary button (empty states, What's new, permission): system prominent button
/// in the brand fill with ink text, so every such button is drawn the same way.
struct BrandProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 15.0, *) {
            content
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color("BrandFill"))
                .foregroundColor(Color("Ink"))
        } else {
            content
                .foregroundColor(Color("Ink"))
        }
    }
}

extension View {
    func brandProminentButton() -> some View {
        modifier(BrandProminentButton())
    }
}

/// One notice line: a tinted symbol, the text at footnote size, and an optional borderless action
/// that sits on the same line when it fits. Used for notifications off, sign-in refused, muted and
/// not encrypted, so the four read as one family.
struct InlineNotice: View {
    let symbol: String
    var tint: Color = .secondary
    let text: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label.fixedSize()
                    Spacer(minLength: 0)
                    actionButton
                }
                stacked
            }
        } else {
            stacked
        }
    }

    private var label: some View {
        Label {
            noticeText
        } icon: {
            icon
        }
        .font(.footnote)
    }

    /// When the action doesn't fit on the line it goes under the text, in the label's title column,
    /// so it stays aligned with the text at every text size (the icon column grows with it).
    private var stacked: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                noticeText
                actionButton
            }
        } icon: {
            icon
        }
        .font(.footnote)
    }

    private var noticeText: some View {
        Text(text)
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var icon: some View {
        Image(systemName: symbol).foregroundColor(tint)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let actionTitle {
            Button(actionTitle, action: action)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
        }
    }
}

/// Select mode on a topic: Delete needs something to delete, and the back button and Compose step
/// aside so the bar holds only Delete and Done.
enum MessageSelectionChrome {
    static func deleteEnabled(selectionCount: Int) -> Bool { selectionCount > 0 }
    static func hidesBackButton(editing: Bool) -> Bool { editing }
    static func showsCompose(editing: Bool) -> Bool { !editing }
}
