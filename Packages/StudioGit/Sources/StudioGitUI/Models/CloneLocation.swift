public import Foundation

/// Where clones go: the app container (default; visible in Files under
/// "On My iPad") or a user-chosen folder from any file provider, kept as a
/// security-scoped bookmark and re-resolved at each launch.
public enum CloneLocation: Hashable, Sendable {
    case appContainer
    case folder(SavedFolder)

    /// `Documents/Workspaces`.
    public static var workspacesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appending(path: "Workspaces", directoryHint: .isDirectory)
    }
}

/// A folder the user picked, stored as bookmark data.
public struct SavedFolder: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var bookmark: Data

    /// Resolves the bookmark, refreshing stale bookmark data in place.
    public mutating func resolve() throws -> URL {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale, let fresh = try? Self.bookmarkData(for: url) { bookmark = fresh }
        return url
    }

    static func bookmarkData(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
}

/// The saved folders (UserDefaults).
public final class SavedFolderStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "StudioGit.savedFolders"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var folders: [SavedFolder] {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([SavedFolder].self, from: data)) ?? []
        }
    }

    /// Saves a folder returned by the document picker (call while its
    /// security scope is open).
    @discardableResult
    public func add(_ url: URL) throws -> SavedFolder {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let folder = SavedFolder(id: UUID(), name: url.lastPathComponent, bookmark: try SavedFolder.bookmarkData(for: url))
        save(folders.filter { $0.name != folder.name } + [folder])
        return folder
    }

    public func remove(_ folder: SavedFolder) {
        save(folders.filter { $0.id != folder.id })
    }

    public func update(_ folder: SavedFolder) {
        save(folders.map { $0.id == folder.id ? folder : $0 })
    }

    private func save(_ folders: [SavedFolder]) {
        lock.withLock { defaults.set(try? JSONEncoder().encode(folders), forKey: key) }
    }
}

extension CloneLocation {
    /// Runs `body` with the parent directory for a new clone, inside the
    /// folder's security scope when it is a user folder.
    public func withDirectory<T>(_ store: SavedFolderStore, appFolder: URL = CloneLocation.workspacesDirectory,
                                 isolation: isolated (any Actor)? = #isolation,
                                 _ body: (URL) async throws -> T) async throws -> T {
        switch self {
        case .appContainer:
            let dir = appFolder
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try await body(dir)
        case .folder(var folder):
            let url = try folder.resolve()
            store.update(folder)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try await body(url)
        }
    }
}
