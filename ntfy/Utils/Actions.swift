import Foundation

struct Actions {
    static let shared = Actions()
    private let tag = "Actions"
    static let supportedActions = ["view", "http", "copy"]
    private static var loggedTypes = Set<String>()
    private static let logLock = NSLock()

    /// The actions this build can show, from storage or the wire. Each action is read on its own, so
    /// one this build can't read (an unknown type, a missing label) never hides the others. Storage
    /// keeps the raw JSON (`Message.rawActions`), so what is skipped here is still there (SPEC 4).
    func parse(_ actions: String?) -> [Action]? {
        guard let actions = actions, actions != "",
              let data = actions.data(using: .utf8) else { return nil }
        guard let raw = try? JSONDecoder().decode([JSONValue].self, from: data) else {
            Log.e(tag, "Unable to parse actions")
            return nil
        }
        return known(raw)
    }

    func known(_ raw: [JSONValue]) -> [Action] {
        raw.compactMap { value -> Action? in
            guard let data = JSONValue.compact(value)?.data(using: .utf8),
                  let action = try? JSONDecoder().decode(Action.self, from: data) else { return nil }
            guard Self.supportedActions.contains(action.action) else {
                Self.logOnce(action.action, tag: tag)
                return nil
            }
            return action
        }
    }

    private static func logOnce(_ type: String, tag: String) {
        logLock.lock()
        let first = loggedTypes.insert(type).inserted
        logLock.unlock()
        if first { Log.d(tag, "Keeping action type \(type) in storage; not shown") }
    }

    func encode(_ actions: [Action]?) -> String {
        guard let actions = actions else { return "" }
        if let actionsData = try? JSONEncoder().encode(actions) {
            return String(data: actionsData, encoding: .utf8) ?? ""
        }
        return ""
    }
}


/// A normal view link remains useful in clients that do not support typed replies.
/// Only the exact versioned guide link opts into the text-input contract.
enum BannerReply {
    static func destination(for action: Action) -> URL? {
        guard action.action == "view", let raw = action.url,
              let link = URLComponents(string: raw), link.scheme == "https",
              HostedServer.hosts.contains(link.host?.lowercased() ?? ""), link.port == nil || link.port == 443,
              link.user == nil, link.password == nil, link.query == nil,
              link.percentEncodedPath == "/docs/agents",
              let fragment = link.percentEncodedFragment, fragment.hasPrefix("reply-v1="),
              let decoded = String(fragment.dropFirst("reply-v1=".count)).removingPercentEncoding,
              let target = URLComponents(string: decoded),
              ["https", "http"].contains(target.scheme ?? ""),
              let host = target.host, !host.isEmpty,
              target.user == nil, target.password == nil, target.query == nil, target.fragment == nil,
              let url = target.url else { return nil }
        let segments = target.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first == "", segments.count >= 2,
              !segments.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let topic = segments.last?.removingPercentEncoding,
              (1...64).contains(topic.utf8.count),
              topic.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return HostedServer.requestURL(url)
    }

    /// Raw UTF-8 avoids template substitution and preserves quotes, Unicode and newlines.
    static func httpAction(for action: Action, text: String) -> Action? {
        guard let url = destination(for: action), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Action(id: action.id, action: "http", label: action.label, url: url.absoluteString,
                      method: "POST", headers: ["Content-Type": "text/plain; charset=utf-8"],
                      body: text, clear: action.clear)
    }
}
