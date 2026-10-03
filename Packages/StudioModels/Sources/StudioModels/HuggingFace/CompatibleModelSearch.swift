// StudioModels: Hugging Face search narrowed to what LSE loads.
//
// Search tags are not trusted. For each candidate the search fetches, at the
// candidate's pinned commit:
//  - config.json,
//  - the tensor names (model.safetensors.index.json, or the single file's
//    safetensors header via two range requests),
//  - the file tree, for sizes and digests.
// It then applies ModelInspector, i.e. LSE's own rules. The summary's
// model_type only decides which repositories are worth those fetches. All of
// it is cached per commit.
//
// Facets:
//  - MTP: what LSE does. A config declaring text_config.mtp_num_hidden_layers
//    needs a module from an `mtp/` directory in the repo or a `-MTP` sibling
//    repo (`org/Name-MTP-4bit` for `org/Name-4bit`, or `org/Name-MTP`), with
//    matching geometry.
//  - DFlash2: published DFlash2 drafts (architectures DFlash2DraftModel)
//    whose hidden_size and vocab_size match and whose num_target_layers
//    equals the model's layer count, the check LSE applies when it loads.
//    Drafts sharing a base model or the model's family name rank first.
//    Unquantized single-file drafts are fine: LSE converts them to Q8 when it
//    loads them.

import Foundation

public enum MTPAvailability: Sendable, Hashable {
    /// The config declares no MTP layers.
    case none
    /// Declared, and a module LSE accepts was found.
    case available(repository: String, inRepository: Bool)
    /// Declared, but no module was found under the names LSE tries.
    case notFound
    /// Declared with dedicated embeddings, which LSE does not support.
    case unsupported

    public var isAvailable: Bool { if case .available = self { true } else { false } }
}

public struct DraftCandidate: Sendable, Hashable, Identifiable {
    public var id: String { repository }
    public var repository: String
    public var revision: String
    public var traits: ModelTraits
    public var files: [ModelFile]
    public var baseModels: [String]
    public var downloads: Int
    /// The checkpoint is unquantized; LSE converts it to Q8 on first load.
    public var convertsOnLoad: Bool

