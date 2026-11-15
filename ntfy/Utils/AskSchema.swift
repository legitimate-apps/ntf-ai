import Foundation

/// An agent's typed question (agent protocol v2, SPEC 2). `ntf ask` 0.4 puts a versioned JSON schema,
/// base64url-encoded, in the fragment of a `view` action:
/// `https://ntf-ai.app/docs/agents#ask-v2=<b64url>`. Stock servers keep it untouched and older apps
/// show it as a link to the guide, so the question still works everywhere through its other buttons.
/// This build renders it as a native control and answers on the main topic with `re-<seq>,ans`.
struct AskSchema: Equatable {
    static let fragmentPrefix = "ask-v2="
    static let guidePath = "/docs/agents"
    /// Bigger, or not decodable: unknown, and the question falls back to its v1 buttons and reply link.
    static let maxJSONBytes = 1536
    static let version = 2

    enum Kind: String { case choice, number, date, text, form }
    enum DateMode: String { case date, time, datetime }

    struct Option: Equatable {
        let key: String
        let label: String
        /// Shown red, and needs a second step before it sends.
        let destructive: Bool
    }

    struct ChoiceSpec: Equatable {
        var options: [Option]
        var multi: Bool
        var minCount: Int
        var maxCount: Int
    }

    struct NumberSpec: Equatable {
        var min: Decimal?
        var max: Decimal?
        var step: Decimal
        var unit: String?
    }

    struct DateSpec: Equatable {
        var mode: DateMode
        var min: String?
        var max: String?
    }

    struct TextSpec: Equatable {
        var placeholder: String?
        var max: Int
    }

    struct Field: Equatable {
        let key: String
        let label: String
        let optional: Bool
        let input: Input
    }

    indirect enum Input: Equatable {
        case choice(ChoiceSpec)
        case number(NumberSpec)
        case date(DateSpec)
        case text(TextSpec)
        case form([Field])
    }

    var input: Input
    /// The agent's deadline, unix seconds (`exp`).
    var expires: Int64?
    /// Reminder counter, 1-3 (`rem`); nil on the first send.
    var reminder: Int?
    /// Whether a free reply box is offered too (`reply`); nil means the default.
    var reply: Bool?
    /// The plain-text instruction `ntf` appended to the body for older apps.
    var hint: String?

    var kind: Kind {
        switch input {
        case .choice: return .choice
        case .number: return .number
        case .date: return .date
        case .text: return .text
        case .form: return .form
        }
    }

