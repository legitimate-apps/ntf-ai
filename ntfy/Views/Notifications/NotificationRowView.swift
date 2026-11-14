//
//  NotificationRowView.swift
//  ntfy
//
//  Created by Alek Michelson on 5/11/26.
//

import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct NotificationRowView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openURL) private var openURL
    @Environment(\.editMode) private var editMode
    @Environment(\.sizeCategory) private var sizeCategory
    @ObservedObject var notification: Notification
    let onCopyMessage: () -> Void
    /// Unread when the topic was opened: keeps the dot and weight for this visit (see HeldUnreadMarkers).
    var heldUnread = false
    /// The user set this row's read state themselves, which ends the hold.
    var onReleaseHeldUnread: () -> Void = {}
    @ScaledMetric(relativeTo: .subheadline) private var priorityGlyphSize = MessageRowMetrics.priorityGlyphSize
    @StateObject private var attachmentController = NotificationAttachmentController()
    @State private var browserURL: URL?
    @State private var attachmentPresentation: AttachmentPresentation?
    @State private var metadataWidth: CGFloat = 0
    @State private var isExpanded = false
    @State private var titleExceedsCap = false
    @State private var bodyExceedsCap = false
    
    var body: some View {
        notificationRow
            .swipeActions(edge: .leading) {
                Button {
                    toggleRead()
                } label: {
                    readToggleLabel(swipe: true)
                }
                .tint(Color("BrandControlFill"))
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    store.delete(notification: notification)
                } label: {
                    Label(String(localized: "Delete"), systemImage: AppSymbol.delete(swipe: true))
                }
                // The app-wide tint overrides the destructive role in swipe actions; keep it red.
                .tint(.red)
            }
            .background(InAppBrowser(url: $browserURL))
            .sheet(item: $attachmentPresentation) { attachmentPresentation in
                switch attachmentPresentation.mode {
                case .preview:
                    AttachmentPreviewView(url: attachmentPresentation.url)
                case .share:
                    ActivityView(activityItems: [attachmentPresentation.url])
                }
            }
    }
    
    private var notificationRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            messageContentWithTapPolicy

            if let attachment = notification.messageAttachment() {
                NotificationAttachmentSectionView(
                    notification: notification,
                    attachment: attachment,
                    authorizationHeader: attachmentAuthorizationHeader,
                    controller: attachmentController,
                    onOpen: { attachmentPresentation = AttachmentPresentation(url: $0, mode: .preview) },
                    onShare: { attachmentPresentation = AttachmentPresentation(url: $0, mode: .share) },
                    onSave: { url in
                        Task { @MainActor in
                            AttachmentExportPresenter.shared.present(url: url)
                        }
                    },
                    onCopy: showCopyFeedback
                )
                .padding(.leading, contentLeadingInset)
            }
            if !notification.actionsList().isEmpty {
                MessageActionButtons(
                    actions: notification.actionsList(),
                    run: runAction
                )
                .padding(.top, 8)
                .padding(.leading, contentLeadingInset)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsUnread {
                // Inside the row's leading inset, so the text column stays on the screen margin.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: MessageRowMetrics.unreadDotSize, height: MessageRowMetrics.unreadDotSize)
                    .offset(x: -MessageRowMetrics.unreadDotGutter,
                            y: max(0, firstLineHeight / 2 - MessageRowMetrics.unreadDotSize / 2))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { messageMenuItems }
        .accessibilityElement(children: .contain)
        .accessibilityValue(showsUnread ? String(localized: "Unread") : "")
        .modifier(SeparatorFromRowLeadingEdge())
    }

    private func runAction(_ action: Action) {
        ActionExecutor.execute(
            action,
            notificationId: notification.id,
            baseUrl: notification.subscription?.baseUrl,
            openURL: openMessageURL
        )
        if action.copiesText {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showCopyFeedback()
        }
    }

    @ViewBuilder
    private var messageContentWithTapPolicy: some View {
        if tapPolicy.installsAncestorContentTap {
            messageContent
                .contentShape(Rectangle())
                .onTapGesture {
                    handleRowTap()
                }
        } else {
            messageContent
        }
    }

    private var title: String? {
        guard let title = notification.formatTitle(), !title.isEmpty else { return nil }
        return title
    }

    private var titleStyle: MessageTextStyle {
        .title(read: !showsUnread)
    }

    /// The style of whichever text opens the row: the title, or the body when there is none.
    private var firstLineStyle: MessageTextStyle {
        title == nil ? .body : titleStyle
    }

    private var traitCollection: UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(sizeCategory))
    }

    private var firstLineHeight: CGFloat {
        firstLineStyle.lineHeight(compatibleWith: traitCollection)
    }

    private var showsPriority: Bool {
        [4, 5].contains(notification.priority)
    }

    /// At accessibility sizes the time gets its own line under the title instead of sharing one.
    private var stacksMetadata: Bool {
        sizeCategory.isAccessibilityCategory
    }

    private var contentLeadingInset: CGFloat {
        notification.iconUrl() == nil ? 0 : MessageRowMetrics.iconSize + MessageRowMetrics.iconSpacing
    }

    private var messageContent: some View {
        HStack(alignment: .top, spacing: MessageRowMetrics.iconSpacing) {
            if let iconUrl = notification.iconUrl() {
                AsyncImage(url: iconUrl) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.secondarySystemFill)
                }
                .frame(width: MessageRowMetrics.iconSize, height: MessageRowMetrics.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
                .modifier(MessageRowTapModifier(enabled: installsMessageRegionTaps, action: handleRowTap))
            }
            VStack(alignment: .leading, spacing: 0) {
                firstLine
                if title != nil {
                    messageText
                        .padding(.top, 2)
                }
                if let cue = messageRowExpansionCue(exceedsLineCap: exceedsLineCap, isExpanded: isExpanded) {
                    expansionToggle(cue)
                }
                if notification.encryptionState == .locked {
                    Text(String(localized: "Set this topic's password (topic menu → End-to-end encryption) to read it."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding([.top], 2)
                        .modifier(MessageRowTapModifier(enabled: installsMessageRegionTaps, action: handleRowTap))
                }
                if !notification.nonEmojiTags().isEmpty {
                    Text(notification.nonEmojiTags().joined(separator: " · "))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding([.top], 4)
                        .accessibilityLabel(String(localized: "Tags: \(notification.nonEmojiTags().joined(separator: ", "))"))
                        .modifier(MessageRowTapModifier(enabled: installsMessageRegionTaps, action: handleRowTap))
                }
            }
        }
    }

    /// Line 1: [priority] title (or the body's first line) with the time trailing on the same
    /// baseline. The glyph and the time are reserved out of the text's first line only, so a
    /// wrapped title or body uses the full width below them.
    @ViewBuilder
    private var firstLine: some View {
        if stacksMetadata {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if showsPriority { priorityGlyph }
                    firstText(exclusion: FirstLineExclusion())
                }
                metadata
            }
        } else {
            ZStack(alignment: Alignment(horizontal: .trailing, vertical: .firstTextBaseline)) {
                firstText(exclusion: FirstLineExclusion(
                    leading: showsPriority ? priorityGlyphSize + 4 : 0,
                    trailing: metadataWidth > 0 ? metadataWidth + 8 : 0,
                    lineHeight: max(0, firstLineHeight - 1)
                ))
                metadata
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: MetadataWidthKey.self, value: proxy.size.width)
                    })
            }
            .overlay(alignment: .topLeading) {
                if showsPriority {
                    priorityGlyph
                        .padding(.top, max(0, (firstLineHeight - priorityGlyphSize) / 2))
                }
            }
            .onPreferenceChange(MetadataWidthKey.self) { metadataWidth = ceil($0) }
        }
    }

    @ViewBuilder
    private func firstText(exclusion: FirstLineExclusion) -> some View {
        let style = firstLineStyle
        let baseline = style.firstBaseline(compatibleWith: traitCollection)
        Group {
            if let title {
                SelectableMessageText(
                    attributedText: renderMessageTitle(title),
                    style: style,
                    exclusion: exclusion,
                    lineCap: MessageRowLineCap.title(accessibilitySize: sizeCategory.isAccessibilityCategory),
                    isCollapsed: !isExpanded,
                    isInteractionEnabled: !isEditing,
                    onOpenURL: openMessageURL, onPlainTap: handleRowTap,
                    onExceedsLineCapChange: { titleExceedsCap = $0 }
                )
            } else {
                SelectableMessageText(
                    attributedText: notification.renderedMessageAttributedString(),
                    style: .body,
                    exclusion: exclusion,
                    lineCap: MessageRowLineCap.body,
                    isCollapsed: !isExpanded,
                    isInteractionEnabled: !isEditing,
                    onOpenURL: openMessageURL, onPlainTap: handleRowTap,
                    onExceedsLineCapChange: { bodyExceedsCap = $0 }
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.firstTextBaseline) { _ in baseline }
    }

    private var priorityGlyph: some View {
        Image("priority-\(notification.priority)")
            .resizable()
            .scaledToFit()
            .frame(width: priorityGlyphSize, height: priorityGlyphSize)
            .accessibilityLabel(priorityLabel)
    }

    /// Encryption state and time at footnote size on one baseline. The message's actions live in
    /// the long-press menu, so line 1 carries no button.
    private var metadata: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            switch notification.encryptionState {
            case .none:
                EmptyView()
            case .decrypted, .locked:
                // Locked reads as a warning (can't read it yet), not as a lighter lock.
                Image(systemName: notification.encryptionState == .locked ? "lock.trianglebadge.exclamationmark" : "lock.fill")
                    .font(.caption)
                    .foregroundColor(notification.encryptionState == .locked ? .orange : .secondary)
                    .accessibilityLabel(notification.encryptionState == .locked
                        ? String(localized: "Encrypted, not readable yet")
                        : String(localized: "End-to-end encrypted"))
            case .unencrypted:
                Label(String(localized: "Not encrypted"), systemImage: "lock.open")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .accessibilityLabel(String(localized: "Not encrypted: this topic has a password, but this message was sent without it"))
            }
            Text(Notification.shortTime(for: notification.date()))
                .font(.footnote.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                // Never truncate the time (ntfy#1205): it keeps its width and the text yields.
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityLabel(notification.shortDateTime())
        }
        .fixedSize()
        .modifier(MessageRowTapModifier(enabled: installsMessageRegionTaps, action: handleRowTap))
    }

    private var messageText: some View {
        SelectableMessageText(
            attributedText: notification.renderedMessageAttributedString(),
            style: .body,
            exclusion: FirstLineExclusion(),
            lineCap: MessageRowLineCap.body,
            isCollapsed: !isExpanded,
            isInteractionEnabled: !isEditing,
            onOpenURL: openMessageURL, onPlainTap: handleRowTap,
            onExceedsLineCapChange: { bodyExceedsCap = $0 }
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exceedsLineCap: Bool {
        titleExceedsCap || bodyExceedsCap
    }

    /// The cut-off cue after the last line ("more"), and "less" in the same spot once expanded,
    /// each with its own tap so a row whose tap opens a click URL can still expand and collapse.
    /// Plain text, not a Button: a Button in the List row rendered blank.
    private func expansionToggle(_ cue: MessageRowExpansionCue) -> some View {
        Text(cue == .less ? String(localized: "less") : String(localized: "more"))
            .font(.subheadline)
            .foregroundColor(.secondary)
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(MessageRowTapModifier(enabled: installsMessageRegionTaps, action: toggleExpansion))
            .accessibilityAddTraits(.isButton)
    }

    private func toggleExpansion() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded.toggle()
        }
    }

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing == true
    }

    private var installsMessageRegionTaps: Bool {
        tapPolicy.installsRegionTaps
    }

    private var tapPolicy: MessageRowTapPolicy {
        messageRowTapPolicy(isEditing: isEditing)
    }
    
    private var clickUrl: URL? {
        guard let click = notification.click, !click.isEmpty else {
            return nil
        }
        return URL(string: click)
    }

    private var attachmentAuthorizationHeader: String? {
        guard
            let baseUrl = notification.subscription?.baseUrl,
            let user = store.getBasicUser(baseUrl: baseUrl)
        else {
            return nil
        }
        return user.toHeader()
    }
    
    /// The long-press menu: everything the row offers besides its swipe actions.
    @ViewBuilder
    private var messageMenuItems: some View {
        Button {
            copyMessage()
        } label: {
            Label(String(localized: "Copy message"), systemImage: "doc.on.doc")
        }
        if let title = notification.title, !title.isEmpty {
            Button {
                UIPasteboard.general.setValue(title, forPasteboardType: UTType.plainText.identifier)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                showCopyFeedback()
            } label: {
                Label(String(localized: "Copy title"), systemImage: AppSymbol.copyText)
            }
        }
        if #available(iOS 16.0, *) {
            ShareLink(item: shareText) {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
        Button {
            toggleRead()
        } label: {
            readToggleLabel(swipe: false)
        }
        Button(role: .destructive) {
            store.delete(notification: notification)
        } label: {
            Label(String(localized: "Delete"), systemImage: AppSymbol.delete())
        }
    }

    /// Unread as the row shows it: really unread, or held from when the topic was opened.
    private var showsUnread: Bool {
        !notification.read || heldUnread
    }

    private func readToggleLabel(swipe: Bool) -> some View {
        Label(showsUnread ? String(localized: "Mark read") : String(localized: "Mark unread"),
              systemImage: showsUnread ? AppSymbol.markRead(swipe: swipe) : AppSymbol.markUnread(swipe: swipe))
    }

    private func toggleRead() {
        let read = showsUnread
        onReleaseHeldUnread()
        store.setRead(read, forNotification: notification)
    }

    private var shareText: String {
        [notification.title, notification.formatMessage()]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private var priorityLabel: String {
        switch notification.priority {
        case 1: return String(localized: "Minimum priority")
        case 2: return String(localized: "Low priority")
        case 4: return String(localized: "High priority")
        case 5: return String(localized: "Maximum priority")
        default: return String(localized: "Default priority")
        }
    }

    private func copyMessage() {
        UIPasteboard.general.setValue(notification.formatMessage(), forPasteboardType: UTType.plainText.identifier)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showCopyFeedback()
    }

    private func showCopyFeedback() {
        onCopyMessage()
    }
    
    private func openMessageURL(_ url: URL) {
        if InAppBrowser.shouldOpen(url, enabled: UserDefaults.standard.bool(forKey: InAppBrowser.preferenceKey)) {
            browserURL = url
        } else { openURL(url) }
    }

    private func handleRowTap() {
        switch messageRowTapAction(hasClickURL: clickUrl != nil, exceedsLineCap: exceedsLineCap) {
        case .openClickURL:
            if let clickUrl { openMessageURL(clickUrl) }
        case .toggleExpansion:
            toggleExpansion()
        case .none:
            break
        }
    }
}

// MARK: Helper structs
extension NotificationRowView {
    private struct MessageRowTapModifier: ViewModifier {
        let enabled: Bool
        let action: () -> Void

        @ViewBuilder
        func body(content: Content) -> some View {
            if enabled {
                content
                    .contentShape(Rectangle())
                    .onTapGesture(perform: action)
            } else {
                content
            }
        }
    }

    private struct SelectableMessageText: UIViewRepresentable {
        let attributedText: AttributedString
        let style: MessageTextStyle
        var exclusion = FirstLineExclusion()
        var lineCap = 0
        var isCollapsed = true
        let isInteractionEnabled: Bool
        let onOpenURL: (URL) -> Void
        let onPlainTap: () -> Void
        var onExceedsLineCapChange: (Bool) -> Void = { _ in }

        func makeCoordinator() -> Coordinator {
            Coordinator(onOpenURL: onOpenURL, onPlainTap: onPlainTap)
        }

        func makeUIView(context: Context) -> MessageTextView {
            let textView = MessageTextView(frame: .zero, textContainer: nil)
            configureMessageTextView(textView, isInteractionEnabled: isInteractionEnabled)
            textView.delegate = context.coordinator
            context.coordinator.installTapRecognizer(on: textView)
            return textView
        }

        func updateUIView(_ textView: MessageTextView, context: Context) {
            context.coordinator.onOpenURL = onOpenURL
            context.coordinator.onPlainTap = onPlainTap
            configureMessageTextView(textView, isInteractionEnabled: isInteractionEnabled)
            let report = onExceedsLineCapChange
            // Reported from layout, so the state change waits for the current update to finish.
            textView.onExceedsLineCapChange = { exceeds in DispatchQueue.main.async { report(exceeds) } }
            textView.setMessageText(attributedText, style: style)
            textView.setFirstLineExclusion(exclusion)
            textView.setLineCap(lineCap, collapsed: isCollapsed)
            // Report the current answer on every update too, not only on a change: a List can hand
            // this row a text view that already measured "exceeds" for an earlier row, and then no
            // change ever fires and the row never shows "more".
            let exceeds = textView.exceedsLineCap
            DispatchQueue.main.async { report(exceeds) }
        }

        /// The height at the width SwiftUI proposes. Reporting it through `intrinsicContentSize`
        /// alone left rows sized from a stale `bounds` (the same row 162 pt in light, 182 in dark).
        @available(iOS 16.0, *)
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: MessageTextView, context: Context) -> CGSize? {
            guard let width = proposal.width, width > 0, width.isFinite else { return nil }
            return CGSize(width: width, height: uiView.fittingHeight(forWidth: width))
        }

        final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
            var onOpenURL: (URL) -> Void
            var onPlainTap: () -> Void

            init(onOpenURL: @escaping (URL) -> Void, onPlainTap: @escaping () -> Void) {
                self.onOpenURL = onOpenURL
                self.onPlainTap = onPlainTap
            }

            func installTapRecognizer(on textView: UITextView) {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                recognizer.cancelsTouchesInView = false
                recognizer.delegate = self
                textView.addGestureRecognizer(recognizer)
            }

            @objc
            private func handleTap(_ recognizer: UITapGestureRecognizer) {
                guard
                    recognizer.state == .ended,
                    let textView = recognizer.view as? UITextView,
                    !linkWasTapped(by: recognizer, in: textView)
                else {
                    return
                }
                onPlainTap()
            }

            private func linkWasTapped(
                by recognizer: UITapGestureRecognizer,
                in textView: UITextView
            ) -> Bool {
                let location = recognizer.location(in: textView)
                let point = CGPoint(
                    x: location.x - textView.textContainerInset.left,
                    y: location.y - textView.textContainerInset.top
                )
                let layoutManager = textView.layoutManager
                let glyphIndex = layoutManager.glyphIndex(
                    for: point,
                    in: textView.textContainer,
                    fractionOfDistanceThroughGlyph: nil
                )
                guard glyphIndex < layoutManager.numberOfGlyphs else {
                    return false
                }
                let glyphRect = layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyphIndex, length: 1),
                    in: textView.textContainer
                )
                guard glyphRect.insetBy(dx: -2, dy: -2).contains(point) else {
                    return false
                }
                let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
                guard characterIndex < textView.attributedText.length else {
                    return false
                }
                return textView.attributedText.attribute(
                    .link,
                    at: characterIndex,
                    effectiveRange: nil
                ) != nil
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
            ) -> Bool {
                // Cooperate with UITextView's own link/selection recognizers. The
                // SwiftUI hierarchy intentionally has no ancestor content tap.
                otherGestureRecognizer.view === gestureRecognizer.view
            }

            func textView(
                _ textView: UITextView,
                shouldInteractWith URL: URL,
                in characterRange: NSRange,
                interaction: UITextItemInteraction
            ) -> Bool {
                guard interaction == .invokeDefaultAction else { return true }
                onOpenURL(URL)
                return false
            }

            @available(iOS 17.0, *)
            func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
                guard case .link(let url) = textItem.content else { return defaultAction }
                return UIAction { [weak self] _ in self?.onOpenURL(url) }
            }

            @available(iOS 17.0, *)
            func textView(
                _ textView: UITextView,
                menuConfigurationFor textItem: UITextItem,
                defaultMenu: UIMenu
            ) -> UITextItem.MenuConfiguration? {
                UITextItem.MenuConfiguration(menu: preservedDefaultLinkMenu(defaultMenu))
            }
        }
    }

    struct ActivityView: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        }
    }

    struct AttachmentPresentation: Identifiable {
        enum Mode {
            case preview
            case share
        }

        let id = UUID()
        let url: URL
        let mode: Mode
    }

    struct AttachmentPreviewView: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> UINavigationController {
            let controller = AttachmentPreviewController(onClose: {
                context.coordinator.dismiss?()
            })
            controller.configure(url: url)
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.modalPresentationStyle = .pageSheet
            context.coordinator.dismiss = { [weak navigationController] in
                navigationController?.dismiss(animated: true)
            }
            return navigationController
        }

        func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
            guard let controller = uiViewController.viewControllers.first as? AttachmentPreviewController else {
                return
            }
            controller.configure(url: url)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        final class Coordinator {
            var dismiss: (() -> Void)?
        }
    }

    private final class AttachmentPreviewController: QLPreviewController, QLPreviewControllerDataSource {
        private let loadingView = UIActivityIndicatorView(style: .large)
        private let onClose: () -> Void
        private var previewItem: PreviewItem?
        private var configuredURL: URL?
        private var hasLoadedCurrentItem = false

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()

            view.backgroundColor = .systemBackground
            dataSource = self
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(closePreview)
            )

            loadingView.translatesAutoresizingMaskIntoConstraints = false
            loadingView.hidesWhenStopped = true
            loadingView.startAnimating()
            view.addSubview(loadingView)

            NSLayoutConstraint.activate([
                loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !hasLoadedCurrentItem else {
                return
            }
            hasLoadedCurrentItem = true
            reloadPreview()
        }

        func configure(url: URL) {
            guard configuredURL != url else {
                return
            }
            configuredURL = url
            previewItem = PreviewItem(url: url)
            navigationItem.title = url.lastPathComponent
            hasLoadedCurrentItem = false
            if isViewLoaded {
                loadingView.startAnimating()
                if view.window != nil {
                    hasLoadedCurrentItem = true
                    reloadPreview()
                }
            }
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            previewItem == nil ? 0 : 1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            previewItem ?? PreviewItem(url: URL(fileURLWithPath: ""))
        }

        private func reloadPreview() {
            reloadData()
            currentPreviewItemIndex = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.loadingView.stopAnimating()
            }
        }

        @objc
        private func closePreview() {
            onClose()
        }
    }

    private final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL) {
            self.previewItemURL = url
            self.previewItemTitle = url.lastPathComponent
        }
    }

    @MainActor
    final class AttachmentExportPresenter: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        static let shared = AttachmentExportPresenter()
        private var activePicker: UIDocumentPickerViewController?
        private var activeExportUrl: URL?

        func present(url: URL) {
            guard let presenter = topViewController(from: rootViewController()) else {
                return
            }

            let exportUrl: URL
            do {
                exportUrl = try makeTemporaryExportCopy(of: url)
            } catch {
                Log.w("AttachmentExportPresenter", "Failed to prepare attachment export copy", error)
                return
            }

            cleanupActiveExport()

            let picker = UIDocumentPickerViewController(forExporting: [exportUrl], asCopy: true)
            picker.delegate = self
            picker.presentationController?.delegate = self
            activePicker = picker
            activeExportUrl = exportUrl
            presenter.present(picker, animated: true)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            cleanupIfActive(controller)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            cleanupIfActive(controller)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let picker = presentationController.presentedViewController as? UIDocumentPickerViewController else {
                return
            }
            cleanupIfActive(picker)
        }

        private func rootViewController() -> UIViewController? {
            UIApplication.shared
                .connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }?
                .rootViewController
        }

        private func topViewController(from controller: UIViewController?) -> UIViewController? {
            if let navigationController = controller as? UINavigationController {
                return topViewController(from: navigationController.visibleViewController)
            }
            if let tabBarController = controller as? UITabBarController {
                return topViewController(from: tabBarController.selectedViewController)
            }
            if let presentedViewController = controller?.presentedViewController {
                return topViewController(from: presentedViewController)
            }
            return controller
        }

        private func cleanupIfActive(_ controller: UIDocumentPickerViewController) {
            guard activePicker === controller else {
                return
            }
            cleanupActiveExport()
        }

        private func cleanupActiveExport() {
            activePicker = nil
            if let activeExportUrl {
                try? FileManager.default.removeItem(at: activeExportUrl)
            }
            activeExportUrl = nil
        }

        private func makeTemporaryExportCopy(of url: URL) throws -> URL {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ntfy-export", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let destinationUrl = tempDir.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: destinationUrl)
            try FileManager.default.copyItem(at: url, to: destinationUrl)
            return destinationUrl
        }
    }

}

