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
