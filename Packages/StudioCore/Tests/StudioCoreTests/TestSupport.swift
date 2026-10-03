import Foundation
import XCTest

/// A temporary directory populated from a dictionary of relative paths.
/// Paths ending in "/" are folders; everything else is a file with the
/// given contents.
final class TemporaryTree {
    let url: URL

    init(_ files: [String: String] = [:], file: StaticString = #filePath, line: UInt = #line) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioCoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (path, contents) in files {
            try write(path, contents)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ path: String, _ contents: String) throws {
        let target = url.appendingPathComponent(path)
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: target)
        }
    }

    func writeData(_ path: String, _ data: Data) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    func child(_ path: String) -> URL {
        url.appendingPathComponent(path)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
