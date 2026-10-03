// StudioModels: the geometry in a model's config.json that load settings and
// memory estimates need.
//
// Read the way LSE reads it (src/model/config.cpp): Qwen3.5-family values
// come from `text_config`, falling back to the root; DFlash2 drafts keep them
// at the root. A hybrid Qwen3.5 model has two kinds of layer:
//  - full attention, every `full_attention_interval`-th layer (or as
//    `layer_types` lists them), which keeps a K/V cache growing with kv_len;
//  - linear attention (Gated DeltaNet), which keeps a fixed-size recurrent
//    state and a short convolution window, whatever the context.

import Foundation

public struct ModelConfigSummary: Codable, Sendable, Hashable {
    public var kind: ModelKind
    /// `max_position_embeddings`: the longest context the model was trained for.
    public var maxContext: Int?
    /// `mtp_num_hidden_layers`.
    public var mtpLayers: Int
    public var numLayers: Int
    /// Layers with a K/V cache that grows with kv_len.
    public var fullAttentionLayers: Int
    /// Gated DeltaNet layers, with fixed-size state.
    public var linearAttentionLayers: Int
    /// Sliding-window attention layers (DFlash2 drafts), with a bounded cache.
    public var slidingAttentionLayers: Int
    public var numAttentionHeads: Int
    public var numKeyValueHeads: Int
    public var headDim: Int
    public var hiddenSize: Int
    public var vocabSize: Int
    public var intermediateSize: Int
    /// Rotated channels per head: head_dim × partial_rotary_factor.
    public var ropeDim: Int

    // Gated DeltaNet geometry (zero when the model has no linear layers).
    public var linearKeyHeads: Int
    public var linearValueHeads: Int
    public var linearKeyHeadDim: Int
    public var linearValueHeadDim: Int
    public var linearConvKernel: Int

    // DFlash2 drafts.
    public var slidingWindow: Int?
    /// Tokens the draft proposes per step (`dflash_config.block_size`).
    public var draftBlockSize: Int?
    /// Target layers whose features the draft reads (`dflash_config.target_layer_ids`).
    public var draftTargetLayers: Int?

    public var hasMTP: Bool { mtpLayers > 0 }

    public init?(config data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let architectures = root["architectures"] as? [String] ?? []
        let isDraft = architectures.contains("DFlash2DraftModel")
        let text = isDraft ? root : (root["text_config"] as? [String: Any] ?? root)
        func int(_ key: String) -> Int? { ModelInspector.int(text[key]) ?? ModelInspector.int(root[key]) }
        func double(_ key: String) -> Double? { ModelInspector.double(text[key]) ?? ModelInspector.double(root[key]) }

        guard let layers = int("num_hidden_layers"), let hidden = int("hidden_size"),
              let vocab = int("vocab_size") else { return nil }
        let modelType = root["model_type"] as? String ?? ""
        kind = isDraft ? .dflash2Draft : modelType.hasSuffix("_mtp") ? .mtpModule
            : root["text_config"] != nil ? .main : .unknown
        maxContext = int("max_position_embeddings")
        mtpLayers = isDraft ? 0 : (int("mtp_num_hidden_layers") ?? 0)
        numLayers = layers
        hiddenSize = hidden
        vocabSize = vocab
        numAttentionHeads = int("num_attention_heads") ?? 0
        numKeyValueHeads = int("num_key_value_heads") ?? numAttentionHeads
        headDim = int("head_dim") ?? (numAttentionHeads > 0 ? hidden / numAttentionHeads : 0)
        intermediateSize = int("intermediate_size") ?? int("moe_intermediate_size") ?? 4 * hidden
        let rotary = double("partial_rotary_factor")
            ?? ModelInspector.double((text["rope_parameters"] as? [String: Any])?["partial_rotary_factor"]) ?? 1
        ropeDim = Int((Double(headDim) * rotary).rounded())

        linearKeyHeads = int("linear_num_key_heads") ?? 0
        linearValueHeads = int("linear_num_value_heads") ?? 0
        linearKeyHeadDim = int("linear_key_head_dim") ?? 0
        linearValueHeadDim = int("linear_value_head_dim") ?? 0
        linearConvKernel = int("linear_conv_kernel_dim") ?? 0

        if let types = text["layer_types"] as? [String], types.count == layers {
            fullAttentionLayers = types.filter { $0 == "full_attention" || $0 == "attention" }.count
            linearAttentionLayers = types.filter { $0 == "linear_attention" }.count
            slidingAttentionLayers = types.filter { $0 == "sliding_attention" }.count
        } else if let interval = int("full_attention_interval"), interval > 0 {
            // LSE's rule: layer i attends when (i + 1) % interval == 0.
            fullAttentionLayers = layers / interval
            linearAttentionLayers = layers - fullAttentionLayers
            slidingAttentionLayers = 0
        } else {
            fullAttentionLayers = layers
            linearAttentionLayers = 0
            slidingAttentionLayers = 0
        }

        slidingWindow = isDraft ? int("sliding_window") : nil
        let dflash = root["dflash_config"] as? [String: Any]
        draftBlockSize = ModelInspector.int(dflash?["block_size"])
        draftTargetLayers = (dflash?["target_layer_ids"] as? [Any])?.count
    }

    /// The summary of an installed model directory's config.json.
    public static func read(directory: URL) -> ModelConfigSummary? {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")) else { return nil }
        return ModelConfigSummary(config: data)
    }
}
