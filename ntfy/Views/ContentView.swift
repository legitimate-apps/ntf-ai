import SwiftUI

struct ContentView: View {
    var body: some View {
        MainView()
            .toggleStyle(SwitchToggleStyle(tint: Color("BrandFill")))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
