// Load settings: defaults, launch arguments, persistence in the registry, and
// the config.json memory estimate on the Qwen3.8-27B fixture configs.

import Foundation
import Testing
@testable import StudioModels

/// A file of `size` bytes that occupies no disk space.
func sparseFile(_ url: URL, size: UInt64) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: size)
    try handle.close()
}

/// A model directory: a fixture config.json and sparse weight shards.
func fixtureModel(_ config: String, in dir: URL, shards: [String: UInt64]) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Fixtures.data("configs/\(config)").write(to: dir.appending(path: "config.json"))
    for (name, size) in shards { try sparseFile(dir.appending(path: name), size: size) }
    return dir
}

@Suite("Load settings")
struct LoadSettingsTests {
    let model = URL(fileURLWithPath: "/m/qwen38-27b-q4")
    let draft = URL(fileURLWithPath: "/m/qwen38-27b-dflash2")

    @Test func theDefaultsAreTheStandardPreset() {
        let s = ModelLoadSettings()
        let preset = LSELaunchPreset.standard
        #expect(s == .standard)
        #expect(s.kvCacheDType.rawValue == preset.kvCacheDType && s.kvLength == preset.kvLength)
        #expect(s.batchSize == preset.batchSize && s.ubatchSize == preset.ubatchSize)
        #expect(s.temperature == nil && s.dflash2Enabled && !s.mtpEnabled)
        #expect(s.mtpDepth == 3 && s.topP == nil && s.topK == nil && s.minP == nil)

        let launch = preset.configuration(model: model, settings: s, dflash2Draft: draft, mtpModule: nil)
        #expect(launch.arguments == preset.arguments(model: model, dflash2Draft: draft))
        #expect(launch.commandLine == preset.commandLine(model: model, dflash2Draft: draft))
        // A model with an MTP module but DFlash2 on: LSE ignores MTP, nothing to add.
        let withModule = preset.configuration(model: model, settings: s, dflash2Draft: draft,
                                              mtpModule: model.appending(path: "mtp"))
        #expect(withModule.arguments == preset.arguments(model: model, dflash2Draft: draft))
    }

    @Test func settingsMapToLSEFlags() {
        let mtp = model.appending(path: "mtp")
        var s = ModelLoadSettings(kvCacheDType: .fp8, kvLength: 65536, batchSize: 2048, ubatchSize: 512,
                                  dflash2Enabled: false, mtpEnabled: true, mtpDepth: 5, temperature: 1,
                                  topP: 0.9)
        var launch = LSELaunchConfiguration(model: model, settings: s, dflash2Draft: draft, mtpModule: mtp)
        #expect(!launch.dflash2 && launch.usesMTP && !launch.noMTP)
        #expect(launch.arguments.joined(separator: " ") ==
                "--model /m/qwen38-27b-q4 --pool hrx:0 --dialect loom --kv-cache-dtype fp8 --kv-len 65536 --batch-size 2048 --ubatch-size 512 --mtp-depth 5")
        // Sampling is sent per request, never as a launch option.
        #expect(!launch.arguments.contains("--temperature") && !launch.arguments.contains("--max-tokens"))

