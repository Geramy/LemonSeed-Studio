// StudioModels: how one model is loaded into LSE, chosen per model.
//
// Each field maps to one lse_config field (lse.h) and one lse-server flag:
//
//   kvCacheDType    kv_cache_dtype   --kv-cache-dtype fp32|fp16|bf16|fp8|bf8
//   kvLength        kv_len           --kv-len N (tokens the KV cache can hold)
//   batchSize       batch_size       --batch-size N (power of two, 128...4096)
//   ubatchSize      ubatch_size      --ubatch-size N (power of two, <= batch)
//   dflash2Enabled  dflash2          --dflash2=on
//   draftID         dflash2_model    --dflash2-model <the draft's directory>
//   mtpEnabled      no_mtp (negated) --no-mtp when off; LSE finds mtp/ itself
//   mtpDepth        mtp_depth        --mtp-depth N (1...7)
//   temperature     temperature      --temperature T (has_temperature = 1)
//   maxTokens       max_tokens       --max-tokens N (nil: the KV length, so a
//                                    reply runs until the context is full)
//   topP            (none)           sent per request as "top_p"
//
// LSE runs DFlash2 or MTP, never both: with DFlash2 on it ignores any MTP
// module. The defaults reproduce LSELaunchPreset.standard exactly.

import Foundation

public struct ModelLoadSettings: Codable, Sendable, Hashable {
    /// The K/V cache element type (kv::CacheDType in LSE).
    public enum KVCacheDType: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
        case fp32
        case fp16
        case bf16
        /// E4M3, packed four to a word with one FP32 scale per head vector.
        case fp8
        /// E5M2, packed like fp8.
        case bf8

        public var id: String { rawValue }

        public var label: String { rawValue.uppercased() }

        /// Whether LSE packs the cache as 8-bit codes plus a per-vector scale.
        public var isPacked: Bool { self == .fp8 || self == .bf8 }

        /// Bytes per element, ignoring the per-vector scale of the packed types.
        public var bytesPerElement: Int {
            switch self {
            case .fp32: 4
            case .fp16, .bf16: 2
            case .fp8, .bf8: 1
            }
        }