    var expiryDate: Date? { expires.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    func isExpired(now: Date = Date()) -> Bool {
        guard let expires else { return false }
        return now.timeIntervalSince1970 >= TimeInterval(expires)
    }

    // MARK: Decoding

    /// The schema, or nil when it is unknown to this build: `v` other than 2, an unknown kind, a
    /// wrong type, a violated limit, or more than 1536 bytes. Unknown keys are ignored.
    static func decode(json data: Data) -> AskSchema? {
        guard data.count <= maxJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = int(object["v"]), v == version,
              let kindName = object["kind"] as? String, let kind = Kind(rawValue: kindName) else { return nil }
        guard let input = Self.input(kind: kind, object, inForm: false) else { return nil }
        var schema = AskSchema(input: input)
        if let value = object["exp"] {
            guard let exp = int64(value), exp > 0 else { return nil }
            schema.expires = exp
        }
        if let value = object["rem"] {
            guard let rem = int(value), (1...3).contains(rem) else { return nil }
            schema.reminder = rem
        }
        if let value = object["reply"] {
            guard let reply = bool(value) else { return nil }
            schema.reply = reply
        }
        if let value = object["hint"] {
            guard let hint = value as? String, hint.count <= 200 else { return nil }
            schema.hint = hint
        }
        return schema
    }

    /// The JSON carried by an `ask-v2` link, or nil when `action` is not one. Only the exact guide
    /// link on either hosted name qualifies, whatever server the topic is on (SPEC 1).
    static func payload(of action: Action) -> Data? {
        guard action.action == "view", let raw = action.url,
              let link = URLComponents(string: raw), link.scheme == "https",
              HostedServer.hosts.contains(link.host?.lowercased() ?? ""), link.port == nil || link.port == 443,
              link.user == nil, link.password == nil, link.query == nil,
              link.percentEncodedPath == guidePath,
              let fragment = link.percentEncodedFragment, fragment.hasPrefix(fragmentPrefix) else { return nil }
        return TopicEncryption.base64urlDecode(fragment.dropFirst(fragmentPrefix.count))
    }

    static func isCarrier(_ action: Action) -> Bool { payload(of: action) != nil }

    /// What a message's actions say about a typed question.
    enum Detection: Equatable {
        /// No `ask-v2` link: a v1 question or none.
        case none
        case native(AskSchema, carrier: String)
        /// An `ask-v2` link this build can't render: shown as 1.26 shows it, plus an update line.
        case unsupported(carrier: String)

        var schema: AskSchema? {
            if case .native(let schema, _) = self { return schema }
            return nil
        }
    }

    /// The first `ask-v2` link decides.
    static func detect(in actions: [Action]) -> Detection {
        guard let carrier = actions.first(where: isCarrier), let data = payload(of: carrier) else { return .none }
        if let schema = decode(json: data) { return .native(schema, carrier: carrier.id) }
        return .unsupported(carrier: carrier.id)
    }

    private static func input(kind: Kind, _ object: [String: Any], inForm: Bool) -> Input? {
        switch kind {
        case .choice:
            guard let list = object["options"] as? [Any], (2...12).contains(list.count) else { return nil }
            var options: [Option] = []
            for item in list {
                guard let option = item as? [String: Any], let key = option["k"] as? String, isKey(key),
                      let label = option["l"] as? String, (1...40).contains(label.count),
                      !options.contains(where: { $0.key == key }) else { return nil }
                var destructive = false
                if let value = option["d"] { guard let d = bool(value) else { return nil }; destructive = d }
                options.append(Option(key: key, label: label, destructive: destructive))
            }
            var multi = false
            if let value = object["multi"] { guard let m = bool(value) else { return nil }; multi = m }
            if inForm && multi { return nil }
            var minCount = 1, maxCount = multi ? options.count : 1
            if multi {
                if let value = object["min"] { guard let n = int(value) else { return nil }; minCount = n }
                if let value = object["max"] { guard let n = int(value) else { return nil }; maxCount = n }
                guard 1 <= minCount, minCount <= maxCount, maxCount <= options.count else { return nil }
            }
            return .choice(ChoiceSpec(options: options, multi: multi, minCount: minCount, maxCount: maxCount))
        case .number:
            var spec = NumberSpec(min: nil, max: nil, step: 1, unit: nil)
            if let value = object["min"] { guard let n = decimal(value) else { return nil }; spec.min = n }
            if let value = object["max"] { guard let n = decimal(value) else { return nil }; spec.max = n }
            if let value = object["step"] { guard let n = decimal(value), n > 0 else { return nil }; spec.step = n }
            if let value = object["unit"] { guard let u = value as? String, u.count <= 12 else { return nil }; spec.unit = u }
            if let min = spec.min, let max = spec.max, min > max { return nil }
            return .number(spec)
        case .date:
            var spec = DateSpec(mode: .datetime, min: nil, max: nil)
            if let value = object["mode"] {
                guard let name = value as? String, let mode = DateMode(rawValue: name) else { return nil }
                spec.mode = mode
            }
            for key in ["min", "max"] {
                guard let value = object[key] else { continue }
                guard let text = value as? String, AskDates.parse(text, mode: spec.mode) != nil else { return nil }
                if key == "min" { spec.min = text } else { spec.max = text }
            }
            if let min = spec.min, let max = spec.max, AskDates.compare(min, max, mode: spec.mode) == .orderedDescending { return nil }
            return .date(spec)
        case .text:
            var spec = TextSpec(placeholder: nil, max: 200)
            if let value = object["placeholder"] { guard let p = value as? String, p.count <= 60 else { return nil }; spec.placeholder = p }
            if let value = object["max"] { guard let n = int(value), (1...1000).contains(n) else { return nil }; spec.max = n }
            return .text(spec)
        case .form:
            guard !inForm, let list = object["fields"] as? [Any], (1...6).contains(list.count) else { return nil }
            var fields: [Field] = []
            for item in list {
                guard let field = item as? [String: Any], let key = field["k"] as? String, isKey(key),
                      let label = field["l"] as? String, (1...40).contains(label.count),
                      let kindName = field["kind"] as? String, let kind = Kind(rawValue: kindName), kind != .form,
                      !fields.contains(where: { $0.key == key }),
                      let input = Self.input(kind: kind, field, inForm: true) else { return nil }
                var optional = false
                if let value = field["opt"] { guard let o = bool(value) else { return nil }; optional = o }
                fields.append(Field(key: key, label: label, optional: optional, input: input))
            }
            return .form(fields)
        }
    }

    /// Same as today's answer keys: no commas, so a multi answer splits cleanly.
    static func isKey(_ key: String) -> Bool {
        (1...40).contains(key.utf8.count) && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 46 || $0 == 45
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func bool(_ value: Any) -> Bool? {
        isBool(value) ? (value as? NSNumber)?.boolValue : nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !isBool(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return Int(double)
    }

    private static func int64(_ value: Any) -> Int64? { int(value).map(Int64.init) }

    /// Shortest round-trip text of the parsed number, so `0.01` is exactly 0.01, not the double's tail.
    private static func decimal(_ value: Any) -> Decimal? {
        guard !isBool(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return Decimal(string: "\(double)", locale: AskNumbers.posix)
    }
}

// MARK: - Answers

/// A typed answer, before it becomes a body.
indirect enum AskAnswer: Equatable {
    /// Selected keys, in the agent's option order.
    case choice([String])
    case number(Decimal)
    /// Already in the mode's wire format.
    case date(String)
    case text(String)
    /// Field key to value; an optional field left empty is absent.
    case form([String: AskAnswer])
}

extension AskSchema {
    /// The answer as the agent receives it (SPEC 2 "Answer bodies"), or nil when it breaks the schema.
    func body(for answer: AskAnswer) -> String? {
        guard let normalized = Self.validated(answer, input: input) else { return nil }
        return Self.body(normalized, input: input)
    }

    /// Reads a structured answer body back; nil when it isn't valid for this schema. Free replies
    /// ("3", "Production") are `ntf`'s to interpret, never the app's.
    func answer(fromBody body: String) -> AskAnswer? {
        Self.parse(body, input: input)
    }

    private static func body(_ answer: AskAnswer, input: Input) -> String? {
        switch (answer, input) {
        case (.choice(let keys), _): return keys.joined(separator: ",")
        case (.number(let value), _): return AskNumbers.wire(value)
        case (.date(let text), _), (.text(let text), _): return text
        case (.form(let values), .form(let fields)):
            var parts: [String] = []
            for field in fields {
                guard let value = values[field.key] else { continue }
                let encoded: String
                switch value {
                case .number(let n): encoded = AskNumbers.wire(n)
                case .choice(let keys): encoded = jsonString(keys.first ?? "")
                case .date(let text), .text(let text): encoded = jsonString(text)
                case .form: return nil
                }
                parts.append(jsonString(field.key) + ":" + encoded)
            }
            return "{" + parts.joined(separator: ",") + "}"
        default: return nil
        }
    }

    private static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }

    /// The answer checked against the schema and put in canonical form (choice keys in option order,
    /// text trimmed), or nil.
    static func validated(_ answer: AskAnswer, input: Input) -> AskAnswer? {
        switch (answer, input) {
        case (.choice(let keys), .choice(let spec)):
            guard Set(keys).count == keys.count else { return nil }
            let ordered = spec.options.map(\.key).filter(keys.contains)
            guard ordered.count == keys.count else { return nil }
            if spec.multi {
                guard (spec.minCount...spec.maxCount).contains(ordered.count) else { return nil }
            } else {
                guard ordered.count == 1 else { return nil }
            }
            return .choice(ordered)
        case (.number(let value), .number(let spec)):
            if let min = spec.min, value < min { return nil }
            if let max = spec.max, value > max { return nil }
            guard AskNumbers.onStep(value, base: spec.min ?? 0, step: spec.step) else { return nil }
            return .number(value)
        case (.date(let text), .date(let spec)):
            guard AskDates.parse(text, mode: spec.mode) != nil else { return nil }
            if let min = spec.min, AskDates.compare(text, min, mode: spec.mode) == .orderedAscending { return nil }
            if let max = spec.max, AskDates.compare(text, max, mode: spec.mode) == .orderedDescending { return nil }
            return .date(text)
        case (.text(let raw), .text(let spec)):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= spec.max else { return nil }
            return .text(text)
        case (.form(let values), .form(let fields)):
            var out: [String: AskAnswer] = [:]
            for field in fields {
                if let value = values[field.key], let checked = validated(value, input: field.input) {
                    out[field.key] = checked
                } else if values[field.key] != nil || !field.optional {
                    return nil
                }
            }
            return .form(out)
        default:
            return nil
        }
    }

    private static func parse(_ body: String, input: Input) -> AskAnswer? {
        switch input {
        case .choice:
            guard !body.isEmpty else { return nil }
            return validated(.choice(body.components(separatedBy: ",")), input: input)
        case .number:
            guard let value = AskNumbers.parseWire(body) else { return nil }
            return validated(.number(value), input: input)
        case .date:
            return validated(.date(body), input: input)
        case .text:
            guard body == body.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return validated(.text(body), input: input)
        case .form(let fields):
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            var values: [String: AskAnswer] = [:]
            for field in fields {
                guard let raw = object[field.key] else { continue }
                switch field.input {
                case .number:
                    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                          let value = Decimal(string: "\(number.doubleValue)", locale: AskNumbers.posix) else { return nil }
                    values[field.key] = .number(value)
                case .choice:
                    guard let key = raw as? String else { return nil }
                    values[field.key] = .choice([key])
                case .date:
                    guard let text = raw as? String else { return nil }
                    values[field.key] = .date(text)
                case .text:
                    guard let text = raw as? String else { return nil }
                    values[field.key] = .text(text)
                case .form:
                    return nil
                }
            }
            return validated(.form(values), input: input)
        }
    }
}

// MARK: - Numbers

/// Numbers on the wire are POSIX decimals ("12.5"), whatever the phone's language: a German phone
/// shows and accepts "12,5" and still sends "12.5".
enum AskNumbers {
    static let posix = Locale(identifier: "en_US_POSIX")

    static func wire(_ value: Decimal) -> String {
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 12, .plain)
        return NSDecimalNumber(decimal: rounded).description(withLocale: posix)
    }

    static func parseWire(_ text: String) -> Decimal? {
        guard text.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: posix)
    }

    /// What a person typed, read in their own locale; plain POSIX is accepted too.
    static func parseTyped(_ text: String, locale: Locale) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        formatter.isLenient = false
        if let number = formatter.number(from: trimmed) as? NSDecimalNumber { return number.decimalValue }
        return parseWire(trimmed)
    }

