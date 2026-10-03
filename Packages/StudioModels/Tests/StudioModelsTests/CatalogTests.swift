// The bundled catalog, launch presets, model inspection, digests and chunking.

import Foundation
import Testing
@testable import StudioModels

@Suite("Catalog")
struct CatalogTests {
    let catalog = ModelCatalog.bundled()

    @Test func entriesArePinnedBySizeAndDigest() {
        #expect(catalog.models.map(\.id) == ["qwen38-27b-q4", "qwen38-27b-dflash2", "qwen38-27b-dflash2-q8"])
        for entry in catalog.models {
            #expect(!entry.files.isEmpty)
            for file in entry.files {
                #expect(file.size > 0)
                #expect(file.sha256?.count == 64 && file.sha256!.allSatisfy(\.isHexDigit), "\(entry.id)/\(file.path)")
            }
            if entry.source == .huggingFace {
                #expect(entry.revision?.count == 40, "\(entry.id) must pin a commit")
            }
            for draft in entry.drafts ?? [] { #expect(catalog.entry(id: draft)?.role == .dflash2Draft) }
        }
    }

    @Test func theQ4ModelIsTheLMStudioMLXBuild() throws {
        let q4 = try #require(catalog.entry(id: "qwen38-27b-q4"))
        #expect(q4.repository == "lmstudio-community/Qwen3.8-27B-MLX-4bit")
        #expect(q4.revision == "6067b15cf581666a4aecf6af3afaba4bb5efc20c")
        #expect(q4.totalBytes == 16_074_763_291)
        #expect(q4.quantization == .affine(bits: 4, groupSize: 64))
    }

    @Test func theDraftDownloadsAsItsBF16Source() throws {
        let draft = try #require(catalog.entry(id: "qwen38-27b-dflash2"))
        #expect(draft.repository == "incoai/Qwen3.8-27B-DFlash2")
        #expect(draft.revision == "dedf8df68adfb1afeaf7b7480c0a0243108177b4")
        #expect(draft.files.first { $0.path == "model.safetensors" }?.sha256
                == "67fc76d68dc5a9415511a4f394ef744d67510cd20e93b37cc2cc7d28e4bab65c")
        #expect(draft.lseConversion?.outputSHA256 == "cc3b5742f8edf02c4edcc734ef66e7c4c5f660b43438641ee36c5a72f8414188")
        let request = try #require(DownloadRequest(catalog: draft))
        #expect(request.extraBytes == 2_044_950_184)
        // The converted Q8 is recognized when copied in, but cannot be downloaded.
        let q8 = try #require(catalog.entry(id: "qwen38-27b-dflash2-q8"))
        #expect(!q8.isDownloadable && DownloadRequest(catalog: q8) == nil)
        #expect(q8.files.first { $0.path == "model.safetensors" }?.sha256 == draft.lseConversion?.outputSHA256)
    }

    @Test func entriesAreFoundBySizesWhenRenamed() {
        let sizes = ["config.json": Int64(1322), "model.safetensors": Int64(2_044_950_184), "extra": Int64(1)]
        #expect(catalog.entry(matchingSizes: sizes)?.id == "qwen38-27b-dflash2-q8")
    }

    @Test func theLaunchPresetMatchesTheBenchmarkedConfiguration() {
        let args = LSELaunchPreset.standard.arguments(model: URL(fileURLWithPath: "/m/qwen38-27b-q4"),
                                                     dflash2Draft: URL(fileURLWithPath: "/m/qwen38-27b-dflash2"))
        #expect(args.joined(separator: " ") ==
                "--model /m/qwen38-27b-q4 --dflash2=on --dflash2-model /m/qwen38-27b-dflash2 --pool hrx:0 --dialect loom --kv-cache-dtype bf16 --kv-len 32768 --temperature 0.6 --batch-size 1024 --ubatch-size 1024")
        let plain = LSELaunchPreset.standard.arguments(model: URL(fileURLWithPath: "/m/x"), dflash2Draft: nil)
        #expect(!plain.contains("--dflash2=on"))
        #expect(LSELaunchPreset.standard.commandLine(model: URL(fileURLWithPath: "/a b/m"), dflash2Draft: nil)
            .hasPrefix("--model '/a b/m' "))
    }
}

