import Foundation
import Observation

/// A file or folder in the explorer tree. Folders load their children
/// lazily, the first time they are expanded.
@MainActor
@Observable
public final class FileNode: Identifiable {
    public private(set) var url: URL
    public private(set) var name: String
    public let isDirectory: Bool
    @ObservationIgnored public private(set) weak var parent: FileNode?
    /// nil until loaded; folders only.
    public internal(set) var children: [FileNode]?
    public internal(set) var isLoading = false

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    init(url: URL, isDirectory: Bool, parent: FileNode?) {
        self.url = url.standardizedFileURL
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.parent = parent
    }

    public var depth: Int {
        var depth = 0
        var node = parent
        while let current = node {
            depth += 1
            node = current.parent
        }
        return depth
    }

    /// Path relative to the tree's root.
    public var relativePath: String {
        var parts: [String] = []
        var node: FileNode? = self
        while let current = node, current.parent != nil {
            parts.insert(current.name, at: 0)
            node = current.parent
        }
        return parts.joined(separator: "/")
    }

    func rebase(to newURL: URL) {
        url = newURL.standardizedFileURL
        name = newURL.lastPathComponent
        for child in children ?? [] {
            child.rebase(to: url.appendingPathComponent(child.name))
        }
    }
}

/// The explorer tree for one workspace: lazily loaded folders, expansion
/// state, and the flattened list of visible rows the sidebar draws.
@MainActor
@Observable
public final class FileTree {
    public struct Row: Identifiable {
        public let node: FileNode
        public let depth: Int
        public var id: ObjectIdentifier { node.id }
    }

    public let root: FileNode
    public private(set) var expanded: Set<String> = []
    /// Names hidden from the tree (still visible to the terminal).
    public var hiddenNames: Set<String> = [".git", ".DS_Store", ".build", ".swiftpm", "xcuserdata"] {
        didSet { Task { await reloadAll() } }
    }
    public var showHiddenFiles = true {
        didSet { Task { await reloadAll() } }
    }
    /// Called with every directory the tree starts or stops showing, so the
    /// workspace can watch exactly the visible folders.
    @ObservationIgnored public var onVisibleDirectoriesChanged: ((_ added: [URL], _ removed: [URL]) -> Void)?

    public init(rootURL: URL) {
        root = FileNode(url: rootURL, isDirectory: true, parent: nil)
        expanded = [root.url.path]
    }

    // MARK: Rows

    /// Visible rows, depth-first, children of expanded folders only. The
    /// root itself is not a row.
    public var rows: [Row] {
        var result: [Row] = []
        func append(_ node: FileNode, depth: Int) {
            for child in node.children ?? [] {
                result.append(Row(node: child, depth: depth))
                if child.isDirectory, expanded.contains(child.url.path) {
                    append(child, depth: depth + 1)
                }
            }
        }
        append(root, depth: 0)
        return result
    }

    public func isExpanded(_ node: FileNode) -> Bool {
        expanded.contains(node.url.path)
    }

    // MARK: Expansion

    public func toggle(_ node: FileNode) async {
        if isExpanded(node) { collapse(node) } else { await expand(node) }
    }

    public func expand(_ node: FileNode) async {
        guard node.isDirectory else { return }
        expanded.insert(node.url.path)
        if node.children == nil { await load(node) }
        onVisibleDirectoriesChanged?([node.url], [])
    }

    public func collapse(_ node: FileNode) {
        guard node !== root else { return }
        expanded.remove(node.url.path)
        onVisibleDirectoriesChanged?([], [node.url])
    }

    public func collapseAll() {
        let removed = expanded.filter { $0 != root.url.path }.map { URL(fileURLWithPath: $0) }
        expanded = [root.url.path]
        onVisibleDirectoriesChanged?([], removed)
    }

