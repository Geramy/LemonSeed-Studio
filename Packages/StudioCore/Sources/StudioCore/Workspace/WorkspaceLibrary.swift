import Foundation
import Observation

/// A saved pointer to a workspace folder: a project in the app's own
/// Projects folder, or any folder picked in Files (kept as a
/// security-scoped bookmark).
public struct WorkspaceReference: Codable, Hashable, Sendable, Identifiable {
    public enum Location: Codable, Hashable, Sendable {
        /// A folder inside the app container's Documents/Projects.
        case project(name: String)
        /// A folder chosen in Files: bookmark data, plus the last path seen.
        case bookmark(Data, lastKnownPath: String)
    }

    public var id: UUID
    public var displayName: String
    public var location: Location
    public var lastOpened: Date

    public init(id: UUID = UUID(), displayName: String, location: Location, lastOpened: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.location = location
        self.lastOpened = lastOpened
    }

    public var isProject: Bool {
        if case .project = location { return true }
        return false
    }

    /// Where it lives, for display ("On My iPad › Projects", "iCloud Drive › ...").
    public var locationDescription: String {
        switch location {
        case .project: return "On My iPad › LemonSeed Studio › Projects"
        case .bookmark(_, let path):
            if path.contains("/Mobile Documents/") { return "iCloud Drive" }
            if path.contains("/File Provider Storage/") || path.contains("/CloudStorage/") { return "Files" }
            return (path as NSString).deletingLastPathComponent
        }
    }
}

/// An opened workspace location. Call `close()` when the workspace closes
/// to balance security-scoped access.
public final class ResolvedWorkspace: @unchecked Sendable {
    public let url: URL
    private let accessing: Bool
    private var closed = false
    private let lock = NSLock()

    init(url: URL, accessing: Bool) {
        self.url = url
        self.accessing = accessing
    }

    public func close() {
        let shouldStop = lock.withLock { () -> Bool in
            defer { closed = true }
            return !closed && accessing
        }
        if shouldStop { url.stopAccessingSecurityScopedResource() }
    }

    deinit { close() }
}

public enum WorkspaceLibraryError: LocalizedError, Equatable {
    case notFound(String)
    case notAFolder(String)
    case bookmarkFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name): "“\(name)” can no longer be found. It may have been moved, renamed or deleted, or its drive is disconnected."
        case .notAFolder(let name): "“\(name)” is not a folder."
        case .bookmarkFailed(let reason): "The folder could not be remembered: \(reason)"
        }
    }
}

/// Recent workspaces, persisted with their bookmarks, plus the app's own
/// Projects folder (Documents/Projects, visible in Files as
/// "On My iPad › LemonSeed Studio").
@MainActor
@Observable
public final class WorkspaceLibrary {
    public private(set) var recents: [WorkspaceReference] = []
    public let projectsFolder: URL
    private let storageURL: URL
    public var maximumRecents = 24

    public init(storageURL: URL, projectsFolder: URL) {
        self.storageURL = storageURL
        self.projectsFolder = projectsFolder
        try? FileManager.default.createDirectory(at: projectsFolder, withIntermediateDirectories: true)
        load()
    }

    /// The library in the app container: Application Support/Workspaces.json
    /// and Documents/Projects.
    public static func standard() -> WorkspaceLibrary {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        return WorkspaceLibrary(storageURL: support.appendingPathComponent("Workspaces.json"),
                                projectsFolder: standardProjectsFolder)
    }

