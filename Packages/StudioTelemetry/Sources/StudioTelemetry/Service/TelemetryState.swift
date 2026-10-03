// StudioTelemetry: what the screen and the status widget render.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import Foundation

/// Why there is (or is not) data. Every non-live case carries the reason
/// the driver gave, so the UI never shows a fake zero.
public enum TelemetryAvailability: Sendable, Equatable {
    case starting
    /// The host knows the driver extension is not enabled (Settings ›
    /// General › Drivers on iPadOS).
    case driverNotEnabled
    /// No MacLinuxGPU service: no GPU bound to the driver.
    case noDevice
    /// The upstream driver is not running in a GPU session yet.
    case notRunning(String)
    /// The dext predates the observer Linux reads.
    case unsupported(String)
    case error(String)
    case live

    public var isLive: Bool { self == .live }
}

/// The few numbers the status widget shows, each with its source.
public struct GPUSummary: Sendable, Equatable {
    public var load: Double?
    public var loadSource = "n/a"
    public var vram: UsagePair?
    public var vramSource = "sysfs mem_info_vram_used / mem_info_vram_total"
    public var temperature: Double?
    public var temperatureLabel: String?
    /// The meter's scale: the driver's temp*_crit when reported.
    public var temperatureLimit: Double?
    public var temperatureSource = "n/a"
    public var power: Double?
    public var powerCap: Double?
    public var powerSource = "n/a"

    public init() {}

    init(_ snap: LinuxSnapshot) {
        guard snap.statusOK else { return }
        load = snap.coreCurrent
        loadSource = snap.coreHardware ? "GRBM_STATUS.GUI_ACTIVE, 2 s" : "sysfs gpu_busy_percent"
        vram = snap.vram
        let temps = snap.sensors.filter { $0.kind == .temperature }
        if let t = temps.first(where: { $0.label.lowercased().contains("junction") }) ?? temps.first {
            temperature = t.value
            temperatureLabel = t.label.replacingOccurrences(of: "Temp ", with: "")
            temperatureSource = t.source
            temperatureLimit = t.maxValue
        }
        let powers = snap.sensors.filter { $0.kind == .power }
        if let p = powers.first(where: { $0.label.hasPrefix("Power avg") }) ?? powers.first {
            power = p.value
            powerCap = p.maxValue
            powerSource = p.source
        }
    }
}

public struct TelemetryState: Sendable, Equatable {
    public var availability: TelemetryAvailability = .starting
    public var devices: [ObserverDevice] = []
    public var device: ObserverDevice?
    /// A marketing name from the PCI ID, when known, and where it came from.
    public var deviceName: String?
    public var deviceNameSource: String?
    public var snapshot = LinuxSnapshot()
    public var summary = GPUSummary()
    /// Where the data comes from: the IOKit observer or a named fixture.
    public var sourceName = ""
    public var sourceDetails: [LabeledText] = []
    /// Wall-clock time the snapshot was taken (charts scroll from it).
    public var capturedAt = Date.distantPast
    public var sampleRate: TelemetrySampleRate = .paused

    public init() {}
}

public enum TelemetrySampleRate: Int, Sendable, Comparable, CaseIterable {
    case paused = 0
    /// The status widget alone: 1 Hz.
    case widget = 1
    /// The GPU screen is visible: 10 Hz, GRBM sampling at amdgpu_top's cadence.
    case screen = 10

    public var interval: Duration? {
        switch self {
        case .paused: return nil
        case .widget: return .seconds(1)
        case .screen: return .milliseconds(100)
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// PCI device IDs whose names are known here (vendor 0x1002). Anything else
/// shows the raw ID only.
enum PCINames {
    static let source = "PCI ID (sysfs vendor/device)"
    static let amd: [String: String] = [
        "7550": "AMD Radeon RX 9070 Series",
        "7551": "AMD Radeon AI PRO R9700",
    ]

    static func name(deviceLine: String) -> String? {
        let parts = deviceLine.split(separator: " ").first?.split(separator: ":") ?? []
        guard parts.count == 2, parts[0].lowercased() == "1002" else { return nil }
        return amd[parts[1].lowercased()]
    }
}
