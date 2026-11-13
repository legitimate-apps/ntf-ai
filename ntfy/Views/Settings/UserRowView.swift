//
//  UserRowView.swift
//  ntfy
//
//  Created by Alek Michelson on 4/10/26.
//

import SwiftUI

struct UserRowView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var user: User
    
    var body: some View {
        // TODO: swipe to delete action
        // I tried to add a swipe action here to delete, but for some strange reason it doesn't work,
        // even though in the subscription list it does.
        
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.getBasicUser(baseUrl: user.baseUrl ?? "")?.username ?? String(localized: "Sign-in required"))
                Text(shortUrl(url: user.baseUrl ?? "?"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            RowAccessoryGlyph()
        }
    }
}