        s.mtpEnabled = false
        launch = LSELaunchConfiguration(model: model, settings: s, dflash2Draft: nil, mtpModule: mtp)
        #expect(launch.noMTP && launch.arguments.contains("--no-mtp") && !launch.arguments.contains("--mtp-depth"))
        // Without a module there is nothing to turn off.
        launch = LSELaunchConfiguration(model: model, settings: s, dflash2Draft: nil, mtpModule: nil)
        #expect(!launch.noMTP && !launch.arguments.contains("--no-mtp"))
        // The default MTP-only launch (no draft, module present) matches the preset.
        let plain = ModelLoadSettings.defaults(linkedDraftID: nil, summary: nil, hasMTPModule: true)
        #expect(plain.mtpEnabled && !plain.dflash2Enabled)
        #expect(LSELaunchConfiguration(model: model, settings: plain, dflash2Draft: nil, mtpModule: mtp).arguments
                == LSELaunchPreset.standard.arguments(model: model, dflash2Draft: nil))
    }

    @Test func samplingIsTheModelsUnlessOverriddenAndOldSettingsMigrate() throws {
        let decoder = JSONDecoder()
        // The old fixed default (0.6) and the old reply limits read back as nothing chosen.
        let old = try decoder.decode(ModelLoadSettings.self,
                                     from: Data(#"{"temperature":0.6,"maxTokens":4096,"maxReplyTokens":2048,"topP":0.9}"#.utf8))
        #expect(old.temperature == nil && old.topP == 0.9)
        // A temperature someone did choose stays an override.
        #expect(try decoder.decode(ModelLoadSettings.self, from: Data(#"{"temperature":0.8}"#.utf8)).temperature == 0.8)
        // Overrides round-trip; unset fields stay unset.
        let chosen = ModelLoadSettings(temperature: 0.6, topK: 0, minP: 0.05, presencePenalty: 0.5, repetitionPenalty: 1.1)
        let back = try decoder.decode(ModelLoadSettings.self, from: JSONEncoder().encode(chosen))
        #expect(back == chosen && back.temperature == 0.6)
        #expect(try decoder.decode(ModelLoadSettings.self, from: JSONEncoder().encode(ModelLoadSettings())) == ModelLoadSettings())
        let json = String(decoding: try JSONEncoder().encode(ModelLoadSettings()), as: UTF8.self)
        #expect(!json.contains("temperature") && !json.contains("maxTokens"))
    }

    @Test func modelDefaultsReadFromLSE() {
        let info: [String: Any] = ["generation_defaults": ["temperature": 1.0, "top_k": 20, "top_p": 0.95, "min_p": 0.0,
                                                           "repetition_penalty": 1.0, "presence_penalty": 0.0,
                                                           "sources": ["temperature": "generation_config.json"]]]
        let d = ModelGenerationDefaults(lseModelInfo: info)
        #expect(d?.temperature == 1.0 && d?.topK == 20 && d?.topP == 0.95 && d?.sources["temperature"] == "generation_config.json")
        #expect(ModelGenerationDefaults(lseModelInfo: [:]) == nil)
        #expect(ConfigMemoryEstimator().generationDefaults(modelDirectory: model) == nil)
    }

    @Test func valuesAreClampedToWhatLSEAccepts() {
        var s = ModelLoadSettings(kvLength: 1_000_000, batchSize: 1000, ubatchSize: 4096, mtpDepth: 9,
                                  temperature: 3, topK: -4, topP: 1.5, minP: -1)
        s = s.clamped(maxContext: 262_144)
        #expect(s.kvLength == 262_144 && s.batchSize == 1024 && s.ubatchSize == 1024)
        #expect(s.mtpDepth == 7 && s.temperature == 2 && s.topP == 1 && s.topK == 0 && s.minP == 0)
        #expect(ModelLoadSettings(kvLength: 100).clamped(maxContext: 262_144).kvLength == 2048)
        #expect(ModelLoadSettings(kvLength: 100).clamped(maxContext: 1024).kvLength == 1024)

        let both = ModelLoadSettings(dflash2Enabled: true, mtpEnabled: true)
        #expect(!both.normalized(for: nil).mtpEnabled)
    }

    @Test func contextChoicesSnapToPowersOfTwoAndMultiplesOf1024() {
        let choices = ModelLoadSettings.contextLengthChoices(maxContext: 262_144)
        #expect(choices.first == 2048 && choices.last == 262_144)
        #expect(choices.allSatisfy { $0 % 1024 == 0 })
        #expect(zip(choices, choices.dropFirst()).allSatisfy { $0 < $1 })
        for shift in 11...18 { #expect(choices.contains(1 << shift)) }
        #expect(choices.count < 50)
        #expect(ModelLoadSettings.contextLengthChoices(maxContext: 40000).last == 40000)
    }

    @Test func decodingNeverFails() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ModelLoadSettings.self, from: Data("{}".utf8)) == ModelLoadSettings())
        let odd = #"{"kvCacheDType":"int3","kvLength":"long","batchSize":512,"topP":0.8}"#
        let s = try decoder.decode(ModelLoadSettings.self, from: Data(odd.utf8))
        #expect(s.kvCacheDType == .bf16 && s.kvLength == 32768 && s.batchSize == 512 && s.topP == 0.8)
        let custom = ModelLoadSettings(kvCacheDType: .bf8, kvLength: 8192, draftID: "d", topK: 40, topP: 0.5)
        #expect(try decoder.decode(ModelLoadSettings.self, from: JSONEncoder().encode(custom)) == custom)
    }
}

