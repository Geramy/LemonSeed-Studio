// The transport and model over FixtureObserverConnection (the same code
// path as IOKit), recording, and the no-data states.

import Foundation
import Testing
@testable import StudioTelemetry

@Suite("Fixture transport", .enabled(if: Fixtures.haveRecordings, "needs the recorded R9700 fixtures"))
struct FixtureTransportTests {
    @Test func sysfsReadsArriveInChunksWithTheDextsWords() throws {
        let f = try Fixtures.load("r9700-idle")
        let clock = TestClock()
        let c = FixtureObserverConnection(fixture: f, clock: clock.closure)
        let path = Array("hwmon".utf8)
        let first = c.call(selector: LinuxABI.selSysfsRead, scalars: [LinuxABI.opList, 0], input: path,
                           outputWords: 3, outputBytes: 3)
        #expect(first.status == 0 && first.words.count == 3 && first.words[0] == 0)
        #expect(first.words[1] == 3 && first.bytes.count == 3)
        let total = Int(first.words[2])
        var data = first.bytes
        while data.count < total {
            let r = c.call(selector: LinuxABI.selSysfsRead, scalars: [LinuxABI.opList, UInt64(data.count)],
                           input: path, outputWords: 3, outputBytes: 3)
            data += r.bytes
        }
        #expect(String(decoding: data, as: UTF8.self) == f.listings["hwmon"])
    }

    @Test func missingFilesAnswerWithLinuxErrnos() throws {
        let f = try Fixtures.load("r9700-idle")
        let c = FixtureObserverConnection(fixture: f)
        let r = c.call(selector: LinuxABI.selSysfsRead, scalars: [LinuxABI.opRead, 0],
                       input: Array("no_such_attribute".utf8), outputWords: 3, outputBytes: 4096)
        #expect(r.status == 0 && Int64(bitPattern: r.words[0]) == -Int64(ENOENT))
        let dir = c.call(selector: LinuxABI.selSysfsRead, scalars: [LinuxABI.opRead, 0],
                         input: Array("hwmon".utf8), outputWords: 3, outputBytes: 4096)
        #expect(Int64(bitPattern: dir.words[0]) == -Int64(EISDIR))
        let other = c.call(selector: 61, scalars: [], input: nil, outputWords: 1, outputBytes: 0)
        #expect(other.status == IOReturnValue.notPermitted)
    }

    @Test func playbackPingPongs() throws {
        let f = try Fixtures.load("r9700-idle")
        let clock = TestClock()
        let c = FixtureObserverConnection(fixture: f, clock: clock.closure)
        let d = f.duration
        clock.advance(seconds: d * 0.25)
        #expect(abs(c.position - d * 0.25) < 1e-6)
        clock.advance(seconds: d)                      // 1.25 d: playing backward
        #expect(abs(c.position - d * 0.75) < 1e-6)
        clock.advance(seconds: d * 0.75)               // 2 d: back at the start
        #expect(c.position < 1e-6)
    }

