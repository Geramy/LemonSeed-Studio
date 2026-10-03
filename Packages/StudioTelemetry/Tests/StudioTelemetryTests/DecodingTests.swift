// Decoding against payloads recorded from a real R9700 through the
// mac_linuxgpu observer: gpu_metrics by its header, pp_dpm_* levels, and
// the hwmon labels.

import Foundation
import Testing
@testable import StudioTelemetry

@Suite("Recorded fixtures")
struct FixtureInventoryTests {
    @Test func requiredFixturesAreBundled() throws {
        withKnownIssue("R9700 recordings not captured yet: run Tools/capture_fixtures.sh with the GPU attached",
                       isIntermittent: true) {
            for name in Fixtures.required {
                #expect(Fixtures.names.contains(name), "missing recorded fixture \(name)")
            }
        }
    }

    @Test(arguments: ObserverFixture.bundledNames)
    func fixtureIsARealCapture(name: String) throws {
        let f = try Fixtures.load(name)
        #expect(f.schema == ObserverFixture.schemaName)
        #expect(f.device.service == "MacLinuxGPU")
        #expect(f.capture.driver == "mac_linuxgpu")
        // The dext's RuntimeBuild counter (192 for the iPad recordings; the
        // Mac's driver counts separately). Any real capture reports one.
        #expect((f.capture.runtimeBuild ?? 0) > 0)
        #expect(f.frames.count >= 30, "about a minute at 1 Hz")
        #expect(f.grbm.samples.count >= 1000, "five GRBM reads per 100 ms")
        #expect(f.grbm.offset != nil)
        // Every frame carries the files amdgpu_mtopg reads.
        for frame in f.frames {
            for path in LinuxPaths.device + ["gpu_metrics"] {
                #expect(frame.files[path] != nil, "\(name) t=\(frame.t): \(path) missing")
            }
        }
    }

    @Test(arguments: ObserverFixture.bundledNames)
    func jsonRoundTrip(name: String) throws {
        let f = try Fixtures.load(name)
        let again = try ObserverFixture(data: try f.encoded())
        #expect(again == f)
    }
}

