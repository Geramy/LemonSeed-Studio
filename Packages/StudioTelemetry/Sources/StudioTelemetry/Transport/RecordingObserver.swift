// StudioTelemetry: recording a live observer into a fixture.
//
// RecordingObserverConnection passes every call to the connection it wraps
// (normally IOKitObserverConnection) unchanged and keeps what came back:
// whole sysfs files (reassembled from SysfsRead chunks), listings, GRBM_STATUS
// values from DrmInfo READ_MMR_REG, and the cached-state selectors. A new
// frame starts when a file of the current frame is read again, which is how
// the transport's once-a-second refresh looks from below.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import Foundation
import Synchronization

/// Accumulates observer replies into an ObserverFixture. Thread-safe, so the
/// fixture can be taken from any thread while the telemetry queue records.
public final class FixtureRecorder: Sendable {
    private struct State {
        var selectors = ObserverFixture.Selectors()
        var listings: [String: String] = [:]
        var staticFiles: [String: ObserverFixture.Entry] = [:]
        var frames: [ObserverFixture.Frame] = []
        var current: ObserverFixture.Frame?
        var partial: [String: [UInt8]] = [:]
        var grbmOffset: UInt32?
        var grbm: [[Double]] = []
        var startNs: UInt64?
    }

    private let state = Mutex(State())
    private let clock: NanosecondClock
    public let name: String
    public let registryID: UInt64

    public init(name: String, registryID: UInt64, clock: @escaping NanosecondClock = uptimeNanoseconds) {
        self.name = name
        self.registryID = registryID
        self.clock = clock
    }

    /// Files read once per session (discovery) rather than every refresh.
    static func isStatic(_ path: String) -> Bool { path.hasPrefix("ip_discovery/") }

    func record(selector: UInt32, scalars: [UInt64], input: [UInt8]?, reply: ObserverReply) {
        let now = clock()
        state.withLock { s in
            let start = s.startNs ?? now
            s.startNs = start
            let seconds = Double(now &- start) / 1e9
            switch selector {
            case LinuxABI.selRuntimeBuild where reply.status == 0:
                s.selectors.runtimeBuild = .init(kr: 0, words: reply.words)
            case LinuxABI.selQuery where reply.status == 0 && scalars.first == LinuxABI.tagProbeStatus:
                s.selectors.probeStatus = .init(kr: 0, words: reply.words)
            case LinuxABI.selSysfsRead where reply.status == 0 && reply.words.count == 3 && scalars.count == 2:
                Self.recordSysfs(&s, op: scalars[0], offset: Int(scalars[1]), input: input, reply: reply, at: seconds)
            case LinuxABI.selDrmInfo where reply.status == 0 && reply.words.first == 0
                && scalars.first == LinuxABI.infoReadMMRReg && reply.bytes.count == 4:
                let args = input ?? []
                if args.count >= 4 {
                    s.grbmOffset = UInt32(args[0]) | UInt32(args[1]) << 8 | UInt32(args[2]) << 16 | UInt32(args[3]) << 24
                }
                let b = reply.bytes
                let value = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                s.grbm.append([(seconds * 10_000).rounded() / 10, Double(value)])
            default:
                break
            }
        }
    }

    private static func recordSysfs(_ s: inout State, op: UInt64, offset: Int, input: [UInt8]?,
                                    reply: ObserverReply, at seconds: Double) {
        var name = input ?? []
        if name.last == 0 { name.removeLast() }
        let path = String(decoding: name, as: UTF8.self)
        let key = (op == LinuxABI.opList ? "list:" : "read:") + path
        let status = Int64(bitPattern: reply.words[0])
        if status != 0 {
            s.partial[key] = nil
            if op == LinuxABI.opRead { store(&s, path: path, entry: .errno(Int32(clamping: -status)), at: seconds) }
            return
        }
        var data = offset == 0 ? [] : (s.partial[key] ?? [])
        guard data.count == offset else { s.partial[key] = nil; return }
        data += reply.bytes
        let length = Int(min(reply.words[2], UInt64(Int.max)))
        guard reply.bytes.isEmpty || data.count >= length else {
            s.partial[key] = data
            return
        }
        s.partial[key] = nil
        if op == LinuxABI.opList {
            s.listings[path] = String(decoding: data, as: UTF8.self)
        } else if path.hasSuffix("gpu_metrics") {
            store(&s, path: path, entry: .bytes(data), at: seconds)
        } else if let text = String(validating: data, as: UTF8.self) {
            store(&s, path: path, entry: .text(text), at: seconds)
        } else {
            store(&s, path: path, entry: .bytes(data), at: seconds)
        }
    }

