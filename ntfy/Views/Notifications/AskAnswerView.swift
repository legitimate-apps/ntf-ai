import SwiftUI
import UIKit

// Agent protocol v2 (SPEC 2-7): a typed question answered with a native control on the question
// page and in Waiting on you, its deadline, a withdrawn question, and who is asking.

extension Notification {
    /// The question's `ask-v2` link, read once per draw.
    var askDetection: AskSchema.Detection { AskSchema.detect(in: actionsList()) }

    /// The buttons and links a surface shows. A typed question hides its `ask-v2` link and the old
    /// answer paths it carries for older apps; other links ("Open PR") stay (SPEC 4).
    func shownActions(_ detection: AskSchema.Detection? = nil) -> [Action] {
        let actions = answerableActions()
        guard case .native(_, let carrier) = detection ?? askDetection, let key = AnswerKey(notification: self),
              let subscription else { return actions }
        return AskSchema.visibleActions(actions, carrier: carrier, sequence: key.sequence,
                                        topicURL: topicUrl(baseUrl: subscription.baseUrl ?? "", topic: subscription.topic ?? ""))
    }
}

/// "Expires in 1h 20m", and whether it has.
enum AskDeadline {
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
    var now = Date()

    var body: some View {
        if case .unsupported = detection {
            Label(String(localized: "Update NTF-AI to answer this here"), systemImage: "arrow.down.app")
                .font(.footnote).foregroundColor(.secondary)
                .accessibilityIdentifier("ask-update-app")
        } else if let schema = detection.schema, let date = schema.expiryDate {
            if schema.isExpired(now: now) {
                Label(String(localized: "Expired"), systemImage: "clock.badge.xmark")
                    .font(.footnote).foregroundColor(.secondary)
                    .accessibilityIdentifier("ask-expired")
            } else {
                Label(String(localized: "Expires in \(AskDeadline.remaining(until: date, now: now))"), systemImage: "clock")
                    .font(.footnote).foregroundColor(.secondary)
                    .accessibilityIdentifier("ask-expires")
            }
        }
    }
}

/// A native control for a typed question. Choices send on a tap (a red option asks first); a
/// multiple choice, number, date or text sends with its own button. A form is answered on the
/// question page; elsewhere it offers the page.
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

    private var size: ControlSize { place == .page ? .large : .regular }

    var body: some View {
        content
            .disabled(disabled || sending)
            .opacity(disabled ? 0.4 : 1)
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
            let items = spec.options.map { ActionBarItem.answer(Action(id: "ask-option-" + $0.key, action: "http", label: $0.label,
                                                                       url: nil, method: nil, headers: nil, body: nil, clear: nil)) }
            let destructive = Set(spec.options.filter(\.destructive).map { "ask-option-" + $0.key })
            // The card's one prominent button is the first safe answer, never a destructive one.
            let prominent = place == .card ? items.first(where: { !destructive.contains($0.id) })?.id : nil
            ActionBar(items: items, prominentId: prominent, destructiveIds: destructive,
                      sendingId: sending ? "pending" : nil) { item in
                guard let option = spec.options.first(where: { "ask-option-" + $0.key == item.id }) else { return }
                if option.destructive { confirming = option } else { send(.choice([option.key])) }
            }
        case .choice(let spec):
            AskMultiChoice(spec: spec, size: size) { send(.choice($0)) }
        case .number(let spec):
            AskNumberField(spec: spec, size: size) { send(.number($0)) }
        case .date(let spec):
            AskDateField(spec: spec, size: size) { send(.date($0)) }
        case .text(let spec):
            ReplyField(placeholder: spec.placeholder ?? String(localized: "Answer"), maxLength: spec.max) { send(.text($0)) }
        case .form(let fields):
            if place == .page {
                AskForm(fields: fields, size: size) { send(.form($0)) }
            } else {
                AskSendButton(title: String(localized: "Answer"), size: size, enabled: true, action: openPage)
                    .accessibilityIdentifier("ask-open-form")
            }
        }
    }

    private func send(_ answer: AskAnswer) {
        guard let body = schema.body(for: answer) else { return }
        let written: Bool
        switch schema.input {
        case .text, .form: written = true
        default: written = false
        }
        onAnswer(body, schema.summary(answer), written)
    }
}

/// The prominent capsule every typed answer sends with.
struct AskSendButton: View {
    let title: String
    let size: ControlSize
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(InboxColor.fill)
        // A disabled prominent button keeps a grey fill; the fill's dark label vanished on it in dark mode.
        .foregroundColor(enabled ? InboxColor.onFill : .secondary)
        .buttonBorderShape(.capsule)
        .controlSize(size)
        .disabled(!enabled)
    }
}

struct AskMultiChoice: View {
    let spec: AskSchema.ChoiceSpec
    let size: ControlSize
    let send: ([String]) -> Void
    @State private var picked: Set<String> = []