        /// Bytes one cached head vector of `width` elements occupies, as
        /// kv::storage_width lays it out: packed types store width/4 words of
        /// codes followed by one FP32 scale word.
        public func bytesPerVector(width: Int) -> Int {
            isPacked ? (width / 4 + 1) * 4 : width * bytesPerElement
        }
    }

    public var kvCacheDType: KVCacheDType
    /// Tokens the KV cache holds: the longest conversation the model can carry.
    public var kvLength: Int
    public var batchSize: Int
    public var ubatchSize: Int
    public var dflash2Enabled: Bool
    /// The registry id of the DFlash2 draft. Nil means the model's linked draft.
    public var draftID: String?
    /// Only meaningful for a model with MTP layers and an mtp/ module beside it.
    public var mtpEnabled: Bool
    public var mtpDepth: Int
    public var temperature: Double
    /// Nil leaves top-p to the model's generation config.
    public var topP: Double?
    /// The most tokens one reply may generate, reasoning included. Nil (the
    /// default) sets no limit of its own: a reply runs until the context is
    /// full.
    public var maxTokens: Int?

    public static let defaultKVLength = 32768
    public static let minimumKVLength = 2048
    /// What registries written before the limit became optional stored when
    /// nobody chose one (LSE's own --max-tokens default). Read back as nil.
    static let formerDefaultMaxTokens = 4096
    public static let defaultMTPDepth = 3
    public static let mtpDepthRange = 1...7
    public static let temperatureRange = 0.0...2.0
    /// The prefill sizes LSE accepts (runtime::PrefillBatch::valid_size).
    public static let batchSizeChoices = [128, 256, 512, 1024, 2048, 4096]

    public init(kvCacheDType: KVCacheDType = .bf16, kvLength: Int = ModelLoadSettings.defaultKVLength,
                batchSize: Int = 1024, ubatchSize: Int = 1024, dflash2Enabled: Bool = true,
                draftID: String? = nil, mtpEnabled: Bool = false, mtpDepth: Int = ModelLoadSettings.defaultMTPDepth,
                temperature: Double = 0.6, topP: Double? = nil, maxTokens: Int? = nil) {
        self.kvCacheDType = kvCacheDType
        self.kvLength = kvLength
        self.batchSize = batchSize
        self.ubatchSize = ubatchSize
        self.dflash2Enabled = dflash2Enabled
        self.draftID = draftID
        self.mtpEnabled = mtpEnabled
        self.mtpDepth = mtpDepth
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    /// The settings a launch preset describes: DFlash2 on, MTP off.
    public init(preset: LSELaunchPreset) {
        self.init(kvCacheDType: KVCacheDType(rawValue: preset.kvCacheDType) ?? .bf16, kvLength: preset.kvLength,
                  batchSize: preset.batchSize, ubatchSize: preset.ubatchSize, temperature: preset.temperature)
    }

    /// LSELaunchPreset.standard as settings.
    public static let standard = ModelLoadSettings(preset: .standard)

    /// Defaults for one installed model: the preset, DFlash2 when a draft is
    /// linked, and otherwise MTP when the model has a module (what LSE does on
    /// its own), with the context clamped to the model's.
    public static func defaults(preset: LSELaunchPreset = .standard, linkedDraftID: String?,
                                summary: ModelConfigSummary?, hasMTPModule: Bool) -> ModelLoadSettings {
        var settings = ModelLoadSettings(preset: preset)
        settings.dflash2Enabled = linkedDraftID != nil
        settings.draftID = linkedDraftID
        settings.mtpEnabled = linkedDraftID == nil && hasMTPModule && (summary?.hasMTP ?? true)
        return settings.normalized(for: summary)
    }

    // MARK: Decoding

    private enum CodingKeys: String, CodingKey {
        case kvCacheDType, kvLength, batchSize, ubatchSize, dflash2Enabled, draftID, mtpEnabled, mtpDepth,
             temperature, topP
        /// Written only when a limit is set.
        case maxTokens = "maxReplyTokens"
    }

    /// The key registries used while the limit was not optional.
    private enum LegacyKeys: String, CodingKey { case maxTokens }

    /// Never fails: a missing or unreadable field takes its default, so a
    /// registry written by another version always loads.
    public init(from decoder: any Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let v = try? c.decodeIfPresent(String.self, forKey: .kvCacheDType), let dtype = KVCacheDType(rawValue: v) {
            kvCacheDType = dtype
        }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .kvLength) { kvLength = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .batchSize) { batchSize = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .ubatchSize) { ubatchSize = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .dflash2Enabled) { dflash2Enabled = v }
        draftID = (try? c.decodeIfPresent(String.self, forKey: .draftID)) ?? nil
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mtpEnabled) { mtpEnabled = v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: .mtpDepth) { mtpDepth = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .temperature) { temperature = v }
        topP = (try? c.decodeIfPresent(Double.self, forKey: .topP)) ?? nil
        if let v = try? c.decodeIfPresent(Int.self, forKey: .maxTokens) {
            maxTokens = v
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let v = try? legacy.decodeIfPresent(Int.self, forKey: .maxTokens),
                  v != Self.formerDefaultMaxTokens {
            // The former default was written out like a choice; it means no limit.
            maxTokens = v
        }
    }

    // MARK: Validity

    /// Every value brought inside what LSE accepts: kv_len within
    /// 2048...max context (or the max context when it is smaller), batch
    /// sizes on the power-of-two ladder with ubatch <= batch, MTP depth 1...7,
    /// temperature 0...2, top-p 0...1, a reply limit (when set) of at least
    /// one token.
    public func clamped(maxContext: Int?) -> ModelLoadSettings {
        var s = self
        let upper = max(1, maxContext ?? Int.max)
        s.kvLength = min(max(s.kvLength, min(Self.minimumKVLength, upper)), upper)
        s.batchSize = Self.nearestBatchSize(s.batchSize)
        s.ubatchSize = min(Self.nearestBatchSize(s.ubatchSize), s.batchSize)
        s.mtpDepth = min(max(s.mtpDepth, Self.mtpDepthRange.lowerBound), Self.mtpDepthRange.upperBound)
        s.temperature = s.temperature.isFinite
            ? min(max(s.temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound) : 0.6
        if let p = s.topP { s.topP = p.isFinite ? min(max(p, 0), 1) : nil }
        if let limit = s.maxTokens { s.maxTokens = max(1, limit) }
        return s
    }

    /// Clamped to the model, with MTP off for a model that has none and off
    /// whenever DFlash2 is on (LSE would ignore it).
    public func normalized(for summary: ModelConfigSummary?) -> ModelLoadSettings {
        var s = clamped(maxContext: summary?.maxContext)
        if let summary, !summary.hasMTP { s.mtpEnabled = false }
        if s.dflash2Enabled && s.mtpEnabled { s.mtpEnabled = false }
        return s
    }

    static func nearestBatchSize(_ n: Int) -> Int {
        batchSizeChoices.min { abs($0 - n) < abs($1 - n) } ?? 1024
    }

    /// The context lengths the settings slider offers, from 2048 up to the
    /// model's maximum. All are multiples of 1024 and every power of two in
    /// range is included; steps widen as the values grow (1K to 8K, 2K to
    /// 32K, 8K to 128K, then 32K). The maximum itself is always the last.
    public static func contextLengthChoices(maxContext: Int?) -> [Int] {
        let upper = max(maxContext ?? 262_144, 1)
        guard upper > minimumKVLength else { return [upper] }
        var values: [Int] = []
        var v = minimumKVLength
        while v <= upper {
            values.append(v)
            v += v < 8192 ? 1024 : v < 32768 ? 2048 : v < 131_072 ? 8192 : 32768
        }
        if values.last != upper { values.append(upper) }
        return values
    }
}

