import SwiftUI

@main
struct LemonSeedStudioApp: App {
    @StateObject private var model = ProbeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
