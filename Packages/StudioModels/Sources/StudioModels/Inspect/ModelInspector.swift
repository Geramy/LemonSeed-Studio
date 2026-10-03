// StudioModels: what LSE can load, decided the way LSE decides it.
//
// The rules mirror LemonSeed-Engine:
//  - Main models are picked by tensor names, not model_type
//    (src/model/registry.cpp, src/models/qwen3_5*.cpp). Qwen3.5-family
//    checkpoints need the MLX naming: the GDN marker
//    `language_model.model.layers.0.linear_attn.in_proj_qkv.weight`, plus
//    `...mlp.gate_proj.weight` (dense) or `...mlp.switch_mlp.gate_proj.weight`
//    (MoE). A tensor no loader claims fails the load; `vision_tower.*` is the
//    one exception and is skipped.
//  - The config must carry a `text_config` with the Qwen3.5 geometry keys
//    (src/model/config.cpp from_hf_json). `num_experts` selects MoE.
//  - Quantization is the root `quantization`, else `quantization_config`:
//    mode absent or "affine", bits in {2,3,4,5,6,8}, group size in
//    {32,64,128} (src/quant/group_affine.cpp). No block means unquantized
//    safetensors (BF16/F16/F32), which LSE also loads. GGUF is not read.
//  - MTP: LSE reads `text_config.mtp_num_hidden_layers` and loads the module
//    from a separate checkpoint (an `mtp/` directory beside the model, or a
//    `-MTP` sibling repo). It rejects `mtp_use_dedicated_embeddings`
//    (src/model/mtp.cpp).
//  - DFlash2 drafts: `architectures` contains "DFlash2DraftModel". A draft
//    pairs with a target when hidden_size and vocab_size match and
//    num_target_layers equals the target's num_hidden_layers
//    (src/model/dflash2.cpp DFlash2Config::validate).

import Foundation

public enum ModelLayout: String, Codable, Sendable, Hashable {
    case dense
    case moe

    public var label: String { self == .dense ? "Dense" : "MoE" }
}

public enum ModelKind: String, Codable, Sendable, Hashable {
    case main
    case dflash2Draft
    case mtpModule
    case unknown
}

public struct ModelTraits: Codable, Sendable, Hashable {
    public var kind: ModelKind
    public var modelType: String?
    public var architectures: [String]
    public var layout: ModelLayout?
    public var quantization: Quantization?
    public var hiddenSize: Int?
    public var vocabSize: Int?
    public var numLayers: Int?
    /// DFlash2 drafts: the target layer count they were trained against.
    public var numTargetLayers: Int?
    /// MTP geometry the module must share with its parent.
    public var numAttentionHeads: Int?
    public var numKeyValueHeads: Int?
    public var headDim: Int?
    public var intermediateSize: Int?
    public var ropeTheta: Double?
    /// `text_config.mtp_num_hidden_layers`.
    public var mtpLayers: Int
    public var mtpDedicatedEmbeddings: Bool
    /// Why LSE would refuse it. Empty means loadable.
    public var problems: [String]

    public var isCompatible: Bool { problems.isEmpty }

    /// The LSE architecture name for display: "qwen3.5", "qwen3.5-moe" or "dflash2".
    public var architectureLabel: String {
        switch kind {
        case .dflash2Draft: "dflash2"
        case .mtpModule: "qwen3.5-mtp"
        case .main: layout == .moe ? "qwen3.5-moe" : "qwen3.5"
        case .unknown: modelType ?? "unknown"
        }
    }

    /// Whether `draft` can drive this target under LSE's geometry check.
    public func accepts(draft: ModelTraits) -> Bool {
        guard kind == .main, draft.kind == .dflash2Draft,
              let h = hiddenSize, let v = vocabSize, let n = numLayers else { return false }
        return draft.hiddenSize == h && draft.vocabSize == v && draft.numTargetLayers == n
    }

    /// Whether `module` can serve as this model's MTP module (mtp.cpp same_geometry).
    public func accepts(mtpModule module: ModelTraits) -> Bool {
        guard kind == .main, module.kind == .mtpModule || module.kind == .main else { return false }
        return module.hiddenSize == hiddenSize && module.vocabSize == vocabSize
            && module.numAttentionHeads == numAttentionHeads
            && module.numKeyValueHeads == numKeyValueHeads && module.headDim == headDim
            && module.intermediateSize == intermediateSize && module.ropeTheta == ropeTheta
    }
}

