import LemonText
import SwiftUI

@main
struct LemonTextDemoApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-keyboardStress") {
                KeyboardStressView()
            } else if HarnessOptions.current.isEnabled && ProcessInfo.processInfo.arguments.contains("-uitextview") {
                PlainTextViewHarness()
            } else if HarnessOptions.current.isEnabled {
                KeyboardHarnessView()
            } else {
                DemoRootView()
            }
        }
    }
}
