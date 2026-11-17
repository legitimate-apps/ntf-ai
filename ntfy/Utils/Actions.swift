import Foundation

struct Actions {
    static let shared = Actions()
    private let tag = "Actions"
    private let supportedActions = ["view", "http", "copy"]
    
    func parse(_ actions: String?) -> [Action]? {
        guard let actions = actions, actions != "",
              let data = actions.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([Action].self, from: data)
                .filter { supportedActions.contains($0.action) }
        } catch {
            Log.e(tag, "Unable to parse actions: \(error.localizedDescription)", error)
            return nil
        }
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