    @Test func transportReadsTheRecordingLikeTheDriver() throws {
        let f = try Fixtures.load("r9700-idle")
        let clock = TestClock()
        let transport = Fixtures.transport(f, clock: clock)
        let history = LinuxHistory()
        var snap = LinuxSnapshot()
        for _ in 0..<25 {                               // 2.5 s at 10 Hz
            let s = transport.read(registry: f.device.registryID)
            #expect(s.error == nil && !s.notReady && !s.unsupported)
            history.add(s, nowNs: clock.now)
            snap = makeLinuxSnapshot(s, history: history, nowNs: clock.now)
            clock.advance(seconds: 0.1 - 0.032)        // the GRBM sleeps advanced 32 ms
        }
        #expect(snap.statusOK && snap.status == "upstream amdgpu running")
        #expect(snap.build == f.capture.runtimeBuild)
        #expect(snap.deviceLine.hasPrefix("1002:"))
        // Enough GRBM samples in the 2 s window: load comes from hardware sampling.
        #expect(snap.coreHardware)
        #expect(snap.coreSummary.hasPrefix("GRBM_STATUS.GUI_ACTIVE"))
        let load = try #require(snap.coreCurrent)
        #expect(load >= 0 && load <= 100)
        #expect(snap.vram.map { $0.total > 8 && $0.used > 0 && $0.used <= $0.total } == true)
        #expect(snap.gtt != nil)
        #expect(snap.metricsFormat.hasPrefix("gpu_metrics v1."))
        #expect(snap.clocks.map(\.name) == ["GFX", "MEMORY", "SOC", "FABRIC"])
        #expect(snap.clocks[0].levels.contains { $0.active })
        #expect(snap.clocks[0].current != nil)
        #expect(snap.sensors.contains { $0.label == "Temp junction" })
        #expect(snap.pcie.first?.label == "endpoint link")
        #expect(snap.linkLine.hasPrefix("PCIe "))
        #expect(!snap.pcieLevels.isEmpty)
        #expect(snap.throttleIndependent != nil)
    }

