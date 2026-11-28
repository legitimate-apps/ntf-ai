// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
// Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
import SwiftUI

struct ContentView: View {
    var body: some View {
        MainView()
            .modifier(FeedbackHost())
            .tint(Color("AccentColor"))
            .toggleStyle(SwitchToggleStyle(tint: Color("BrandControlFill")))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