    /// For showing a value in the person's language: "12,5" in German.
    static func display(_ value: Decimal, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 12
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? wire(value)
    }

    /// `value` is `base + n * step` for a whole n, within 1e-9 (SPEC 2).
    static func onStep(_ value: Decimal, base: Decimal, step: Decimal) -> Bool {
        guard step > 0 else { return false }
        var quotient = (value - base) / step
        var whole = Decimal()
        NSDecimalRound(&whole, &quotient, 0, .plain)
        let off = abs(NSDecimalNumber(decimal: quotient - whole).doubleValue * NSDecimalNumber(decimal: step).doubleValue)
        return off <= 1e-9
    }
}

// MARK: - Dates

/// The three wire formats: `2026-11-16`, `09:30`, `2026-11-16T09:30:00-08:00`.
enum AskDates {
    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AskNumbers.posix
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    private static let utc = TimeZone(identifier: "UTC")!

    static func parse(_ text: String, mode: AskSchema.DateMode) -> Date? {
        switch mode {
        case .date:
            guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
                  let date = formatter("yyyy-MM-dd", timeZone: utc).date(from: text),
                  formatter("yyyy-MM-dd", timeZone: utc).string(from: date) == text else { return nil }
            return date
        case .time:
            guard text.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else { return nil }
            return formatter("HH:mm", timeZone: utc).date(from: text)
        case .datetime:
            guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:[0-9]{2})$"#,
                             options: .regularExpression) != nil else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            // Seconds are optional on input ("2026-11-16T09:30-08:00").
            return formatter("yyyy-MM-dd'T'HH:mmXXXXX", timeZone: utc).date(from: text)
        }
    }

    static func compare(_ a: String, _ b: String, mode: AskSchema.DateMode) -> ComparisonResult {
        guard let left = parse(a, mode: mode), let right = parse(b, mode: mode) else { return .orderedSame }
        return left.compare(right)
    }

    /// A picked date in the wire format, in the person's time zone.
    static func wire(_ date: Date, mode: AskSchema.DateMode, timeZone: TimeZone = .current) -> String {
        switch mode {
        case .date: return formatter("yyyy-MM-dd", timeZone: timeZone).string(from: date)
        case .time: return formatter("HH:mm", timeZone: timeZone).string(from: date)
        case .datetime: return formatter("yyyy-MM-dd'T'HH:mm:ssXXXXX", timeZone: timeZone).string(from: date)
        }
    }

    /// A wire value as a picker date, in the person's time zone (a bare date or time has no zone).
    static func pickerDate(_ text: String, mode: AskSchema.DateMode, timeZone: TimeZone = .current) -> Date? {
        switch mode {
        case .date: return formatter("yyyy-MM-dd", timeZone: timeZone).date(from: text)
        case .time:
            guard let time = formatter("HH:mm", timeZone: timeZone).date(from: text) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: time)
            return calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: Date())
        case .datetime: return parse(text, mode: .datetime)
        }
    }

    static func display(_ text: String, mode: AskSchema.DateMode, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date = pickerDate(text, mode: mode, timeZone: timeZone) else { return text }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = mode == .time ? .none : .medium
        formatter.timeStyle = mode == .date ? .none : .short
        return formatter.string(from: date)
    }
}

