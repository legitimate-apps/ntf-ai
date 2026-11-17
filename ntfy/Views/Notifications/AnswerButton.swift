import SwiftUI
import UIKit

// The control a person answers an agent with: the answer buttons on question cards and the message
// page, the Send of a typed reply, and the app's other solid buttons. One component, so every answer
// presses, sends and confirms the same way (operator, 2026-11-15: "these interactions are going to
// be like the primary why the user interacts with our app").
//
// Forest, lit: a deep green gradient dark enough for a white label in light and dark mode, a 52 pt
// target, a spring press with a light tick, a spinner while sending, a check when the agent has the
// answer (success buzz), a shake when it didn't (error buzz). Reduce Motion keeps the colour changes
// and drops the movement.

/// What a button does, which decides how loud it is.
enum AnswerRole: Equatable {
    /// The answer the agent leads with, or Send: the solid Forest fill with a white label.
    case primary
    /// Every other answer: a Forest tint with a Forest label.
    case secondary
    /// An answer the agent marked as doing damage: a red tint with a red label, never the green fill.
    case destructive
    /// A link, a copy, "Open link": a grey fill and a plain label, so it never reads as an answer.
    case link
}

/// Where one answer stands. `failed` draws as `idle` (the person can send again); the change into it
/// shakes the button.
enum AnswerPhase: Equatable {
    case idle, sending, sent, failed

    /// One button's phase from what the answer log says about its question: the action in flight,
    /// the label of an answer that just landed (nil once its moment has passed), and the label of an
    /// answer that didn't reach the agent.
    static func of(id: String, label: String, sendingId: String?, sentLabel: String?, failedLabel: String?) -> AnswerPhase {
        if let sendingId { return sendingId == id ? .sending : .idle }
        if let sentLabel, sentLabel == label { return .sent }
        if let failedLabel, failedLabel == label { return .failed }
        return .idle
    }
}

extension AnswerPhase {
    /// The glyph that leads the label: a spinner while the answer is on its way, a check once the
    /// agent has it. The label itself always stays, so the person sees which answer is going
    /// (DESIGN-REVIEW S3) and sending and sent share one layout.
    enum Glyph: Equatable { case spinner, check }

    var glyph: Glyph? {
        switch self {
        case .sending: return .spinner
        case .sent: return .check
        case .idle, .failed: return nil
        }
    }
}

/// What sits behind an answer control's label.
enum AnswerSurface: Equatable {
    /// The lit Forest gradient (primary).
    case forest
    /// A Forest wash (secondary).
    case tint
    /// A red wash (destructive).
    case destructiveTint
    /// A grey fill (links, copy).
    case grey
    /// Disabled: no fill, a hairline outline. Never the grey slab a link wears, so "nothing to send"
    /// doesn't look like a grey action (DESIGN-REVIEW S2).
    case outline

    static func of(role: AnswerRole, enabledLook: Bool) -> AnswerSurface {
        guard enabledLook else { return .outline }
        switch role {
        case .primary: return .forest
        case .secondary: return .tint
        case .destructive: return .destructiveTint
        case .link: return .grey
        }
    }
}

/// The haptics an answer plays.
enum AnswerFeedback: Equatable {
    /// Finger down on a button: a light tick.
    case press
    /// The agent has the answer.
    case success
    /// The answer didn't reach the agent.
    case failure
}

/// Plays answer haptics. The app uses `.live`; tests inject a recorder through the environment.
struct AnswerHaptics {
    let play: (AnswerFeedback) -> Void

