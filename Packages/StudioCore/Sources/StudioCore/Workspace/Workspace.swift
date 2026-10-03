import Foundation
import Observation

/// An open workspace: a root folder with its file tree, open documents,
/// quick-open file index, diagnostics and output, kept current by a file
/// watcher. File operations go through here so the tree, the index and
/// open documents all follow renames, moves and deletes.
@MainActor
@Observable
public final class Workspace {
    public let rootURL: URL
    public private(set) var name: String
    public let reference: WorkspaceReference?
    public let tree: FileTree
    public let diagnostics = DiagnosticsCenter()
    public let output = OutputCenter()

    /// Every file in the workspace (relative paths, ignore-aware), for quick
    /// open. Rebuilt in the background when the tree changes.
    public private(set) var fileIndex: [String] = []
    public private(set) var isIndexing = false
    public private(set) var documents: [EditorDocument] = []
    public var walkOptions = WalkOptions() {
        didSet { scheduleIndex() }
    }

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var resolved: ResolvedWorkspace?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexGeneration = 0

    public init(rootURL: URL, reference: WorkspaceReference? = nil, resolved: ResolvedWorkspace? = nil) {
        let root = rootURL.standardizedFileURL
        self.rootURL = root
        self.name = reference?.displayName ?? root.lastPathComponent
        self.reference = reference
        self.resolved = resolved
        self.tree = FileTree(rootURL: root)
        let watcher = FileWatcher { [weak self] urls in
            Task { @MainActor in self?.filesChanged(urls) }
        }
        self.watcher = watcher
        tree.onVisibleDirectoriesChanged = { [weak watcher] added, removed in
            removed.forEach { watcher?.unwatch($0) }
            added.forEach { watcher?.watch($0) }
        }
        watcher.watch(root)
    }

    /// Loads the first level and builds the index.
    public func open() async {
        await tree.load(tree.root)
        rebuildIndex()
        output.append("Opened \(rootURL.path)", channel: "Studio")
    }

    /// Stops watching and releases security-scoped access.
    public func close() {
        indexTask?.cancel()
        watcher?.unwatchAll()
        watcher = nil
        resolved?.close()
        resolved = nil
    }

    // MARK: Documents

