// StudioModels: how much GPU memory a model needs with given load settings.
//
// The app supplies an estimator through ModelMemoryEstimating. LSE will offer
// its own figures (lse_model_info and an estimate call); until then
// ConfigMemoryEstimator is the FALLBACK: it works the numbers out from
// config.json and the weight files on disk, following how LSE allocates, and
// marks its result approximate.

import Foundation

public struct ModelMemoryEstimate: Sendable, Hashable {
    /// The target model's weights as loaded (the vision tower is never loaded).
    public var weightsBytes: UInt64
    /// The target's K/V cache at full kv_len, plus the fixed linear-attention state.
    public var kvCacheBytes: UInt64
    /// The speculative drafter: DFlash2 draft or MTP module weights, plus its cache and state.
    public var draftBytes: UInt64
    /// Activations, logits, RoPE tables, allocator rounding and runtime reserve.
    public var workspaceBytes: UInt64
    public var totalBytes: UInt64
    public var isApproximate: Bool
    /// Where the figures come from, for display.
    public var source: String

    /// `totalBytes` defaults to the sum of the parts.
    public init(weightsBytes: UInt64, kvCacheBytes: UInt64, draftBytes: UInt64, workspaceBytes: UInt64,
                totalBytes: UInt64? = nil, isApproximate: Bool, source: String) {
        self.weightsBytes = weightsBytes
        self.kvCacheBytes = kvCacheBytes
        self.draftBytes = draftBytes
        self.workspaceBytes = workspaceBytes
        self.totalBytes = totalBytes ?? (weightsBytes + kvCacheBytes + draftBytes + workspaceBytes)
        self.isApproximate = isApproximate
        self.source = source
    }

    /// How the estimate compares with the GPU's memory.
    public func fit(vramTotalBytes: UInt64?) -> MemoryFit {
        guard let vram = vramTotalBytes, vram > 0 else { return .unknown }
        let share = Double(totalBytes) / Double(vram)
        if share > MemoryFit.wontFitShare { return .wontFit }
        if share > MemoryFit.tightShare { return .tight }
        return .fits
    }
}

public enum MemoryFit: String, Sendable, Hashable {
    /// Up to 85% of VRAM.
    case fits
    /// 85% to 95%: it should load, with little room for anything else.
    case tight
    /// Over 95%: loading is likely to fail.
    case wontFit
    /// No VRAM figure to compare with.
    case unknown

    public static let tightShare = 0.85
    public static let wontFitShare = 0.95
}

/// Anything that can size a load: the config fallback below now, LSE later.
public protocol ModelMemoryEstimating: Sendable {
    /// `draftDirectory` is the DFlash2 draft to run, when `settings` enable it.
    func estimate(modelDirectory: URL, draftDirectory: URL?, settings: ModelLoadSettings) throws -> ModelMemoryEstimate
}

public enum ModelMemoryEstimateError: Error, LocalizedError {
    case unreadableConfig(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadableConfig(let dir): "No readable config.json in \(dir.lastPathComponent)."
        }
    }
}

