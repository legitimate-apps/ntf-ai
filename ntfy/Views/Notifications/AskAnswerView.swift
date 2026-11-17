import Combine
import SwiftUI
import UIKit

// Agent protocol v2 (SPEC 2-7): a typed question answered with a native control on the question
// page and in Waiting on you, its deadline, a withdrawn question, and who is asking.

extension Notification {
    /// The question's `ask-v2` link, read once per draw.
    var askDetection: AskSchema.Detection { AskSchema.detect(in: actionsList()) }

    /// The buttons and links a surface shows. A typed question hides its `ask-v2` link and the old
    /// answer paths it carries for older apps; other links ("Open PR") stay (SPEC 4). One this build
    /// can't render keeps its old answers but drops the link, which only says to answer in NTF-AI
    /// (DESIGN-REVIEW-v2 F7).
    func shownActions(_ detection: AskSchema.Detection? = nil) -> [Action] {
        let detection = detection ?? askDetection
        let topic = subscription.map { topicUrl(baseUrl: $0.baseUrl ?? "", topic: $0.topic ?? "") }
        return AskSchema.shownActions(answerableActions(), detection: detection,
                                      sequence: AnswerKey(notification: self)?.sequence, topicURL: topic)
    }

    /// The agent named by an `@name` tag (SPEC 6).
    var agentName: String? { AgentIdentity.name(tags: parseAllTags(tags)) }
}

/// "Expires in 1h 20m", and whether it has.
enum AskDeadline {
    /// Redraws "Expires in" and turns the controls off at the deadline while a card or page stays open.
    static let ticks = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    static func remaining(until date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        let seconds = max(60, date.timeIntervalSince(now))
        formatter.allowedUnits = seconds < 86_400 ? [.hour, .minute] : [.day, .hour]
        return formatter.string(from: seconds) ?? ""
    }
}

/// The deadline and "update the app" lines under a question. A withdrawn question shows its
/// receipt instead (`AgentReceipt`).
struct AskStatusLine: View {
    let notification: Notification
    let detection: AskSchema.Detection
    @State var now = Date()

    var body: some View {
        line.onReceive(AskDeadline.ticks) { now = $0 }
    }

    @ViewBuilder private var line: some View {
        if case .unsupported = detection {
            if let store = Config.appStoreListingUrl.flatMap(URL.init(string:)) {
                Link(destination: store) {
                    Self.row("arrow.down.app", Text("Update NTF-AI to answer this here"))
                        .foregroundColor(InboxColor.ink)
                }
                .accessibilityIdentifier("ask-update-app")
            } else {
                Self.row("arrow.down.app", Text("Update NTF-AI to answer this here"))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("ask-update-app")
            }
        } else if let schema = detection.schema, let date = schema.expiryDate {
            if schema.isExpired(now: now) {
                Self.row("clock.badge.xmark", Text("Expired"))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("ask-expired")
            } else {
                Self.row("clock", Text("Expires in \(AskDeadline.remaining(until: date, now: now))"))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("ask-expires")
            }
        }
    }

    /// An icon on the text edge with the same gap on the card and the page: a `Label` in a list
    /// row takes the list's icon column instead (DESIGN-REVIEW-v2 S9).
    static func row(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            text
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}

/// The agent's picture where policy allows it, else its initial in Forest on a light Forest tint (SPEC 6, `MonogramColor`).
struct AgentAvatar: View {
    let name: String
    let icon: String?
    let baseUrl: String
    let encrypted: Bool
    var size: CGFloat = 24
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Color(MonogramColor.agentFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(AgentIdentity.monogram(name))
                    .font(size <= 28 ? .caption.weight(.bold) : .title3.weight(.bold))
                    .foregroundColor(Color(MonogramColor.agentLetter))
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .onAppear {
            guard image == nil else { return }
            AgentAvatarStore.shared.avatar(icon: icon, baseUrl: baseUrl, encrypted: encrypted) { data in
                guard let data, let loaded = UIImage(data: data) else { return }
                DispatchQueue.main.async { image = loaded }
            }
        }
    }
}

extension AgentAvatar {
    init(notification: Notification, name: String, size: CGFloat = 24) {
        self.init(name: name, icon: notification.icon, baseUrl: notification.subscription?.baseUrl ?? "",
                  encrypted: notification.encryptionState == .decrypted, size: size)
    }
}

/// A native control for a typed question. Choices send on a tap (a red option asks first); a
/// multiple choice, number, date or text sends with its own button. A form is answered on the
/// question page; elsewhere it offers the page. Every control is the shared answer component
/// (`AnswerButton.swift`) at `AnswerMetrics.height`, so a typed answer presses, sends and
/// disables the way a 1.26 answer does (DESIGN-REVIEW-v2 F2, F4).
struct AskAnswerView: View {
    enum Place { case page, card }

