import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
struct ComposeSheetView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject var subscription: Subscription
    @StateObject var model = ComposeModel()
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var confirmDiscard = false
    @Environment(\.answerHaptics) private var haptics

    init(subscription: Subscription, model: ComposeModel? = nil) {
        self.subscription = subscription
        _model = StateObject(wrappedValue: model ?? ComposeModel())
    }

    private var encrypted: Bool { store.topicKeyState(for: subscription) != .notEncrypted }

    /// A vertical text field, so "Message" lines up with "Title (optional)" above it; a
    /// TextEditor's own text inset put its placeholder 6 pt to the right.
    @ViewBuilder
    private var messageEditor: some View {
        if #available(iOS 16.0, *) {
            TextField(String(localized: "Message"), text: $model.message, axis: .vertical)
                .lineLimit(5...12)
        } else {
            TextEditor(text: $model.message)
                .frame(minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if model.message.isEmpty {
                        Text(String(localized: "Message"))
                            .foregroundColor(Color(.placeholderText))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    var body: some View {
        NavigationView {
            Form {
                // In the order the message renders: title, then body, then what's attached.
                Section(footer: attachmentFooter) {
                    TextField(String(localized: "Title (optional)"), text: $model.title)
                        .accessibilityIdentifier("compose-title")
                    messageEditor
                        .accessibilityLabel(String(localized: "Message"))
                        .accessibilityIdentifier("compose-message")
                    if !encrypted {
                        attachmentRow
                    }
                }
                Section(header: Text(String(localized: "Options"))) {
                    Toggle(String(localized: "Markdown"), isOn: $model.markdown)
                    TextField(String(localized: "Tags, separated by commas"), text: $model.tags)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Picker(String(localized: "Priority"), selection: $model.priority) {
                        Text(String(localized: "Minimum")).tag(1)
                        Text(String(localized: "Low")).tag(2)
                        Text(String(localized: "Default")).tag(3)
                        Text(String(localized: "High")).tag(4)
                        Text(String(localized: "Maximum")).tag(5)
                    }
                    urlField(String(localized: "Click URL (optional)"), text: $model.clickURL).accessibilityIdentifier("compose-click")
                    TextField(String(localized: "Delay, for example 30m or 3h"), text: $model.delay)
                        .autocapitalization(.none).disableAutocorrection(true)
                    Text(String(localized: "Delayed messages appear when the server delivers them.")).font(.caption).foregroundColor(.secondary)
                    if !encrypted && model.fileURL == nil {
                        urlField(String(localized: "Attachment URL (optional)"), text: $model.attachmentURL)
                    }
                }
                if !model.error.isEmpty {
                    Section {
                        Label(model.error, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red).accessibilityIdentifier("compose-error")
                    }
                }
                if model.busy {
                    Section { ProgressView(String(localized: "Sending…")) }
                }
            }
            .disabled(model.busy)
            .navigationBarTitleDisplayMode(.inline)
            // The topic is the title, its short address the subtitle, in the same format as the
            // topic list (no scheme).
            .modifier(ComposeTitle(title: subscription.shortDisplayName(), subtitle: subscription.shortUrlString()))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        if model.dirty { confirmDiscard = true } else { close() }
                    }.disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        haptics.play(.press)
                        model.send(subscription: subscription, store: store) {
                            haptics.play(.success)
                            SubscriptionManager(store: store).pollWithOutcome(subscription, manual: true) { _ in }
                            close()
                        }
                    } label: {
                        // The colour sits on the Text: glassProminent ignores a foregroundStyle on the button.
                        if let label = ComposeSendLook.label(enabled: model.canSend) {
                            Text(String(localized: "Send")).foregroundColor(label)
                        } else {
                            Text(String(localized: "Send"))
                        }
                    }
                        .modifier(ComposeSendLook())
                        .disabled(!model.canSend).accessibilityIdentifier("compose-send")
                }
            }
            .alert(String(localized: "Discard message?"), isPresented: $confirmDiscard) {
                Button(String(localized: "Discard"), role: .destructive, action: close)
                Button(String(localized: "Keep editing"), role: .cancel) {}
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .interactiveDismissDisabled(model.busy || model.dirty)
        .onChange(of: model.error) { error in
            if !error.isEmpty { haptics.play(.failure) }
        }
        .onAppear(perform: loadLimits)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item]) { model.selectFile($0) }
        .sheet(isPresented: $showPhotos) {
            ComposePhotoPicker(limit: model.attachmentLimit ?? 0, cancel: { showPhotos = false }) { result in
                showPhotos = false
                switch result {
                case .success(let url): model.acceptFile(url)
                case .failure(let failure): model.error = failure.userMessage
                }
            }
        }
    }

    /// Photo and file buttons directly under the message; once something is attached, a
    /// thumbnail or file chip with a remove control in their place.
    @ViewBuilder
    private var attachmentRow: some View {
        if let fileURL = model.fileURL {
            HStack(spacing: 10) {
                if let image = UIImage(contentsOfFile: fileURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .accessibilityLabel(model.fileName)
                    Spacer(minLength: 0)
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "doc")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                        Text(model.fileName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(minHeight: 44)
                    .background(Color(.secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Button { model.removeFile() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Remove attachment"))
            }
        } else {
            HStack(spacing: 4) {
                Button { showPhotos = true } label: {
                    Image(systemName: "photo").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Choose photo"))
                .accessibilityIdentifier("compose-photo")
                .disabled(!canAttachFile)
                Button { showFiles = true } label: {
                    Image(systemName: "paperclip").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Choose file"))
                .accessibilityIdentifier("compose-file")
                .disabled(!canAttachFile)
                Spacer(minLength: 0)
                if model.attachmentLimit == nil {
                    Button(String(localized: "Check upload limits")) { loadLimits() }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .disabled(model.loadingLimits)
                }
            }
            .font(.title3)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
        }
    }

    private var canAttachFile: Bool {
        guard let limit = model.attachmentLimit else { return false }
        return limit > 0 && model.attachmentURL.isEmpty
    }

    @ViewBuilder
    private var attachmentFooter: some View {
        if encrypted {
            Text(String(localized: "Attachments are unavailable for encrypted topics. Your message, title, tags and click URL stay encrypted."))
        } else if let limit = model.attachmentLimit {
            Text(String(localized: "Available upload size: \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))"))
        } else {
            Text(String(localized: "Upload limits are unavailable. You can still attach a URL."))
        }
    }

    private func urlField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text).keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
            .accessibilityLabel(label)
    }
    private func loadLimits() {
        guard !encrypted else { return }
        let baseURL = subscription.baseUrl ?? ""
        model.loadLimits(baseURL: baseURL, user: store.getTransportCredential(baseUrl: baseURL))
    }
    private func close() {
        model.close()
        presentationMode.wrappedValue.dismiss()
    }
}

/// The system photo picker grants just the selected item; no library entitlement is needed.
private struct ComposePhotoPicker: UIViewControllerRepresentable {
    let limit: Int64
    let cancel: () -> Void
    let completion: (Result<URL, ApiService.PublishError>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ComposePhotoPicker
        init(_ parent: ComposePhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else { parent.cancel(); return }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                let result: Result<URL, ApiService.PublishError>
                if let url {
                    do { result = .success(try ComposeModel.stage(url, limit: self.parent.limit)) }
                    catch { result = .failure((error as? ApiService.PublishError) ?? .attachmentUnreadable) }
                } else { result = .failure(.attachmentUnreadable) }
                DispatchQueue.main.async { self.parent.completion(result) }
            }
        }
    }
}

private struct ComposeTitle: ViewModifier {
    let title: String
    let subtitle: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
        } else {
            content.toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Compose's Send in the toolbar: on iOS 26 a prominent glass button in the answer fill with a white
/// label, the same green as every other Send; earlier, the answer fill as the text colour.
struct ComposeSendLook: ViewModifier {
    /// The label on the Forest glass. Set, never left to the system: iOS 26 picks black for this green
    /// in dark mode (3.74:1, DESIGN-REVIEW F1). Disabled keeps the system's dimmed look.
    static func label(enabled: Bool) -> Color? { enabled ? AnswerColor.label : nil }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent).tint(AnswerColor.fill)
        } else {
            content.tint(AnswerColor.fill)
        }
    }
}
