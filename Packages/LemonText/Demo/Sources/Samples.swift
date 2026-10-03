import Foundation
import LemonText

/// A bundled sample file.
struct Sample: Identifiable, Hashable {
    let fileName: String
    var id: String { fileName }
    var language: LemonLanguage { LanguageDetector.language(forFileName: fileName) }

    var url: URL? {
        Bundle.main.url(forResource: (fileName as NSString).deletingPathExtension,
                        withExtension: (fileName as NSString).pathExtension.isEmpty ? nil : (fileName as NSString).pathExtension,
                        subdirectory: "Samples")
    }

    func load() -> String {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "// \(fileName) is missing from the bundle\n"
        }
        return text
    }

    static let groups: [(title: String, samples: [Sample])] = [
        ("Systems", ["kernel_queue.cpp", "ring_buffer.c", "GPUSampler.m", "checkpoint.rs", "broker.go", "Telemetry.swift"].map(Sample.init)),
        ("Scripting", ["tokenize.py", "palette.js", "session.ts", "bootstrap.sh"].map(Sample.init)),
        ("Build & data", ["CMakeLists.txt", "Makefile", "model.json", "ci.yml", "README.md", "index.html", "editor.css"].map(Sample.init))
    ]

    static var all: [Sample] { groups.flatMap(\.samples) }

    /// A large document the user copied into the app's Documents folder (e.g. sqlite3.c).
    static var largeDocuments: [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let contents = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasSuffix(".json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