    let notification: Notification
    let schema: AskSchema
    var place: Place = .page
    var disabled = false
    var sending = false
    var openPage: () -> Void = {}
    var onAnswer: (_ body: String, _ summary: String, _ written: Bool) -> Void

    @State private var confirming: AskSchema.Option?
    /// The option a tap sent, so only it spins while the others fold away.
    @State private var tapped: String?
    @State private var now = Date()

    private var off: Bool { disabled || schema.isExpired(now: now) }
    private var phase: AnswerPhase { sending ? .sending : .idle }

    var body: some View {
        // No dimming here: the answer component draws its own readable disabled state.
        content
            .disabled(off || sending)
            .onReceive(AskDeadline.ticks) { now = $0 }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                                titleVisibility: .visible) {
                if let option = confirming {
                    Button(String(localized: "Send"), role: .destructive) { send(.choice([option.key])) }
                }
            }
    }

    private var confirmTitle: String {
        confirming.map { String(localized: "Send \u{201C}\($0.label)\u{201D} to the agent?") } ?? ""
    }

    @ViewBuilder private var content: some View {
        switch schema.input {
        case .choice(let spec) where !spec.multi:
            let items = spec.options.map { ActionBarItem.answer(Action(id: Self.optionId($0.key), action: "http", label: $0.label,
                                                                       url: nil, method: nil, headers: nil, body: nil, clear: nil)) }
            let destructive = Set(spec.options.filter(\.destructive).map { Self.optionId($0.key) })
            // The options are peers the agent listed, so none is painted as the suggested one
            // (DESIGN-REVIEW-v2 S1); a red option is the destructive style and asks first.
            ActionBar(items: items, prominentId: nil, destructiveIds: destructive,
                      sendingId: sending ? tapped : nil) { item in
                guard let option = spec.options.first(where: { Self.optionId($0.key) == item.id }) else { return }
                if option.destructive { confirming = option } else { tapped = item.id; send(.choice([option.key])) }
            }
        case .choice(let spec):
            AskMultiChoice(spec: spec, phase: phase) { send(.choice($0)) }
        case .number(let spec):
            AskNumberField(spec: spec, phase: phase) { send(.number($0)) }
        case .date(let spec):
            AskDateField(spec: spec, phase: phase) { send(.date($0)) }
        case .text(let spec):
            ReplyField(placeholder: spec.placeholder ?? String(localized: "Answer"), phase: phase, maxLength: spec.max, verbatim: true) { send(.text($0)) }
        case .form(let fields):
            if place == .page {
                AskForm(fields: fields, phase: phase) { send(.form($0)) }
            } else {
                AskSendButton(title: String(localized: "Answer"), enabled: true, action: openPage)
                    .accessibilityIdentifier("ask-open-form")
            }
        }
    }

    static func optionId(_ key: String) -> String { "ask-option-" + key }

    private func send(_ answer: AskAnswer) {
        guard let body = schema.body(for: answer) else { return }
        if case .choice(let keys) = answer, keys.count == 1, case .choice(let spec) = schema.input, !spec.multi {
            tapped = Self.optionId(keys[0])
        }
        let written: Bool
        switch schema.input {
        case .text, .form: written = true
        default: written = false
        }
        onAnswer(body, schema.summary(answer), written)
    }
}