// MARK: Row layout

/// One message-row spec (REVIEW.md 2026-11-12, finding 1): every number the row uses.
enum MessageRowMetrics {
    static let verticalInset: CGFloat = 10

    /// Before iOS 26 a row can't set only its vertical insets, so the horizontal margin is spelled
    /// out as UIKit picks it: 20 pt on lists 414 pt wide and up, 16 below.
    static func horizontalMargin(listWidth: CGFloat) -> CGFloat {
        listWidth >= 414 ? 20 : 16
    }

    static func insets(listWidth: CGFloat) -> EdgeInsets {
        let margin = horizontalMargin(listWidth: listWidth)
        return EdgeInsets(top: verticalInset, leading: margin, bottom: verticalInset, trailing: margin)
    }
    static let unreadDotSize: CGFloat = 8
    /// The dot's leading edge sits this far left of the text column, inside the row's inset.
    static let unreadDotGutter: CGFloat = 12
    static let priorityGlyphSize: CGFloat = 12
    static let iconSize: CGFloat = 28
    static let iconSpacing: CGFloat = 8
}

/// Starts the row's separator at the row's own leading edge. SwiftUI otherwise aligns it to the
/// first SwiftUI `Text` it finds; title and body are UIKit text views, so in some rows that was the
/// time at the trailing edge and the separator became a stub under it.
private struct SeparatorFromRowLeadingEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        } else {
            content
        }
    }
}

