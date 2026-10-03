// StudioModels: the durable index of every installed or partly downloaded model.
//
// The registry is a JSON file in Application Support. It is written
// atomically (temporary file plus rename) after every change, then copied to
// registry.json.bak. If the main file ever fails to decode, the backup is
// used. The unreadable file is kept beside it under a dated name, never
// deleted, so no model is forgotten.
//
// On launch `reconcile` compares the registry with Documents/Models:
//  - a directory the registry does not know (copied in with devicectl, the
//    Files app or Finder) is added;
//  - a model whose directory is gone is marked missing, not dropped;
//  - an installed model with missing or resized files is marked incomplete.
// Downloads in progress keep their state. The downloader resumes them from
// the chunk lists recorded here.

import Foundation

public struct ModelRecord: Codable, Sendable, Hashable, Identifiable {
    public enum State: Codable, Sendable, Hashable {
        case queued
        case downloading
        case paused
        case verifying
        case installed
        /// Some files are absent or the wrong size.
        case incomplete
        /// The directory is gone. The record is kept so nothing silently disappears.
        case missing
        case failed(String)

        public var label: String {
            switch self {
            case .queued: "Queued"
            case .downloading: "Downloading"
            case .paused: "Paused"
            case .verifying: "Verifying"
            case .installed: "Installed"
            case .incomplete: "Incomplete"
            case .missing: "Missing"
            case .failed: "Failed"
            }
        }

        public var isTransferring: Bool { self == .queued || self == .downloading || self == .verifying }
    }

    public enum Origin: String, Codable, Sendable, Hashable {
        /// Downloaded from a catalog entry.
        case catalog
        /// Downloaded from a Hugging Face search result.
        case huggingFace
        /// Found in Documents/Models: copied from a Mac or imported in Files.
        case preplaced
    }

    public enum Verification: String, Codable, Sendable, Hashable {
        case unverified
        case verified
        case mismatch
        case missing
    }

    public struct File: Codable, Sendable, Hashable {
        public var path: String
        public var size: Int64
        public var sha256: String?
        public var gitBlobSHA1: String?
        public var sourceRepository: String?
        public var sourceRevision: String?
        public var sourcePath: String?
        public var verification: Verification
        /// Size and mtime when last verified. A changed stamp means re-verify.
        public var stamp: FileStamp?
        /// Download bookkeeping: the range-chunk size and the chunks already
        /// written to the part file.
        public var chunkSize: Int64?
        public var completedChunks: [Int]

        public init(_ file: ModelFile, verification: Verification = .unverified) {
            path = file.path
            size = file.size
            sha256 = file.sha256
            gitBlobSHA1 = file.gitBlobSHA1
            sourceRepository = file.sourceRepository
            sourceRevision = file.sourceRevision
            sourcePath = file.sourcePath
            self.verification = verification
            completedChunks = []
        }

        public var spec: ModelFile {
            ModelFile(path: path, size: size, sha256: sha256, gitBlobSHA1: gitBlobSHA1,
                      sourceRepository: sourceRepository, sourceRevision: sourceRevision, sourcePath: sourcePath)
        }
    }

    public var id: String
    public var name: String
    public var role: ModelRole
    public var origin: Origin
    public var catalogID: String?
    public var repository: String?
    public var revision: String?
    /// The directory name under Documents/Models.
    public var directoryName: String
    public var files: [File]
    public var traits: ModelTraits?
    /// For main models: the DFlash2 draft LSE should run with.
    public var linkedDraftID: String?
    /// For main models: how LSE loads it, when the user changed the defaults.
    /// Absent in registries written before load settings existed.
    public var loadSettings: ModelLoadSettings?
    public var state: State
    public var addedAt: Date
    public var lastUsedAt: Date?
    public var verifiedAt: Date?

