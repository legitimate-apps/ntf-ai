import SwiftUI
import UIKit

enum FeedbackSettings {
    static let shakeKey = "shakeToSendFeedback"
    static let includeLogsKey = "feedbackIncludeLogs"

    static func shakeEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: shakeKey) as? Bool ?? true
    }
}

/// Shake opens feedback only when nothing else claims it: iOS uses shake for undo while text is
/// being edited, and a sheet or alert already on screen keeps the person's attention.
enum ShakeGuard {
    static func shouldOpen(enabled: Bool, active: Bool, editingText: Bool, presenting: Bool) -> Bool {
        enabled && active && !editingText && !presenting
    }
}

struct FeedbackRequest: Identifiable, Equatable {
    let id = UUID()
    let kind: FeedbackKind
    let source: FeedbackSource
}

/// One presenter for the three ways in: Settings, a shake, and "Not really" on the review question.
final class FeedbackCenter: ObservableObject {
    static let shared = FeedbackCenter()
    static let shook = Foundation.Notification.Name("FeedbackDeviceShook")
    @Published var request: FeedbackRequest?

    func present(kind: FeedbackKind = .feedback, source: FeedbackSource) {
        DispatchQueue.main.async { self.request = FeedbackRequest(kind: kind, source: source) }
    }

    func handleShake() {
        guard ShakeGuard.shouldOpen(enabled: FeedbackSettings.shakeEnabled(),
                                    active: UIApplication.shared.applicationState == .active,
                                    editingText: Self.editingText(),
                                    presenting: request != nil || Self.screenBusy()) else { return }
        present(source: .shake)
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }
    }

    /// A sheet, alert or menu is up.
    static func screenBusy() -> Bool { keyWindow?.rootViewController?.presentedViewController != nil }

    static func editingText() -> Bool {
        FirstResponder.current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.feedbackCaptureFirstResponder), to: nil, from: nil, for: nil)
        defer { FirstResponder.current = nil }
        return FirstResponder.current is UITextInput
    }
}

private enum FirstResponder { static weak var current: UIResponder? }

extension UIResponder {
    @objc fileprivate func feedbackCaptureFirstResponder() { FirstResponder.current = self }
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake { NotificationCenter.default.post(name: FeedbackCenter.shook, object: nil) }
    }
}

/// Hosts the feedback sheet and the review question above the whole app.
struct FeedbackHost: ViewModifier {
    @ObservedObject private var center = FeedbackCenter.shared
    @ObservedObject private var review = ReviewPrompt.shared

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: FeedbackCenter.shook)) { _ in center.handleShake() }
            .background(EmptyView().sheet(item: $center.request) { request in
                #if DEBUG
                FeedbackDebug.sheet(request: request) { center.request = nil }
                #else
                FeedbackSheet(request: request) { center.request = nil }
                #endif
            })
            #if DEBUG
            .onAppear(perform: FeedbackDebug.start)
            #endif
            .background(EmptyView().alert(isPresented: $review.asking) {
                Alert(title: Text(String(localized: "Enjoying NTF-AI?")),
                      primaryButton: .default(Text(String(localized: "Yes"))) { review.answeredYes() },
                      secondaryButton: .default(Text(String(localized: "Not really"))) { review.answeredNotReally() })
            })
    }
}

struct FeedbackSheet: View {
    enum Phase: Equatable { case editing, sending, sent, queued, failed }

    let request: FeedbackRequest
    let onClose: () -> Void
    var send: (FeedbackPayload, FeedbackKind, @escaping (FeedbackSendResult) -> Void) -> Void = { payload, kind, done in
        FeedbackSender.shared.send(payload, kind: kind, completion: done)
    }
    @State private var note: String
    @State private var email: String
    @State private var phase: Phase
    @AppStorage(FeedbackSettings.includeLogsKey) private var includeLogs = false

    init(request: FeedbackRequest, onClose: @escaping () -> Void,
         note: String = "", email: String = "", phase: Phase = .editing) {
        self.request = request
        self.onClose = onClose
        _note = State(initialValue: note)
        _email = State(initialValue: email)
        _phase = State(initialValue: phase)
    }

