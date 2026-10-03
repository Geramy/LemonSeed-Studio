import Foundation

/// A folder the agent works in, provided by the app shell.
///
/// On iPad a workspace is usually a security-scoped bookmark into Files; the
/// shell resolves it and implements `withSecurityScope` around
/// `startAccessingSecurityScopedResource`. Everything the agent touches goes
/// through this scope and through `WorkspaceFileSystem`'s path jail.
public protocol AgentWorkspace: Sendable {
    /// The workspace root. Every tool path is resolved inside it.
    var rootURL: URL { get }
    /// Shown in the agent UI and in the system prompt.
    var displayName: String { get }
    /// Where `.lemonseed/` state lives (sessions, checkpoints). Defaults to
    /// `<root>/.lemonseed`; read-only folders point it into the app container.
    var stateDirectory: URL { get }
    /// Runs `body` with access to the root granted.
    func withSecurityScope<T>(_ body: () throws -> T) rethrows -> T
}

extension AgentWorkspace {
    public var stateDirectory: URL { rootURL.appending(path: ".lemonseed", directoryHint: .isDirectory) }
    public var displayName: String { rootURL.lastPathComponent }
}

/// A plain directory, optionally security-scoped.
public struct LocalWorkspace: AgentWorkspace {
    public let rootURL: URL
    public let displayName: String
    public let stateDirectory: URL
    private let securityScoped: Bool

    public init(rootURL: URL, displayName: String? = nil, stateDirectory: URL? = nil,
                securityScoped: Bool = false) {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = root
        self.displayName = displayName ?? root.lastPathComponent
        self.stateDirectory = stateDirectory ?? root.appending(path: ".lemonseed", directoryHint: .isDirectory)
        self.securityScoped = securityScoped
    }

