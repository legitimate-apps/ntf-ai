// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import SwiftUI

/// An open-source component in the app; MIT, Apache-2.0 and zlib require its notice to ship with it.
struct OpenSourceComponent: Identifiable, Hashable {
    let name: String
    let detail: String
    let licenseName: String
    let notice: String         // copyright line(s), plus the license text when it is short
    let licenseText: String?   // the shared Apache-2.0 or PolyForm Shield text, stored once
    /// NTF-AI's own entry: listed first, in its own section, above the projects it builds on.
    var isThisApp = false

    var id: String { name }
    var fullText: String { [notice, licenseText].compactMap { $0 }.joined(separator: "\n\n") }
    // Legal terms and notices are canonical in every locale; only the surrounding UI is translated.
    var localizedFullText: String { fullText }
    /// The detail screen: the translated description, then the canonical notice and license text.
    var displayText: String {
        Bundle.main.localizedString(forKey: detail, value: detail, table: nil) + "\n\n"
            + OpenSourceLicenses.reflowed(localizedFullText)
    }
}

enum OpenSourceLicenses {
    /// License files are hard-wrapped at ~80 columns, which wraps raggedly on a phone. For display,
    /// join the lines of each paragraph; blank lines still separate paragraphs. Words are unchanged.
    static func reflowed(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section {
                ForEach(OpenSourceLicenses.components.filter(\.isThisApp)) { row($0) }
            }
            Section(footer: Text(String(localized: "NTF-AI is built on these open-source projects."))) {
                ForEach(OpenSourceLicenses.components.filter { !$0.isThisApp }) { row($0) }
            }
        }
        .navigationTitle(String(localized: "Licenses"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ component: OpenSourceComponent) -> some View {
        NavigationLink {
            LicenseTextView(text: component.displayText)
                .navigationTitle(component.name)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                Text(LocalizedStringKey(component.licenseName))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityIdentifier(component.isThisApp ? "license-this-app" : "license-\(component.name)")
    }
}

/// A read-only UITextView: it scrolls itself, supports selecting any range (SwiftUI's
/// `textSelection` only copies the whole Text), and follows Dynamic Type and dark mode.
private struct LicenseTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .callout)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .systemBackground
        // Text on the same margin as the title and every list: 16 pt on narrow phones, 20 on wide.
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = LicenseTextInsets.insets(width: UIScreen.main.bounds.width)
        view.accessibilityIdentifier = "licenseText"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if view.bounds.width > 0 {
            let insets = LicenseTextInsets.insets(width: view.bounds.width)
            if view.textContainerInset != insets { view.textContainerInset = insets }
        }
    }
}

enum LicenseTextInsets {
    static func insets(width: CGFloat) -> UIEdgeInsets {
        let side: CGFloat = width >= 414 ? 20 : 16
        return UIEdgeInsets(top: 16, left: side, bottom: 16, right: side)
    }
}