// MARK: - What the app shows

extension AskSchema {
    /// The answer in words for the receipt: "Staging, Production", "12,5 GB", "Nov 16, 2026".
    func summary(_ answer: AskAnswer, locale: Locale = .current) -> String {
        Self.summary(answer, input: input, locale: locale)
    }

    private static func summary(_ answer: AskAnswer, input: Input, locale: Locale) -> String {
        switch (answer, input) {
        case (.choice(let keys), .choice(let spec)):
            return keys.map { key in spec.options.first { $0.key == key }?.label ?? key }
                .joined(separator: ", ")
        case (.number(let value), .number(let spec)):
            let number = AskNumbers.display(value, locale: locale)
            return spec.unit.map { "\(number) \($0)" } ?? number
        case (.date(let text), .date(let spec)):
            return AskDates.display(text, mode: spec.mode, locale: locale)
        case (.text(let text), _):
            return text
        case (.form(let values), .form(let fields)):
            return fields.compactMap { field in
                values[field.key].map { "\(field.label): \(summary($0, input: field.input, locale: locale))" }
            }.joined(separator: " · ")
        default:
            return ""
        }
    }

    /// The body without the hint `ntf` added for older apps: only an exact `"\n\n" + hint` ending.
    static func strippingHint(_ body: String, hint: String?) -> String {
        guard let hint, !hint.isEmpty, body.hasSuffix("\n\n" + hint) else { return body }
        return String(body.dropLast(hint.count + 2))
    }