    /// The standard library's projects: Documents/Projects in the app container.
    public static var standardProjectsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Projects", isDirectory: true)
    }

    public func reference(id: UUID) -> WorkspaceReference? {
        recents.first { $0.id == id }
    }

    // MARK: Projects folder

    /// Folders in the Projects folder, by name.
    public func projects() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { FileOperations.isDirectory($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Creates a new, empty project folder.
    public func createProject(named name: String) throws -> WorkspaceReference {
        let url = try FileOperations.createFolder(named: name, in: projectsFolder)
        return reference(forProject: url.lastPathComponent)
    }

    /// The recent entry for a project folder, created if needed.
    public func reference(forProject name: String) -> WorkspaceReference {
        if let existing = recents.first(where: { $0.location == .project(name: name) }) {
            return existing
        }
        let reference = WorkspaceReference(displayName: name, location: .project(name: name))
        insert(reference)
        return reference
    }

    // MARK: Folders from Files

    /// Remembers a folder the user picked in Files. Call while holding
    /// security-scoped access (the document picker grants it).
    public func addFolder(_ url: URL) throws -> WorkspaceReference {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard FileOperations.isDirectory(url) else { throw WorkspaceLibraryError.notAFolder(url.lastPathComponent) }
        // Inside our own Projects folder: no bookmark needed.
        if let relative = FileOperations.relativePath(of: url, to: projectsFolder), !relative.isEmpty, !relative.contains("/") {
            return reference(forProject: relative)
        }
        let data: Data
        do {
            data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw WorkspaceLibraryError.bookmarkFailed(error.localizedDescription)
        }
        let standardized = url.standardizedFileURL.path
        if let index = recents.firstIndex(where: {
            if case .bookmark(_, let path) = $0.location { return path == standardized }
            return false
        }) {
            recents[index].location = .bookmark(data, lastKnownPath: standardized)
            recents[index].lastOpened = Date()
            let updated = recents[index]
            sortAndSave()
            return updated
        }
        let reference = WorkspaceReference(displayName: url.lastPathComponent,
                                           location: .bookmark(data, lastKnownPath: standardized))
        insert(reference)
        return reference
    }

    /// Resolves a reference to a URL and starts security-scoped access.
    /// Stale bookmarks are refreshed.
    public func resolve(_ reference: WorkspaceReference) throws -> ResolvedWorkspace {
        switch reference.location {
        case .project(let name):
            let url = projectsFolder.appendingPathComponent(name, isDirectory: true)
            guard FileOperations.isDirectory(url) else { throw WorkspaceLibraryError.notFound(name) }
            return ResolvedWorkspace(url: url, accessing: false)
        case .bookmark(let data, _):
            var stale = false
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                throw WorkspaceLibraryError.notFound(reference.displayName)
            }
            let accessing = url.startAccessingSecurityScopedResource()
            guard FileOperations.isDirectory(url) else {
                if accessing { url.stopAccessingSecurityScopedResource() }
                throw WorkspaceLibraryError.notFound(reference.displayName)
            }
            if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
               let index = recents.firstIndex(where: { $0.id == reference.id }) {
                recents[index].location = .bookmark(fresh, lastKnownPath: url.standardizedFileURL.path)
                recents[index].displayName = url.lastPathComponent
                save()
            }
            return ResolvedWorkspace(url: url, accessing: accessing)
        }
    }

    public func markOpened(_ id: UUID) {
        guard let index = recents.firstIndex(where: { $0.id == id }) else { return }
        recents[index].lastOpened = Date()
        sortAndSave()
    }

    public func remove(_ id: UUID) {
        recents.removeAll { $0.id == id }
        save()
    }

    /// Follows a project folder renamed in the app.
    public func renameProject(from oldName: String, to newName: String) {
        guard let index = recents.firstIndex(where: { $0.location == .project(name: oldName) }) else { return }
        recents[index].location = .project(name: newName)
        recents[index].displayName = newName
        save()
    }

    // MARK: Persistence

    private func insert(_ reference: WorkspaceReference) {
        recents.insert(reference, at: 0)
        sortAndSave()
    }

    private func sortAndSave() {
        recents.sort { $0.lastOpened > $1.lastOpened }
        if recents.count > maximumRecents { recents.removeLast(recents.count - maximumRecents) }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([WorkspaceReference].self, from: data) else { return }
        recents = decoded.sorted { $0.lastOpened > $1.lastOpened }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