    private static func store(_ s: inout State, path: String, entry: ObserverFixture.Entry, at seconds: Double) {
        if isStatic(path) {
            s.staticFiles[path] = entry
            return
        }
        if s.current == nil || s.current?.files[path] != nil {
            if let done = s.current { s.frames.append(done) }
            s.current = ObserverFixture.Frame(t: (seconds * 1000).rounded() / 1000, files: [:])
        }
        s.current?.files[path] = entry
    }

    /// Everything recorded so far.
    public func fixture(description: String = "") -> ObserverFixture {
        state.withLock { s in
            var frames = s.frames
            if let current = s.current { frames.append(current) }
            let duration = s.startNs.map { Double(clock() &- $0) / 1e9 }
            var capture = ObserverFixture.Capture()
            capture.date = ISO8601DateFormatter().string(from: Date())
            capture.driver = "mac_linuxgpu"
            capture.runtimeBuild = s.selectors.runtimeBuild?.words.count == 4 ? s.selectors.runtimeBuild?.words[3] : nil
            capture.tool = "StudioTelemetry RecordingObserverConnection"
            capture.durationSeconds = duration
            return ObserverFixture(name: name, description: description, capture: capture,
                                   device: .init(service: LinuxABI.serviceName, registryID: registryID),
                                   selectors: s.selectors, listings: s.listings, static: s.staticFiles,
                                   frames: frames, grbm: .init(offset: s.grbmOffset, samples: s.grbm))
        }
    }
}

/// Wraps an observer connection and records its replies.
public final class RecordingObserverConnection: ObserverConnection {
    public let wrapped: any ObserverConnection
    public let recorder: FixtureRecorder

    public init(wrapping connection: any ObserverConnection, recorder: FixtureRecorder) {
        self.wrapped = connection
        self.recorder = recorder
    }

    public func call(selector: UInt32, scalars: [UInt64], input: [UInt8]?,
                     outputWords: Int, outputBytes: Int) -> ObserverReply {
        let reply = wrapped.call(selector: selector, scalars: scalars, input: input,
                                 outputWords: outputWords, outputBytes: outputBytes)
        recorder.record(selector: selector, scalars: scalars, input: input, reply: reply)
        return reply
    }

    public func close() { wrapped.close() }
}

/// A directory whose observers record into one FixtureRecorder per device.
public final class RecordingObserverDirectory: ObserverDirectory {
    public let wrapped: any ObserverDirectory
    public let name: String
    private let recorders = Mutex<[UInt64: FixtureRecorder]>([:])

    public init(wrapping directory: any ObserverDirectory, name: String) {
        self.wrapped = directory
        self.name = name
    }

    public var sourceName: String { wrapped.sourceName + " (recording)" }

    public func devices() -> [ObserverDevice] { wrapped.devices() }

    public func openObserver(registryID: UInt64) throws -> any ObserverConnection {
        let connection = try wrapped.openObserver(registryID: registryID)
        let recorder = recorders.withLock { map in
            if let r = map[registryID] { return r }
            let r = FixtureRecorder(name: name, registryID: registryID)
            map[registryID] = r
            return r
        }
        return RecordingObserverConnection(wrapping: connection, recorder: recorder)
    }

    public func recorder(for registryID: UInt64) -> FixtureRecorder? {
        recorders.withLock { $0[registryID] }
    }
}
