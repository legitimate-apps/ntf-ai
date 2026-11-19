//
//  AboutView.swift
//  ntfy
//
//  Created by Alek Michelson on 4/10/26.
//

import SwiftUI

struct AboutView: View {
    @State private var shareRequest: ShareRequest?

    var body: some View {
        Group {
            // Word of mouth is how most people find the app: one tap to the share sheet.
            Button { shareRequest = .app() } label: {
                ValueRow(String(localized: "Share NTF-AI"), value: "") {
                    RowAccessoryGlyph(systemName: AppSymbol.share)
                }
                .shareSheet($shareRequest)
            }
            .foregroundColor(.primary)
            .accessibilityIdentifier("share-app")
            // Primary help is the default server's quick start: its examples publish to ntfy-me.com.
            linkRow(String(localized: "Getting started"), detail: shortUrl(url: normalizeBaseUrl(Config.helpUrl)),
                    url: Config.helpUrl)
            // The support page explains how to reach us.
            linkRow(String(localized: "Get help or report a bug"), detail: String(localized: "NTF-AI support"),
                    url: Config.supportUrl)
            NavigationLink(String(localized: "Diagnostic reports")) { DiagnosticReportsView() }
            // Only a build with an App Store id (APP_STORE_ID) has a listing to rate.
            if let reviewUrl = Config.reviewUrl {
                linkRow(String(localized: "Rate the app"), detail: "App Store", url: reviewUrl)
            }
            NavigationLink(String(localized: "Licenses")) { LicensesView() }
            ValueRow(String(localized: "Version"), value: "\(Config.version) (\(Config.build))")
        }
    }

    // One builder rather than four near-identical blocks. The bug this replaces
    // was a wrong literal in one of those blocks — "Rate the app" opened
    // upstream's App Store listing — which is exactly the mistake that hides in
    // copy-pasted rows. Every URL now comes from Config.
    /// Ends in the external-link arrow, the same size and colour as the chevrons on the push rows.
    private func linkRow(_ title: String, detail: String, url: String) -> some View {
        Button(action: { open(url: url) }) {
            ValueRow(title, value: detail) {
                RowAccessoryGlyph(systemName: AppSymbol.externalLink)
            }
        }
        .foregroundColor(.primary)
    }

    private func open(url: String) {
        guard let url = URL(string: url) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}

/// A settings row with a title and a grey value. Side by side, both broke mid-word at the
/// accessibility text sizes ("Ver-sion", "ntfy-/me.-/com"), so there the value goes under the
/// title, the way iOS Settings lays it out.
struct ValueRow<Accessory: View>: View {
    @Environment(\.sizeCategory) private var sizeCategory
    let title: String
    let value: String
    let accessory: Accessory

    init(_ title: String, value: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.value = value
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .foregroundColor(.primary)
                    Text(value)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Text(value)
                    .foregroundColor(.secondary)
            }
            accessory
        }
    }
}

extension ValueRow where Accessory == EmptyView {
    init(_ title: String, value: String) {
        self.init(title, value: value) { EmptyView() }
    }
}
