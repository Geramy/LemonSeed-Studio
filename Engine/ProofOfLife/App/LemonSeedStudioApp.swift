import SwiftUI

@main
struct LemonSeedStudioApp: App {
    @StateObject private var model = ProbeModel()
    @StateObject private var lse = LSEModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .environmentObject(model)
                    .tabItem { Label("Driver", systemImage: "cpu") }
                LSEView()
                    .environmentObject(lse)
                    .tabItem { Label("LSE", systemImage: "text.bubble") }
            }
        }
    }
}
