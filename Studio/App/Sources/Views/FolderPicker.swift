import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Files folder picker (UIDocumentPickerViewController for folders).
/// The picked URL is security-scoped; WorkspaceLibrary turns it into a
/// bookmark that survives relaunches.
struct FolderPicker: UIViewControllerRepresentable {
    let startingAt: URL?
    let completion: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.directoryURL = startingAt
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void

        init(completion: @escaping (URL?) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(nil)
        }
    }
}
