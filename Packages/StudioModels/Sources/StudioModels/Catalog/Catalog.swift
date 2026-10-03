// StudioModels: the curated model catalog.
//
// Every entry pins a Hugging Face repository at a commit, and every file by
// size and SHA-256, so a download is verifiable without trusting the network.
// Entries with source `localOnly` are not downloadable. They exist so that
// copies pushed from a Mac (`devicectl device copy to`) are recognized and
// verified.

import Foundation

public enum ModelRole: String, Codable, Sendable, Hashable {
    case main
    case dflash2Draft
    case mtpModule

    public var label: String {
        switch self {
        case .main: "Model"
        case .dflash2Draft: "DFlash2 draft"
        case .mtpModule: "MTP module"
        }
    }
}

/// Weight storage as LSE understands it: MLX group-affine or unquantized.
public struct Quantization: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case affine
        case unquantized
    }

    public var kind: Kind
    public var bits: Int?
    public var groupSize: Int?
    /// For unquantized checkpoints: the stored dtype, e.g. "bfloat16".
    public var dtype: String?

    public init(kind: Kind, bits: Int? = nil, groupSize: Int? = nil, dtype: String? = nil) {
        self.kind = kind
        self.bits = bits
        self.groupSize = groupSize
        self.dtype = dtype
    }

    public static func affine(bits: Int, groupSize: Int) -> Quantization {
        Quantization(kind: .affine, bits: bits, groupSize: groupSize)
    }

    public var label: String {
        switch kind {
        case .affine:
            "Q\(bits ?? 0)" + (groupSize.map { " g\($0)" } ?? "")
        case .unquantized:
            switch dtype?.lowercased() {
            case "bfloat16", "bf16": "BF16"
            case "float16", "f16", "fp16": "F16"
            case "float32", "f32", "fp32": "F32"
            case let other?: other.uppercased()
            case nil: "Unquantized"
            }
        }
    }
}

public struct ModelFile: Codable, Sendable, Hashable {
    /// Path relative to the model directory, with "/" separators.
    public var path: String
    public var size: Int64
    /// The SHA-256 of the content. Hugging Face publishes it for LFS files.
    public var sha256: String?
    /// The git blob id, which is what Hugging Face publishes for small,
    /// non-LFS files. Used when no SHA-256 is known.
    public var gitBlobSHA1: String?
    /// Fetch this file from another repository: an MTP module downloads into
    /// `mtp/` inside its parent model, where LSE looks for it.
    public var sourceRepository: String?
    public var sourceRevision: String?
    /// The path in the source repository, when it differs from `path`.
    public var sourcePath: String?

    public init(path: String, size: Int64, sha256: String? = nil, gitBlobSHA1: String? = nil,
                sourceRepository: String? = nil, sourceRevision: String? = nil, sourcePath: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.gitBlobSHA1 = gitBlobSHA1
        self.sourceRepository = sourceRepository
        self.sourceRevision = sourceRevision
        self.sourcePath = sourcePath
    }
}

/// What LSE adds next to a BF16 DFlash2 source the first time it loads it.
public struct LSEConversion: Codable, Sendable, Hashable {
    /// The cache directory LSE writes inside the source directory.
    public var cacheDirectory: String
    public var outputBytes: Int64
    public var outputSHA256: String
}

public struct CatalogEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable, Hashable {
        case huggingFace
        case localOnly
    }

    public var id: String
    public var name: String
    public var summary: String
    public var role: ModelRole
    public var source: Source
    public var repository: String?
    public var revision: String?
    public var derivedFrom: String?
    /// "qwen3.5", "qwen3.5-moe" or "dflash2", as LSE names them.
    public var architecture: String
    public var quantization: Quantization
    /// `text_config.mtp_num_hidden_layers`. LSE loads the MTP module from a
    /// separate checkpoint; this records only what the config declares.
    public var mtpLayers: Int
    /// Draft ids in order of preference, for main models.
    public var drafts: [String]?
    public var lseConversion: LSEConversion?
    public var files: [ModelFile]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var isDownloadable: Bool { source == .huggingFace && repository != nil && revision != nil }
}

public struct ModelCatalog: Codable, Sendable, Hashable {
    public var version: Int
    public var models: [CatalogEntry]

    public init(version: Int = 1, models: [CatalogEntry]) {
        self.version = version
        self.models = models
    }

    public static func bundled() -> ModelCatalog {
        guard let url = Bundle.module.url(forResource: "Catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data)
        else {
            preconditionFailure("StudioModels: the bundled Catalog.json is missing or invalid")
        }
        return catalog
    }

    public func entry(id: String) -> CatalogEntry? { models.first { $0.id == id } }

    public var mainModels: [CatalogEntry] { models.filter { $0.role == .main } }

    /// Finds the entry a directory of files belongs to by file sizes. Used
    /// for directories copied in under a different name.
    public func entry(matchingSizes sizes: [String: Int64]) -> CatalogEntry? {
        models.first { entry in
            entry.files.allSatisfy { sizes[$0.path] == $0.size }
        }
    }
}
