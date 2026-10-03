import Foundation
@testable import StudioAgent

/// A temporary workspace with files, removed when the value is released.
final class TempWorkspace: @unchecked Sendable {
    let workspace: LocalWorkspace
    var root: URL { workspace.rootURL }

    init(_ files: [String: String] = [:]) throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "lemonseed-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspace = LocalWorkspace(rootURL: dir)
        for (path, text) in files { try write(path, text) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: path).path) }

    func fileSystem(observer: (any FileMutationObserver)? = nil) -> WorkspaceFileSystem {
        WorkspaceFileSystem(workspace: workspace, observer: observer)
    }

    func context(observer: (any FileMutationObserver)? = nil) -> ToolContext {
        ToolContext(fileSystem: fileSystem(observer: observer), shell: InProcessShell())
    }
}
