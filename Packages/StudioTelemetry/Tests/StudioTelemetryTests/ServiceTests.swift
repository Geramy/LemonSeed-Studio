import Foundation
import Testing
@testable import StudioTelemetry

@Suite("Telemetry service", .enabled(if: Fixtures.haveRecordings, "needs the recorded R9700 fixtures"))
@MainActor
struct ServiceTests {
    @Test func fixtureServiceGoesLive() async throws {
        let service = TelemetryService.fixture("r9700-idle")
        await service.refreshNow()
        let state = service.state
        #expect(state.availability == .live)
        #expect(state.sourceName == "recorded fixture r9700-idle")
        #expect(state.sourceDetails.contains { $0.label == "captured" })
        #expect(state.device != nil)
        #expect(state.summary.vram != nil)
        #expect(state.summary.temperatureLabel == "junction")
        #expect(state.summary.temperatureSource.hasPrefix("hwmon/") && state.summary.temperatureSource.contains("_input"))
        #expect(state.summary.power != nil && state.summary.powerCap != nil)
        #expect(state.summary.load != nil)
    }

    @Test func deviceNameComesFromThePCIID() async throws {
        let service = TelemetryService.fixture("r9700-idle")
        await service.refreshNow()
        let line = service.state.snapshot.deviceLine
        if line.hasPrefix("1002:7551") {
            #expect(service.state.deviceName == "AMD Radeon AI PRO R9700")
            #expect(service.state.deviceNameSource == PCINames.source)
        }
        #expect(PCINames.name(deviceLine: "1002:abcd rev 00") == nil)
    }

    @Test func notRunningIsReportedWithTheDriversWords() async {
        let service = TelemetryService.fixture("r9700-idle", scenario: .notRunning)
        await service.refreshNow()
        guard case .notRunning(let status) = service.state.availability else {
            Issue.record("expected notRunning, got \(service.state.availability)"); return
        }
        #expect(status.hasPrefix("upstream amdgpu not running"))
        #expect(service.state.summary.load == nil)
    }

    @Test func sampling10HzProducesASmoothSeries() async throws {
        let service = TelemetryService.fixture("r9700-idle")
        let hold = Task { await service.hold(.screen) }
        try await Task.sleep(for: .milliseconds(2600))
        hold.cancel()
        let snap = service.state.snapshot
        #expect(snap.core.count >= 15, "about ten points a second")
        #expect(snap.coreHardware, "GRBM samples fill the 2 s window at 10 Hz")
    }
}

@Suite("Telemetry service states")
@MainActor
struct ServiceStateTests {
    @Test(arguments: [(FixtureScenario.noDevice, TelemetryAvailability.noDevice)])
    func emptyStates(scenario: FixtureScenario, expected: TelemetryAvailability) async {
        let service = TelemetryService(directory: FixtureObserverDirectory(fixture: Fixtures.empty, scenario: scenario))
        await service.refreshNow()
        #expect(service.state.availability == expected)
        #expect(service.state.summary == GPUSummary())
    }

    @Test func hostCanSayTheDriverIsOff() async throws {
        let f = Fixtures.empty
        let service = TelemetryService(directory: FixtureObserverDirectory(fixture: f, scenario: .noDevice),
                                       driverEnabled: { false })
        await service.refreshNow()
        #expect(service.state.availability == .driverNotEnabled)
    }

    @Test func rateFollowsDemand() async throws {
        let service = TelemetryService(directory: FixtureObserverDirectory(fixture: Fixtures.empty))
        #expect(service.sampleRate == .paused)
        let widget = Task { await service.hold(.widget) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.sampleRate == .widget)
        let screen = Task { await service.hold(.screen) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.sampleRate == .screen)
        service.setForeground(false)
        #expect(service.sampleRate == .paused)
        service.setForeground(true)
        screen.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.sampleRate == .widget)
        widget.cancel()
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.sampleRate == .paused)
    }

    @Test func aMissingFixtureIsNamedNotFaked() async {
        let service = TelemetryService.fixture("no-such-recording")
        await service.refreshNow()
        #expect(service.state.availability == .noDevice)
        #expect(service.state.sourceName.hasPrefix("no recorded fixture no-such-recording bundled"))
        #expect(service.state.summary == GPUSummary())
    }
}

#if os(macOS)
/// Against the real driver, read-only: `STUDIO_TELEMETRY_LIVE=1 swift test`.
@Suite("Live IOKit observer", .enabled(if: ProcessInfo.processInfo.environment["STUDIO_TELEMETRY_LIVE"] == "1"))
struct LiveObserverTests {
    @Test func opensAnObserverAndReadsTheBuild() throws {
        let directory = IOKitObserverDirectory()
        let device = try #require(directory.devices().first, "no MacLinuxGPU service")
        let c = try directory.openObserver(registryID: device.registryID)
        defer { c.close() }
        let r = c.call(selector: LinuxABI.selRuntimeBuild, scalars: [], input: nil, outputWords: 4, outputBytes: 0)
        #expect(r.status == 0 && r.words.count == 4 && r.words[3] >= 229)
        let s = LinuxTransport(directory: directory).read(registry: device.registryID)
        #expect(s.error == nil)
    }
}
#endif
