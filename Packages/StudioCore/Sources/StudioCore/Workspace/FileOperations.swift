import Foundation

/// Errors from file operations, phrased for people.
public enum FileOperationError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case moveIntoItself(String)
    case outsideWorkspace(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "“\(name)” is not a valid file name."
        case .alreadyExists(let name): "An item named “\(name)” already exists here."
        case .notFound(let name): "“\(name)” no longer exists."
        case .moveIntoItself(let name): "“\(name)” cannot be moved into itself."
        case .outsideWorkspace(let path): "\(path) is outside the workspace."
        }
    }
}

/// File-system operations behind the file tree, the terminal and the agent.
/// All of them coordinate with other processes (Files, iCloud, other
/// providers) through NSFileCoordinator and are safe to call off the main
/// thread.
public enum FileOperations {
    // MARK: Names

    /// Checks a single path component typed by the user.
    public static func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else {
            throw FileOperationError.invalidName(name)
        }
    }

    /// "name.txt" -> "name 2.txt" -> "name 3.txt" ... until free in `folder`.
    public static func uniqueURL(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ns = name as NSString
        // ".gitignore" has no extension; "a.tar" has "tar".
        let dotfile = name.hasPrefix(".") && !name.dropFirst().contains(".")
        let ext = dotfile ? "" : ns.pathExtension
        var base = ext.isEmpty ? name : ns.deletingPathExtension
        // Strip an existing " N" suffix so duplicates of "a 2" become "a 3".
        if let range = base.range(of: #" \d+$"#, options: .regularExpression), range.lowerBound > base.startIndex {
            base.removeSubrange(range)
        }
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    // MARK: Create

    @discardableResult
    public static func createFile(named name: String, in folder: URL, contents: Data = Data()) throws -> URL {
        try validate(name: name)
        let url = folder.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FileOperationError.alreadyExists(name) }
        try coordinatedWrite(contents, to: url, options: .withoutOverwriting)
        return url
    }

    @discardableResult
    public static func createFolder(named name: String, in folder: URL) throws -> URL {
        try validate(name: name)
        let url = folder.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FileOperationError.alreadyExists(name) }
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) } catch { thrown = error }
        }
        if let error = coordinationError ?? thrown { throw error }
        return url
    }

    // MARK: Rename, move, copy, delete

    @discardableResult
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        try validate(name: newName)
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        if destination.path == url.path { return url }
        // Allow case-only renames on case-insensitive volumes.
        let caseOnly = destination.path.lowercased() == url.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: destination.path) {
            throw FileOperationError.alreadyExists(newName)
        }
        return try coordinatedMove(url, to: destination)
    }

    /// Moves `url` into `folder`, picking a free name on collision.
    @discardableResult
    public static func move(_ url: URL, into folder: URL) throws -> URL {
        let source = url.standardizedFileURL
        let target = folder.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FileOperationError.notFound(source.lastPathComponent)
        }
        if source.deletingLastPathComponent().path == target.path { return source }
        if target.path == source.path || target.path.hasPrefix(source.path + "/") {
            throw FileOperationError.moveIntoItself(source.lastPathComponent)
        }
        let destination = uniqueURL(for: source.lastPathComponent, in: target)
        return try coordinatedMove(source, to: destination)
    }

    /// Copies `url` into `folder`, picking a free name on collision.
    @discardableResult
    public static func copy(_ url: URL, into folder: URL) throws -> URL {
        let destination = uniqueURL(for: url.lastPathComponent, in: folder)
        try copy(url, to: destination)
        return destination
    }

    public static func copy(_ url: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], writingItemAt: destination, options: [],
                                       error: &coordinationError) { source, target in
            do { try FileManager.default.copyItem(at: source, to: target) } catch { thrown = error }
        }
        if let error = coordinationError ?? thrown { throw error }
    }

    @discardableResult
    public static func duplicate(_ url: URL) throws -> URL {
        let destination = uniqueURL(for: url.lastPathComponent, in: url.deletingLastPathComponent())
        try copy(url, to: destination)
        return destination
    }

    public static func delete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileOperationError.notFound(url.lastPathComponent)
        }
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { thrown = error }
        }
        if let error = coordinationError ?? thrown { throw error }
    }

    // MARK: Coordinated I/O

    public static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target, options: .mappedIfSafe) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    public static func coordinatedWrite(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) throws {
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: options) } catch { thrown = error }
        }
        if let error = coordinationError ?? thrown { throw error }
    }

    private static func coordinatedMove(_ source: URL, to destination: URL) throws -> URL {
        var coordinationError: NSError?
        var thrown: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination,
                               options: .forReplacing, error: &coordinationError) { from, to in
            do {
                coordinator.item(at: from, willMoveTo: to)
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch { thrown = error }
        }
        if let error = coordinationError ?? thrown { throw error }
        return destination
    }

    // MARK: Paths

    /// `url`'s path relative to `root`, or nil when it is not inside it.
    public static func relativePath(of url: URL, to root: URL) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        if path == base { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// The modification date, read fresh (never from a URL's value cache).
    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