public enum ModelInspector {
    static let gdnMarker = "language_model.model.layers.0.linear_attn.in_proj_qkv.weight"
    static let moeMarker = "language_model.model.layers.0.mlp.switch_mlp.gate_proj.weight"
    static let denseMarker = "language_model.model.layers.0.mlp.gate_proj.weight"
    static let allowedBits: Set<Int> = [2, 3, 4, 5, 6, 8]
    static let allowedGroups: Set<Int> = [32, 64, 128]
    static let textConfigKeys = [
        "vocab_size", "hidden_size", "num_hidden_layers", "rms_norm_eps", "full_attention_interval",
        "num_attention_heads", "num_key_value_heads", "head_dim", "linear_num_key_heads",
        "linear_num_value_heads", "linear_conv_kernel_dim", "linear_key_head_dim",
        "linear_value_head_dim", "rope_parameters",
    ]
    static let draftKeys = [
        "hidden_size", "vocab_size", "num_hidden_layers", "num_target_layers", "num_attention_heads",
        "num_key_value_heads", "head_dim", "intermediate_size", "sliding_window", "rms_norm_eps",
        "rope_parameters", "layer_types", "dflash_config", "is_causal",
    ]

    /// Inspects a config.json. With `weightNames` (the safetensors index's
    /// weight_map keys, or a single file's header), the tensor-name rules
    /// apply too. Without them the verdict rests on the config alone.
    public static func inspect(config data: Data, weightNames: [String]? = nil) -> ModelTraits {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ModelTraits(kind: .unknown, modelType: nil, architectures: [], mtpLayers: 0,
                               mtpDedicatedEmbeddings: false, problems: ["config.json is not a JSON object"])
        }
        let architectures = root["architectures"] as? [String] ?? []
        if architectures.contains("DFlash2DraftModel") {
            return inspectDraft(root, architectures: architectures, weightNames: weightNames)
        }
        return inspectQwen(root, architectures: architectures, weightNames: weightNames)
    }

    // MARK: - Qwen3.5 family

    private static func inspectQwen(_ root: [String: Any], architectures: [String],
                                    weightNames: [String]?) -> ModelTraits {
        let modelType = root["model_type"] as? String
        var traits = ModelTraits(kind: .unknown, modelType: modelType, architectures: architectures,
                                 mtpLayers: 0, mtpDedicatedEmbeddings: false, problems: [])
        guard let text = root["text_config"] as? [String: Any] else {
            traits.problems.append("no text_config: not a Qwen3.5-family checkpoint LSE recognizes")
            if let q = quantization(root, problems: &traits.problems) { traits.quantization = q }
            return traits
        }
        let isMTP = (modelType ?? "").hasSuffix("_mtp")
        traits.kind = isMTP ? .mtpModule : .main
        let missing = textConfigKeys.filter { text[$0] == nil }
        if !missing.isEmpty {
            traits.problems.append("text_config lacks " + missing.joined(separator: ", "))
        }
        traits.hiddenSize = int(text["hidden_size"])
        traits.vocabSize = int(text["vocab_size"])
        traits.numLayers = int(text["num_hidden_layers"])
        traits.numAttentionHeads = int(text["num_attention_heads"])
        traits.numKeyValueHeads = int(text["num_key_value_heads"])
        traits.headDim = int(text["head_dim"])
        traits.intermediateSize = int(text["intermediate_size"])
        traits.ropeTheta = double((text["rope_parameters"] as? [String: Any])?["rope_theta"])
        if let rope = text["rope_parameters"] as? [String: Any], rope["partial_rotary_factor"] == nil {
            traits.problems.append("rope_parameters lacks partial_rotary_factor")
        }
        if let k = int(text["linear_key_head_dim"]), let v = int(text["linear_value_head_dim"]), k != v {
            traits.problems.append("linear key and value head dims differ")
        }
        if let only = text["mlp_only_layers"] as? [Any], !only.isEmpty {
            traits.problems.append("mlp_only_layers is not supported")
        }
        if text["num_experts"] != nil {
            traits.layout = .moe
            for key in ["num_experts_per_tok", "moe_intermediate_size", "shared_expert_intermediate_size"]
            where text[key] == nil {
                traits.problems.append("MoE text_config lacks \(key)")
            }
        } else {
            traits.layout = .dense
            if text["intermediate_size"] == nil { traits.problems.append("text_config lacks intermediate_size") }
        }
        traits.mtpLayers = int(text["mtp_num_hidden_layers"]) ?? 0
        traits.mtpDedicatedEmbeddings = text["mtp_use_dedicated_embeddings"] as? Bool ?? false
        traits.quantization = quantization(root, problems: &traits.problems)
            ?? Quantization(kind: .unquantized, dtype: (text["dtype"] ?? text["torch_dtype"]
                ?? root["dtype"] ?? root["torch_dtype"]) as? String)

        if let names = weightNames, traits.kind == .main {
            let set = Set(names)
            if !set.contains(gdnMarker) {
                traits.problems.append("tensor names are not MLX Qwen3.5 layout (no \(gdnMarker))")
            } else if set.contains(moeMarker) {
                traits.layout = .moe
            } else if set.contains(denseMarker) {
                traits.layout = .dense
            } else {
                traits.problems.append("no dense or MoE MLP tensors in layer 0")
            }
            let stray = names.filter { !$0.hasPrefix("language_model.") && !$0.hasPrefix("vision_tower.") }
            if let first = stray.first {
                traits.problems.append("tensors LSE does not load, such as \(first)")
            }
        }
        return traits
    }

    // MARK: - DFlash2 drafts

    private static func inspectDraft(_ root: [String: Any], architectures: [String],
                                     weightNames: [String]?) -> ModelTraits {
        var traits = ModelTraits(kind: .dflash2Draft, modelType: root["model_type"] as? String,
                                 architectures: architectures, mtpLayers: 0,
                                 mtpDedicatedEmbeddings: false, problems: [])
        let missing = draftKeys.filter { root[$0] == nil }
        if !missing.isEmpty { traits.problems.append("DFlash2 config lacks " + missing.joined(separator: ", ")) }
        traits.hiddenSize = int(root["hidden_size"])
        traits.vocabSize = int(root["vocab_size"])
        traits.numLayers = int(root["num_hidden_layers"])
        traits.numTargetLayers = int(root["num_target_layers"])
        traits.numAttentionHeads = int(root["num_attention_heads"])
        traits.numKeyValueHeads = int(root["num_key_value_heads"])
        traits.headDim = int(root["head_dim"])
        traits.intermediateSize = int(root["intermediate_size"])
        traits.layout = .dense
        if root["is_causal"] as? Bool == true { traits.problems.append("causal DFlash2 drafts are not supported") }
        if let rope = root["rope_parameters"] as? [String: Any] {
            traits.ropeTheta = double(rope["rope_theta"])
            if rope["rope_type"] as? String != "default" { traits.problems.append("DFlash2 needs default RoPE") }
        }
        if let layers = root["layer_types"] as? [String], layers.contains(where: { $0 != "sliding_attention" }) {
            traits.problems.append("DFlash2 needs sliding attention in every layer")
        }
        if let d = root["dflash_config"] as? [String: Any] {
            if int(d["conv_kernel_size"]) != 2 { traits.problems.append("DFlash2 needs two-tap convolution") }
            if let block = int(d["block_size"]), !(2...8).contains(block) {
                traits.problems.append("DFlash2 block size must be 2...8")
            }
            for key in ["mask_token_id", "target_layer_ids", "conv_group_size", "selector_rank", "selector_top_k"]
            where d[key] == nil {
                traits.problems.append("dflash_config lacks \(key)")
            }
        }
        traits.quantization = quantization(root, problems: &traits.problems)
            ?? Quantization(kind: .unquantized, dtype: (root["dtype"] ?? root["torch_dtype"]) as? String)
        if let names = weightNames, !names.contains("fc.weight") {
            traits.problems.append("DFlash2 weights lack fc.weight")
        }
        return traits
    }

    // MARK: - Quantization

    /// The group-affine block, or nil for an unquantized checkpoint. Problems
    /// are appended for anything LSE's GroupAffineMap would reject.
    static func quantization(_ root: [String: Any], problems: inout [String]) -> Quantization? {
        guard let block = (root["quantization"] ?? root["quantization_config"]) as? [String: Any] else {
            return nil
        }
        if let method = block["quant_method"] as? String, block["bits"] == nil {
            problems.append("\(method) quantization is not supported (MLX affine only)")
            return Quantization(kind: .affine)
        }
        if let mode = block["mode"] as? String, mode != "affine" {
            problems.append("\(mode) quantization is not supported (affine only)")
        }
        let bits = int(block["bits"]), group = int(block["group_size"])
        if (bits == nil) != (group == nil) { problems.append("quantization needs both bits and group_size") }
        if let bits, !allowedBits.contains(bits) { problems.append("\(bits)-bit quantization is not supported") }
        if let group, !allowedGroups.contains(group) { problems.append("group size \(group) is not supported") }
        if bits == nil, group == nil { return nil }
        return Quantization(kind: .affine, bits: bits, groupSize: group)
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as NSNumber: n.intValue
        default: nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: n
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    /// Tensor names from a safetensors header (the JSON after the 8-byte length).
    public static func tensorNames(safetensorsHeader data: Data) -> [String]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object.keys.filter { $0 != "__metadata__" }.sorted()
    }

    /// Tensor names from a model.safetensors.index.json.
    public static func tensorNames(index data: Data) -> [String]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let map = object["weight_map"] as? [String: Any] else { return nil }
        return map.keys.sorted()
    }

    /// Reads traits from an installed directory: config.json plus the index
    /// or the single file's header.
    public static func inspect(directory: URL) -> ModelTraits? {
        guard let config = try? Data(contentsOf: directory.appending(path: "config.json")) else { return nil }
        var names: [String]?
        if let index = try? Data(contentsOf: directory.appending(path: "model.safetensors.index.json")) {
            names = tensorNames(index: index)
        } else if let header = try? SafetensorsHeader.read(directory.appending(path: "model.safetensors")) {
            names = tensorNames(safetensorsHeader: header)
        }
        return inspect(config: config, weightNames: names)
    }
}

enum SafetensorsHeader {
    static let maxHeaderBytes: UInt64 = 100 << 20

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = length(prefix)
        guard size <= maxHeaderBytes, let header = try handle.read(upToCount: Int(size)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return header
    }

    static func length(_ prefix: Data) -> UInt64 {
        prefix.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
}