@Suite("gpu_metrics by header", .enabled(if: Fixtures.haveRecordings, "needs the recorded R9700 fixtures"))
struct GPUMetricsDecodingTests {
    @Test(arguments: ObserverFixture.bundledNames)
    func everyRecordedBlobDecodesByItsHeader(name: String) throws {
        let f = try Fixtures.load(name)
        for frame in f.frames {
            guard case .bytes(let blob)? = frame.files["gpu_metrics"] else {
                Issue.record("t=\(frame.t): gpu_metrics not binary"); continue
            }
            let m = try #require(GPUMetrics(bytes: blob))
            #expect(m.decoded, "t=\(frame.t): \(m.versionText) not decoded")
            #expect(m.structureSize == blob.count)
            // The layout is picked by (format, content) revision alone.
            let layout = try #require(GPUMetricsLayout.formats.first {
                $0.formatRevision == m.formatRevision && $0.contentRevision == m.contentRevision
            })
            #expect(layout.size == blob.count)
        }
    }

    /// Two independent driver paths must agree: the SMU's gpu_metrics
    /// temperatures (whole °C) and hwmon's temp*_input (millidegrees),
    /// read within the same refresh. They are sampled at different instants
    /// of that refresh, so under load (r9700-load: junction moving several
    /// degrees a second) they differ by up to ~6 °C. A wrong field offset
    /// is off by tens of degrees or reads nonsense, so 8 °C still catches it.
    @Test(arguments: ObserverFixture.bundledNames)
    func temperaturesAgreeWithHwmon(name: String) throws {
        let f = try Fixtures.load(name)
        let hwmon = try #require(Fixtures.hwmonDir(f))
        var compared = 0
        for frame in f.frames {
            guard case .bytes(let blob)? = frame.files["gpu_metrics"], let m = GPUMetrics(bytes: blob) else { continue }
            for n in 1...3 {
                guard let label = Fixtures.text(frame, "\(hwmon)/temp\(n)_label"),
                      let milli = Fixtures.text(frame, "\(hwmon)/temp\(n)_input").flatMap(Double.init) else { continue }
                let field = switch label {
                case "edge": "temperature_edge"
                case "junction": "temperature_hotspot"
                case "mem": "temperature_mem"
                default: ""
                }
                guard let smu = m.double(field) else { continue }
                #expect(abs(smu - milli / 1000) <= 8, "\(label): gpu_metrics \(smu) vs hwmon \(milli / 1000)")
                compared += 1
            }
        }
        #expect(compared >= f.frames.count, "at least one temperature compared per frame")
    }

    @Test(arguments: ObserverFixture.bundledNames)
    func pcieWidthIsPlausibleAgainstPciSysfs(name: String) throws {
        let f = try Fixtures.load(name)
        let frame = try #require(f.frames.first)
        guard case .bytes(let blob)? = frame.files["gpu_metrics"], let m = GPUMetrics(bytes: blob),
              let width = m.value("pcie_link_width") else { return }
        // pci-sysfs reports the GPU function's link to the card's own PCIe
        // switch (x16 at 32 GT/s on the R9700), while the SMU's
        // pcie_link_width is the card's upstream link, which over Thunderbolt
        // trains narrower (x4 in the iPad recordings). So the SMU's width is
        // a real PCIe width no wider than the function's maximum.
        #expect([1, 2, 4, 8, 16, 32].contains(Int(width)), "pcie_link_width \(width)")
        let maxWidth = Fixtures.text(frame, "max_link_width").flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(maxWidth != nil && Int(width) <= maxWidth!, "pcie_link_width \(width) vs max_link_width \(maxWidth ?? 0)")
    }

    @Test func otherHeadersAreNotDecoded() throws {
        let f = try Fixtures.load("r9700-idle")
        guard case .bytes(let blob)? = f.frames[0].files["gpu_metrics"] else { Issue.record("no blob"); return }
        var other = blob
        other[3] = 9                                   // a content revision with no layout
        #expect(GPUMetrics(bytes: other)?.decoded == false)
        #expect(GPUMetrics(bytes: Array(blob.prefix(40)))?.decoded == false)   // shorter than its header says
        var resized = blob
        resized[0] = UInt8(truncatingIfNeeded: blob.count + 8)               // size field disagrees with the struct
        #expect(GPUMetrics(bytes: resized)?.decoded == false)
        #expect(GPUMetrics(bytes: [1, 2]) == nil)
    }

    @Test func unfilledFieldsReadAsAbsent() throws {
        // smu_cmn_init_soft_gpu_metrics fills the struct with all-ones; a
        // field the SMU does not write must read back nil, never 65535.
        let f = try Fixtures.load("r9700-idle")
        guard case .bytes(let blob)? = f.frames[0].files["gpu_metrics"], let m = GPUMetrics(bytes: blob),
              let format = m.format else { Issue.record("no blob"); return }
        for (name, field) in format.fields {
            let raw = (0..<field.size).reduce(UInt64(0)) { $0 | UInt64(blob[field.offset + $1]) << (8 * $1) }
            let allOnes: UInt64 = field.size >= 8 ? .max : (1 << (8 * field.size)) - 1
            #expect((m.value(name) == nil) == (raw == allOnes), "\(name)")
        }
    }
}

