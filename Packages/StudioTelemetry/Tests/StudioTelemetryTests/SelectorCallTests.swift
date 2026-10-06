// The observer's driver calls (mac_linuxgpu host/selector_call.h) and the
// bounded reads' Timeout and Busy, which skip a sample.

import CMacLinuxGPUObserver
import Foundation
import Synchronization
import Testing
@testable import StudioTelemetry

@Suite struct SelectorCallTests {
    private func synchronous(_ selector: UInt32, _ input: [UInt64] = []) -> Bool {
        input.withUnsafeBufferPointer { mlg_selector_is_synchronous(selector, $0.baseAddress, UInt32(input.count)) }
    }

    /// Build 243's split: calls that never sleep, and the bounded reads,
    /// are answered synchronously; every other call is async.
    @Test func theDriversSyncAndAsyncSelectors() {
        #expect(synchronous(0, [0xA117_AB1E]))                 // Ping
        #expect(synchronous(43))                               // RuntimeBuild
        #expect(synchronous(21, [0x4C50_524F]))                // QueryInfo 'LPRO'
        #expect(synchronous(21, [0x4C53_4553]))                // QueryInfo 'LSES'
        #expect(synchronous(21, [0x4C4C_4F47, 0]))             // QueryInfo 'LLOG', cursor
        #expect(synchronous(LinuxABI.selSysfsRead, [LinuxABI.opRead, 0]))
        #expect(synchronous(LinuxABI.selDrmInfo, [LinuxABI.infoReadMMRReg, 4]))
        for selector: UInt32 in [1, 2, 9, 54, 55, 42, 82, 85, 61] {
            #expect(!synchronous(selector, [0]), "selector \(selector) is async")
        }
        #expect(!synchronous(21, [1]))                         // a compute QueryInfo tag
    }
}

/// Answers SysfsRead and DrmInfo with Timeout or Busy when told to, and
/// otherwise as the fixture does.
private final class FlakyConnection: ObserverConnection, @unchecked Sendable {
    let wrapped: any ObserverConnection
    let failing = Mutex<IOReturnCode?>(nil)
    init(_ wrapped: any ObserverConnection) { self.wrapped = wrapped }
    func call(selector: UInt32, scalars: [UInt64], input: [UInt8]?, outputWords: Int, outputBytes: Int) -> ObserverReply {
        if selector == LinuxABI.selSysfsRead || selector == LinuxABI.selDrmInfo, let kr = failing.withLock({ $0 }) {
            return ObserverReply(status: kr)
        }
        return wrapped.call(selector: selector, scalars: scalars, input: input, outputWords: outputWords, outputBytes: outputBytes)
    }
    func close() { wrapped.close() }
}

private final class OneDevice: ObserverDirectory, @unchecked Sendable {
    let connection: any ObserverConnection
    let id: UInt64
    init(_ c: any ObserverConnection, id: UInt64) { connection = c; self.id = id }
    var sourceName: String { "flaky" }
    func devices() -> [ObserverDevice] { [ObserverDevice(registryID: id, label: "")] }
    func openObserver(registryID: UInt64) throws -> any ObserverConnection { connection }
}

@Suite("Skipped samples", .enabled(if: Fixtures.haveRecordings, "needs the recorded R9700 fixtures"))
struct SkippedSampleTests {
    @Test(arguments: [IOReturnValue.timeout, IOReturnValue.busy])
    func timeoutAndBusySkipTheSampleAndKeepTheLastValues(_ code: IOReturnCode) throws {
        let f = try Fixtures.load("r9700-idle")
        let clock = TestClock()
        let source = FixtureObserverDirectory(fixture: f, clock: clock.closure)
        let flaky = FlakyConnection(try source.openObserver(registryID: f.device.registryID))
        let transport = LinuxTransport(directory: OneDevice(flaky, id: f.device.registryID),
                                       clock: clock.closure, sleepMicroseconds: { clock.advance(microseconds: $0) })
        let good = transport.read(registry: f.device.registryID)
        #expect(good.error == nil && !good.text.isEmpty && good.metrics != nil)
        #expect(good.grbm.count == LinuxTransport.grbmSamplesPerRefresh)

        // Every bounded read times out (or is busy) for a slow refresh.
        flaky.failing.withLock { $0 = code }
        clock.advance(seconds: 1.1)
        let skipped = transport.read(registry: f.device.registryID)
        #expect(skipped.error == nil, "not an error")
        #expect(!skipped.notReady && !skipped.unsupported)
        #expect(skipped.text == good.text, "the last values stay")
        #expect(skipped.errnos == good.errnos, "no errno invented")
        #expect(skipped.metrics != nil)
        #expect(skipped.grbm.isEmpty, "no GRBM sample this time")
        #expect(skipped.grbmStatus == nil, "and no failure reported for it")

        // The driver answers again: the next refresh reads normally.
        flaky.failing.withLock { $0 = nil }
        clock.advance(seconds: 1.1)
        let again = transport.read(registry: f.device.registryID)
        #expect(again.error == nil && !again.text.isEmpty)
        #expect(again.grbm.count == LinuxTransport.grbmSamplesPerRefresh)
    }

    /// A skip during discovery (the first refresh) retries it next time
    /// instead of settling without hwmon or the GRBM register.
    @Test func aSkippedDiscoveryRunsAgain() throws {
        let f = try Fixtures.load("r9700-idle")
        let clock = TestClock()
        let source = FixtureObserverDirectory(fixture: f, clock: clock.closure)
        let flaky = FlakyConnection(try source.openObserver(registryID: f.device.registryID))
        let transport = LinuxTransport(directory: OneDevice(flaky, id: f.device.registryID),
                                       clock: clock.closure, sleepMicroseconds: { clock.advance(microseconds: $0) })
        flaky.failing.withLock { $0 = IOReturnValue.timeout }
        let first = transport.read(registry: f.device.registryID)
        #expect(first.error == nil && first.text.isEmpty)
        flaky.failing.withLock { $0 = nil }
        clock.advance(seconds: 1.1)
        let second = transport.read(registry: f.device.registryID)
        #expect(second.hwmon != nil && !second.hwmonFiles.isEmpty)
        #expect(second.grbm.count == LinuxTransport.grbmSamplesPerRefresh)
    }
}