@Suite("Load settings in the registry")
struct LoadSettingsRegistryTests {
    /// registry.json as written before load settings existed.
    static let oldRegistry = """
    {
      "models" : [
        {
          "addedAt" : "2026-09-01T10:00:00Z",
          "directoryName" : "old-q4",
          "files" : [ { "completedChunks" : [], "path" : "config.json", "size" : 2, "verification" : "unverified" } ],
          "id" : "old-q4",
          "linkedDraftID" : "old-draft",
          "name" : "Old Q4",
          "origin" : "preplaced",
          "role" : "main",
          "state" : { "installed" : {} }
        },
        {
          "addedAt" : "2026-09-01T10:00:00Z",
          "directoryName" : "odd",
          "files" : [],
          "id" : "odd",
          "loadSettings" : { "kvCacheDType" : 7, "kvLength" : 4096 },
          "name" : "Odd",
          "origin" : "preplaced",
          "role" : "main",
          "state" : { "installed" : {} }
        }
      ],
      "version" : 1
    }
    """

    @Test func anOldRegistryLoadsAndSettingsRoundTrip() async throws {
        let scratch = try Scratch()
        let location = scratch.location
        try location.prepare()
        try FileManager.default.createDirectory(at: location.supportRoot, withIntermediateDirectories: true)
        try Data(Self.oldRegistry.utf8).write(to: location.registryURL)

        let registry = ModelRegistry(location: location)
        #expect(await registry.all().map(\.id) == ["old-q4", "odd"])
        #expect(await registry.record("old-q4")?.loadSettings == nil)
        // A malformed field takes its default instead of losing the registry.
        #expect(await registry.record("odd")?.loadSettings?.kvLength == 4096)
        #expect(await registry.record("odd")?.loadSettings?.kvCacheDType == .bf16)
        // No settings stored: the defaults. The linked draft is not installed, so no DFlash2.
        let defaults = await registry.loadSettings(for: "old-q4")
        #expect(!defaults.dflash2Enabled && defaults.kvLength == 32768 && defaults.kvCacheDType == .bf16)

        let chosen = ModelLoadSettings(kvCacheDType: .fp8, kvLength: 131_072, dflash2Enabled: false, temperature: 0.8)
        try await registry.setLoadSettings(chosen, for: "old-q4")
        let reloaded = ModelRegistry(location: location)
        #expect(await reloaded.record("old-q4")?.loadSettings == chosen)
        #expect(await reloaded.loadSettings(for: "old-q4") == chosen)
        #expect(await reloaded.record("old-q4")?.linkedDraftID == "old-draft")
        let json = try String(contentsOf: location.registryURL, encoding: .utf8)
        #expect(json.contains("\"loadSettings\"") && json.contains("\"fp8\""))

        // Choosing a draft links it; unlinking turns DFlash2 off in the stored settings.
        try await reloaded.setLoadSettings(ModelLoadSettings(draftID: "other-draft"), for: "old-q4")
        #expect(await reloaded.record("old-q4")?.linkedDraftID == "other-draft")
        try await reloaded.link(main: "old-q4", draft: nil)
        #expect(await reloaded.record("old-q4")?.loadSettings?.dflash2Enabled == false)
        try await reloaded.setLoadSettings(nil, for: "old-q4")
        #expect(await reloaded.record("old-q4")?.loadSettings == nil)
    }

