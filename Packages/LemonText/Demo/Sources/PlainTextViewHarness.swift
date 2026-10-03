import SwiftUI
import UIKit

/// A UIKit `UITextView` with the same accessibility outputs as the editor harness, used as a baseline
/// for the keyboard tests (`-keyboardHarness -uitextview`).
struct PlainTextViewHarness: View {
    @State private var text = ""
    @State private var caret = 0

    var body: some View {
        VStack {
            PlainTextView(text: $text, caret: $caret)
            Text("length=\(text.utf16.count);hash=0;caret=\(caret);keys=0;p50=0;p95=0;p99=0;max=0;idle=1")
                .accessibilityIdentifier("harness.status")
            Text(text).accessibilityIdentifier("harness.text").accessibilityLabel(text)
        }
    }
}

private struct PlainTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var caret: Int

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: PlainTextView
        init(_ parent: PlainTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidChangeSelection(_ textView: UITextView) { parent.caret = textView.selectedRange.location }
    }
}
