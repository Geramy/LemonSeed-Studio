// StudioModels: the one object an app holds.
//
//   let library = ModelLibrary.standard()     // at launch, before the first scene
//   await library.start()                     // reconcile Documents/Models, resume downloads
//   library.launchArguments(for: "qwen38-27b-q4")
//
// It owns the registry, the downloader and the Hugging Face client, and
// mirrors their state on the main actor for SwiftUI.

import Foundation
import Observation

@MainActor
@Observable
public final class ModelLibrary {
    public let catalog: ModelCatalog
    public let location: ModelStoreLocation
    public let registry: ModelRegistry
    public let downloader: ModelDownloader
    public let hub: HubClient
    public let search: CompatibleModelSearch
    public let tokenStore: HubTokenStore
    public var preset: LSELaunchPreset

    public private(set) var records: [ModelRecord] = []
    public private(set) var progress: [String: DownloadProgress] = [:]
    public private(set) var verifying: [String: VerificationProgress] = [:]
    public private(set) var availableBytes: Int64?
    public private(set) var lastReconcile: ReconcileReport?
    public var lastError: String?

    @ObservationIgnored private var verifyTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var started = false

    /// The background session identifier. It must not change between releases,
    /// or downloads in flight are orphaned.
    public static let backgroundSessionIdentifier = "com.geramyloveless.LemonSeedStudio.models"

    public init(catalog: ModelCatalog = .bundled(), location: ModelStoreLocation = .standard(),
                endpoint: HubEndpoint = .huggingFace,
                downloads: DownloaderConfiguration = .background(identifier: ModelLibrary.backgroundSessionIdentifier),
                transport: any HTTPTransport = URLSessionTransport(), tokenStore: HubTokenStore = HubTokenStore(),
                preset: LSELaunchPreset = .standard) {
        self.catalog = catalog
        self.location = location
        self.tokenStore = tokenStore
        self.preset = preset
        try? location.prepare()
        registry = ModelRegistry(location: location)
        let token: @Sendable () -> String? = { tokenStore.token() }
        downloader = ModelDownloader(registry: registry, endpoint: endpoint, configuration: downloads, token: token)
        hub = HubClient(endpoint: endpoint, transport: transport, cacheDirectory: location.hubCacheRoot, token: token)
        search = CompatibleModelSearch(client: hub)
    }

    /// The app-wide library with the background session.
    public static func standard() -> ModelLibrary { ModelLibrary() }

    /// Reconciles with Documents/Models, resumes interrupted downloads and
    /// starts mirroring state. Call once at launch; later calls only refresh.
    public func start() async {
        if !started {
            started = true
            Task { [weak self, registry] in
                for await snapshot in await registry.updates() { self?.records = snapshot }
            }
            Task { [weak self, downloader] in
                for await event in await downloader.events() { self?.handle(event) }
            }
        }
        await refresh()
        await downloader.restore()
        for record in records where record.state == .downloading {
            if let p = await downloader.progress(of: record.id) { progress[record.id] = p }
        }
    }

    /// Re-scans Documents/Models (models copied in while the app ran).
    public func refresh() async {
        do {
            lastReconcile = try await registry.reconcile(catalog: catalog)
        } catch {
            lastError = error.localizedDescription
        }
        records = await registry.all()
        availableBytes = location.availableCapacity()
    }