@Suite("Inspection follows LSE's loader")
struct InspectorTests {
    func config(_ name: String) throws -> Data { try Fixtures.data("configs/\(name)") }

    @Test func theQ4CheckpointIsALoadableDenseQwen() throws {
        let names = try #require(ModelInspector.tensorNames(index: config("qwen38-27b-q4.index.json")))
        let traits = ModelInspector.inspect(config: try config("qwen38-27b-q4.config.json"), weightNames: names)
        #expect(traits.problems == [])
        #expect(traits.kind == .main && traits.layout == .dense && traits.architectureLabel == "qwen3.5")
        #expect(traits.quantization == .affine(bits: 4, groupSize: 64))
        #expect(traits.hiddenSize == 5120 && traits.vocabSize == 248320 && traits.numLayers == 64)
        #expect(traits.mtpLayers == 1 && !traits.mtpDedicatedEmbeddings)
    }

    @Test func draftsPairByLSEsGeometryCheck() throws {
        let target = ModelInspector.inspect(config: try config("qwen38-27b-q4.config.json"))
        let bf16 = ModelInspector.inspect(config: try config("qwen38-27b-dflash2-bf16.config.json"))
        let names = try JSONDecoder().decode([String].self, from: try config("qwen38-27b-dflash2-q8.tensors.json"))
        let q8 = ModelInspector.inspect(config: try config("qwen38-27b-dflash2-q8.config.json"), weightNames: names)
        #expect(bf16.kind == .dflash2Draft && bf16.problems == [])
        #expect(bf16.quantization == Quantization(kind: .unquantized, dtype: "bfloat16"))
        #expect(q8.problems == [] && q8.quantization == .affine(bits: 8, groupSize: 64))
        #expect(bf16.numTargetLayers == 64)
        #expect(target.accepts(draft: bf16) && target.accepts(draft: q8))
        var other = bf16
        other.numTargetLayers = 48
        #expect(!target.accepts(draft: other))
    }

    @Test func theMTPModuleMatchesItsParent() throws {
        let target = ModelInspector.inspect(config: try config("qwen38-27b-q4.config.json"))
        let module = ModelInspector.inspect(config: try config("qwen38-27b-mtp-q8.config.json"))
        #expect(module.kind == .mtpModule)
        #expect(target.accepts(mtpModule: module))
        #expect(CompatibleModelSearch.mtpCompanionNames("mlx-community/Qwen3.8-27B-8bit")
                == ["mlx-community/Qwen3.8-27B-MTP-8bit", "mlx-community/Qwen3.8-27B-8bit-MTP"])
    }

    @Test func unsupportedFormatsAreRejectedWithReasons() throws {
        var q4 = try JSONSerialization.jsonObject(with: config("qwen38-27b-q4.config.json")) as! [String: Any]
        q4["quantization"] = ["quant_method": "fp8"]
        var traits = ModelInspector.inspect(config: try JSONSerialization.data(withJSONObject: q4))
        #expect(traits.problems.contains { $0.contains("fp8") })

        q4["quantization"] = ["bits": 4, "group_size": 64, "mode": "mxfp4"]
        traits = ModelInspector.inspect(config: try JSONSerialization.data(withJSONObject: q4))
        #expect(traits.problems.contains { $0.contains("mxfp4") })

        q4["quantization"] = ["bits": 7, "group_size": 64]
        traits = ModelInspector.inspect(config: try JSONSerialization.data(withJSONObject: q4))
        #expect(traits.problems.contains { $0.contains("7-bit") })

        // A transformers-layout checkpoint has the right config but not MLX tensor names.
        q4["quantization"] = nil
        q4["quantization_config"] = nil
        traits = ModelInspector.inspect(config: try JSONSerialization.data(withJSONObject: q4),
                                        weightNames: ["model.language_model.layers.0.linear_attn.in_proj_qkv.weight"])
        #expect(traits.problems.contains { $0.contains("MLX Qwen3.5 layout") })
        #expect(traits.quantization?.kind == .unquantized)

        let flat = Data(#"{"model_type": "llama", "architectures": ["LlamaForCausalLM"]}"#.utf8)
        #expect(!ModelInspector.inspect(config: flat).isCompatible)
    }

    @Test func moeIsRecognizedFromConfigAndTensors() throws {
        var root = try JSONSerialization.jsonObject(with: config("qwen38-27b-q4.config.json")) as! [String: Any]
        var text = root["text_config"] as! [String: Any]
        text["num_experts"] = 256
        text["num_experts_per_tok"] = 8
        text["moe_intermediate_size"] = 512
        text["shared_expert_intermediate_size"] = 512
        root["text_config"] = text
        let names = [ModelInspector.gdnMarker, ModelInspector.moeMarker]
        let traits = ModelInspector.inspect(config: try JSONSerialization.data(withJSONObject: root), weightNames: names)
        #expect(traits.problems == [] && traits.layout == .moe && traits.architectureLabel == "qwen3.5-moe")
    }
}

