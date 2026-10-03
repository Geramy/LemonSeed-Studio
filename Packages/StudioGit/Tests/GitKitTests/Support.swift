import Foundation
@testable import GitKit

/// A throwaway directory under the test's temporary directory.
struct TempDir {
    let url: URL
    init(_ name: String = "repo") {
        url = FileManager.default.temporaryDirectory
            .appending(path: "gitkit-tests")
            .appending(path: "\(name)-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appending(path: path), encoding: .utf8)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: url.appending(path: path))
    }
}

let testAuthor = Signature(name: "Test Author", email: "author@example.com",
                           date: Date(timeIntervalSince1970: 1_700_000_000), timeZoneOffsetMinutes: 0)

extension GitRepository {
    /// Stages everything and commits with the test author.
    @discardableResult
    func commitAll(_ message: String, date: Date? = nil) throws -> ObjectID {
        try stageAll()
        var author = testAuthor
        if let date { author.date = date }
        return try commit(message: message, options: CommitOptions(author: author))
    }
}

/// A repository with an initial commit and user identity configured.
func makeRepo(_ files: [String: String] = ["README.md": "hello\n"], branch: String = "main") async throws -> (TempDir, GitRepository) {
    let dir = TempDir()
    let repo = try GitRepository.create(at: dir.url, initialBranch: branch)
    try await repo.setConfigValue("user.name", testAuthor.name)
    try await repo.setConfigValue("user.email", testAuthor.email)
    for (path, text) in files { try dir.write(path, text) }
    if !files.isEmpty { try await repo.commitAll("Initial commit") }
    return (dir, repo)
}