    /// Forward from the app delegate's
    /// application(_:handleEventsForBackgroundURLSession:completionHandler:).
    public func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.backgroundSessionIdentifier else { return completion() }
        // UIKit's handler is not Sendable; the session delegate calls it on the main queue.
        nonisolated(unsafe) let completion = completion
        downloader.handleBackgroundEvents { completion() }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let p):
            progress[p.id] = p
        case .stateChanged(let id, let state):
            if state != .downloading { progress[id] = state == .paused ? progress[id] : nil }
        case .installed(let id):
            progress[id] = nil
            Task { await refresh() }
        case let .failed(id, message):
            lastError = "\(record(id)?.name ?? id): \(message)"
        }
        availableBytes = location.availableCapacity()
    }

    // MARK: Queries

    public func record(_ id: String) -> ModelRecord? { records.first { $0.id == id } }

    public func record(forCatalog id: String) -> ModelRecord? {
        records.first { $0.catalogID == id || $0.id == id }
    }

    public var installedModels: [ModelRecord] { records.filter { $0.role == .main } }
    public var installedDrafts: [ModelRecord] { records.filter { $0.role == .dflash2Draft } }

    public func directory(of record: ModelRecord) -> URL { location.directory(for: record.directoryName) }

    /// Bytes the installed and partial models occupy, including LSE's caches.
    public func usedBytes() -> Int64 {
        ModelStoreLocation.allocatedSize(of: location.modelsRoot)
    }

    /// Whether LSE has already converted a BF16 DFlash2 source in place.
    public func hasLSEConversion(_ record: ModelRecord) -> Bool {
        let cache = record.catalogID.flatMap { catalog.entry(id: $0)?.lseConversion?.cacheDirectory } ?? "lse-q8g64"
        return FileManager.default.fileExists(atPath: directory(of: record).appending(path: cache)
            .appending(path: "model.safetensors").path)
    }

    /// The draft a main model runs with: its link, if installed.
    public func linkedDraft(of record: ModelRecord) -> ModelRecord? {
        guard let id = record.linkedDraftID, let draft = self.record(id), draft.state == .installed else { return nil }
        return draft
    }

    /// LSE's arguments for an installed main model: its load settings (stored,
    /// or the preset's defaults) and its draft.
    public func launchArguments(for id: String) -> [String]? {
        launchConfiguration(for: id)?.arguments
    }

    /// The resolved launch for an installed main model: the lse_config values
    /// its load settings give, with the draft and MTP module found on disk.
    public func launchConfiguration(for id: String) -> LSELaunchConfiguration? {
        guard let record = record(id), record.state == .installed, record.role == .main else { return nil }
        let settings = loadSettings(for: id)
        return preset.configuration(model: directory(of: record), settings: settings,
                                    dflash2Draft: draft(of: record, settings: settings).map(directory(of:)),
                                    mtpModule: mtpModuleDirectory(of: record))
    }

    // MARK: Load settings

    /// The model's config.json geometry: max context, MTP, layer split.
    public func configSummary(for id: String) -> ModelConfigSummary? {
        guard let record = record(id) else { return nil }
        return ModelConfigSummary.read(directory: directory(of: record))
    }

    /// The model's stored load settings, or its defaults: the preset, with
    /// DFlash2 when a draft is linked (otherwise MTP when it has a module),
    /// clamped to its config.
    public func loadSettings(for id: String) -> ModelLoadSettings {
        guard let record = record(id) else { return ModelLoadSettings(preset: preset) }
        let summary = ModelConfigSummary.read(directory: directory(of: record))
        if let stored = record.loadSettings { return stored.normalized(for: summary) }
        return defaultLoadSettings(for: record, summary: summary)
    }

    /// The defaults for a model, ignoring anything stored.
    public func defaultLoadSettings(for id: String) -> ModelLoadSettings {
        guard let record = record(id) else { return ModelLoadSettings(preset: preset) }
        return defaultLoadSettings(for: record, summary: ModelConfigSummary.read(directory: directory(of: record)))
    }

    private func defaultLoadSettings(for record: ModelRecord, summary: ModelConfigSummary?) -> ModelLoadSettings {
        .defaults(preset: preset, linkedDraftID: linkedDraft(of: record)?.id, summary: summary,
                  hasMTPModule: mtpModuleDirectory(of: record) != nil)
    }

    /// Persists a model's load settings (nil: back to the defaults), clamped
    /// to its config. Returns false, with `lastError` set, when the registry
    /// could not be written.
    @discardableResult
    public func setLoadSettings(_ settings: ModelLoadSettings?, for id: String) async -> Bool {
        let normalized = settings?.normalized(for: configSummary(for: id))
        do {
            try await registry.setLoadSettings(normalized, for: id)
        } catch {
            lastError = error.localizedDescription
            return false
        }
        records = await registry.all()
        return true
    }

    /// Installed DFlash2 drafts that pass LSE's geometry check for the model
    /// (a draft or model without readable traits is offered too).
    public func compatibleDrafts(for id: String) -> [ModelRecord] {
        let mine = record(id)?.traits
        return installedDrafts.filter { draft in
            guard draft.state == .installed else { return false }
            guard let mine, let theirs = draft.traits else { return true }
            return mine.accepts(draft: theirs)
        }
    }

    /// The draft a launch with these settings runs: the chosen one, else the
    /// linked one, when installed and DFlash2 is on.
    public func draft(of record: ModelRecord, settings: ModelLoadSettings) -> ModelRecord? {
        guard settings.dflash2Enabled else { return nil }
        if let id = settings.draftID, let draft = self.record(id), draft.state == .installed,
           draft.role == .dflash2Draft {
            return draft
        }
        return linkedDraft(of: record)
    }

    /// The MTP module LSE finds beside the model (`mtp/`), when installed.
    public func mtpModuleDirectory(of record: ModelRecord) -> URL? {
        let dir = directory(of: record).appending(path: "mtp")
        return ConfigMemoryEstimator.isDirectory(dir) ? dir : nil
    }

    // MARK: Commands

    public func download(catalogID: String, withDraft: Bool = true) async {
        guard let entry = catalog.entry(id: catalogID) else { return }
        guard let request = DownloadRequest(catalog: entry) else {
            lastError = DownloadError.notDownloadable(entry.name).localizedDescription
            return
        }
        await perform { try await self.downloader.start(request) }
        if withDraft, entry.role == .main, linkedDraftCandidate(for: entry) == nil,
           let draftID = entry.drafts?.first(where: { catalog.entry(id: $0)?.isDownloadable == true }),
           let draftEntry = catalog.entry(id: draftID), let draftRequest = DownloadRequest(catalog: draftEntry),
           record(forCatalog: draftID) == nil {
            await perform { try await self.downloader.start(draftRequest) }
        }
        // Link the first preferred draft that is installed or on its way.
        let known = await registry.all()
        if let draft = entry.drafts?.lazy.compactMap({ id in known.first { $0.catalogID == id || $0.id == id } }).first {
            try? await registry.link(main: entry.id, draft: draft.id)
        }
    }

    /// An installed or downloading draft from the entry's preference list.
    private func linkedDraftCandidate(for entry: CatalogEntry) -> ModelRecord? {
        entry.drafts?.lazy.compactMap { self.record(forCatalog: $0) }.first
    }

    public func download(_ result: HubSearchResult, draft: DraftCandidate? = nil, includeMTP: Bool = false) async {
        let request = CompatibleModelSearch.downloadRequest(for: result, includeMTP: includeMTP)
        await perform { try await self.downloader.start(request) }
        if let draft {
            let draftRequest = CompatibleModelSearch.downloadRequest(for: draft)
            if record(draftRequest.id) == nil {
                await perform { try await self.downloader.start(draftRequest) }
            }
            try? await registry.link(main: request.id, draft: draftRequest.id)
        }
    }

    public func pause(_ id: String) async { await downloader.pause(id) }

    public func resume(_ id: String) async { await perform { try await self.downloader.resume(id) } }

    public func cancel(_ id: String) async {
        await downloader.cancel(id)
        progress[id] = nil
    }

    /// Removes a model's files and its registry entry.
    public func delete(_ id: String) async {
        guard let record = record(id) else { return }
        verifyTasks[id]?.cancel()
        if record.state.isTransferring || record.state == .paused { await downloader.cancel(id) }
        let fm = FileManager.default
        try? fm.removeItem(at: directory(of: record))
        try? fm.removeItem(at: location.partialDirectory(for: id))
        await perform { try await self.registry.remove(id) }
        progress[id] = nil
        availableBytes = location.availableCapacity()
    }

    public func link(main: String, draft: String?) async {
        await perform { try await self.registry.link(main: main, draft: draft) }
    }

    public func markUsed(_ id: String) async {
        try? await registry.markUsed(id)
    }

    /// Hashes every file and compares it with its pinned digest.
    public func verify(_ id: String, force: Bool = true) {
        guard let record = record(id), verifyTasks[id] == nil else { return }
        let dir = directory(of: record)
        verifyTasks[id] = Task { [weak self, registry] in
            let files = await ModelVerifier.verify(files: record.files, in: dir, force: force) { p in
                Task { @MainActor in self?.verifying[id] = p }
            }
            let now = Date()
            _ = try? await registry.update(id) { r in
                r.files = files
                r.verifiedAt = now
                if files.contains(where: { $0.verification == .missing }) {
                    r.state = .incomplete
                } else if let bad = files.first(where: { $0.verification == .mismatch }) {
                    r.state = .failed("\(bad.path) does not match its checksum")
                } else if r.state == .incomplete || r.state == .missing {
                    r.state = .installed
                }
            }
            self?.verifying[id] = nil
            self?.verifyTasks[id] = nil
        }
    }

    /// Re-downloads a model's missing or damaged files.
    public func repair(_ id: String) async {
        guard let record = record(id), let repository = record.repository, let revision = record.revision else {
            lastError = "This model has no recorded source to repair from. Copy it again from the Mac."
            return
        }
        if case .failed = record.state {
            _ = try? await registry.update(id) { $0.state = .incomplete }
        }
        let request = DownloadRequest(id: id, name: record.name, role: record.role, origin: record.origin,
                                      catalogID: record.catalogID, repository: repository, revision: revision,
                                      files: record.files.map(\.spec), traits: record.traits)
        await perform { try await self.downloader.start(request) }
    }

    public var hubToken: String? {
        get { tokenStore.token() }
        set {
            do { try tokenStore.setToken(newValue) } catch { lastError = "Could not save the token: \(error.localizedDescription)" }
        }
    }

    private func perform(_ body: @escaping () async throws -> Void) async {
        do {
            try await body()
        } catch {
            lastError = error.localizedDescription
        }
        availableBytes = location.availableCapacity()
    }
}