    private var valid: Bool { (spec.minCount...spec.maxCount).contains(picked.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(spec.options, id: \.key) { option in
                let on = picked.contains(option.key)
                Button {
                    if on { picked.remove(option.key) } else if picked.count < spec.maxCount { picked.insert(option.key) }
                } label: {
                    HStack {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(on ? InboxColor.ink : .secondary)
                        Text(option.label).foregroundColor(option.destructive ? .red : .primary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .buttonBorderShape(.capsule)
                .controlSize(size)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("ask-pick-\(option.key)")
            }
            Text(rangeText).font(.footnote).foregroundColor(.secondary)
            AskSendButton(title: String(localized: "Send"), size: size, enabled: valid) {
                send(spec.options.map(\.key).filter(picked.contains))
            }
            .accessibilityIdentifier("ask-send")
        }
    }

    private var rangeText: String {
        spec.minCount == spec.maxCount ? String(localized: "Choose \(spec.minCount)")
            : String(localized: "Choose \(spec.minCount) to \(spec.maxCount)")
    }
}

struct AskNumberField: View {
    let spec: AskSchema.NumberSpec
    let size: ControlSize
    let send: (Decimal) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

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
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .font(.title3.monospacedDigit())
                        .accessibilityIdentifier("ask-number")
                    if let unit = spec.unit { Text(unit).foregroundColor(.secondary) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemBackground)))
                stepButton("plus", by: 1).accessibilityLabel(String(localized: "Increase"))
            }
            if let range = rangeText {
                Text(range).font(.footnote).foregroundColor(!text.isEmpty && !valid ? .red : .secondary)
            }
            AskSendButton(title: String(localized: "Send"), size: size, enabled: valid) {
                if let value { focused = false; send(value) }
            }
            .accessibilityIdentifier("ask-send")
        }
    }

    private func stepButton(_ symbol: String, by direction: Decimal) -> some View {
        Button {
            var next = (value ?? spec.min ?? 0) + (value == nil ? 0 : direction * spec.step)
            if let min = spec.min, next < min { next = min }
            if let max = spec.max, next > max { next = max }
            text = AskNumbers.display(next, locale: .current)
        } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .tint(.secondary)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .controlSize(size)
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

struct AskDateField: View {
    let spec: AskSchema.DateSpec
    let size: ControlSize
    let send: (String) -> Void
    @State private var date = Date()
    @State private var ready = false

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
        VStack(alignment: .leading, spacing: 8) {
            picker
                .accessibilityIdentifier("ask-date")
            AskSendButton(title: String(localized: "Send"), size: size, enabled: true) {
                send(AskDates.wire(date, mode: spec.mode))
            }
            .accessibilityIdentifier("ask-send")
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            if let lower, date < lower { date = lower }
            if let upper, date > upper { date = upper }
        }
    }

    @ViewBuilder private var picker: some View {
        let label = Text(String(localized: "Date"))
        if let lower, let upper {
            DatePicker(selection: $date, in: lower...upper, displayedComponents: components) { label }
        } else if let lower {
            DatePicker(selection: $date, in: lower..., displayedComponents: components) { label }
        } else if let upper {
            DatePicker(selection: $date, in: ...upper, displayedComponents: components) { label }
        } else {
            DatePicker(selection: $date, displayedComponents: components) { label }
        }
    }
}

/// Up to six fields, each labelled, with "Optional" on those that may stay empty.
struct AskForm: View {
    let fields: [AskSchema.Field]
    let size: ControlSize
    let send: ([String: AskAnswer]) -> Void
    @State private var texts: [String: String] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var setDates: Set<String> = []
    @State private var picks: [String: String] = [:]

    private var answer: [String: AskAnswer] {
        var values: [String: AskAnswer] = [:]
        for field in fields {
            switch field.input {
            case .text:
                let text = (texts[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { values[field.key] = .text(text) }
            case .number:
                if let n = AskNumbers.parseTyped(texts[field.key] ?? "", locale: .current) { values[field.key] = .number(n) }
            case .date(let spec):
                if setDates.contains(field.key) || !field.optional {
                    values[field.key] = .date(AskDates.wire(dates[field.key] ?? Date(), mode: spec.mode))
                }
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
            AskSendButton(title: String(localized: "Send"), size: size, enabled: valid) { send(answer) }
                .accessibilityIdentifier("ask-send")
        }
    }

    @ViewBuilder private func control(_ field: AskSchema.Field) -> some View {
        switch field.input {
        case .text(let spec):
            boxed(TextField(spec.placeholder ?? field.label, text: binding(field.key)))
        case .number(let spec):
            boxed(HStack {
                TextField(String(localized: "Number"), text: binding(field.key)).keyboardType(.decimalPad)
                if let unit = spec.unit { Text(unit).foregroundColor(.secondary) }
            })
        case .date(let spec):
            // An optional date nobody picked is not sent, so it shows no date until one is chosen.
            if field.optional && !setDates.contains(field.key) {
                Button(String(localized: "Choose")) { setDates.insert(field.key) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            } else {
                HStack {
                    DatePicker(selection: Binding(get: { dates[field.key] ?? Date() },
                                                  set: { dates[field.key] = $0; setDates.insert(field.key) }),
                               displayedComponents: spec.mode == .date ? [.date] : spec.mode == .time ? [.hourAndMinute] : [.date, .hourAndMinute]) {
                        Text(field.label)
                    }
                    .labelsHidden()
                    if field.optional {
                        Button { setDates.remove(field.key); dates[field.key] = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(String(localized: "Remove"))
                    }
                }
            }
        case .choice(let spec):
            Picker(field.label, selection: Binding(get: { picks[field.key] ?? "" }, set: { picks[field.key] = $0.isEmpty ? nil : $0 })) {
                Text(String(localized: "Choose")).tag("")
                ForEach(spec.options, id: \.key) { Text($0.label).tag($0.key) }
            }
            .pickerStyle(.menu)
        case .form:
            EmptyView()
        }
    }

    private func boxed<Content: View>(_ content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 })
    }
}
