import SwiftUI
import UIKit

/// What an agent needs to reach this topic, as text to paste into its chat or instructions.
/// Every line holds for the shipped server and matches the agent guide
/// (server/ntfy-me/ntfyme-docs-src/agents.md): the topic URL, a tagged curl send, the `-answers`
/// convention for button answers, written replies as untagged messages, and the guide's address.
/// It is addressed to the agent, so like the commands in it, it stays in English.
enum AgentInstructions {
    static let guideUrl = "https://ntf-ai.app/docs/agents"

    static func text(baseUrl: String, topic: String, auth: PublishCommand.Auth = .none) -> String {
        let url = PublishCommand.publishUrl(baseUrl: baseUrl, topic: topic)
        // The server's root, where a JSON publish goes: the topic URL without "/<topic>".
        let root = url.hasSuffix("/" + topic) ? String(url.dropLast(topic.count + 1)) : url
        var lines = [
            "Send me phone notifications with NTF-AI. It speaks the ntfy protocol over plain HTTPS: no SDK or API key.",
            "",
            "Topic URL: \(url)",
            "Treat it as a password: anyone who knows it can read and send. Keep it out of repos, logs and transcripts.",
        ]
        if !auth.isEmpty {
            lines.append("This server needs a login: send it with every request, as in the command below.")
        }
        lines += [
            "",
            "Send a notification:",
            PublishCommand.agentSend(baseUrl: baseUrl, topic: topic, auth: auth),
            "",
            "Ask me a question: POST JSON to \(root) with \"topic\": \"\(topic)\", a \"message\", \"tags\": [\"agent\"], and \"http\" actions (for example Approve and Reject) that POST \"reply:<request-id>:<answer>\" to \(url)-answers. Then poll \(url)-answers/json?poll=1&since=all for your request ID, and stop waiting after a deadline. Never ask me to subscribe to the -answers topic.",
            "I can also write back from the app: a written reply is a message on \(url) without the agent tag.",
            "When a question is settled, update it or clear it, so it leaves my Waiting list.",
            "",
            "Full guide, including the ntf command that does all of this: \(guideUrl)",
        ]
        return lines.joined(separator: "\n")
    }
}

/// "Connect an agent" (DECISION change 10): step 2 of Add topic, and in the topic menu.
struct ConnectAgentView: View {
    @EnvironmentObject private var store: Store
    let baseUrl: String
    let topic: String
    let onDone: () -> Void
    @State private var copied: String?

    private var auth: PublishCommand.Auth {
        PublishCommand.Auth(
            username: store.getBasicUser(baseUrl: baseUrl).flatMap { $0.isAccessToken ? nil : $0.username },
            accessToken: store.getBasicUser(baseUrl: baseUrl)?.isAccessToken ?? false,
            headerNames: KeychainCredentialStore.shared.httpHeaders(baseUrl: baseUrl).keys.sorted()
        )
    }

    private var instructions: String { AgentInstructions.text(baseUrl: baseUrl, topic: topic, auth: auth) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Paste this into your agent's chat or instructions. It tells the agent how to notify you, ask you a question and read your answer."))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: instructions)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                    .accessibilityIdentifier("connect-instructions")
                Button {
                    copy(instructions, as: "instructions")
                } label: {
                    Label(copied == "instructions" ? String(localized: "Copied") : String(localized: "Copy instructions"),
                          systemImage: copied == "instructions" ? "checkmark" : AppSymbol.copyText)
                        .frame(maxWidth: .infinity)
                }
                .brandProminentButton()
                .accessibilityIdentifier("connect-copy")
                Button {
                    copy(PublishCommand.publishUrl(baseUrl: baseUrl, topic: topic), as: "url")
                } label: {
                    Label(copied == "url" ? String(localized: "Copied") : String(localized: "Copy topic URL"),
                          systemImage: copied == "url" ? "checkmark" : AppSymbol.copyLink)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                if let guide = URL(string: AgentInstructions.guideUrl) {
                    Link(destination: guide) {
                        Label(String(localized: "Agent guide"), systemImage: "arrow.up.right")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                }
                Button(String(localized: "Done"), action: onDone)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .frame(maxWidth: .infinity)
                    .tint(.secondary)
                    .foregroundColor(.primary)
                    .accessibilityIdentifier("connect-done")
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(String(localized: "Connect an agent"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copy(_ text: String, as which: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = which
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == which { copied = nil } }
    }
}

/// The Connect sheet on its own, from a topic's menu.
struct ConnectAgentSheet: View {
    let baseUrl: String
    let topic: String
    @Binding var isShowing: Bool

    var body: some View {
        NavigationView {
            ConnectAgentView(baseUrl: baseUrl, topic: topic) { isShowing = false }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