    /// The open document for `url`, opening and loading it if needed.
    public func document(for url: URL) -> EditorDocument {
        let target = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url == target }) { return existing }
        let document = EditorDocument(url: target)
        documents.append(document)
        watcher?.watch(target)
        Task { await document.load() }
        return document
    }

    public func openDocument(at url: URL) -> EditorDocument? {
        documents.first { $0.url == url.standardizedFileURL }
    }

    /// Forgets a document no editor shows anymore.
    public func release(_ document: EditorDocument) {
        documents.removeAll { $0 === document }
        watcher?.unwatch(document.url)
    }

    public var dirtyDocuments: [EditorDocument] { documents.filter(\.isDirty) }

    public func saveAll() async throws {
        for document in dirtyDocuments { try await document.save() }
    }

    // MARK: File operations

    @discardableResult
    public func createFile(named name: String, in folder: URL, contents: Data = Data()) async throws -> URL {
        let url = try await Task.detached { try FileOperations.createFile(named: name, in: folder, contents: contents) }.value
        await refresh(folder)
        return url
    }

    @discardableResult
    public func createFolder(named name: String, in folder: URL) async throws -> URL {
        let url = try await Task.detached { try FileOperations.createFolder(named: name, in: folder) }.value
        await refresh(folder)
        return url
    }

    @discardableResult
    public func rename(_ url: URL, to newName: String) async throws -> URL {
        let wasDirectory = FileOperations.isDirectory(url)
        let destination = try await Task.detached { try FileOperations.rename(url, to: newName) }.value
        moved(from: url, to: destination, isDirectory: wasDirectory)
        await refresh(url.deletingLastPathComponent())
        return destination
    }

    @discardableResult
    public func move(_ url: URL, into folder: URL) async throws -> URL {
        let wasDirectory = FileOperations.isDirectory(url)
        let destination = try await Task.detached { try FileOperations.move(url, into: folder) }.value
        guard destination.standardizedFileURL != url.standardizedFileURL else { return destination }
        moved(from: url, to: destination, isDirectory: wasDirectory)
        await refresh(url.deletingLastPathComponent())
        await refresh(folder)
        return destination
    }

    /// Copies an item (e.g. dropped from Files) into a workspace folder.
    @discardableResult
    public func importItem(_ url: URL, into folder: URL) async throws -> URL {
        let destination = try await Task.detached {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try FileOperations.copy(url, into: folder)
        }.value
        await refresh(folder)
        return destination
    }

    @discardableResult
    public func duplicate(_ url: URL) async throws -> URL {
        let destination = try await Task.detached { try FileOperations.duplicate(url) }.value
        await refresh(url.deletingLastPathComponent())
        return destination
    }

    /// Deletes an item. Open documents for it (or inside it) are returned so
    /// the caller can close their tabs.
    @discardableResult
    public func delete(_ url: URL) async throws -> [EditorDocument] {
        try await Task.detached { try FileOperations.delete(url) }.value
        let path = url.standardizedFileURL.path
        let affected = documents.filter { $0.url.path == path || $0.url.path.hasPrefix(path + "/") }
        watcher?.unwatchTree(url)
        await refresh(url.deletingLastPathComponent())
        return affected
    }

    private func moved(from old: URL, to new: URL, isDirectory: Bool) {
        let oldPath = old.standardizedFileURL.path
        for document in documents where document.url.path == oldPath || document.url.path.hasPrefix(oldPath + "/") {
            watcher?.unwatch(document.url)
            let suffix = document.url.path.dropFirst(oldPath.count)
            document.didMove(to: URL(fileURLWithPath: new.standardizedFileURL.path + suffix))
            watcher?.watch(document.url)
        }
        if isDirectory {
            watcher?.unwatchTree(old)
            tree.folderMoved(from: old, to: new)
        }
        diagnostics.move(from: old, to: new)
    }

    /// Reloads one folder in the tree and refreshes the index.
    public func refresh(_ folder: URL) async {
        await tree.reload(directory: folder)
        if let node = tree.node(for: folder), tree.isExpanded(node) { watcher?.watch(folder) }
        scheduleIndex()
    }

    // MARK: Watching

    private func filesChanged(_ urls: Set<URL>) {
        var directoriesChanged = false
        for url in urls {
            let standardized = url.standardizedFileURL
            if let document = openDocument(at: standardized) {
                Task { await document.fileDidChangeOnDisk() }
            }
            if tree.node(for: standardized)?.isDirectory == true || standardized == rootURL {
                directoriesChanged = true
                Task { await tree.reload(directory: standardized) }
            }
        }
        if directoriesChanged { scheduleIndex() }
    }

    // MARK: Index

    /// Rebuilds the quick-open index now.
    public func rebuildIndex() {
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        let root = rootURL
        let options = walkOptions
        isIndexing = true
        indexTask = Task { [weak self] in
            let files = await Task.detached(priority: .utility) { FileWalker.files(in: root, options: options, limit: 250_000) }.value
            guard let self, !Task.isCancelled, generation == self.indexGeneration else { return }
            self.fileIndex = files
            self.isIndexing = false
        }
    }

    private func scheduleIndex() {
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        indexTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, generation == self.indexGeneration else { return }
            self.rebuildIndex()
        }
    }

    /// Waits until the current index build finishes (tests, automation).
    public func waitForIndex() async {
        while isIndexing {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    public func url(forRelativePath path: String) -> URL {
        rootURL.appendingPathComponent(path)
    }

    public func relativePath(of url: URL) -> String? {
        FileOperations.relativePath(of: url, to: rootURL)
    }
}
