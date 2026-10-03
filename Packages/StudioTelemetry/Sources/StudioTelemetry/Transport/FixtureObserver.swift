// StudioTelemetry: replaying a recorded observer.
//
// FixtureObserverConnection answers the observer selectors from a fixture
// recorded on a real GPU, with the dext's own reply shapes: SysfsRead in
// chunks with errno/count/length words, DrmInfo READ_MMR_REG with the
// recorded GRBM_STATUS values, NotReady when the upstream driver is not
// running. The transport and model above it cannot tell it from IOKit.
//
// Time: the recording plays at real speed and ping-pongs (forward, then
// backward) so the loop has no jump. Every value shown is one the GPU
// produced; nothing is synthesized or smoothed.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import Foundation

/// What a fixture directory pretends the device is doing.
public enum FixtureScenario: String, Sendable, CaseIterable {
    /// The recording plays.
    case live
    /// The upstream driver is not running in a session: reads return NotReady.
    case notRunning
    /// A dext without the observer Linux reads: SysfsRead is NotPermitted.
    case predatesObserverReads
    /// No MacLinuxGPU service: no GPU bound to the driver.
    case noDevice
}

/// Monotonic nanoseconds; injectable for tests.
public typealias NanosecondClock = @Sendable () -> UInt64

public let uptimeNanoseconds: NanosecondClock = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

public struct FixtureObserverDirectory: ObserverDirectory {
    public let fixture: ObserverFixture
    public let scenario: FixtureScenario
    public let speed: Double
    public let clock: NanosecondClock

    public init(fixture: ObserverFixture, scenario: FixtureScenario = .live,
                speed: Double = 1, clock: @escaping NanosecondClock = uptimeNanoseconds) {
        self.fixture = fixture
        self.scenario = scenario
        self.speed = speed
        self.clock = clock
    }

    public var sourceName: String { "recorded fixture \(fixture.name)" }

    public var sourceDetails: [LabeledText] {
        let c = fixture.capture
        var rows = [LabeledText(label: "fixture", text: fixture.name)]
        if !fixture.description.isEmpty { rows.append(LabeledText(label: "recorded", text: fixture.description)) }
        if let date = c.date { rows.append(LabeledText(label: "captured", text: date)) }
        if let host = c.host { rows.append(LabeledText(label: "host", text: host)) }
        if let build = c.runtimeBuild { rows.append(LabeledText(label: "driver", text: "\(c.driver ?? "mac_linuxgpu") build \(build)")) }
        rows.append(LabeledText(label: "replay", text: String(format: "%.0f s, real time, forward then backward", fixture.duration)))
        if scenario != .live { rows.append(LabeledText(label: "scenario", text: scenario.rawValue)) }
        return rows
    }

    public func devices() -> [ObserverDevice] {
        guard scenario != .noDevice else { return [] }
        let id = fixture.device.registryID
        return [ObserverDevice(registryID: id, label: "0x" + String(id, radix: 16))]
    }

    public func openObserver(registryID: UInt64) throws -> any ObserverConnection {
        guard scenario != .noDevice, registryID == fixture.device.registryID else {
            throw ObserverError.noSuchDevice(registryID)
        }
        return FixtureObserverConnection(fixture: fixture, scenario: scenario, speed: speed, clock: clock)
    }
}

public final class FixtureObserverConnection: ObserverConnection {
    public let fixture: ObserverFixture
    public let scenario: FixtureScenario
    private let speed: Double
    private let clock: NanosecondClock
    private let startNs: UInt64
    private let frames: [ObserverFixture.Frame]
    private let grbmTimes: [Double]
    private let grbmValues: [UInt32]
    private var lastGRBMIndex: Int?
    private var closed = false

    public init(fixture: ObserverFixture, scenario: FixtureScenario = .live, speed: Double = 1,
                clock: @escaping NanosecondClock = uptimeNanoseconds) {
        self.fixture = fixture
        self.scenario = scenario
        self.speed = speed
        self.clock = clock
        self.startNs = clock()
        self.frames = fixture.frames.sorted { $0.t < $1.t }
        let samples = fixture.grbm.samples.filter { $0.count == 2 }.sorted { $0[0] < $1[0] }
        self.grbmTimes = samples.map { $0[0] }
        self.grbmValues = samples.map { UInt32(clamping: Int64($0[1])) }
    }

    /// Seconds into the recording, ping-ponging over its length.
    public var position: Double {
        let elapsed = Double(clock() &- startNs) / 1e9 * speed
        let d = fixture.duration
        let phase = elapsed.truncatingRemainder(dividingBy: 2 * d)
        return phase <= d ? phase : 2 * d - phase
    }

    private var playingBackward: Bool {
        let elapsed = Double(clock() &- startNs) / 1e9 * speed
        return elapsed.truncatingRemainder(dividingBy: 2 * fixture.duration) > fixture.duration
    }