    public var sizeBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct HubSearchResult: Sendable, Hashable, Identifiable {
    public var id: String { repository }
    public var repository: String
    public var revision: String
    public var downloads: Int
    public var gated: Bool
    public var baseModels: [String]
    public var traits: ModelTraits
    public var files: [ModelFile]
    public var mtp: MTPAvailability
    /// The MTP module's files, under `mtp/`, when one was found in a sibling repo.
    public var mtpFiles: [ModelFile]
    /// Drafts that fit, best match first.
    public var drafts: [DraftCandidate]

    public var isCompatible: Bool { traits.isCompatible }
    public var sizeBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct HubSearchFilters: Sendable, Hashable {
    public var mtp: Bool?
    public var dflash2: Bool?
    public var layout: ModelLayout?
    /// Quantization bits, or 0 for unquantized; nil for any.
    public var bits: Int?
    public var maxBytes: Int64?
    public var includeIncompatible: Bool

    public init(mtp: Bool? = nil, dflash2: Bool? = nil, layout: ModelLayout? = nil, bits: Int? = nil,
                maxBytes: Int64? = nil, includeIncompatible: Bool = false) {
        self.mtp = mtp
        self.dflash2 = dflash2
        self.layout = layout
        self.bits = bits
        self.maxBytes = maxBytes
        self.includeIncompatible = includeIncompatible
    }

    public func matches(_ result: HubSearchResult) -> Bool {
        if !includeIncompatible && !result.isCompatible { return false }
        if let mtp, result.mtp.isAvailable != mtp { return false }
        if let dflash2, result.drafts.isEmpty == dflash2 { return false }
        if let layout, result.traits.layout != layout { return false }
        if let bits {
            let q = result.traits.quantization
            let actual = q?.kind == .affine ? (q?.bits ?? -1) : 0
            if actual != bits { return false }
        }
        if let maxBytes, result.sizeBytes > maxBytes { return false }
        return true
    }
}

public actor CompatibleModelSearch {
    public nonisolated let client: HubClient
    let draftQuery: String
    let concurrency: Int
    static let supportedModelTypes: Set<String> = ["qwen3_5", "qwen3_5_moe", "qwen3_5_text", "qwen3_5_moe_text"]
    private var draftCache: [DraftCandidate]?

    public init(client: HubClient, draftQuery: String = "DFlash2", concurrency: Int = 6) {
        self.client = client
        self.draftQuery = draftQuery
        self.concurrency = concurrency
    }

    /// Searches and inspects. Filtering is left to `HubSearchFilters` so
    /// changing a facet needs no new requests.
    public func search(_ text: String, limit: Int = 30) async throws -> [HubSearchResult] {
        let summaries = try await client.search(text, limit: limit)
        let candidates = summaries.filter(Self.worthInspecting)
        let drafts = (try? await self.drafts()) ?? []
        let results = await mapConcurrently(candidates) { summary in
            try? await self.inspect(summary, drafts: drafts)
        }
        return results.compactMap { $0 }.sorted {
            ($0.isCompatible ? 1 : 0, $0.downloads) > ($1.isCompatible ? 1 : 0, $1.downloads)
        }
    }

    /// Whether a summary could be a main model LSE loads: the right family,
    /// safetensors present, and not an MTP module or a DFlash2 draft.
    static func worthInspecting(_ summary: HubModelSummary) -> Bool {
        guard summary.sha != nil else { return false }
        let architectures = summary.config?.architectures ?? []
        if architectures.contains("DFlash2DraftModel") { return false }
        guard let type = summary.config?.modelType, supportedModelTypes.contains(type) else { return false }
        return summary.fileNames.contains { $0.hasSuffix(".safetensors") }
    }

    public func inspect(_ summary: HubModelSummary, drafts: [DraftCandidate]) async throws -> HubSearchResult {
        let repository = summary.id
        guard let revision = summary.sha else { throw HubError.badResponse("no commit for \(repository)") }
        let tree = try await client.tree(repository, revision: revision).filter(\.isFile)
        let config = try await client.file(repository, revision: revision, path: "config.json")
        let names = try? await tensorNames(repository, revision: revision, tree: tree)
        var traits = ModelInspector.inspect(config: config, weightNames: names)
        if names == nil { traits.problems.append("could not read the tensor names") }
        if !tree.contains(where: { $0.path.hasSuffix(".safetensors") }) {
            traits.problems.append("no safetensors weights (GGUF is not supported)")
        }
        var mtpFiles: [ModelFile] = []
        let mtp = await mtpAvailability(repository, traits: traits, tree: tree, files: &mtpFiles)
        let fitting = drafts.filter { traits.accepts(draft: $0.traits) }
            .sorted { lhs, rhs in
                let a = Self.affinity(summary, lhs), b = Self.affinity(summary, rhs)
                return a != b ? a > b : lhs.downloads > rhs.downloads
            }
        return HubSearchResult(repository: repository, revision: revision, downloads: summary.downloads ?? 0,
                               gated: summary.gated, baseModels: summary.baseModels, traits: traits,
                               files: Self.downloadable(tree), mtp: mtp, mtpFiles: mtpFiles, drafts: fitting)
    }

    private func tensorNames(_ repository: String, revision: String, tree: [HubTreeEntry]) async throws -> [String]? {
        if tree.contains(where: { $0.path == "model.safetensors.index.json" }) {
            let index = try await client.file(repository, revision: revision, path: "model.safetensors.index.json")
            return ModelInspector.tensorNames(index: index)
        }
        guard let single = tree.first(where: { $0.path.hasSuffix(".safetensors") && !$0.path.contains("/") }) else {
            return nil
        }
        let header = try await client.safetensorsHeader(repository, revision: revision, path: single.path)
        return ModelInspector.tensorNames(safetensorsHeader: header)
    }

    // MARK: MTP

    /// LSE's companion names for `--model <repo>` (mtp.cpp mtp_repo_names).
    public static func mtpCompanionNames(_ repository: String) -> [String] {
        var names: [String] = []
        if let dash = repository.lastIndex(of: "-"), let slash = repository.lastIndex(of: "/"), dash > slash {
            names.append(String(repository[..<dash]) + "-MTP" + String(repository[dash...]))
        }
        names.append(repository + "-MTP")
        return names
    }

    private func mtpAvailability(_ repository: String, traits: ModelTraits, tree: [HubTreeEntry],
                                 files: inout [ModelFile]) async -> MTPAvailability {
        guard traits.mtpLayers > 0 else { return .none }
        if traits.mtpDedicatedEmbeddings { return .unsupported }
        if tree.contains(where: { $0.path == "mtp/config.json" }) {
            return .available(repository: repository, inRepository: true)
        }
        for name in Self.mtpCompanionNames(repository) {
            guard let summary = try? await client.model(name), let sha = summary.sha,
                  let config = try? await client.file(name, revision: sha, path: "config.json") else { continue }
            let module = ModelInspector.inspect(config: config)
            guard module.problems.isEmpty, traits.accepts(mtpModule: module),
                  let moduleTree = try? await client.tree(name, revision: sha) else { continue }
            files = Self.downloadable(moduleTree.filter(\.isFile)).map { file in
                var f = file
                f.sourceRepository = name
                f.sourceRevision = sha
                f.sourcePath = file.path
                f.path = "mtp/" + file.path
                return f
            }
            return .available(repository: name, inRepository: false)
        }
        return .notFound
    }

    // MARK: DFlash2

    /// Published DFlash2 drafts LSE can load, inspected at their commits.
    public func drafts() async throws -> [DraftCandidate] {
        if let draftCache { return draftCache }
        let summaries = try await client.search(draftQuery, limit: 100)
            .filter { ($0.config?.architectures ?? []).contains("DFlash2DraftModel") && $0.sha != nil }
        let found = await mapConcurrently(summaries) { summary -> DraftCandidate? in
            guard let sha = summary.sha,
                  let tree = try? await self.client.tree(summary.id, revision: sha).filter(\.isFile),
                  let config = try? await self.client.file(summary.id, revision: sha, path: "config.json") else {
                return nil
            }
            let traits = ModelInspector.inspect(config: config)
            guard traits.isCompatible, traits.kind == .dflash2Draft else { return nil }
            let weights = tree.filter { $0.path.hasSuffix(".safetensors") }
            let unquantized = traits.quantization?.kind != .affine
            // LSE converts only a single-file BF16 source.
            if unquantized && !(weights.count == 1 && weights[0].path == "model.safetensors") { return nil }
            if weights.isEmpty { return nil }
            return DraftCandidate(repository: summary.id, revision: sha, traits: traits,
                                  files: Self.downloadable(tree), baseModels: summary.baseModels,
                                  downloads: summary.downloads ?? 0, convertsOnLoad: unquantized)
        }
        let drafts = found.compactMap { $0 }
        draftCache = drafts
        return drafts
    }

    /// 2 for a shared base model, 1 for a shared family name, else 0.
    static func affinity(_ model: HubModelSummary, _ draft: DraftCandidate) -> Int {
        let mine = Set(model.baseModels.map { $0.lowercased() } + [model.id.lowercased()])
        let theirs = Set(draft.baseModels.map { $0.lowercased() })
        if !mine.isDisjoint(with: theirs) { return 2 }
        let family = familyName(model.id)
        return !family.isEmpty && familyName(draft.repository).hasPrefix(family) ? 1 : 0
    }

    /// "lmstudio-community/Qwen3.8-27B-MLX-4bit" → "qwen3.8-27b".
    static func familyName(_ repository: String) -> String {
        let name = repository.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        let parts = name.split(separator: "-")
        var kept: [Substring] = []
        for part in parts {
            if ["mlx", "dflash2", "mtp", "gguf", "instruct", "bf16", "fp16"].contains(part) { break }
            if part.hasSuffix("bit") || part.first == "q" && part.dropFirst().allSatisfy(\.isNumber) { break }
            kept.append(part)
        }
        return kept.joined(separator: "-")
    }

    // MARK: Files

    /// What to download from a repository: weights, configs and tokenizer at
    /// the top level (what LSE loads from a directory) plus an `mtp/` module;
    /// not READMEs, images, GGUF, PyTorch pickles or variant subfolders.
    public static func downloadable(_ tree: [HubTreeEntry]) -> [ModelFile] {
        let keepSuffixes = [".safetensors", ".json", ".jinja", ".txt", ".model", ".tiktoken"]
        return tree.filter { entry in
            let path = entry.path
            let name = path.split(separator: "/").last.map(String.init) ?? path
            if name.hasPrefix(".") { return false }
            let depth = path.split(separator: "/").count
            if depth > 2 || (depth == 2 && !path.hasPrefix("mtp/")) { return false }
            if name.lowercased().hasPrefix("readme") || name.lowercased().hasPrefix("license") { return false }
            return keepSuffixes.contains { path.hasSuffix($0) }
        }.map(\.modelFile).sorted { $0.path < $1.path }
    }

    /// A download for a search result, with its MTP module under `mtp/` when
    /// one was found in a sibling repository.
    public static func downloadRequest(for result: HubSearchResult, includeMTP: Bool = false) -> DownloadRequest {
        let files = result.files + (includeMTP ? result.mtpFiles : [])
        return DownloadRequest(id: localID(result.repository), name: result.repository, role: .main,
                               origin: .huggingFace, repository: result.repository, revision: result.revision,
                               files: files, traits: result.traits)
    }

    public static func downloadRequest(for draft: DraftCandidate) -> DownloadRequest {
        DownloadRequest(id: localID(draft.repository), name: draft.repository, role: .dflash2Draft,
                        origin: .huggingFace, repository: draft.repository, revision: draft.revision,
                        files: draft.files, traits: draft.traits,
                        extraBytes: draft.convertsOnLoad ? draft.sizeBytes * 53 / 100 : 0)
    }

    /// The directory name for a repository: "org--name".
    public static func localID(_ repository: String) -> String {
        repository.replacingOccurrences(of: "/", with: "--")
    }

    // MARK: Concurrency

    private nonisolated func mapConcurrently<T: Sendable, R: Sendable>(
        _ items: [T], _ body: @escaping @Sendable (T) async -> R
    ) async -> [R] {
        let width = concurrency
        return await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            while next < min(width, items.count) {
                let i = next
                group.addTask { (i, await body(items[i])) }
                next += 1
            }
            while let (i, value) = await group.next() {
                results[i] = value
                if next < items.count {
                    let j = next
                    group.addTask { (j, await body(items[j])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}