/// FALLBACK estimator: an approximation from config.json and the safetensors
/// sizes on disk, used until LSE reports its own figures (lse_model_info).
/// It follows LSE's allocations as of LemonSeed-Engine 0.4:
///
///  - Weights: the tensors in the *.safetensors files (header byte ranges, so
///    the vision tower LSE skips is left out; the file size when a header is
///    unreadable). mtp/ is counted only when MTP runs, lse-q8g64/ only as the
///    DFlash2 draft's Q8 conversion.
///  - KV: per full-attention layer, K and V of num_key_value_heads × kv_len
///    head vectors (kv::storage_width: fp8/bf8 store head_dim bytes plus a
///    4-byte scale). The paged cache grows on demand, so this is its size
///    once the context is full, the figure that decides whether a long
///    conversation fits. One sequence is assumed.
///  - Linear-attention state: per Gated DeltaNet layer, an FP32 recurrent
///    state of value_heads × value_dim × value_dim and an FP32 convolution
///    window of (kernel - 1) × conv_dim. Fixed, whatever kv_len.
///  - DFlash2 draft: Q8 weights (a BF16 source is converted to Q8 group-64 on
///    first load, about 0.53 of its size, unless lse-q8g64/ already holds the
///    result), an FP32 sliding-window cache of (window - 1 + block) tokens per
///    layer, its RoPE table up to kv_len, and the target features one prefill
///    pass hands it (ubatch × hidden × target layers, FP32).
///  - MTP: the mtp/ module's weights and a K/V cache of kv_len per MTP layer.
///  - Workspace: FP32 activations for one prefill pass of ubatch tokens, the
///    logits of a verification step, RoPE tables, the K/V arenas rounded up
///    to 256 MiB, and a fixed runtime reserve for kernels and staging.
public struct ConfigMemoryEstimator: ModelMemoryEstimating {
    public static let source = "config.json estimate (fallback until lse_model_info)"
    /// kv::kArenaBytes: the K/V cache is carved from arenas of this size.
    static let kvArenaBytes: UInt64 = 256 << 20
    /// Kernels, code objects, staging buffers: not derivable from the config.
    static let runtimeReserveBytes: UInt64 = 256 << 20
    /// MLX affine Q8 with group 64 and BF16 scale and bias: 1 + 4/64 bytes per
    /// weight against BF16's 2.
    static let q8OverBF16 = 0.53125
    static let conversionDirectory = "lse-q8g64"

    public init() {}

    public func estimate(modelDirectory: URL, draftDirectory: URL?,
                         settings: ModelLoadSettings) throws -> ModelMemoryEstimate {
        guard let model = ModelConfigSummary.read(directory: modelDirectory) else {
            throw ModelMemoryEstimateError.unreadableConfig(modelDirectory)
        }
        let s = settings.clamped(maxContext: model.maxContext)
        let kvLength = UInt64(s.kvLength)
        let ubatch = UInt64(s.ubatchSize)

        let weights = Self.weightBytes(in: modelDirectory, skipping: ["mtp", Self.conversionDirectory])
        let attentionKV = Self.kvBytes(layers: model.fullAttentionLayers, kvHeads: model.numKeyValueHeads,
                                       headDim: model.headDim, tokens: kvLength, dtype: s.kvCacheDType)
        let linearState = Self.linearStateBytes(model)

        var draft: UInt64 = 0
        var draftKV: UInt64 = 0
        var verifyRows: UInt64 = 1
        let draftSummary = draftDirectory.flatMap(ModelConfigSummary.read(directory:))
        let mtpDirectory = modelDirectory.appending(path: "mtp")
        if s.dflash2Enabled, let draftDirectory, let d = draftSummary {
            draft += Self.draftWeightBytes(draftDirectory)
            let window = UInt64(max(0, (d.slidingWindow ?? 2048) - 1 + (d.draftBlockSize ?? 8)))
            draft += 2 * UInt64(d.numLayers * d.numKeyValueHeads * d.headDim) * window * 4
            // RoPE cos and sin, FP32, up to the target's KV capacity.
            draft += 2 * (kvLength + UInt64(d.draftBlockSize ?? 8)) * UInt64(d.headDim) * 4
            draft += ubatch * UInt64(d.hiddenSize * (d.draftTargetLayers ?? 1)) * 4
            verifyRows = UInt64(d.draftBlockSize ?? 8)
        } else if s.mtpEnabled, model.hasMTP, Self.isDirectory(mtpDirectory) {
            draft += Self.weightBytes(in: mtpDirectory, skipping: [])
            draftKV = Self.kvBytes(layers: model.mtpLayers, kvHeads: model.numKeyValueHeads,
                                   headDim: model.headDim, tokens: kvLength, dtype: s.kvCacheDType)
            draft += draftKV
            verifyRows = UInt64(s.mtpDepth + 1)
        }

        // One prefill pass: residual, norms and attention or DeltaNet
        // projections, and the MLP's gate, up and product, all FP32.
        let attentionWidth = 2 * model.numAttentionHeads * model.headDim + 2 * model.numKeyValueHeads * model.headDim
        let linearWidth = 2 * model.linearKeyHeads * model.linearKeyHeadDim
            + 2 * model.linearValueHeads * model.linearValueHeadDim
        let perToken = UInt64(6 * model.hiddenSize + 3 * model.intermediateSize + 2 * max(attentionWidth, linearWidth)) * 4
        var workspace = ubatch * perToken
        // Logits for a verification step, and the sampler's copy.
        workspace += 2 * verifyRows * UInt64(model.vocabSize) * 4
        // RoPE cos and sin tables, FP32, kv_len × rope_dim each.
        workspace += 2 * kvLength * UInt64(model.ropeDim) * 4
        // The paged K/V arenas are whole 256 MiB blocks.
        let kvTotal = attentionKV + draftKV
        workspace += (kvTotal + Self.kvArenaBytes - 1) / Self.kvArenaBytes * Self.kvArenaBytes - kvTotal
        workspace += Self.runtimeReserveBytes

        return ModelMemoryEstimate(weightsBytes: weights, kvCacheBytes: attentionKV + linearState,
                                   draftBytes: draft, workspaceBytes: workspace,
                                   isApproximate: true, source: Self.source)
    }

