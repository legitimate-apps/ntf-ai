//
//  UserEditorView.swift
//  ntfy
//
//  Created by Alek Michelson on 5/18/26.
//
// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.

import SwiftUI

struct AttachmentAutoDownloadOption: Identifiable, Equatable {
    let value: Int64
    let title: String

    var id: Int64 { value }

    /// The choices, in the order the menu lists them.
    static var all: [AttachmentAutoDownloadOption] {
        [
            .init(value: Store.autoDownloadNever, title: String(localized: "Never")),
            .init(value: Store.autoDownloadAlways, title: String(localized: "Always")),
            .init(value: Store.autoDownload100KB, title: String(localized: "Under 100 KB")),
            .init(value: Store.autoDownload500KB, title: String(localized: "Under 500 KB")),
            .init(value: Store.autoDownload1MB, title: String(localized: "Under 1 MB")),
            .init(value: Store.autoDownload5MB, title: String(localized: "Under 5 MB")),
            .init(value: Store.autoDownload10MB, title: String(localized: "Under 10 MB")),
            .init(value: Store.autoDownload50MB, title: String(localized: "Under 50 MB"))
        ]
    }

    /// What the picker reads and writes: the stored limit, saved through the same store call the
    /// action sheet made.
    static func selection(store: Store, current: @escaping () -> Int64) -> Binding<Int64> {
        Binding(get: current, set: { store.saveAttachmentAutoDownloadMaxSize($0) })
    }
}

/// A menu picker, like "Sort topics by" above it: the value is tinted and carries the up-down
/// chevron, so the row reads as a choice rather than a read-only value.
struct AttachmentAutoDownloadView: View {
    @EnvironmentObject private var store: Store
    @FetchRequest(sortDescriptors: []) private var prefs: FetchedResults<Preference>

    private var currentValue: Int64 {
        prefs
            .first { $0.key == Store.prefKeyAttachmentAutoDownloadMaxSize }?
            .value
            .flatMap(Int64.init) ?? Store.autoDownloadDefault
    }

    var body: some View {
        Picker(String(localized: "Download attachments"),
               selection: AttachmentAutoDownloadOption.selection(store: store, current: { currentValue })) {
            ForEach(AttachmentAutoDownloadOption.all) { option in
                Text(option.title).tag(option.value)
            }
        }
    }
}