    static let live = AnswerHaptics { feedback in
        switch feedback {
        case .press: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

private struct AnswerHapticsKey: EnvironmentKey {
    static let defaultValue = AnswerHaptics.live
}

extension EnvironmentValues {
    var answerHaptics: AnswerHaptics {
        get { self[AnswerHapticsKey.self] }
        set { self[AnswerHapticsKey.self] = newValue }
    }
}

/// Turns phase changes into haptics: a success buzz only for an answer this button sent, an error
/// buzz when that send failed. An answer that lands while the button wasn't sending (another device,
/// the notification banner) stays silent.
struct AnswerFeedbackTracker: Equatable {
    private(set) var phase: AnswerPhase = .idle

    /// The person pressed: the answer is on its way, even before the log says so.
    mutating func fired() { phase = .sending }

    mutating func move(to next: AnswerPhase) -> AnswerFeedback? {
        defer { phase = next }
        guard phase == .sending else { return nil }
        switch next {
        case .sent: return .success
        case .failed: return .failure
        case .idle, .sending: return nil
        }
    }
}

/// Sizes and motion, in one place so every answer control matches (DESIGN-REVIEW-v2: one height).
enum AnswerMetrics {
    /// Every answer control is this tall at the default text size, and grows with Dynamic Type.
    /// 44: the operator asked twice for "4-6pt shorter" (52, then 48, 2026-11-16/17). 44 is Apple's
    /// minimum hit target, so this is the floor; Dynamic Type still grows it.
    static let height: CGFloat = 44
    static let cornerRadius: CGFloat = 14
    static let pressedScale: CGFloat = 0.96
    /// Pressed fills darken by this much (brightness), with or without Reduce Motion.
    static let pressedDarken: Double = -0.07

    /// How far a pressed button shrinks. With Reduce Motion it doesn't move; it only darkens.
    static func scale(pressed: Bool, reduceMotion: Bool) -> CGFloat {
        pressed && !reduceMotion ? pressedScale : 1
    }

    /// Whether a failed send shakes the button. With Reduce Motion the error line and haptic carry it.
    static func shakes(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// The press and release: a spring, or a short cross-fade with Reduce Motion.
    static func pressAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.58)
    }

    /// Phase changes (spinner, check, siblings folding away).
    static func phaseAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.78)
    }
}

/// The colours, all asset colour sets so `ThemeColorTests` can pin them and their contrast.
enum AnswerColor {
    static let fillTop = Color("AnswerFillTop")
    static let fill = Color("AnswerFill")
    static let label = Color.white
    static let tint = Color("AnswerTint")
    static let tintLabel = Color("AnswerTintLabel")
    static let destructiveTint = Color("DestructiveTint")
    static let destructiveLabel = Color("DestructiveInk")
    /// Disabled labels: darker than the system's secondary label so a disabled Send still reads (4.5:1+).
    static let disabledLabel = Color("AnswerDisabledLabel")
}