    @Test func libraryLaunchesWithStoredSettings() async throws {
        let scratch = try Scratch()
        let location = scratch.location
        try location.prepare()
        let mainFiles = ["config.json": try Fixtures.data("configs/qwen38-27b-q4.config.json"),
                         "model.safetensors": testBytes(64, seed: 3)]
        let draftFiles = ["config.json": try Fixtures.data("configs/qwen38-27b-dflash2-q8.config.json"),
                          "model.safetensors": testBytes(32, seed: 4)]
        let catalog = smallCatalog(mainFiles: mainFiles, draftFiles: draftFiles)
        try place(mainFiles, in: location.directory(for: "tiny-q4"))
        try place(draftFiles, in: location.directory(for: "tiny-draft"))
        let library = await ModelLibrary(catalog: catalog, location: location,
                                         downloads: DownloaderConfiguration(session: .foreground),
                                         tokenStore: HubTokenStore(service: "studiomodels-tests-\(UUID())"))
        await library.start()
        let q4 = location.directory(for: "tiny-q4").path, draft = location.directory(for: "tiny-draft").path

        // Nothing stored: the preset with the linked draft, exactly as before.
        let defaults = await library.loadSettings(for: "tiny-q4")
        #expect(defaults == ModelLoadSettings(draftID: "tiny-draft"))
        #expect(await library.launchArguments(for: "tiny-q4")
                == LSELaunchPreset.standard.arguments(model: URL(fileURLWithPath: q4),
                                                      dflash2Draft: URL(fileURLWithPath: draft)))
        #expect(await library.configSummary(for: "tiny-q4")?.maxContext == 262_144)
        #expect(await library.compatibleDrafts(for: "tiny-q4").map(\.id) == ["tiny-draft"])

        var custom = defaults
        custom.kvCacheDType = .fp8
        custom.kvLength = 1_000_000 // clamped to the model's 262144
        custom.ubatchSize = 512
        #expect(await library.setLoadSettings(custom, for: "tiny-q4"))
        let args = try #require(await library.launchArguments(for: "tiny-q4"))
        #expect(args.prefix(5) == ["--model", q4, "--dflash2=on", "--dflash2-model", draft])
        #expect(args.joined(separator: " ").contains("--kv-cache-dtype fp8 --kv-len 262144"))
        #expect(args.joined(separator: " ").contains("--ubatch-size 512"))

        custom.dflash2Enabled = false
        await library.setLoadSettings(custom, for: "tiny-q4")
        #expect(await library.launchArguments(for: "tiny-q4")?.contains("--dflash2=on") == false)
        let config = try #require(await library.launchConfiguration(for: "tiny-q4"))
        #expect(config.kvCacheDType == "fp8" && config.dflash2Model == nil)

        await library.setLoadSettings(nil, for: "tiny-q4")
        #expect(await library.loadSettings(for: "tiny-q4") == defaults)
    }
}

@Suite("Memory estimate from config.json")
struct MemoryEstimateTests {
    let estimator = ConfigMemoryEstimator()
    let gib: UInt64 = 1 << 30

    func q4(_ scratch: Scratch) throws -> URL {
        try fixtureModel("qwen38-27b-q4.config.json", in: scratch.url.appending(path: "q4"),
                         shards: ["model-00001-of-00002.safetensors": 9 * gib,
                                  "model-00002-of-00002.safetensors": 7 * gib])
    }

    @Test func theConfigSummaryFollowsTheHybridLayout() throws {
        let q4 = try #require(ModelConfigSummary(config: Fixtures.data("configs/qwen38-27b-q4.config.json")))
        #expect(q4.kind == .main && q4.maxContext == 262_144)
        #expect(q4.numLayers == 64 && q4.fullAttentionLayers == 16 && q4.linearAttentionLayers == 48)
        #expect(q4.numKeyValueHeads == 4 && q4.headDim == 256 && q4.hiddenSize == 5120 && q4.vocabSize == 248_320)
        #expect(q4.ropeDim == 64 && q4.hasMTP)

        let mtp = try #require(ModelConfigSummary(config: Fixtures.data("configs/qwen38-27b-mtp-q8.config.json")))
        #expect(mtp.kind == .mtpModule && mtp.hasMTP && mtp.mtpLayers == 1 && mtp.maxContext == 262_144)

        let draft = try #require(ModelConfigSummary(config: Fixtures.data("configs/qwen38-27b-dflash2-q8.config.json")))
        #expect(draft.kind == .dflash2Draft && !draft.hasMTP && draft.fullAttentionLayers == 0)
        #expect(draft.slidingAttentionLayers == 5 && draft.slidingWindow == 2048 && draft.draftBlockSize == 8)
        #expect(draft.draftTargetLayers == 5 && draft.maxContext == 262_144)

        // Without layer_types, LSE's interval rule gives the same split.
        var object = try JSONSerialization.jsonObject(with: Fixtures.data("configs/qwen38-27b-q4.config.json")) as! [String: Any]
        var text = object["text_config"] as! [String: Any]
        text["layer_types"] = nil
        object["text_config"] = text
        let byInterval = try #require(ModelConfigSummary(config: JSONSerialization.data(withJSONObject: object)))
        #expect(byInterval.fullAttentionLayers == 16 && byInterval.linearAttentionLayers == 48)
    }

