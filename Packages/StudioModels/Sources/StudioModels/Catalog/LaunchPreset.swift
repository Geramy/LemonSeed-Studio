// StudioModels: how LSE is launched for an installed model.
//
// The default preset is the configuration benchmarked in LSE for Qwen3.8-27B
// Q4 with the DFlash2 draft on an R9700:
//
//   --model <q4> --dflash2=on --dflash2-model <dflash2> --pool hrx:0
//   --dialect loom --kv-cache-dtype bf16 --kv-len 32768 --temperature 0.6
//   --batch-size 1024 --ubatch-size 1024
//
// The draft may be the BF16 source or the converted Q8 directory. LSE tells
// them apart from the checkpoint and converts the source once.

import Foundation

public struct LSELaunchPreset: Codable, Sendable, Hashable {
    public var pool: String
    public var dialect: String
    public var kvCacheDType: String
    public var kvLength: Int
    public var temperature: Double
    public var batchSize: Int
    public var ubatchSize: Int

    public init(pool: String = "hrx:0", dialect: String = "loom", kvCacheDType: String = "bf16",
                kvLength: Int = 32768, temperature: Double = 0.6, batchSize: Int = 1024,
                ubatchSize: Int = 1024) {
        self.pool = pool
        self.dialect = dialect
        self.kvCacheDType = kvCacheDType
        self.kvLength = kvLength
        self.temperature = temperature
        self.batchSize = batchSize
        self.ubatchSize = ubatchSize
    }

    public static let standard = LSELaunchPreset()

    /// The LSE command-line arguments, without the executable name. With no
    /// draft, DFlash2 is left off.
    public func arguments(model: URL, dflash2Draft: URL?) -> [String] {
        var args = ["--model", model.path]
        if let draft = dflash2Draft {
            args += ["--dflash2=on", "--dflash2-model", draft.path]
        }
        args += [
            "--pool", pool,
            "--dialect", dialect,
            "--kv-cache-dtype", kvCacheDType,
            "--kv-len", String(kvLength),
            "--temperature", Self.format(temperature),
            "--batch-size", String(batchSize),
            "--ubatch-size", String(ubatchSize),
            // No reply limit of its own: LSE's default cap (4096) would end a
            // reply before the context is full.
            "--max-tokens", String(kvLength),
        ]
        return args
    }

    /// The arguments as one shell-quoted line, for logs and copy/paste.
    public func commandLine(model: URL, dflash2Draft: URL?) -> String {
        arguments(model: model, dflash2Draft: dflash2Draft).map(Self.shellQuote).joined(separator: " ")
    }

    static func format(_ value: Double) -> String {
        var text = String(value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text
    }

    static func shellQuote(_ arg: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,@+")
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy(safe.contains) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