/// The links a typed question carries ("Open PR"), drawn as quiet links rather than answer buttons,
/// so nobody reads them as one more answer (DESIGN-REVIEW-v2 F5).
struct AskLinks: View {
    let items: [ActionBarItem]
    let run: (ActionBarItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button { run(item) } label: {
                    HStack(spacing: 4) {
                        Text(item.label)
                        Image(systemName: Self.symbol(item)).font(.caption.weight(.semibold)).accessibilityHidden(true)
                    }
                    .frame(minHeight: AnswerMetrics.height, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(InboxColor.ink)
                .accessibilityIdentifier("ask-link-\(item.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func symbol(_ item: ActionBarItem) -> String {
        if case .copy = item { return "doc.on.doc" }
        return "arrow.up.right"
    }
}

/// The solid answer button every typed answer sends with.
struct AskSendButton: View {
    let title: String
    var phase: AnswerPhase = .idle
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(title) }
            .answerButtonStyle(.primary, phase: phase)
            .disabled(!enabled)
    }
}

/// A field box the same height and fill as every other answer control. A fill token, not a
/// background one, so it shows on the dark card too (DESIGN-REVIEW-v2 F3).
private struct AskFieldBox: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var height = AnswerMetrics.height

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AnswerMetrics.cornerRadius, style: .continuous)
                .fill(Color(.tertiarySystemFill)))
    }
}

extension View {
    fileprivate func askFieldBox() -> some View { modifier(AskFieldBox()) }
}

struct AskMultiChoice: View {
    let spec: AskSchema.ChoiceSpec
    var phase: AnswerPhase = .idle
    let send: ([String]) -> Void
    @State private var picked: Set<String> = []

    private var valid: Bool { (spec.minCount...spec.maxCount).contains(picked.count) }
    private var full: Bool { picked.count >= spec.maxCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(spec.options, id: \.key) { option in
                let on = picked.contains(option.key)
                Button {
                    if on { picked.remove(option.key) } else if !full { picked.insert(option.key) }
                } label: {
                    HStack {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        Text(option.label)
                        Spacer(minLength: 0)
                    }
                }
                .answerButtonStyle(option.destructive ? .destructive : .secondary)
                // A picked row carries an outline in its own ink, so the choice reads at a glance.
                .overlay(RoundedRectangle(cornerRadius: AnswerMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(option.destructive ? AnswerColor.destructiveLabel : AnswerColor.tintLabel, lineWidth: 2)
                    .opacity(on ? 1 : 0))
                .opacity(full && !on ? 0.55 : 1)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("ask-pick-\(option.key)")
            }
            Text(Self.rangeText(min: spec.minCount, max: spec.maxCount))
                .font(.footnote).foregroundColor(full ? .primary : .secondary)
            AskSendButton(title: String(localized: "Send"), phase: phase, enabled: valid) {
                send(spec.options.map(\.key).filter(picked.contains))
            }
            .accessibilityIdentifier("ask-send")
        }
    }

    /// "Choose 2", "Choose up to 2", "Choose 2 to 3" (DESIGN-REVIEW-v2 S3).
    static func rangeText(min: Int, max: Int) -> String {
        if min == max { return String(localized: "Choose \(min)") }
        if min <= 1 { return String(localized: "Choose up to \(max)") }
        return String(localized: "Choose \(min) to \(max)")
    }
}

struct AskNumberField: View {
    let spec: AskSchema.NumberSpec
    var phase: AnswerPhase = .idle
    let send: (Decimal) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var height = AnswerMetrics.height

