// amdgpu_mtopg's check_linux_model.sh as a unit test: a C-filled upstream
// struct gpu_metrics_v1_3 must decode by its header alone, and the model's
// labels, GRBM fraction and fallbacks hold on fixed sysfs text.

import CGPUMetricsReference
import Foundation
import Testing
@testable import StudioTelemetry

@Suite("Reference gpu_metrics and model")
struct ReferenceDecodingTests {
    static func blob() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 512)
        let n = out.withUnsafeMutableBufferPointer { gpu_metrics_v1_3_reference($0.baseAddress, $0.count) }
        return Array(out.prefix(n))
    }

    @Test func cFilledV13DecodesByHeader() throws {
        let b = Self.blob()
        let m = try #require(GPUMetrics(bytes: b))
        #expect(m.decoded && m.versionText == "v1.3" && m.structureSize == b.count)
        #expect(m.value("temperature_edge") == 45 && m.value("temperature_hotspot") == 61)
        #expect(m.value("average_gfx_activity") == 37 && m.value("average_umc_activity") == 12)
        #expect(m.value("current_gfxclk") == 2450 && m.value("average_gfxclk_frequency") == 2400)
        #expect(m.value("current_uclk") == 1258 && m.value("throttle_status") == 0x10)
        #expect(m.value("pcie_link_width") == 16 && m.value("pcie_link_speed") == 160)
        #expect(m.value("temperature_mem") == nil && m.value("current_fan_speed") == nil)   // all-ones: absent
        #expect(!m.has("temperature_gfx"))
        var other = b
        other[3] = 9
        #expect(GPUMetrics(bytes: other)?.decoded == false)
        #expect(GPUMetrics(bytes: Array(b.prefix(40)))?.decoded == false)
    }

    @Test func snapshotSourcesAndFallbacks() throws {
        let m = try #require(GPUMetrics(bytes: Self.blob()))
        var s = LinuxSample()
        s.modulesRunning = true
        s.hwmon = "hwmon/hwmon0"
        s.metrics = m
        s.text = ["gpu_busy_percent": "88", "mem_busy_percent": "12",
                  "mem_info_vram_used": "3221225472", "mem_info_vram_total": "34359738368",
                  "pp_dpm_sclk": "0: 500Mhz \n1: 2450Mhz *", "current_link_speed": "16.0 GT/s PCIe",
                  "current_link_width": "16", "vendor": "0x1002", "device": "0x7551",
                  "hwmon/hwmon0/temp1_input": "45000", "hwmon/hwmon0/temp1_label": "edge",
                  "hwmon/hwmon0/power1_average": "123000000", "hwmon/hwmon0/power1_cap": "300000000"]
        let history = LinuxHistory()
        var now: UInt64 = 10_000_000_000
        history.add(s, nowNs: now)
        var snap = makeLinuxSnapshot(s, history: history, nowNs: now)
        #expect(snap.statusOK && !snap.coreHardware && snap.coreCurrent == 88)      // gpu_busy_percent
        #expect(snap.memoryCurrent == 12 && snap.umcMetrics == 12)
        #expect(snap.vram.map { abs($0.used - 3) < 1e-9 && abs($0.total - 32) < 1e-9 } == true)
        #expect(snap.clocks[0].current == 2450 && snap.clocks[0].levels[1].active)
        #expect(snap.throttleActive == ["PPT0", "TEMP_HOTSPOT"])
        #expect(snap.sensors.first?.label == "Temp edge" && snap.sensors.first?.value == 45)
        #expect(snap.sensors.contains { $0.label == "Power avg" && $0.text == "123 W / 300 W cap" })
        #expect(snap.deviceLine == "1002:7551" && snap.linkLine == "PCIe 16.0 GT/s PCIe x16")
        // Eight GRBM samples, six active: 75 % from hardware sampling.
        let start = now - 1_000_000
        s.grbm = (0..<8).map { (atNs: start + UInt64($0) * 10_000, active: $0 % 4 != 0) }
        now += 2_000_000
        history.add(s, nowNs: now)
        snap = makeLinuxSnapshot(s, history: history, nowNs: now)
        #expect(snap.coreHardware && snap.coreCurrent == 75)
        // Not running: no values, an honest status.
        var idle = LinuxSample()
        idle.notReady = true
        idle.modulesRunning = false
        history.add(idle, nowNs: now)
        snap = makeLinuxSnapshot(idle, history: history, nowNs: now)
        #expect(!snap.statusOK && snap.coreCurrent == nil && snap.status.hasPrefix("upstream amdgpu not running"))
    }

    @Test func upstreamFormatting() {
        let levels = parseDPMLevels("S: 19Mhz *\n0: 500Mhz \n1: 2450Mhz \n")
        #expect(levels.count == 3 && levels[0].label == "S" && levels[0].active && levels[2].mhz == 2450)
        let pcie = parseDPMLevels("0: 2.5GT/s, x1 619Mhz \n1: 16.0GT/s, x16 1143Mhz *\n")
        #expect(pcie[1].active && pcie[1].text == "16.0GT/s, x16 1143Mhz")
        #expect(parseDPMLevels(nil).isEmpty)
    }
}