    public func withSecurityScope<T>(_ body: () throws -> T) rethrows -> T {
        guard securityScoped else { return try body() }
        let started = rootURL.startAccessingSecurityScopedResource()
        defer { if started { rootURL.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

public enum WorkspaceError: Error, Hashable, Sendable, LocalizedError {
    case outsideWorkspace(String)
    case notFound(String)
    case notAFile(String)
    case notADirectory(String)
    case binaryFile(String)
    case alreadyExists(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let p): "\(p) is outside the workspace."
        case .notFound(let p): "\(p) does not exist."
        case .notAFile(let p): "\(p) is a directory, not a file."
        case .notADirectory(let p): "\(p) is not a directory."
        case .binaryFile(let p): "\(p) is not a UTF-8 text file."
        case .alreadyExists(let p): "\(p) already exists."
        case .io(let s): s
        }
    }
}

/// Receives a callback before any file is created, modified, moved or deleted,
/// so the original can be checkpointed first.
public protocol FileMutationObserver: Sendable {
    func willModify(_ url: URL, relativePath: String)
}

/// Jailed file access for tools and the shell.
///
/// Every path is resolved against the root, standardized, symlinks resolved,
/// and rejected if it leaves the root. `.lemonseed/` is off limits to the
/// model so it cannot rewrite its own checkpoints or sessions.
public struct WorkspaceFileSystem: Sendable {
    public let workspace: any AgentWorkspace
    public var observer: (any FileMutationObserver)?

    /// Directory names never listed, searched or globbed.
    public static let ignoredDirectories: Set<String> = [
        ".git", ".lemonseed", ".build", "build", "DerivedData", "node_modules", ".swiftpm", "__pycache__",
    ]

    public init(workspace: any AgentWorkspace, observer: (any FileMutationObserver)? = nil) {
        self.workspace = workspace
        self.observer = observer
    }

    public var root: URL { workspace.rootURL }

    // MARK: Paths

    /// Resolves a model-supplied path (relative to the root, or absolute
    /// inside it) to a URL in the jail.
    public func resolve(_ path: String) throws -> URL {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("@") { p.removeFirst() }  // models sometimes echo @-mentions
        if p.isEmpty || p == "." || p == "./" { return root }
        let candidate: URL
        if p.hasPrefix("/") {
            // An absolute path must name something inside the root; "/src/a.c"
            // is also accepted as root-relative, which is how the prompt
            // presents the workspace.
            let abs = URL(fileURLWithPath: p).standardizedFileURL
            if Self.isInside(abs.path, root.path) {
                candidate = abs
            } else {
                candidate = root.appending(path: String(p.drop(while: { $0 == "/" }))).standardizedFileURL
            }
        } else if p.hasPrefix("~") {
            throw WorkspaceError.outsideWorkspace(path)
        } else {
            candidate = root.appending(path: p).standardizedFileURL
        }
        let resolved = Self.resolveExistingPrefix(candidate)
        guard Self.isInside(resolved.path, root.path) else { throw WorkspaceError.outsideWorkspace(path) }
        let rel = relativePath(of: resolved)
        if rel == ".lemonseed" || rel.hasPrefix(".lemonseed/") { throw WorkspaceError.outsideWorkspace(path) }
        return resolved
    }

    /// Root-relative path with forward slashes ("" for the root itself).
    public func relativePath(of url: URL) -> String {
        let p = url.standardizedFileURL.path
        let r = root.path
        if p == r { return "" }
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        return p
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Resolves symlinks in the longest existing ancestor, so a link inside
    /// the workspace that points outside it is caught even for new files.
    static func resolveExistingPrefix(_ url: URL) -> URL {
        var existing = url
        var rest: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for c in rest { out = out.appending(path: c) }
        return out.standardizedFileURL
    }

    // MARK: Queries

    public func exists(_ url: URL) -> Bool {
        workspace.withSecurityScope { FileManager.default.fileExists(atPath: url.path) }
    }

    public func isDirectory(_ url: URL) -> Bool {
        workspace.withSecurityScope {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
        }
    }

    public func readData(_ url: URL) throws -> Data {
        try workspace.withSecurityScope {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WorkspaceError.notFound(relativePath(of: url))
            }
            if isDirectory(url) { throw WorkspaceError.notAFile(relativePath(of: url)) }
            do { return try Data(contentsOf: url) } catch { throw WorkspaceError.io(error.localizedDescription) }
        }
    }

    public func readText(_ url: URL) throws -> String {
        let data = try readData(url)
        if data.prefix(8192).contains(0) { throw WorkspaceError.binaryFile(relativePath(of: url)) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.binaryFile(relativePath(of: url))
        }
        return text
    }

    /// Lists a directory, sorted, directories suffixed with "/".
    public func list(_ url: URL, includeHidden: Bool = false) throws -> [String] {
        try workspace.withSecurityScope {
            guard isDirectory(url) else { throw WorkspaceError.notADirectory(relativePath(of: url)) }
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return names.filter { includeHidden || !$0.hasPrefix(".") }
                .filter { $0 != ".lemonseed" }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { isDirectory(url.appending(path: $0)) ? $0 + "/" : $0 }
        }
    }

    /// Walks files under `url` (root-relative paths), skipping ignored and
    /// hidden directories. Stops after `limit` files.
    public func walkFiles(under url: URL? = nil, limit: Int = 20_000) -> [String] {
        workspace.withSecurityScope {
            let start = url ?? root
            var out: [String] = []
            guard let e = FileManager.default.enumerator(
                at: start, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsPackageDescendants]) else { return out }
            for case let item as URL in e {
                let name = item.lastPathComponent
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    if Self.ignoredDirectories.contains(name) || name.hasPrefix(".") { e.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true, !name.hasPrefix(".") || name == ".gitignore" else { continue }
                out.append(relativePath(of: item.resolvingSymlinksInPath()))
                if out.count >= limit { break }
            }
            return out.sorted()
        }
    }

    // MARK: Mutations (each one notifies the observer first)

    public func writeText(_ text: String, to url: URL) throws {
        try writeData(Data(text.utf8), to: url)
    }

    public func writeData(_ data: Data, to url: URL) throws {
        observer?.willModify(url, relativePath: relativePath(of: url))
        try workspace.withSecurityScope {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                throw WorkspaceError.io("Could not write \(relativePath(of: url)): \(error.localizedDescription)")
            }
        }
    }

    public func createDirectory(_ url: URL) throws {
        try workspace.withSecurityScope {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            catch { throw WorkspaceError.io(error.localizedDescription) }
        }
    }

    public func remove(_ url: URL) throws {
        for file in isDirectory(url) ? walkFiles(under: url) : [relativePath(of: url)] {
            observer?.willModify(root.appending(path: file), relativePath: file)
        }
        try workspace.withSecurityScope {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw WorkspaceError.io(error.localizedDescription) }
        }
    }

    public func copy(_ from: URL, to: URL) throws {
        let data = try readData(from)
        try writeData(data, to: to)
    }

    public func move(_ from: URL, to: URL) throws {
        observer?.willModify(from, relativePath: relativePath(of: from))
        observer?.willModify(to, relativePath: relativePath(of: to))
        try workspace.withSecurityScope {
            do {
                try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                throw WorkspaceError.io(error.localizedDescription)
            }
        }
    }
}