@Suite("Digests and chunks")
struct DigestTests {
    @Test func streamingDigestsMatchKnownValues() throws {
        let scratch = try Scratch()
        let file = scratch.url.appending(path: "hello")
        try Data("hello\n".utf8).write(to: file)
        #expect(try FileDigest.sha256(of: file) == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
        // `git hash-object` of the same file.
        #expect(try FileDigest.gitBlobSHA1(of: file) == "ce013625030ba8dba906f756967f9e9ca394464a")

        let big = testBytes(20 << 20, seed: 7)
        try big.write(to: file)
        #expect(try FileDigest.sha256(of: file) == sha256Hex(big))
    }

    @Test func theOrderedHasherFollowsTheContiguousPrefix() throws {
        let scratch = try Scratch()
        let data = testBytes(1000, seed: 3)
        let file = scratch.url.appending(path: "part")
        try data.write(to: file)
        var hasher = OrderedHasher()
        try hasher.catchUp(from: file, to: 300)
        try hasher.catchUp(from: file, to: 200)  // never goes backwards
        try hasher.catchUp(from: file, to: 1000)
        #expect(hasher.hashedThrough == 1000 && hasher.digest() == sha256Hex(data))
    }

    @Test func chunkArithmetic() {
        let size: Int64 = 1000, chunk: Int64 = 300
        #expect(ChunkPlan.count(size: size, chunkSize: chunk) == 4)
        #expect(ChunkPlan.range(of: 3, size: size, chunkSize: chunk) == 900..<1000)
        #expect(ChunkPlan.rangeHeader(of: 1, size: size, chunkSize: chunk) == "bytes=300-599")
        #expect(ChunkPlan.rangeHeader(of: 0, size: 10, chunkSize: 10) == nil)
        #expect(ChunkPlan.remaining(size: size, chunkSize: chunk, completed: [0, 2]) == [1, 3])
        #expect(ChunkPlan.contiguousEnd(size: size, chunkSize: chunk, completed: [0, 1, 3]) == 600)
        #expect(ChunkPlan.contiguousEnd(size: size, chunkSize: chunk, completed: [0, 1, 2, 3]) == 1000)
        #expect(ChunkPlan.chunkSize(forFileOfSize: 50, preferred: 300) == 50)
        let parsed = ChunkPlan.parseContentRange("bytes 300-599/1000")
        #expect(parsed?.range == 300..<600 && parsed?.total == 1000)
        #expect(ChunkPlan.parseContentRange("bytes */1000") == nil)
        let key = ChunkKey(model: "m", path: "a/b.safetensors", chunk: 4)
        #expect(ChunkKey(encoded: key.encoded) == key)
    }
}