    /// The frame recorded at or before `t`.
    func frame(at t: Double) -> ObserverFixture.Frame? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        if frames[0].t > t { return frames[0] }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return frames[lo]
    }

    public func call(selector: UInt32, scalars: [UInt64], input: [UInt8]?,
                     outputWords: Int, outputBytes: Int) -> ObserverReply {
        guard !closed else { return ObserverReply(status: IOReturnValue.notAttached) }
        switch selector {
        case LinuxABI.selRuntimeBuild:
            return selectorReply(fixture.selectors.runtimeBuild, outputWords: outputWords)
        case LinuxABI.selQuery:
            guard scalars.first == LinuxABI.tagProbeStatus else {
                return ObserverReply(status: IOReturnValue.unsupported)
            }
            if scenario == .notRunning {
                // Probe status of a dext whose upstream driver is not running.
                return ObserverReply(status: IOReturnValue.success,
                                     words: Array([1, 0, 0, 0, 0].prefix(outputWords)))
            }
            return selectorReply(fixture.selectors.probeStatus, outputWords: outputWords)
        case LinuxABI.selSysfsRead:
            return sysfsRead(scalars: scalars, input: input, outputBytes: outputBytes)
        case LinuxABI.selDrmInfo:
            return drmInfo(scalars: scalars, input: input, outputBytes: outputBytes)
        default:
            return ObserverReply(status: IOReturnValue.notPermitted)
        }
    }

    public func close() { closed = true }

    private func selectorReply(_ reply: ObserverFixture.SelectorReply?, outputWords: Int) -> ObserverReply {
        guard let reply else { return ObserverReply(status: IOReturnValue.unsupported) }
        return ObserverReply(status: IOReturnCode(bitPattern: reply.kr), words: Array(reply.words.prefix(outputWords)))
    }

    private func gate() -> IOReturnCode? {
        switch scenario {
        case .notRunning: return IOReturnValue.notReady
        case .predatesObserverReads: return IOReturnValue.notPermitted
        case .noDevice: return IOReturnValue.notAttached
        case .live: return nil
        }
    }

    private static func errnoWord(_ e: Int32) -> UInt64 { UInt64(bitPattern: Int64(-e)) }

    private func sysfsRead(scalars: [UInt64], input: [UInt8]?, outputBytes: Int) -> ObserverReply {
        if let kr = gate() { return ObserverReply(status: kr) }
        guard scalars.count == 2, scalars[0] == LinuxABI.opRead || scalars[0] == LinuxABI.opList else {
            return ObserverReply(status: IOReturnValue.badArgument)
        }
        var name = input ?? []
        if name.last == 0 { name.removeLast() }
        guard name.count <= LinuxABI.pathMax else { return ObserverReply(status: IOReturnValue.badArgument) }
        let path = String(decoding: name, as: UTF8.self)
        let entry: ObserverFixture.Entry
        if scalars[0] == LinuxABI.opList {
            if let listing = fixture.listings[path] {
                entry = .text(listing)
            } else {
                entry = .errno(lookup(path) == nil ? ENOENT : ENOTDIR)
            }
        } else if let found = lookup(path) {
            entry = found
        } else {
            entry = .errno(fixture.listings[path] != nil ? EISDIR : ENOENT)
        }
        guard let payload = entry.payload else {
            if case .errno(let e) = entry { return ObserverReply(status: 0, words: [Self.errnoWord(e), 0, 0]) }
            return ObserverReply(status: IOReturnValue.error)
        }
        let offset = Int(min(scalars[1], UInt64(payload.count)))
        let count = min(payload.count - offset, min(outputBytes, LinuxABI.chunk))
        return ObserverReply(status: 0, words: [0, UInt64(count), UInt64(payload.count)],
                             bytes: Array(payload[offset..<(offset + count)]))
    }

    private func lookup(_ path: String) -> ObserverFixture.Entry? {
        if let entry = frame(at: position)?.files[path] { return entry }
        return fixture.static[path]
    }

    private func drmInfo(scalars: [UInt64], input: [UInt8]?, outputBytes: Int) -> ObserverReply {
        if let kr = gate() { return ObserverReply(status: kr) }
        guard scalars.count == 2, scalars[1] >= 1, scalars[1] <= UInt64(LinuxABI.chunk) else {
            return ObserverReply(status: IOReturnValue.badArgument)
        }
        guard scalars[0] == LinuxABI.infoReadMMRReg else {
            // Allowed by the dext but not recorded.
            return ObserverReply(status: 0, words: [Self.errnoWord(EINVAL)])
        }
        let args = input ?? []
        guard args.count >= 4 else { return ObserverReply(status: 0, words: [Self.errnoWord(EINVAL)]) }
        let offset = UInt32(args[0]) | UInt32(args[1]) << 8 | UInt32(args[2]) << 16 | UInt32(args[3]) << 24
        // Upstream refuses registers outside the ASIC's allowed list with EFAULT;
        // the fixture holds only the register it recorded.
        guard offset == fixture.grbm.offset, !grbmValues.isEmpty, scalars[1] == 4 else {
            return ObserverReply(status: 0, words: [Self.errnoWord(EFAULT)])
        }
        let value = grbmValues[nextGRBMIndex()]
        let bytes = withUnsafeBytes(of: value.littleEndian) { Array($0) }
        return ObserverReply(status: 0, words: [0], bytes: Array(bytes.prefix(outputBytes)))
    }

    /// The recorded sample nearest the play position; consecutive reads
    /// within one tick step through consecutive samples, as live reads do.
    private func nextGRBMIndex() -> Int {
        let ms = position * 1000
        var lo = 0, hi = grbmTimes.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if grbmTimes[mid] < ms { lo = mid + 1 } else { hi = mid }
        }
        var index = lo
        if let last = lastGRBMIndex, abs(index - last) <= 5 {
            let step = playingBackward ? -1 : 1
            if (step > 0 && index <= last) || (step < 0 && index >= last) {
                index = min(max(last + step, 0), grbmTimes.count - 1)
            }
        }
        lastGRBMIndex = index
        return index
    }
}