    // MARK: Pieces

    static func kvBytes(layers: Int, kvHeads: Int, headDim: Int, tokens: UInt64,
                        dtype: ModelLoadSettings.KVCacheDType) -> UInt64 {
        2 * UInt64(layers * kvHeads * dtype.bytesPerVector(width: headDim)) * tokens
    }

    static func linearStateBytes(_ m: ModelConfigSummary) -> UInt64 {
        guard m.linearAttentionLayers > 0 else { return 0 }
        let recurrent = m.linearValueHeads * m.linearValueHeadDim * m.linearValueHeadDim
        let convDim = 2 * m.linearKeyHeads * m.linearKeyHeadDim + m.linearValueHeads * m.linearValueHeadDim
        let conv = max(0, m.linearConvKernel - 1) * convDim
        return UInt64(m.linearAttentionLayers * (recurrent + conv)) * 4
    }

    /// The draft as LSE loads it: the Q8 conversion when present, a BF16
    /// source scaled to its Q8 size, or a quantized draft's own files.
    static func draftWeightBytes(_ dir: URL) -> UInt64 {
        let converted = dir.appending(path: conversionDirectory)
        if FileManager.default.fileExists(atPath: converted.appending(path: "model.safetensors").path) {
            return weightBytes(in: converted, skipping: [])
        }
        let source = weightBytes(in: dir, skipping: [conversionDirectory])
        let config = (try? Data(contentsOf: dir.appending(path: "config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let quantized = config?["quantization"] != nil || config?["quantization_config"] != nil
        return quantized ? source : UInt64(Double(source) * q8OverBF16)
    }

    /// Bytes of the tensors LSE loads from every *.safetensors under `dir`.
    static func weightBytes(in dir: URL, skipping skipped: Set<String>) -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension == "safetensors",
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += loadedTensorBytes(url) ?? UInt64(max(0, v.fileSize ?? 0))
        }
        return total
    }

    /// The tensors' byte ranges from a safetensors header, without the
    /// `vision_tower.*` tensors LSE skips. Nil when the header is unreadable.
    static func loadedTensorBytes(_ url: URL) -> UInt64? {
        guard let header = try? SafetensorsHeader.read(url),
              let object = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any] else { return nil }
        var total: UInt64 = 0
        for (name, value) in object where name != "__metadata__" && !name.hasPrefix("vision_tower.") {
            guard let info = value as? [String: Any], let offsets = info["data_offsets"] as? [Any], offsets.count == 2,
                  let begin = ModelInspector.int(offsets[0]), let end = ModelInspector.int(offsets[1]),
                  end >= begin else { return nil }
            total += UInt64(end - begin)
        }
        return total
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