    /// The actions a 1.27 question page still shows: everything except the `ask-v2` link, the
    /// question's own `-answers` buttons (`reply:<seq>:` on `<topic>-answers`) and a reply link to its
    /// own topic. Other links ("Open PR") stay (SPEC 4, version rules).
    static func visibleActions(_ actions: [Action], carrier: String, sequence: String, topicURL: String) -> [Action] {
        actions.filter { action in
            if action.id == carrier { return false }
            if action.action == "http", let url = action.url, sameTarget(url, topicURL + "-answers"),
               (action.body ?? "").hasPrefix("reply:\(sequence):") { return false }
            if let reply = BannerReply.destination(for: action), sameTarget(reply.absoluteString, topicURL) { return false }
            return true
        }
    }

    /// Same scheme, host and path once the public host is routed to the stored one.
    static func sameTarget(_ a: String, _ b: String) -> Bool {
        func key(_ text: String) -> String? {
            guard let url = URL(string: text) else { return nil }
            let routed = HostedServer.requestURL(url)
            guard let parts = URLComponents(url: routed, resolvingAgainstBaseURL: false), let host = parts.host else { return nil }
            var path = parts.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            return "\(parts.scheme?.lowercased() ?? "")://\(host.lowercased()):\(parts.port ?? 0)\(path)"
        }
        guard let left = key(a), let right = key(b) else { return false }
        return left == right
    }
}