    public init(id: String, name: String, role: ModelRole, origin: Origin, catalogID: String? = nil,
                repository: String? = nil, revision: String? = nil, directoryName: String? = nil,
                files: [File], traits: ModelTraits? = nil, linkedDraftID: String? = nil,
                state: State, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.role = role
        self.origin = origin
        self.catalogID = catalogID
        self.repository = repository
        self.revision = revision
        self.directoryName = directoryName ?? id
        self.files = files
        self.traits = traits
        self.linkedDraftID = linkedDraftID
        self.state = state
        self.addedAt = addedAt
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public var isVerified: Bool { !files.isEmpty && files.allSatisfy { $0.verification == .verified } }

    public var hasMismatch: Bool { files.contains { $0.verification == .mismatch } }

    public var architectureLabel: String {
        traits?.architectureLabel ?? (role == .dflash2Draft ? "dflash2" : "unknown")
    }
}

public struct RegistrySnapshot: Codable, Sendable {
    public var version: Int
    public var models: [ModelRecord]
}

public struct ReconcileReport: Sendable, Hashable {
    public var added: [String] = []
    public var missing: [String] = []
    public var restored: [String] = []
    public var incomplete: [String] = []
}

public enum RegistryError: Error, LocalizedError {
    case unknownModel(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): "No model \(id) in the registry."
        }
    }
}