@Suite("pp_dpm_* levels", .enabled(if: Fixtures.haveRecordings, "needs the recorded R9700 fixtures"))
struct DPMParsingTests {
    @Test(arguments: ObserverFixture.bundledNames)
    func recordedClockTablesParse(name: String) throws {
        let f = try Fixtures.load(name)
        for frame in f.frames {
            for path in ["pp_dpm_sclk", "pp_dpm_mclk", "pp_dpm_socclk", "pp_dpm_fclk"] {
                guard let text = Fixtures.text(frame, path) else { continue }
                let levels = parseDPMLevels(text)
                let lines = text.split(separator: "\n")
                #expect(levels.count == lines.count, "\(path): \(text)")
                #expect(levels.allSatisfy { $0.mhz != nil }, "\(path): every level has MHz")
                #expect(levels.filter(\.active).count == 1, "\(path): exactly one current level")
            }
            if let text = Fixtures.text(frame, "pp_dpm_pcie") {
                let levels = parseDPMLevels(text)
                #expect(!levels.isEmpty)
                #expect(levels.allSatisfy { $0.text.contains("GT/s") && $0.text.contains("x") })
            }
        }
    }

    @Test func idleSclkSitsInDeepSleep() throws {
        // At idle the R9700's GFX clock reports its deep-sleep level "S".
        let f = try Fixtures.load("r9700-idle")
        let text = try #require(Fixtures.text(f.frames[0], "pp_dpm_sclk"))
        let levels = parseDPMLevels(text)
        let active = try #require(levels.first { $0.active })
        #expect(active.label == "S")
        #expect(levels.contains { $0.label != "S" && ($0.mhz ?? 0) > 1000 })
    }

}

@Suite("hwmon labels", .enabled(if: Fixtures.haveRecordings, "needs the recorded R9700 fixtures"))
struct HwmonTests {
    @Test(arguments: ObserverFixture.bundledNames)
    func listingNamesTheSensorFiles(name: String) throws {
        let f = try Fixtures.load(name)
        let dir = try #require(Fixtures.hwmonDir(f))
        let files = try #require(f.listings[dir])
        for needed in ["name", "temp1_input", "temp1_label", "power1_cap", "fan1_input"] {
            #expect(files.contains("f \(needed)\n"), "\(dir) lists \(needed)")
        }
    }

    @Test(arguments: ObserverFixture.bundledNames)
    func sensorsUseTheDriversOwnLabels(name: String) throws {
        let f = try Fixtures.load(name)
        let dir = try #require(Fixtures.hwmonDir(f))
        let frame = f.frames[0]
        var text: [String: String] = [:]
        for (path, entry) in frame.files { if case .text(let t) = entry { text[path] = t.trimmingCharacters(in: .whitespacesAndNewlines) } }
        let rows = hwmonSensorRows(text, hwmon: dir)
        let temps = rows.filter { $0.kind == .temperature }
        // amdgpu's hwmon labels for a discrete GPU.
        #expect(temps.map(\.label) == ["Temp edge", "Temp junction", "Temp mem"])
        #expect(temps.allSatisfy { ($0.value ?? 0) > 10 && ($0.value ?? 999) < 110 })
        #expect(temps.allSatisfy { $0.source.hasPrefix("\(dir)/temp") })
        // The driver's temp*_crit is the scale when it is reported.
        if let crit = text["\(dir)/temp1_crit"].flatMap(Double.init) {
            #expect(temps[0].maxValue == crit / 1000)
        }
        let power = try #require(rows.first { $0.kind == .power })
        let cap = try #require(text["\(dir)/power1_cap"].flatMap(Double.init))
        #expect(power.maxValue == cap / 1e6)
        #expect(power.text.hasSuffix(String(format: "/ %.0f W cap", cap / 1e6)))
        if let label = text["\(dir)/power1_label"] { #expect(power.label.contains("(\(label))")) }
        #expect(rows.contains { $0.kind == .fan && $0.source == "\(dir)/fan1_input" })
        let volts = rows.filter { $0.kind == .voltage }
        #expect(volts.allSatisfy { $0.label.hasPrefix("Volt ") && !$0.label.hasSuffix("in0") })
        let clocks = rows.filter { $0.kind == .clock }
        #expect(clocks.allSatisfy { $0.text.hasSuffix(" MHz") })
    }
}
