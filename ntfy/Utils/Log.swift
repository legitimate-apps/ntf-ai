import Foundation

struct Log {
    private static let sensitiveKeys: Set<String> = [
        "actions", "authorization", "body", "click", "message", "password", "title", "token", "url"
    ]
    private static let dateFormat = "yy-MM-dd hh:mm:ss.SSS"
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = .current
        formatter.timeZone = .current
        return formatter
    }()
    
    static func d(_ tag: String, _ message: String, _ other: Any?...) {
        log(.debug, tag, message, other)
    }
    
    static func i(_ tag: String, _ message: String, _ other: Any?...) {
        log(.info, tag, message, other)
    }
    
    static func w(_ tag: String, _ message: String, _ other: Any?...) {
        log(.warning, tag, message, other)
    }
    
    static func e(_ tag: String, _ message: String, _ other: Any?...) {
        log(.error, tag, message, other)
    }

    static func redactedDescription(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let dictionary = value as? [AnyHashable: Any] {
            let entries = dictionary.map { key, nested -> String in
                let keyText = String(describing: key)
                let normalizedKey = keyText.lowercased()
                let isSensitive = sensitiveKeys.contains { normalizedKey.contains($0) }
                return "\(keyText): \(isSensitive ? "<redacted>" : redactedDescription(nested))"
            }
            return "[" + entries.sorted().joined(separator: ", ") + "]"
        }
        if let values = value as? [Any] {
            return "[" + values.map { redactedDescription($0) }.joined(separator: ", ") + "]"
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let error = value as? Error { return error.localizedDescription }
        return "<\(String(describing: type(of: value))) redacted>"
    }

    static func formattedMetadata(_ values: [Any?]) -> [String] {
        values.compactMap { value in
            guard value != nil else { return nil }
            return redactedDescription(value)
        }
    }
    
    private static func log(_ level: LogLevel, _ tag: String, _ message: String, _ other: [Any?]) {
        RecentLog.shared.append("\(levelStr(level).prefix(1)) \(tag): \(message)")
        #if DEBUG
        print("\(dateStr()) ntfyApp [\(levelStr(level))] \(tag): \(message)")
        for line in formattedMetadata(other) {
            print("  ", line)
        }
        #endif
    }
    
    private static func dateStr() -> String {
        dateFormatter.string(from: Date())
    }
    
    private static func levelStr(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING ⚠️"
        case .error: return "ERROR ‼️"
        }
    }
}

/// This process's latest log lines, in memory only and never written to disk. Feedback attaches them,
/// cleaned by `FeedbackScrubber`, only when the person ticks "Include diagnostic logs".
/// Metadata arguments are not kept: they can hold message content.
final class RecentLog {
    static let shared = RecentLog()
    static let capacity = 400
    static let maximumLineLength = 300
    private var lines: [String] = []
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(formatter.string(from: Date()) + " " + String(line.prefix(Self.maximumLineLength)))
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

private enum LogLevel {
    case debug
    case info
    case warning
    case error
}