// MARK: - Questions in general

/// What makes a message a question the person can answer, for the app and the extension alike.
enum AgentQuestion {
    /// `http` actions post back to the agent, the reply action carries typed text, and an `ask-v2`
    /// link this build can render carries a native control. Other `view` and `copy` actions are
    /// links and utilities, not answers.
    static func isAnswerAction(_ action: Action) -> Bool {
        if action.action == "http" || BannerReply.destination(for: action) != nil { return true }
        guard let data = AskSchema.payload(of: action) else { return false }
        return AskSchema.decode(json: data) != nil
    }

    /// An agent's open question: tagged `agent` and carrying an answer.
    static func isAgentQuestion(tags: [String], actions: [Action]) -> Bool {
        tags.contains { $0.lowercased() == "agent" } && actions.contains(where: isAnswerAction)
    }
}

/// Reads the answer log the app keeps (`AnswerLog`, app group defaults) without the app's types, so
/// the extension can tell whether a question was answered before letting a reminder alert.
enum AnswerLogReader {
    private struct Entry: Decodable {
        var kind: String
        var ok: Bool
        var messageId: String?
    }

    static func answered(key: String, version: String?, defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: "answerLog.v1"),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data),
              let entry = entries[key] else { return false }
        guard entry.messageId == nil || version == nil || entry.messageId == version else { return false }
        return entry.ok
    }
}

// MARK: - Reminders (SPEC 7)

/// An agent's reminder is the question sent again on its sequence with a higher `rem`. It alerts
/// only while the question still waits, at most three times a question, at least five minutes
/// apart, and only with "Agent reminders" on. Every other update stays silent, as before.
enum AgentReminder {
    static let settingKey = "agentReminders"
    static let maxAlerts = 3
    static let minInterval: TimeInterval = 5 * 60

    static func isOn(_ defaults: UserDefaults = AgentAck.defaults) -> Bool {
        defaults.object(forKey: settingKey) as? Bool ?? true
    }

    /// Whether the update `next` of a stored question `previous` may alert. `waiting` is the stored
    /// question's own state: not answered, acked, withdrawn or settled.
    static func alerts(next: AskSchema?, previous: AskSchema?, waiting: Bool, priorAlerts: [Date],
                       enabled: Bool, now: Date = Date()) -> Bool {
        guard enabled, waiting, let next, let rem = next.reminder, !next.isExpired(now: now) else { return false }
        guard rem > (previous?.reminder ?? 0) else { return false }
        guard priorAlerts.count < maxAlerts else { return false }
        if let last = priorAlerts.max(), now.timeIntervalSince(last) < minInterval { return false }
        return true
    }
}

/// Which reminders alerted, per question, in the app group so the app and the extension share it.
final class ReminderLog {
    static let shared = ReminderLog(defaults: AgentAck.defaults)
    static let defaultsKey = "agentReminders.v1"
    static let limit = 500

    struct Record: Codable, Equatable {
        var alerts: [Date]
        /// Message ids allowed to alert: an update re-delivered by a poll or a push keeps its decision.
        var ids: [String]
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) { self.defaults = defaults }

    private func all() -> [String: Record] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return decoded
    }

    func record(forKey key: String) -> Record? {
        lock.lock(); defer { lock.unlock() }
        return all()[key]
    }

    func isAlerting(id: String, key: String) -> Bool {
        record(forKey: key)?.ids.contains(id) == true
    }

    func recordAlert(id: String, key: String, at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var records = all()
        var record = records[key] ?? Record(alerts: [], ids: [])
        guard !record.ids.contains(id) else { return }
        record.alerts.append(date)
        record.ids.append(id)
        records[key] = record
        if records.count > Self.limit {
            let oldest = records.sorted { ($0.value.alerts.max() ?? .distantPast) < ($1.value.alerts.max() ?? .distantPast) }
            oldest.prefix(records.count - Self.limit).forEach { records[$0.key] = nil }
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