// MARK: - Launching

/// One LSE launch, resolved: the fields of lse_config the app sets, and the
/// equivalent lse-server arguments.
public struct LSELaunchConfiguration: Sendable, Hashable {
    /// lse_config.model.
    public var model: URL
    /// lse_config.dflash2 is set when this is not nil; it is dflash2_model.
    public var dflash2Model: URL?
    /// lse_config.no_mtp.
    public var noMTP: Bool
    /// lse_config.mtp_depth.
    public var mtpDepth: Int
    /// Whether LSE will run the model's MTP module (found in mtp/ beside it).
    public var usesMTP: Bool
    /// lse_config.kv_cache_dtype.
    public var kvCacheDType: String
    /// lse_config.kv_len.
    public var kvLength: Int
    /// lse_config.batch_size and ubatch_size.
    public var batchSize: Int
    public var ubatchSize: Int
    /// lse_config.temperature, with has_temperature = 1.
    public var temperature: Double
    /// lse_config.max_tokens, LSE's per-request cap: the reply limit when one
    /// is set, otherwise the KV length (a reply can never outgrow the context).
    public var maxTokens: Int
    /// Not an lse_config field: send it as "top_p" in each request.
    public var topP: Double?
    /// lse_config.pool and dialect.
    public var pool: String
    public var dialect: String

    public var dflash2: Bool { dflash2Model != nil }

    /// Resolves settings for a model. `dflash2Draft` is the draft directory
    /// to run (nil: no DFlash2); `mtpModule` the model's mtp/ directory when
    /// one is installed.
    public init(model: URL, settings: ModelLoadSettings, dflash2Draft: URL?, mtpModule: URL?,
                pool: String = LSELaunchPreset.standard.pool, dialect: String = LSELaunchPreset.standard.dialect) {
        self.model = model
        dflash2Model = settings.dflash2Enabled ? dflash2Draft : nil
        usesMTP = dflash2Model == nil && settings.mtpEnabled && mtpModule != nil
        noMTP = dflash2Model == nil && !usesMTP && mtpModule != nil
        mtpDepth = settings.mtpDepth
        kvCacheDType = settings.kvCacheDType.rawValue
        kvLength = settings.kvLength
        batchSize = settings.batchSize
        ubatchSize = settings.ubatchSize
        temperature = settings.temperature
        maxTokens = settings.maxTokens ?? settings.kvLength
        topP = settings.topP
        self.pool = pool
        self.dialect = dialect
    }

    /// The lse-server arguments, without the executable. The standard
    /// settings give exactly LSELaunchPreset.standard's arguments; the MTP
    /// depth is omitted at LSE's own default (3). --max-tokens is always
    /// given: LSE's default (4096) would cap a reply below the context.
    public var arguments: [String] {
        var args = ["--model", model.path]
        if let draft = dflash2Model {
            args += ["--dflash2=on", "--dflash2-model", draft.path]
        }
        args += [
            "--pool", pool,
            "--dialect", dialect,
            "--kv-cache-dtype", kvCacheDType,
            "--kv-len", String(kvLength),
            "--temperature", LSELaunchPreset.format(temperature),
            "--batch-size", String(batchSize),
            "--ubatch-size", String(ubatchSize),
        ]
        if usesMTP && mtpDepth != ModelLoadSettings.defaultMTPDepth { args += ["--mtp-depth", String(mtpDepth)] }
        if noMTP { args.append("--no-mtp") }
        args += ["--max-tokens", String(maxTokens)]
        return args
    }

    /// The arguments as one shell-quoted line, for logs and copy/paste.
    public var commandLine: String { arguments.map(LSELaunchPreset.shellQuote).joined(separator: " ") }
}

extension LSELaunchPreset {
    /// A launch with per-model settings, on this preset's pool and dialect.
    public func configuration(model: URL, settings: ModelLoadSettings, dflash2Draft: URL?,
                              mtpModule: URL?) -> LSELaunchConfiguration {
        LSELaunchConfiguration(model: model, settings: settings, dflash2Draft: dflash2Draft, mtpModule: mtpModule,
                               pool: pool, dialect: dialect)
    }
}