    @Test func kvScalesWithContextAndHalvesAtFP8() throws {
        let scratch = try Scratch()
        let dir = try q4(scratch)
        func kv(_ length: Int, _ dtype: ModelLoadSettings.KVCacheDType = .bf16) throws -> UInt64 {
            try estimator.estimate(modelDirectory: dir, draftDirectory: nil,
                                   settings: ModelLoadSettings(kvCacheDType: dtype, kvLength: length)).kvCacheBytes
        }
        // 48 DeltaNet layers: 48 × (48 × 128 × 128 + 3 × 10240) × 4 bytes, whatever the context.
        let perLayer: Int = 48 * 128 * 128 + 3 * 10240
        let state = UInt64(48 * perLayer * 4)
        // 16 full-attention layers × K and V × 4 heads × 256 × 2 bytes × 32768 = 2 GiB.
        #expect(try kv(32768) - state == 2 * gib)
        #expect(try kv(65536) - state == 2 * (kv(32768) - state))
        #expect(try kv(131_072) - kv(98304) == kv(65536) - kv(32768))
        // FP8 stores 256 code bytes plus a 4-byte scale per head vector.
        let ratio = Double(try kv(32768, .fp8) - state) / Double(try kv(32768) - state)
        #expect(ratio == 260.0 / 512.0)
        #expect(abs(ratio - 0.5) < 0.01)
        #expect(try kv(32768, .fp16) == kv(32768) && kv(32768, .fp32) - state == 4 * gib)
        #expect(try kv(32768, .bf8) == kv(32768, .fp8))
        // Clamped to the model's context.
        #expect(try kv(10_000_000) == kv(262_144))
    }

    @Test func weightsComeFromTheShardsOnDisk() throws {
        let scratch = try Scratch()
        let dir = try q4(scratch)
        // Neither the LSE conversion cache nor an unused MTP module counts.
        try sparseFile(dir.appending(path: "lse-q8g64/model.safetensors"), size: gib)
        let estimate = try estimator.estimate(modelDirectory: dir, draftDirectory: nil, settings: ModelLoadSettings())
        #expect(estimate.weightsBytes == 16 * gib && estimate.draftBytes == 0)
        #expect(estimate.isApproximate && estimate.source == "config.json estimate (fallback until lse_model_info)")
        #expect(estimate.totalBytes == estimate.weightsBytes + estimate.kvCacheBytes + estimate.draftBytes
                + estimate.workspaceBytes)
        #expect(estimate.workspaceBytes > ConfigMemoryEstimator.runtimeReserveBytes)

        // A real header: the vision tower LSE skips is left out.
        var header = Data(#"{"language_model.a":{"dtype":"BF16","shape":[4],"data_offsets":[0,8]},"vision_tower.b":{"dtype":"BF16","shape":[8],"data_offsets":[8,24]},"__metadata__":{"format":"mlx"}}"#.utf8)
        while header.count % 8 != 0 { header.append(0x20) }
        var file = withUnsafeBytes(of: UInt64(header.count).littleEndian) { Data($0) }
        file += header + Data(count: 24)
        let small = scratch.url.appending(path: "small.safetensors")
        try file.write(to: small)
        #expect(ConfigMemoryEstimator.loadedTensorBytes(small) == 8)
    }

