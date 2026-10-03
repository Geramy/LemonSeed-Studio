import SwiftUI
import UIKit

/// Helpers the development remote control uses: snapshots of the key
/// window, orientation requests and a sample workspace. Nothing here runs
/// on its own; the app never starts engine work by itself for testing.
@MainActor
enum DevSupport {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static let sampleWorkspaceName = "Selftest Workspace"

    /// A small C project with a code word in notes/codeword.txt.
    static func prepareSampleWorkspace(app: AppModel) -> URL {
        let root = app.library.projectsFolder.appendingPathComponent(sampleWorkspaceName, isDirectory: true)
        let files: [String: String] = [
            "README.md": "# Selftest Workspace\n\nA small C project for trying the agent.\nThe release code word is kept in notes/codeword.txt.\n",
            "notes/codeword.txt": "The release code word is MARMALADE-7319.\n",
            "src/main.c": "#include <stdio.h>\n#include \"util.h\"\n\nint main(void) {\n    printf(\"%d\\n\", add(2, 3));\n    return 0;\n}\n",
            "src/util.h": "#pragma once\n\nint add(int a, int b);\n",
            "src/util.c": "#include \"util.h\"\n\nint add(int a, int b) { return a + b; }\n",
            "Makefile": "all:\n\tcc -o hello src/main.c src/util.c\n",
        ]
        let fm = FileManager.default
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            guard !fm.fileExists(atPath: url.path) else { continue }
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        return root
    }

    /// Asks the scene for an orientation (the iPad's rotation lock or Stage
    /// Manager may decline).
    static func rotate(to mask: UIInterfaceOrientationMask) async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        try? await Task.sleep(for: .seconds(1.5))
    }

    static var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// The key window as drawn now, PNG.
    static func snapshot() -> Data? {
        guard let window = keyWindow else { return nil }
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        return renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }.pngData()
    }
}
