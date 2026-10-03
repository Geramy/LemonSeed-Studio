// StudioTelemetry: recorded observer payloads.
//
// A fixture holds what a MacLinuxGPU observer answered on a real GPU: the
// sysfs files amdgpu_mtopg reads (once per second), raw GRBM_STATUS
// register values (AMDGPU_INFO_READ_MMR_REG, five per 100 ms), directory
// listings, and the cached-state selectors. Tools/capture_fixture.py and
// RecordingObserverConnection write this format; FixtureObserverConnection
// replays it.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import Foundation

public struct ObserverFixture: Codable, Sendable, Equatable {
    public static let schemaName = "lemonseed.observer-fixture"

    /// A file's payload as the observer returned it, or its Linux errno.
    public enum Entry: Codable, Sendable, Equatable {
        case text(String)
        case bytes([UInt8])
        case errno(Int32)

        public var payload: [UInt8]? {
            switch self {
            case .text(let s): return Array(s.utf8)
            case .bytes(let b): return b
            case .errno: return nil
            }
        }

        private enum Key: String, CodingKey { case text, hex, errno }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            if let text = try c.decodeIfPresent(String.self, forKey: .text) {
                self = .text(text)
            } else if let hex = try c.decodeIfPresent(String.self, forKey: .hex) {
                guard let bytes = [UInt8](hex: hex) else {
                    throw DecodingError.dataCorruptedError(forKey: .hex, in: c, debugDescription: "bad hex")
                }
                self = .bytes(bytes)
            } else {
                self = .errno(try c.decode(Int32.self, forKey: .errno))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            switch self {
            case .text(let s): try c.encode(s, forKey: .text)
            case .bytes(let b): try c.encode(b.hexString, forKey: .hex)
            case .errno(let e): try c.encode(e, forKey: .errno)
            }
        }
    }

    public struct SelectorReply: Codable, Sendable, Equatable {
        public var kr: UInt32
        public var words: [UInt64]
        public init(kr: UInt32, words: [UInt64]) { self.kr = kr; self.words = words }
    }

    public struct Selectors: Codable, Sendable, Equatable {
        public var runtimeBuild: SelectorReply?
        public var probeStatus: SelectorReply?
        public init(runtimeBuild: SelectorReply? = nil, probeStatus: SelectorReply? = nil) {
            self.runtimeBuild = runtimeBuild
            self.probeStatus = probeStatus
        }
    }

    public struct Frame: Codable, Sendable, Equatable {
        /// Seconds since the capture started.
        public var t: Double
        public var files: [String: Entry]
        public init(t: Double, files: [String: Entry]) { self.t = t; self.files = files }
    }

    public struct GRBM: Codable, Sendable, Equatable {
        /// The register offset the capture read (GC base + regGRBM_STATUS).
        public var offset: UInt32?
        /// [milliseconds since the capture started, GRBM_STATUS value].
        public var samples: [[Double]]
        public init(offset: UInt32?, samples: [[Double]]) { self.offset = offset; self.samples = samples }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var gpuBusyPercentMin: Int?
        public var gpuBusyPercentMax: Int?
        public var grbmActiveFraction: Double?
        public init() {}
    }

    public struct Capture: Codable, Sendable, Equatable {
        public var date: String?
        public var host: String?
        public var driver: String?
        public var runtimeBuild: UInt64?
        public var tool: String?
        public var durationSeconds: Double?
        public var stoppedEarly: String?
        public var summary: Summary?
        public init() {}
    }

    public struct Device: Codable, Sendable, Equatable {
        public var service: String
        public var registryID: UInt64
        public init(service: String, registryID: UInt64) { self.service = service; self.registryID = registryID }
    }

    public var schema: String
    public var version: Int
    public var name: String
    public var description: String
    public var capture: Capture
    public var device: Device
    public var selectors: Selectors
    public var listings: [String: String]
    public var `static`: [String: Entry]
    public var frames: [Frame]
    public var grbm: GRBM

    public init(name: String, description: String = "", capture: Capture = Capture(),
                device: Device, selectors: Selectors = Selectors(),
                listings: [String: String] = [:], static: [String: Entry] = [:],
                frames: [Frame] = [], grbm: GRBM = GRBM(offset: nil, samples: [])) {
        self.schema = Self.schemaName
        self.version = 1
        self.name = name
        self.description = description
        self.capture = capture
        self.device = device
        self.selectors = selectors
        self.listings = listings
        self.static = `static`
        self.frames = frames
        self.grbm = grbm
    }

    /// Length of the recording, in seconds.
    public var duration: Double {
        let lastFrame = (frames.last?.t ?? 0) + 1
        let lastGRBM = (grbm.samples.last?.first ?? 0) / 1000
        return max(capture.durationSeconds ?? 0, lastFrame, lastGRBM, 1)
    }

    // MARK: Loading

    public enum LoadError: Error, CustomStringConvertible {
        case notFound(String)
        case wrongSchema(String)

        public var description: String {
            switch self {
            case .notFound(let name): return "fixture \(name) not found"
            case .wrongSchema(let s): return "not an observer fixture (schema \(s))"
            }
        }
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ObserverFixture.self, from: data)
        guard schema == Self.schemaName else { throw LoadError.wrongSchema(schema) }
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// The fixtures shipped in this package, recorded from a real GPU.
    public static var bundledNames: [String] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    public static func bundled(_ name: String) throws -> ObserverFixture {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw LoadError.notFound(name)
        }
        return try ObserverFixture(contentsOf: url)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

extension [UInt8] {
    init?(hex: String) {
        let chars = Array(hex.utf8).filter { $0 != 0x20 && $0 != 0x0a }
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        self = out
    }

    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for b in self {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xf)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