/// How an answer control looks in one phase, pressed or not. The label is the caller's; while sending
/// it gives way to a spinner, and once sent it gains a check.
struct AnswerButtonFace<Label: View>: View {
    let role: AnswerRole
    var phase: AnswerPhase = .idle
    var pressed = false
    /// Fill the width offered (answer bars), or hug the label (a single button in an empty state).
    var expands = true
    /// Bumped by the owner on a failed send; each change shakes once.
    var shakes = 0
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var height = AnswerMetrics.height

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AnswerMetrics.cornerRadius, style: .continuous)
    }

    /// Disabled is drawn here, not left to the system: on iOS 26 the system's dimming made a
    /// disabled Send unreadable in dark mode (DESIGN-REVIEW-v2 F2, 1.08:1). It is an outline with a
    /// readable grey label, so it reads as "not yet", not as a grey button.
    private var enabledLook: Bool { isEnabled || phase != .idle }

    private var foreground: Color {
        guard enabledLook else { return AnswerColor.disabledLabel }
        switch role {
        case .primary: return AnswerColor.label
        case .secondary: return AnswerColor.tintLabel
        case .destructive: return AnswerColor.destructiveLabel
        case .link: return Color(.label)
        }
    }

    var body: some View {
        content
            .font(.body.weight(.semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, expands ? 12 : 22)
            .padding(.vertical, 8)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: height)
            .background(background)
            .contentShape(shape)
            .scaleEffect(AnswerMetrics.scale(pressed: pressed, reduceMotion: reduceMotion))
            .animation(AnswerMetrics.pressAnimation(reduceMotion: reduceMotion), value: pressed)
            .animation(AnswerMetrics.phaseAnimation(reduceMotion: reduceMotion), value: phase)
            .modifier(ShakeEffect(travel: AnswerMetrics.shakes(reduceMotion: reduceMotion) ? 7 : 0, shakes: CGFloat(shakes)))
            .animation(.linear(duration: 0.42), value: shakes)
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: 8) {
            switch phase.glyph {
            case .spinner:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(foreground)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            case .check:
                Image(systemName: "checkmark")
                    .font(.body.weight(.bold))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                    .accessibilityHidden(true)
            case nil:
                EmptyView()
            }
            label()
        }
    }

    @ViewBuilder private var background: some View {
        switch AnswerSurface.of(role: role, enabledLook: enabledLook) {
            case .outline:
                shape.strokeBorder(Color(.separator), lineWidth: 1)
            case .forest:
                shape
                    .fill(LinearGradient(colors: [AnswerColor.fillTop, AnswerColor.fill], startPoint: .top, endPoint: .bottom))
                    // The lit edge: a faint white line along the top that fades out by the middle.
                    .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0)],
                                                               startPoint: .top, endPoint: .center), lineWidth: 1))
                    .brightness(pressed ? AnswerMetrics.pressedDarken : 0)
                    .shadow(color: AnswerColor.fill.opacity(pressed ? 0.22 : 0.42), radius: pressed ? 2 : 7, x: 0, y: pressed ? 1 : 4)
            case .tint:
                shape.fill(AnswerColor.tint).overlay(shape.fill(Color.black.opacity(pressed ? 0.06 : 0)))
            case .destructiveTint:
                shape.fill(AnswerColor.destructiveTint).overlay(shape.fill(Color.black.opacity(pressed ? 0.06 : 0)))
            case .grey:
                shape.fill(Color(.tertiarySystemFill)).overlay(shape.fill(Color.primary.opacity(pressed ? 0.08 : 0)))
        }
    }
}

/// A horizontal shake, one full wiggle per unit of `shakes`.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 3), y: 0))
    }
}

/// The answer look for an ordinary `Button` (Send, Continue, empty-state buttons). It presses with a
/// tick, and when its owner passes the send's phase it shows the spinner and check and plays the
/// success or error haptic.
struct AnswerButtonStyle: ButtonStyle {
    var role: AnswerRole = .primary
    var phase: AnswerPhase = .idle
    var expands = true

    func makeBody(configuration: Configuration) -> some View {
        AnswerStyledButton(configuration: configuration, role: role, phase: phase, expands: expands)
    }
}

private struct AnswerStyledButton: View {
    let configuration: ButtonStyleConfiguration
    let role: AnswerRole
    let phase: AnswerPhase
    let expands: Bool
    @Environment(\.answerHaptics) private var haptics
    @Environment(\.isEnabled) private var isEnabled
    @State private var tracker = AnswerFeedbackTracker()
    @State private var shakes = 0

    var body: some View {
        AnswerButtonFace(role: role, phase: phase, pressed: configuration.isPressed, expands: expands, shakes: shakes) {
            configuration.label
        }
        .onChange(of: configuration.isPressed) { pressed in
            if pressed && isEnabled && phase == .idle { haptics.play(.press) }
        }
        .onChange(of: phase) { next in
            if next == .sending { tracker.fired() }
            if let feedback = tracker.move(to: next) {
                haptics.play(feedback)
                if feedback == .failure { shakes += 1 }
            }
        }
    }
}

extension View {
    /// A system button drawn as the app's primary answer control.
    func answerButtonStyle(_ role: AnswerRole = .primary, phase: AnswerPhase = .idle, expands: Bool = true) -> some View {
        buttonStyle(AnswerButtonStyle(role: role, phase: phase, expands: expands))
    }
}