private struct MetadataWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A message's action buttons: quiet tinted capsules that wrap onto more lines instead of
/// squeezing three long labels into one.
struct MessageActionButtons: View {
    @Environment(\.colorScheme) private var colorScheme
    let actions: [Action]
    let run: (Action) -> Void

    var body: some View {
        if #available(iOS 16.0, *) {
            WrappingHStack(spacing: 8, lineSpacing: 8) { buttons }
        } else {
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
    }

    private var buttons: some View {
        ForEach(actions) { action in
            Button(action.label) { run(action) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .buttonBorderShape(.capsule)
                .tint(Color("BrandFill"))
                // Ink on the pale tinted fill in light mode, the brand yellow in dark: both
                // pass contrast, where yellow text on white would not.
                .foregroundColor(colorScheme == .dark ? Color("BrandFill") : Color("Ink"))
                .lineLimit(1)
        }
    }
}

/// Lays children out left to right and starts a new line when the next one doesn't fit.
@available(iOS 16.0, *)
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = WrappingHStack.frames(for: subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) },
                                           width: width, spacing: spacing, lineSpacing: lineSpacing)
        let used = frames.reduce(CGRect.null) { $0.union($1) }
        return used.isNull ? .zero : CGSize(width: used.maxX, height: used.maxY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.init(width: bounds.width, height: nil)) }
        let frames = WrappingHStack.frames(for: sizes, width: bounds.width, spacing: spacing, lineSpacing: lineSpacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Pure line-breaking, testable without a view tree. A child wider than the line gets the
    /// line to itself, clamped to its width.
    static func frames(for sizes: [CGSize], width: CGFloat, spacing: CGFloat, lineSpacing: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for size in sizes {
            let itemWidth = min(size.width, width)
            if x > 0, x + itemWidth > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
            x += itemWidth + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