    private var value: Decimal? { AskNumbers.parseTyped(text, locale: .current) }
    private var valid: Bool {
        guard let value else { return false }
        return AskSchema.validated(.number(value), input: .number(spec)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                stepButton("minus", by: -1).accessibilityLabel(String(localized: "Decrease"))
                HStack(spacing: 4) {
                    TextField(String(localized: "Number"), text: $text)
                        .keyboardType(AskNumbers.keyboard(for: spec))
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .font(.title3.monospacedDigit())
                        .accessibilityIdentifier("ask-number")
                    if let unit = spec.unit { Text(unit).foregroundColor(.secondary) }
                }
                .askFieldBox()
                stepButton("plus", by: 1).accessibilityLabel(String(localized: "Increase"))
            }
            if let range = rangeText {
                Text(range).font(.footnote).foregroundColor(!text.isEmpty && !valid ? .red : .secondary)
            }
            AskSendButton(title: String(localized: "Send"), phase: phase, enabled: valid) {
                if let value { focused = false; send(value) }
            }
            .accessibilityIdentifier("ask-send")
        }
    }

    /// Square, as tall as the field beside it.
    private func stepButton(_ symbol: String, by direction: Decimal) -> some View {
        Button {
            var next = (value ?? spec.min ?? 0) + (value == nil ? 0 : direction * spec.step)
            if let min = spec.min, next < min { next = min }
            if let max = spec.max, next > max { next = max }
            text = AskNumbers.display(next, locale: .current)
        } label: {
            Image(systemName: symbol)
        }
        .answerButtonStyle(.secondary)
        .frame(width: height)
    }

    private var rangeText: String? {
        let locale = Locale.current
        let unit = spec.unit.map { " " + $0 } ?? ""
        var parts: [String] = []
        if let min = spec.min, let max = spec.max {
            parts.append(String(localized: "From \(AskNumbers.display(min, locale: locale)) to \(AskNumbers.display(max, locale: locale))") + unit)
        } else if let min = spec.min {
            parts.append(String(localized: "At least \(AskNumbers.display(min, locale: locale))") + unit)
        } else if let max = spec.max {
            parts.append(String(localized: "At most \(AskNumbers.display(max, locale: locale))") + unit)
        }
        if spec.step != 1 { parts.append(String(localized: "steps of \(AskNumbers.display(spec.step, locale: locale))")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// A date, time or date-and-time row: the mode's name, then Choose until a value is picked, then a
/// compact picker. Each kind and the form use this one row (DESIGN-REVIEW-v2 F4, S5).
struct AskDateRow: View {
    let spec: AskSchema.DateSpec
    let label: String
    @Binding var date: Date?
    /// An optional form date can be cleared again.
    var clearable = false
    @ScaledMetric(relativeTo: .body) private var height = AnswerMetrics.height

    private var lower: Date? { spec.min.flatMap { AskDates.pickerDate($0, mode: spec.mode) } }
    private var upper: Date? { spec.max.flatMap { AskDates.pickerDate($0, mode: spec.mode) } }
    private var components: DatePickerComponents {
        switch spec.mode {
        case .date: return [.date]
        case .time: return [.hourAndMinute]
        case .datetime: return [.date, .hourAndMinute]
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if date == nil {
                Button(String(localized: "Choose")) { date = AskDates.initial(spec) }
                    .answerButtonStyle(.secondary, expands: false)
                    .accessibilityLabel(String(localized: "Choose") + ", " + label)
                    .accessibilityIdentifier("ask-date-choose")
            } else {
                picker.labelsHidden().accessibilityIdentifier("ask-date")
                if clearable {
                    Button { date = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Remove"))
                }
            }
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, minHeight: height)
        .background(RoundedRectangle(cornerRadius: AnswerMetrics.cornerRadius, style: .continuous)
            .fill(Color(.tertiarySystemFill)))
    }

    @ViewBuilder private var picker: some View {
        let date = Binding(get: { self.date ?? AskDates.initial(spec) }, set: { self.date = $0 })
        let label = Text(label)
        if let lower, let upper {
            DatePicker(selection: date, in: lower...upper, displayedComponents: components) { label }
        } else if let lower {
            DatePicker(selection: date, in: lower..., displayedComponents: components) { label }
        } else if let upper {
            DatePicker(selection: date, in: ...upper, displayedComponents: components) { label }
        } else {
            DatePicker(selection: date, displayedComponents: components) { label }
        }
    }

    /// The row's name by mode, so a time question doesn't say "Date".
    static func modeLabel(_ mode: AskSchema.DateMode) -> String {
        switch mode {
        case .date: return String(localized: "Date")
        case .time: return String(localized: "Time")
        case .datetime: return String(localized: "Date and time")
        }
    }
}

struct AskDateField: View {
    let spec: AskSchema.DateSpec
    var phase: AnswerPhase = .idle
    let send: (String) -> Void
    /// Nil until the person taps Choose: nothing is sent that nobody picked.
    @State private var date: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AskDateRow(spec: spec, label: AskDateRow.modeLabel(spec.mode), date: $date)
            AskSendButton(title: String(localized: "Send"), phase: phase, enabled: date != nil) {
                if let date { send(AskDates.wire(date, mode: spec.mode)) }
            }
            .accessibilityIdentifier("ask-send")
        }
    }
}

extension AskNumbers {
    /// The decimal pad has no minus key, so a range that allows negatives gets one that does.
    static func keyboard(for spec: AskSchema.NumberSpec) -> UIKeyboardType {
        (spec.min.map { $0 < 0 } ?? true) ? .numbersAndPunctuation : .decimalPad
    }
}

/// Up to six fields, each labelled, with "Optional" on those that may stay empty.
struct AskForm: View {
    let fields: [AskSchema.Field]
    var phase: AnswerPhase = .idle
    let send: ([String: AskAnswer]) -> Void
    @State private var texts: [String: String] = [:]
    /// Only the dates the person picked: a date row starts empty, required or not.
    @State private var dates: [String: Date] = [:]
    @State private var picks: [String: String] = [:]

    private var answer: [String: AskAnswer] { Self.answer(fields: fields, texts: texts, dates: dates, picks: picks) }

    /// The form's answer from what was entered; a field left empty is absent, so a required one
    /// fails validation and Send stays off.
    static func answer(fields: [AskSchema.Field], texts: [String: String], dates: [String: Date], picks: [String: String],
                       locale: Locale = .current, timeZone: TimeZone = .current) -> [String: AskAnswer] {
        var values: [String: AskAnswer] = [:]
        for field in fields {
            switch field.input {
            case .text:
                let text = (texts[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { values[field.key] = .text(text) }
            case .number:
                if let n = AskNumbers.parseTyped(texts[field.key] ?? "", locale: locale) { values[field.key] = .number(n) }
            case .date(let spec):
                if let date = dates[field.key] { values[field.key] = .date(AskDates.wire(date, mode: spec.mode, timeZone: timeZone)) }
            case .choice:
                if let key = picks[field.key] { values[field.key] = .choice([key]) }
            case .form:
                break
            }
        }
        return values
    }

    private var valid: Bool { AskSchema.validated(.form(answer), input: .form(fields)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fields, id: \.key) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(field.label).font(.subheadline.weight(.semibold))
                        if field.optional { Text(String(localized: "Optional")).font(.footnote).foregroundColor(.secondary) }
                    }
                    control(field)
                }
            }
            AskSendButton(title: String(localized: "Send"), phase: phase, enabled: valid) { send(answer) }
                .accessibilityIdentifier("ask-send")
        }
    }

    @ViewBuilder private func control(_ field: AskSchema.Field) -> some View {
        switch field.input {
        case .text(let spec):
            // Like a typed text answer, a form's text is kept exactly as typed (ReplyField.verbatim).
            TextField(spec.placeholder ?? field.label, text: binding(field.key))
                .disableAutocapitalization().disableAutocorrection(true).askFieldBox()
        case .number(let spec):
            HStack {
                TextField(String(localized: "Number"), text: binding(field.key)).keyboardType(AskNumbers.keyboard(for: spec))
                if let unit = spec.unit { Text(unit).foregroundColor(.secondary).padding(.trailing, 14) }
            }
            .askFieldBox()
        case .date(let spec):
            // A date nobody picked is not sent, so it shows no date until one is chosen.
            AskDateRow(spec: spec, label: AskDateRow.modeLabel(spec.mode),
                       date: Binding(get: { dates[field.key] }, set: { dates[field.key] = $0 }),
                       clearable: field.optional)
        case .choice(let spec):
            Picker(field.label, selection: Binding(get: { picks[field.key] ?? "" }, set: { picks[field.key] = $0.isEmpty ? nil : $0 })) {
                Text(String(localized: "Choose")).tag("")
                ForEach(spec.options, id: \.key) { Text($0.label).tag($0.key) }
            }
            .pickerStyle(.menu)
            .askFieldBox()
        case .form:
            EmptyView()
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 })
    }
}
