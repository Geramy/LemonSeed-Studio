import Foundation

/// Options for walking a workspace.
public struct WalkOptions: Hashable, Sendable {
    /// Honor .gitignore, .ignore and .git/info/exclude.
    public var respectIgnoreFiles = true
    /// Include dotfiles and dot-directories (other than excluded names).
    public var includeHidden = true
    /// Names never entered or listed, at any depth.
    public var excludedNames: Set<String> = WalkOptions.defaultExcludedNames
    /// Extra glob patterns (gitignore syntax) to exclude, relative to the root.
    public var excludePatterns: [String] = []
    /// Follow symbolic links to directories (cycles are detected).
    public var followSymlinks = false

    public static let defaultExcludedNames: Set<String> = [
        ".git", ".hg", ".svn", ".DS_Store", ".build", ".swiftpm", "DerivedData", "node_modules", "xcuserdata",
    ]

    public init() {}
}

/// One file or directory found by the walker.
public struct WalkEntry: Hashable, Sendable {
    /// Path relative to the root, '/'-separated.
    public var relativePath: String
    public var isDirectory: Bool

    public var name: Substring {
        relativePath.split(separator: "/").last ?? Substring(relativePath)
    }
}

/// A fast, ignore-aware recursive directory walker built on readdir(3).
/// It never enters excluded or ignored directories, which is most of what
/// makes ripgrep fast on real repositories.
public enum FileWalker {
    /// Calls `visit` for every file and directory under `root` (not the root
    /// itself), parents before children. Return false from `visit` to stop.
    /// Returning false for a directory entry is not a skip; use `shouldEnter`.
    public static func walk(root: URL, options: WalkOptions = WalkOptions(),
                            shouldEnter: (WalkEntry) -> Bool = { _ in true },
                            visit: (WalkEntry) -> Bool) {
        let rootPath = root.standardizedFileURL.path
        var baseRules = IgnoreRules()
        if !options.excludePatterns.isEmpty {
            baseRules = IgnoreRules(text: options.excludePatterns.joined(separator: "\n"))
        }
        if options.respectIgnoreFiles {
            let exclude = root.appendingPathComponent(".git/info/exclude")
            if let text = try? String(contentsOf: exclude, encoding: .utf8) {
                baseRules = baseRules.appending(IgnoreRules(text: text))
            }
        }
        var visitedInodes = Set<UInt64>()
        var stopped = false

        func descend(_ absolute: String, relative: String, inherited: IgnoreRules) {
            guard !stopped else { return }
            var rules = inherited
            if options.respectIgnoreFiles {
                rules = rules.appending(IgnoreRules.load(from: URL(fileURLWithPath: absolute), base: relative))
            }
            guard let dir = opendir(absolute) else { return }
            var children: [(name: String, isDirectory: Bool)] = []
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                if options.excludedNames.contains(name) { continue }
                if !options.includeHidden, name.hasPrefix(".") { continue }
                var isDirectory: Bool
                switch Int32(entry.pointee.d_type) {
                case DT_DIR: isDirectory = true
                case DT_REG: isDirectory = false
                case DT_LNK:
                    guard options.followSymlinks else { continue }
                    var info = stat()
                    guard stat(absolute + "/" + name, &info) == 0 else { continue }
                    isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
                    if isDirectory {
                        guard visitedInodes.insert(UInt64(info.st_ino)).inserted else { continue }
                    }
                default:
                    var info = stat()
                    guard lstat(absolute + "/" + name, &info) == 0 else { continue }
                    let kind = info.st_mode & S_IFMT
                    guard kind == S_IFDIR || kind == S_IFREG else { continue }
                    isDirectory = kind == S_IFDIR
                }
                children.append((name, isDirectory))
            }
            closedir(dir)
            children.sort { $0.name < $1.name }
            for child in children {
                guard !stopped else { return }
                let childRelative = relative.isEmpty ? child.name : relative + "/" + child.name
                if rules.isIgnored(path: childRelative, isDirectory: child.isDirectory) { continue }
                let entry = WalkEntry(relativePath: childRelative, isDirectory: child.isDirectory)
                if !visit(entry) {
                    stopped = true
                    return
                }
                if child.isDirectory, shouldEnter(entry) {
                    descend(absolute + "/" + child.name, relative: childRelative, inherited: rules)
                }
            }
        }

        descend(rootPath, relative: "", inherited: baseRules)
    }

    /// All files under `root` (relative paths), in walk order.
    public static func files(in root: URL, options: WalkOptions = WalkOptions(), limit: Int = .max) -> [String] {
        var result: [String] = []
        walk(root: root, options: options) { entry in
            if !entry.isDirectory { result.append(entry.relativePath) }
            return result.count < limit
        }
        return result
    }
}