    /// Expands every ancestor of `url` and returns its node.
    @discardableResult
    public func reveal(_ url: URL) async -> FileNode? {
        guard let relative = FileOperations.relativePath(of: url, to: root.url), !relative.isEmpty else { return nil }
        var node = root
        if node.children == nil { await load(node) }
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            guard let next = node.children?.first(where: { $0.name == part }) else { return nil }
            if index < parts.count - 1 {
                await expand(next)
            }
            node = next
        }
        return node
    }

    // MARK: Loading

    /// Loads (or reloads) a folder's children, keeping existing child nodes
    /// so their expansion state and identity survive.
    public func load(_ node: FileNode) async {
        guard node.isDirectory else { return }
        node.isLoading = true
        let url = node.url
        let hidden = hiddenNames
        let showHidden = showHiddenFiles
        let listing = await Task.detached(priority: .userInitiated) { () -> [(String, Bool)] in
            Self.list(url, hidden: hidden, showHidden: showHidden)
        }.value
        let existing = Dictionary((node.children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [FileNode] = []
        for (name, isDirectory) in listing {
            if let old = existing[name], old.isDirectory == isDirectory {
                next.append(old)
            } else {
                next.append(FileNode(url: url.appendingPathComponent(name), isDirectory: isDirectory, parent: node))
            }
        }
        let removedDirectories = (node.children ?? []).filter { child in child.isDirectory && !next.contains { $0 === child } }
        node.children = next
        node.isLoading = false
        if !removedDirectories.isEmpty {
            let gone = removedDirectories.map(\.url)
            for url in gone { expanded = expanded.filter { $0 != url.path && !$0.hasPrefix(url.path + "/") } }
            onVisibleDirectoriesChanged?([], gone)
        }
        // Reload expanded subfolders that have never loaded (restored state).
        for child in next where child.isDirectory && expanded.contains(child.url.path) && child.children == nil {
            await load(child)
        }
    }

    /// Reloads the folder at `url` if the tree has loaded it.
    public func reload(directory url: URL) async {
        guard let node = node(for: url), node.isDirectory, node.children != nil else { return }
        await load(node)
    }

    public func reloadAll() async {
        func loaded(_ node: FileNode) -> [FileNode] {
            guard node.children != nil else { return [] }
            return [node] + (node.children ?? []).filter(\.isDirectory).flatMap(loaded)
        }
        for node in loaded(root) { await load(node) }
    }

    /// The loaded node for `url`, if any.
    public func node(for url: URL) -> FileNode? {
        let target = url.standardizedFileURL
        if target.path == root.url.path { return root }
        guard let relative = FileOperations.relativePath(of: target, to: root.url) else { return nil }
        var node = root
        for part in relative.split(separator: "/") {
            guard let next = node.children?.first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    /// Updates expansion state after a folder moved, so it stays open.
    public func folderMoved(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        let newPath = new.standardizedFileURL.path
        expanded = Set(expanded.map { path in
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
            return path
        })
    }

    /// Restores expansion from saved relative paths.
    public func restoreExpansion(_ relativePaths: [String]) async {
        for relative in relativePaths.sorted(by: { $0.count < $1.count }) {
            let url = root.url.appendingPathComponent(relative)
            if let node = await reveal(url), node.isDirectory {
                await expand(node)
            }
        }
    }

    /// Expanded folders as relative paths, for state restoration.
    public var expandedRelativePaths: [String] {
        expanded.compactMap { FileOperations.relativePath(of: URL(fileURLWithPath: $0), to: root.url) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    nonisolated static func list(_ url: URL, hidden: Set<String>, showHidden: Bool) -> [(String, Bool)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                      options: []) else { return [] }
        var result: [(String, Bool)] = []
        for item in items {
            let name = item.lastPathComponent
            if hidden.contains(name) { continue }
            if !showHidden, name.hasPrefix(".") { continue }
            let values = try? item.resourceValues(forKeys: Set(keys))
            result.append((name, values?.isDirectory ?? false))
        }
        return sortedForDisplay(result)
    }

    /// Folders first, then files, each in Finder order ("file2" < "file10").
    public nonisolated static func sortedForDisplay(_ entries: [(String, Bool)]) -> [(String, Bool)] {
        entries.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 }
            return lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
        }
    }
}