    @Test func theDraftIsSizedAsLSELoadsIt() throws {
        let scratch = try Scratch()
        let dir = try q4(scratch)
        let bf16 = try fixtureModel("qwen38-27b-dflash2-bf16.config.json", in: scratch.url.appending(path: "bf16"),
                                    shards: ["model.safetensors": 3_849_000_000])
        let q8 = try fixtureModel("qwen38-27b-dflash2-q8.config.json", in: scratch.url.appending(path: "q8"),
                                  shards: ["model.safetensors": 2_044_950_184])
        let settings = ModelLoadSettings()
        let fromSource = try estimator.estimate(modelDirectory: dir, draftDirectory: bf16, settings: settings)
        let fromQ8 = try estimator.estimate(modelDirectory: dir, draftDirectory: q8, settings: settings)
        // The BF16 source is converted to Q8 group-64 before it loads.
        #expect(ConfigMemoryEstimator.draftWeightBytes(bf16) == UInt64(3_849_000_000 * 0.53125))
        #expect(ConfigMemoryEstimator.draftWeightBytes(q8) == 2_044_950_184)
        try sparseFile(bf16.appending(path: "lse-q8g64/model.safetensors"), size: 2_044_950_184)
        #expect(ConfigMemoryEstimator.draftWeightBytes(bf16) == 2_044_950_184)
        // Weights plus a bounded sliding-window cache, RoPE and the feature pass.
        let tokens: Int = 2047 + 8
        let window = UInt64(2 * 5 * 8 * 128 * tokens * 4)
        #expect(fromQ8.draftBytes > 2_044_950_184 + window)
        #expect(fromQ8.draftBytes < 2_044_950_184 + 300 << 20)
        // Only the weights differ: the converted size against the shipped Q8's.
        #expect(fromQ8.draftBytes - fromSource.draftBytes == 2_044_950_184 - UInt64(3_849_000_000 * 0.53125))
        // Off, or no draft: nothing.
        var off = settings
        off.dflash2Enabled = false
        #expect(try estimator.estimate(modelDirectory: dir, draftDirectory: q8, settings: off).draftBytes == 0)
    }

    @Test func mtpCountsOnlyWhenItRuns() throws {
        let scratch = try Scratch()
        let dir = try q4(scratch)
        _ = try fixtureModel("qwen38-27b-mtp-q8.config.json", in: dir.appending(path: "mtp"),
                             shards: ["model.safetensors": 800 << 20])
        var settings = ModelLoadSettings(dflash2Enabled: false, mtpEnabled: true)
        let on = try estimator.estimate(modelDirectory: dir, draftDirectory: nil, settings: settings)
        // Module weights plus one layer's K/V at kv_len: 2 × 4 × 512 × 32768.
        let mtpKV: Int = 2 * 4 * 512 * 32768
        #expect(on.draftBytes == UInt64(800 << 20) + UInt64(mtpKV))
        #expect(on.weightsBytes == 16 * gib)
        settings.mtpEnabled = false
        #expect(try estimator.estimate(modelDirectory: dir, draftDirectory: nil, settings: settings).draftBytes == 0)
    }

    @Test func theFitVerdict() throws {
        let e = ModelMemoryEstimate(weightsBytes: 16 * gib, kvCacheBytes: 2 * gib, draftBytes: 2 * gib,
                                    workspaceBytes: gib, isApproximate: true, source: "test")
        #expect(e.totalBytes == 21 * gib)
        #expect(e.fit(vramTotalBytes: nil) == .unknown)
        #expect(e.fit(vramTotalBytes: 32 * gib) == .fits)
        #expect(e.fit(vramTotalBytes: 23 * gib) == .tight)
        #expect(e.fit(vramTotalBytes: 21 * gib + gib / 2) == .wontFit)
        #expect(e.fit(vramTotalBytes: 16 * gib) == .wontFit)
    }

    @Test func aDirectoryWithoutAConfigIsAnError() throws {
        let scratch = try Scratch()
        #expect(throws: ModelMemoryEstimateError.self) {
            try estimator.estimate(modelDirectory: scratch.url, draftDirectory: nil, settings: ModelLoadSettings())
        }
    }
}