    private var canSend: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .sending
    }

    var body: some View {
        NavigationView {
            Group {
                if phase == .sent || phase == .queued {
                    confirmation
                } else {
                    form
                }
            }
            .navigationTitle(String(localized: "Send feedback"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase != .sent && phase != .queued {
                        Button(String(localized: "Cancel"), action: onClose)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if phase == .sending {
                        ProgressView().accessibilityLabel(String(localized: "Sending"))
                    } else if phase == .sent || phase == .queued {
                        Button(String(localized: "Done"), action: onClose)
                    } else {
                        Button(String(localized: "Send"), action: submit)
                            .disabled(!canSend)
                            .accessibilityIdentifier("feedback-send")
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var form: some View {
        Form {
            Section(header: dislikeHeader, footer: Text(String(localized: "Includes app and device details to help us fix problems. Anonymous unless you add your email."))) {
                ZStack(alignment: .topLeading) {
                    if note.isEmpty {
                        Text(prompt)
                            .foregroundColor(Color(UIColor.placeholderText))
                            .padding(.top, 8)
                            .accessibilityHidden(true)
                    }
                    // TextEditor insets its text 5 points; pull it back so it lines up with the email field.
                    TextEditor(text: Binding(get: { note },
                                             set: { note = String($0.prefix(FeedbackPayload.maximumNoteLength)) }))
                        .padding(.horizontal, -5)
                        .frame(minHeight: 140)
                        .accessibilityLabel(prompt)
                        .accessibilityIdentifier("feedback-note")
                }
                TextField(String(localized: "Email (optional, for a reply)"), text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("feedback-email")
            }
            Section(footer: Group {
                if phase == .failed {
                    Text(String(localized: "Couldn't send. Try again in a moment."))
                        .foregroundColor(.red)
                }
            }) {
                Button(action: { includeLogs.toggle() }) {
                    HStack(spacing: 12) {
                        Image(systemName: includeLogs ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundColor(includeLogs ? Color("AccentColor") : .secondary)
                        Text(String(localized: "Share additional details to help fix this"))
                            .foregroundColor(.primary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Share additional details to help fix this"))
                .accessibilityValue(includeLogs ? String(localized: "Checked") : String(localized: "Unchecked"))
                .accessibilityAddTraits(includeLogs ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("feedback-include-logs")
            }
        }
        .disabled(phase == .sending)
    }

    private var prompt: String {
        request.kind == .dislike ? String(localized: "What would make it better?") : String(localized: "What's on your mind?")
    }

    @ViewBuilder private var dislikeHeader: some View {
        if request.kind == .dislike {
            Text(String(localized: "Sorry to hear that.")).textCase(nil)
        }
    }

    private var confirmation: some View {
        VStack(spacing: 12) {
            Image(systemName: phase == .sent ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                .font(.system(size: 44))
                .foregroundColor(phase == .sent ? Color("AccentColor") : .secondary)
                .accessibilityHidden(true)
            Text(phase == .sent ? String(localized: "Thanks. Your feedback was sent.")
                                : String(localized: "Saved. It will be sent the next time you're online."))
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedback-confirmation")
    }

    private func submit() {
        guard canSend else { return }
        phase = .sending
        let payload = FeedbackPayload(note: note, email: email, includeLogs: includeLogs, logs: nil, source: request.source)
        let deliver: (FeedbackPayload) -> Void = { payload in
            send(payload, request.kind) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .sent: phase = .sent
                    case .queued: phase = .queued
                    case .failed: phase = .failed
                    }
                    let announcement: String
                    switch result {
                    case .sent: announcement = String(localized: "Thanks. Your feedback was sent.")
                    case .queued: announcement = String(localized: "Saved. It will be sent the next time you're online.")
                    case .failed: announcement = String(localized: "Couldn't send. Try again in a moment.")
                    }
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
        }
        FeedbackDiagnostics.collect(includeLogs: includeLogs) { report in
            var full = payload
            full.appState = report.appState
            full.logs = report.logs
            deliver(full)
        }
    }
}

/// Settings > Feedback: the way in that doesn't depend on a shake.
struct FeedbackSettingsSection: View {
    @AppStorage(FeedbackSettings.shakeKey) private var shakeEnabled = true

    var body: some View {
        Section(footer: Text(String(localized: "Shake to open this form from anywhere in the app."))) {
            Button(action: { FeedbackCenter.shared.present(source: .settings) }) {
                Text(String(localized: "Send feedback")).foregroundColor(.primary)
            }
            .accessibilityIdentifier("settings-send-feedback")
            Toggle(String(localized: "Shake to send feedback"), isOn: $shakeEnabled)
                .accessibilityIdentifier("settings-shake-feedback")
        }
    }
}

#if DEBUG
/// Simulator evidence: `-ntfyDebugFeedback empty|filled|sending|sent|queued|failed|dislike|review`.
enum FeedbackDebug {
    static var state: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-ntfyDebugFeedback"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func start() {
        guard let state else { return }
        if state == "post" {
            // One real request through the shipped sender, to prove the endpoint takes the app's request.
            let payload = FeedbackPayload(note: "Simulator check of the app's request path. Ignore.", email: nil,
                                          includeLogs: false, logs: nil, source: .settings)
            FeedbackSender.shared.send(payload, kind: .feedback) { print("FEEDBACK_DEBUG_POST result=\($0)") }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if state == "review" { ReviewPrompt.shared.asking = true }
            else { FeedbackCenter.shared.present(kind: state == "dislike" ? .dislike : .feedback, source: .settings) }
        }
    }

    @ViewBuilder static func sheet(request: FeedbackRequest, onClose: @escaping () -> Void) -> some View {
        let note = "Notifications from my home server arrive late when the phone is locked."
        switch state {
        case "filled": FeedbackSheet(request: request, onClose: onClose, note: note, email: "me@example.com")
        case "sending": FeedbackSheet(request: request, onClose: onClose, note: note, phase: .sending)
        case "sent": FeedbackSheet(request: request, onClose: onClose, phase: .sent)
        case "queued": FeedbackSheet(request: request, onClose: onClose, phase: .queued)
        case "failed": FeedbackSheet(request: request, onClose: onClose, note: note, phase: .failed)
        case "settings": NavigationView { Form { FeedbackSettingsSection() }.navigationTitle("Settings") }
            .navigationViewStyle(.stack)
        default: FeedbackSheet(request: request, onClose: onClose)
        }
    }
}
#endif
