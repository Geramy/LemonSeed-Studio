// StudioModels: where models and their bookkeeping live.
//
//   Documents/Models/<id>/          installed models (visible in Files)
//   Documents/Models/.partial/<id>/ downloads in progress, same volume so
//                                   installing is a rename
//   Application Support/StudioModels/registry.json
//                                   the registry, plus registry.json.bak
//   Library/Caches/StudioModels/hf/ pinned Hugging Face API responses
//
// Model directories are excluded from iCloud backup. They sit in Documents,
// never in Caches, so the system never purges them.

import Foundation

public struct ModelStoreLocation: Sendable, Hashable {
    public var modelsRoot: URL
    public var supportRoot: URL
    public var cacheRoot: URL

    public init(modelsRoot: URL, supportRoot: URL, cacheRoot: URL) {
        self.modelsRoot = modelsRoot
        self.supportRoot = supportRoot
        self.cacheRoot = cacheRoot
    }

    /// The app container's standard locations.
    public static func standard(fileManager: FileManager = .default) -> ModelStoreLocation {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ModelStoreLocation(modelsRoot: documents.appending(path: "Models", directoryHint: .isDirectory),
                                  supportRoot: support.appending(path: "StudioModels", directoryHint: .isDirectory),
                                  cacheRoot: caches.appending(path: "StudioModels", directoryHint: .isDirectory))
    }

    /// Everything under one directory, for tests.
    public static func rooted(at root: URL) -> ModelStoreLocation {
        ModelStoreLocation(modelsRoot: root.appending(path: "Documents/Models", directoryHint: .isDirectory),
                           supportRoot: root.appending(path: "Support", directoryHint: .isDirectory),
                           cacheRoot: root.appending(path: "Caches", directoryHint: .isDirectory))
    }

    public var registryURL: URL { supportRoot.appending(path: "registry.json") }
    public var partialRoot: URL { modelsRoot.appending(path: ".partial", directoryHint: .isDirectory) }
    public var hubCacheRoot: URL { cacheRoot.appending(path: "hf", directoryHint: .isDirectory) }

    public func directory(for id: String) -> URL {
        modelsRoot.appending(path: id, directoryHint: .isDirectory)
    }

    public func partialDirectory(for id: String) -> URL {
        partialRoot.appending(path: id, directoryHint: .isDirectory)
    }

    /// Creates the directories and marks model storage as not backed up.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [modelsRoot, partialRoot, supportRoot, hubCacheRoot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Self.excludeFromBackup(modelsRoot)
        try Self.excludeFromBackup(partialRoot)
    }

    public static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
    }

    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }

    /// Bytes available for user-initiated, important downloads.
    public func availableCapacity() -> Int64? {
        var probe = modelsRoot
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                               .volumeAvailableCapacityKey]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// Allocated bytes under a directory (follows no symlinks).
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        }
        return total
    }
}

/// A file's identity for "verified and unchanged since": size plus mtime.
public struct FileStamp: Codable, Sendable, Hashable {
    public var size: Int64
    public var modified: Double

    public init(size: Int64, modified: Double) {
        self.size = size
        self.modified = modified
    }

    public static func of(_ url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let date = attrs[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, modified: date.timeIntervalSince1970)
    }
}
