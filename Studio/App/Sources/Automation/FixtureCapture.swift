import Foundation
import os
import StudioTelemetry

private let fixtureLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "fixtures")

/// Records StudioTelemetry fixtures from the real GPU, on request from the
/// development remote control.
///
/// A read-only observer client (type 1) wrapped in StudioTelemetry's
/// recording directory is sampled by the package's own TelemetryService at
/// the GPU screen's rate, so only the package's allowlisted files are read.
/// The result is the JSON Tools/capture_fixture.py writes, saved to
/// Documents/fixtures/<name>.json.
@MainActor
enum FixtureCapture {
    static var folder: URL {
        DevSupport.documents.appendingPathComponent("fixtures", isDirectory: true)
    }

    /// Records for `seconds` and returns a one-line summary.
    static func record(name: String, description: String, seconds: Double) async -> String {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let directory = RecordingObserverDirectory(wrapping: IOKitObserverDirectory(), name: name)
        let service = TelemetryService(directory: directory)
        let sampling = Task { await service.hold(.screen) }
        try? await Task.sleep(for: .seconds(seconds))
        sampling.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        let devices = directory.devices()
        guard let device = devices.first(where: { directory.recorder(for: $0.registryID) != nil }),
              let recorder = directory.recorder(for: device.registryID) else {
            return "FAIL fixture \(name): no observer was opened (\(devices.count) device(s), availability \(service.state.availability))"
        }
        var fixture = recorder.fixture(description: description)
        fixture.capture.host = "iPad (LemonSeed Studio)"
        fixture.capture.summary = summary(fixture)
        do {
            let url = folder.appendingPathComponent("\(name).json")
            try fixture.encoded().write(to: url, options: .atomic)
            let s = fixture.capture.summary
            let line = String(format: "OK   fixture %@: %d frames, %d GRBM samples, %.0f s, gpu_busy %@..%@, GUI_ACTIVE %@",
                              name, fixture.frames.count, fixture.grbm.samples.count, fixture.duration,
                              s?.gpuBusyPercentMin.map(String.init) ?? "n/a", s?.gpuBusyPercentMax.map(String.init) ?? "n/a",
                              s?.grbmActiveFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a")
            fixtureLog.log("\(line, privacy: .public)")
            return line
        } catch {
            return "FAIL fixture \(name): \(error)"
        }
    }

    private static func summary(_ fixture: ObserverFixture) -> ObserverFixture.Summary {
        var s = ObserverFixture.Summary()
        let busy = fixture.frames.compactMap { frame -> Int? in
            guard let entry = frame.files.first(where: { $0.key.hasSuffix("gpu_busy_percent") })?.value,
                  let bytes = entry.payload else { return nil }
            return Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        s.gpuBusyPercentMin = busy.min()
        s.gpuBusyPercentMax = busy.max()
        let samples = fixture.grbm.samples.compactMap { $0.count > 1 ? UInt32($0[1]) : nil }
        if !samples.isEmpty {
            let active = samples.filter { $0 & LinuxABI.grbmGuiActive != 0 }.count
            s.grbmActiveFraction = Double(active) / Double(samples.count)
        }
        return s
    }
}