    @Test func grbmReadsReplayTheRecordedRegisterValues() throws {
        // DrmInfo READ_MMR_REG hands out the recorded GRBM_STATUS values in
        // order as time advances, 8 ms apart like the transport's reads.
        let f = try Fixtures.load("r9700-idle")
        let clock = TestClock()
        let c = FixtureObserverConnection(fixture: f, clock: clock.closure)
        let offset = try #require(f.grbm.offset)
        var args = [UInt8]()
        for word in [offset, 1, 0xffff_ffff, 0] { withUnsafeBytes(of: word.littleEndian) { args += $0 } }
        var values: [UInt32] = []
        for i in 0..<5 {
            if i > 0 { clock.advance(microseconds: 8_000) }
            let r = c.call(selector: LinuxABI.selDrmInfo, scalars: [LinuxABI.infoReadMMRReg, 4], input: args,
                           outputWords: 1, outputBytes: 4)
            #expect(r.status == 0 && r.words == [0] && r.bytes.count == 4)
            values.append(r.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        #expect(values == f.grbm.samples.prefix(5).map { UInt32($0[1]) })
        // Another register is refused as upstream refuses it.
        var other = args
        other[0] &+= 4
        let refused = c.call(selector: LinuxABI.selDrmInfo, scalars: [LinuxABI.infoReadMMRReg, 4], input: other,
                             outputWords: 1, outputBytes: 4)
        #expect(Int64(bitPattern: refused.words[0]) == -Int64(EFAULT))
    }

    @Test func loadFollowsGUIActiveInTheRecording() throws {
        // The 2 s GRBM load equals the GUI_ACTIVE share of the samples read.
        let f = try Fixtures.load(Fixtures.names.contains("r9700-load") ? "r9700-load" : "r9700-idle")
        let clock = TestClock()
        let transport = Fixtures.transport(f, clock: clock)
        let history = LinuxHistory()
        var all: [Bool] = []
        var snap = LinuxSnapshot()
        for _ in 0..<15 {
            let s = transport.read(registry: f.device.registryID)
            all += s.grbm.map(\.active)
            history.add(s, nowNs: clock.now)
            snap = makeLinuxSnapshot(s, history: history, nowNs: clock.now)
            clock.advance(seconds: 0.068)
        }
        #expect(snap.coreHardware)
        let expected = Double(all.filter { $0 }.count) / Double(all.count) * 100
        #expect(abs((snap.coreCurrent ?? -1) - expected) < 1e-9)
    }

}

@Suite("No-data paths")
struct NoDataTransportTests {
    @Test func notRunningShowsTheDriversStatusAndNoValues() throws {
        let f = Fixtures.empty
        let clock = TestClock()
        let transport = Fixtures.transport(f, scenario: .notRunning, clock: clock)
        let s = transport.read(registry: f.device.registryID)
        #expect(s.notReady && s.modulesRunning == false)
        let snap = makeLinuxSnapshot(s, history: LinuxHistory(), nowNs: clock.now)
        #expect(!snap.statusOK)
        #expect(snap.status.hasPrefix("upstream amdgpu not running"))
        #expect(snap.coreCurrent == nil && snap.vram == nil && snap.sensors.isEmpty)
        #expect(snap.build == f.capture.runtimeBuild)
    }

    @Test func olderDextIsNamedAsSuch() throws {
        let f = Fixtures.empty
        let clock = TestClock()
        let s = Fixtures.transport(f, scenario: .predatesObserverReads, clock: clock).read(registry: f.device.registryID)
        let snap = makeLinuxSnapshot(s, history: LinuxHistory(), nowNs: clock.now)
        #expect(snap.status.contains("predates the observer Linux reads"))
    }

    @Test func noDeviceFailsToOpen() throws {
        let f = Fixtures.empty
        let directory = FixtureObserverDirectory(fixture: f, scenario: .noDevice)
        #expect(directory.devices().isEmpty)
        #expect(throws: ObserverError.self) { try directory.openObserver(registryID: f.device.registryID) }
    }
}

@Suite("Recording", .enabled(if: Fixtures.haveRecordings, "needs the recorded R9700 fixtures"))
struct RecordingTests {
    @Test func recordingAReplayReproducesIt() throws {
        let original = try Fixtures.load("r9700-idle")
        let clock = TestClock()
        let source = FixtureObserverDirectory(fixture: original, clock: clock.closure)
        let recorder = FixtureRecorder(name: "rerecorded", registryID: original.device.registryID, clock: clock.closure)
        let recording = RecordingObserverConnection(wrapping: try source.openObserver(registryID: original.device.registryID),
                                                    recorder: recorder)
        final class OneConnection: ObserverDirectory, @unchecked Sendable {
            let connection: any ObserverConnection
            let id: UInt64
            init(_ c: any ObserverConnection, id: UInt64) { connection = c; self.id = id }
            var sourceName: String { "recording" }
            func devices() -> [ObserverDevice] { [ObserverDevice(registryID: id, label: "")] }
            func openObserver(registryID: UInt64) throws -> any ObserverConnection { connection }
        }
        let transport = LinuxTransport(directory: OneConnection(recording, id: original.device.registryID),
                                       clock: clock.closure, sleepMicroseconds: { clock.advance(microseconds: $0) })
        for _ in 0..<30 {
            _ = transport.read(registry: original.device.registryID)
            clock.advance(seconds: 0.068)
        }
        let recorded = recorder.fixture()
        #expect(recorded.selectors.runtimeBuild == original.selectors.runtimeBuild)
        #expect(recorded.listings["hwmon"] == original.listings["hwmon"])
        #expect(recorded.static["ip_discovery/die/0/GC/0/base_addr"] == original.static["ip_discovery/die/0/GC/0/base_addr"])
        #expect(recorded.grbm.offset == original.grbm.offset)
        #expect(recorded.grbm.samples.count == 30 * LinuxTransport.grbmSamplesPerRefresh)
        #expect(recorded.frames.count == 3)           // one slow refresh per second
        // Frame files equal the replayed frames' (trimmed by nothing: raw payloads).
        let firstOriginal = original.frames[0]
        for (path, entry) in recorded.frames[0].files {
            #expect(firstOriginal.files[path] == entry, "\(path)")
        }
        // And the recording replays.
        let replay = FixtureObserverConnection(fixture: try ObserverFixture(data: recorded.encoded()))
        let r = replay.call(selector: LinuxABI.selSysfsRead, scalars: [LinuxABI.opRead, 0],
                            input: Array("mem_info_vram_total".utf8), outputWords: 3, outputBytes: 4096)
        #expect(r.status == 0 && r.words[0] == 0 && !r.bytes.isEmpty)
    }
}