public actor ModelRegistry {
    public nonisolated let location: ModelStoreLocation
    private var models: [ModelRecord] = []
    private var observers: [UUID: AsyncStream<[ModelRecord]>.Continuation] = [:]
    static let version = 1
    /// Files LSE or this package add to a model directory that are not model files.
    static let bookkeepingNames: Set<String> = ["hf-origin.json", "lse-q8g64", "lse-q8g64.source-stat"]

    public init(location: ModelStoreLocation) {
        self.location = location
        models = Self.load(location)
    }

    // MARK: Reading

    public func all() -> [ModelRecord] { models }

    public func record(_ id: String) -> ModelRecord? { models.first { $0.id == id } }

    /// Snapshots after every change, starting with the current one.
    public func updates() -> AsyncStream<[ModelRecord]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [ModelRecord].self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        observers[token] = continuation
        continuation.yield(models)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token) }
        }
        return stream
    }

    private func removeObserver(_ token: UUID) { observers[token] = nil }

    // MARK: Writing

    public func upsert(_ record: ModelRecord) throws {
        if let i = models.firstIndex(where: { $0.id == record.id }) {
            models[i] = record
        } else {
            models.append(record)
        }
        try save()
    }

    @discardableResult
    public func update(_ id: String, _ change: @Sendable (inout ModelRecord) -> Void) throws -> ModelRecord {
        guard let i = models.firstIndex(where: { $0.id == id }) else { throw RegistryError.unknownModel(id) }
        change(&models[i])
        try save()
        return models[i]
    }

    public func remove(_ id: String) throws {
        models.removeAll { $0.id == id }
        for i in models.indices where models[i].linkedDraftID == id { models[i].linkedDraftID = nil }
        for i in models.indices where models[i].loadSettings?.draftID == id { models[i].loadSettings?.draftID = nil }
        try save()
    }

    /// Pairs a main model with a DFlash2 draft (nil: none). Stored load
    /// settings follow: they switch to the draft, or turn DFlash2 off.
    public func link(main: String, draft: String?) throws {
        try update(main) { record in
            record.linkedDraftID = draft
            if record.loadSettings != nil {
                record.loadSettings?.draftID = draft
                record.loadSettings?.dflash2Enabled = draft != nil
            }
        }
    }

    // MARK: Load settings

    /// The model's stored load settings, or the defaults for it: the
    /// standard preset with its linked draft, clamped to its config.
    public func loadSettings(for id: String, preset: LSELaunchPreset = .standard) -> ModelLoadSettings {
        guard let record = record(id) else { return ModelLoadSettings(preset: preset) }
        let dir = location.directory(for: record.directoryName)
        let summary = ModelConfigSummary.read(directory: dir)
        if let stored = record.loadSettings { return stored.normalized(for: summary) }
        let draft = record.linkedDraftID.flatMap { id in models.first { $0.id == id && $0.state == .installed } }
        return .defaults(preset: preset, linkedDraftID: draft?.id, summary: summary,
                         hasMTPModule: ConfigMemoryEstimator.isDirectory(dir.appending(path: "mtp")))
    }

    /// Stores a model's load settings (nil: back to the defaults). A chosen
    /// DFlash2 draft becomes the model's linked draft as well.
    public func setLoadSettings(_ settings: ModelLoadSettings?, for id: String) throws {
        try update(id) { record in
            record.loadSettings = settings
            if let settings, settings.dflash2Enabled, let draft = settings.draftID { record.linkedDraftID = draft }
        }
    }

    public func markUsed(_ id: String, at date: Date = Date()) throws {
        try update(id) { $0.lastUsedAt = date }
    }

    // MARK: Persistence

    private func save() throws {
        try FileManager.default.createDirectory(at: location.supportRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(RegistrySnapshot(version: Self.version, models: models))
        try data.write(to: location.registryURL, options: .atomic)
        try? data.write(to: Self.backupURL(location), options: .atomic)
        for continuation in observers.values { continuation.yield(models) }
    }

    static func backupURL(_ location: ModelStoreLocation) -> URL {
        location.registryURL.appendingPathExtension("bak")
    }

    static func load(_ location: ModelStoreLocation) -> [ModelRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fm = FileManager.default
        guard fm.fileExists(atPath: location.registryURL.path) else {
            if let data = try? Data(contentsOf: backupURL(location)),
               let snapshot = try? decoder.decode(RegistrySnapshot.self, from: data) {
                return snapshot.models
            }
            return []
        }
        if let data = try? Data(contentsOf: location.registryURL),
           let snapshot = try? decoder.decode(RegistrySnapshot.self, from: data) {
            return snapshot.models
        }
        // Keep the unreadable file for inspection; never overwrite it.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(at: location.registryURL,
                         to: location.supportRoot.appending(path: "registry.unreadable-\(stamp).json"))
        if let data = try? Data(contentsOf: backupURL(location)),
           let snapshot = try? decoder.decode(RegistrySnapshot.self, from: data) {
            return snapshot.models
        }
        return []
    }

    // MARK: Reconciling with Documents/Models

    public func reconcile(catalog: ModelCatalog) throws -> ReconcileReport {
        var report = ReconcileReport()
        let fm = FileManager.default
        try? fm.createDirectory(at: location.modelsRoot, withIntermediateDirectories: true)
        let present = ((try? fm.contentsOfDirectory(at: location.modelsRoot,
                                                     includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let presentNames = Set(present.map(\.lastPathComponent))

        for i in models.indices {
            let dir = location.directory(for: models[i].directoryName)
            let exists = presentNames.contains(models[i].directoryName)
            switch models[i].state {
            case .installed, .incomplete, .missing:
                guard exists else {
                    if models[i].state != .missing { report.missing.append(models[i].id) }
                    models[i].state = .missing
                    continue
                }
                let wasMissing = models[i].state == .missing
                let complete = Self.refreshFiles(&models[i], in: dir)
                models[i].state = complete ? .installed : .incomplete
                if !complete { report.incomplete.append(models[i].id) }
                if wasMissing { report.restored.append(models[i].id) }
                try? ModelStoreLocation.excludeFromBackup(dir)
            case .queued, .downloading, .paused, .verifying, .failed:
                break
            }
        }

        let known = Set(models.map(\.directoryName))
        for dir in present where !known.contains(dir.lastPathComponent) {
            let record = Self.discover(dir, catalog: catalog)
            models.append(record)
            report.added.append(record.id)
            if record.state == .incomplete { report.incomplete.append(record.id) }
            try? ModelStoreLocation.excludeFromBackup(dir)
        }
        autoLink(catalog: catalog)
        try save()
        return report
    }

    /// Updates presence and size of each file; returns whether all are there.
    static func refreshFiles(_ record: inout ModelRecord, in dir: URL) -> Bool {
        var complete = true
        for j in record.files.indices {
            let url = dir.appending(path: record.files[j].path)
            guard let stamp = FileStamp.of(url), stamp.size == record.files[j].size else {
                record.files[j].verification = .missing
                complete = false
                continue
            }
            if record.files[j].verification == .missing
                || (record.files[j].verification == .verified && record.files[j].stamp != stamp) {
                record.files[j].verification = .unverified
            }
        }
        return complete
    }

    /// A record for a directory found on disk.
    static func discover(_ dir: URL, catalog: ModelCatalog) -> ModelRecord {
        let name = dir.lastPathComponent
        let origin = HubOrigin.read(from: dir)
        let found = listFiles(dir)
        let sizes = Dictionary(found.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        let entry = catalog.entry(id: name)
            ?? origin.flatMap { o in catalog.models.first { $0.repository == o.repository && $0.revision == o.revision } }
            ?? catalog.entry(matchingSizes: sizes)
        let traits = ModelInspector.inspect(directory: dir)
        if let entry {
            var record = ModelRecord(id: name, name: entry.name, role: entry.role, origin: .preplaced,
                                     catalogID: entry.id, repository: entry.repository, revision: entry.revision,
                                     directoryName: name, files: entry.files.map { ModelRecord.File($0) },
                                     traits: traits, state: .installed)
            record.state = refreshFiles(&record, in: dir) ? .installed : .incomplete
            return record
        }
        let role: ModelRole = switch traits?.kind {
        case .dflash2Draft: .dflash2Draft
        case .mtpModule: .mtpModule
        default: .main
        }
        return ModelRecord(id: name, name: origin?.repository ?? name, role: role, origin: .preplaced,
                           repository: origin?.repository, revision: origin?.revision, directoryName: name,
                           files: found.map { ModelRecord.File($0) }, traits: traits, state: .installed)
    }

    /// Model files in a directory, skipping hidden files and bookkeeping.
    static func listFiles(_ dir: URL) -> [ModelFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let base = dir.standardizedFileURL.path + "/"
        var files: [ModelFile] = []
        for case let url as URL in walker {
            if bookkeepingNames.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            files.append(ModelFile(path: path, size: Int64(v.fileSize ?? 0)))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Links main models without a draft to an installed draft that fits:
    /// the catalog's preference first, then any draft LSE's geometry check accepts.
    func autoLink(catalog: ModelCatalog) {
        let drafts = models.filter { $0.role == .dflash2Draft && $0.state == .installed }
        for i in models.indices where models[i].role == .main && models[i].linkedDraftID == nil {
            if let preferred = models[i].catalogID.flatMap({ catalog.entry(id: $0)?.drafts }) {
                if let match = preferred.lazy.compactMap({ id in drafts.first { $0.catalogID == id || $0.id == id } }).first {
                    models[i].linkedDraftID = match.id
                    continue
                }
            }
            if let traits = models[i].traits,
               let match = drafts.first(where: { $0.traits.map(traits.accepts(draft:)) ?? false }) {
                models[i].linkedDraftID = match.id
            }
        }
    }
}

/// `hf-origin.json`: the repository and revision a directory was downloaded
/// from. LSE reads the same file to record a DFlash2 conversion's source.
public struct HubOrigin: Codable, Sendable, Hashable {
    public var repository: String
    public var revision: String

    public init(repository: String, revision: String) {
        self.repository = repository
        self.revision = revision
    }

    public static let fileName = "hf-origin.json"

    public static func read(from dir: URL) -> HubOrigin? {
        guard let data = try? Data(contentsOf: dir.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(HubOrigin.self, from: data)
    }

    public func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: dir.appending(path: Self.fileName), options: .atomic)
    }
}
