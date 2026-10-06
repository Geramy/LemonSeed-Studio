// Copied from Engine/ProofOfLife/App/DriverClient.swift for the Diagnostics screen.
#if LEMONSEED_DEVICE
import Foundation

/// The mac_linuxgpu user-client ABI used by this milestone. Numbers match
/// dext/sources/MacLinuxGPUXcode.mm, dext/sources/dext_compute.h and
/// dext/sources/session_state.h, and the macOS host
/// (host/MacLinuxGPUHostApp.swift, scripts/read-driver-log.py).
enum MLG {
    static let serviceName = "MacLinuxGPU"
    static let dextBundleID = "com.geramyloveless.LemonSeedStudio.AMDGpuDriver"

    enum ClientType: UInt32 {
        case session = 0
        case observer = 1
    }

    enum Selector: UInt32 {
        case ping = 0
        case getIdentity = 1
        case getBARInfo = 2
        /// Runs the upstream amdgpu PCI probe. Upstream requests firmware by
        /// name from inside it, so a firmware servicer must run meanwhile.
        case initDevice = 9
        case queryInfo = 21
        /// Host window: 0 queries the GART aperture size; a nonzero base
        /// places it before InitDevice, as the HSA runtime does.
        case hostWindow = 54
        case runtimeBuild = 43
    }

    static let pingMagic: UInt64 = 0xA117_AB1E
    static let queryProbeStatus: UInt64 = 0x4C50_524F  // 'LPRO'
    static let querySessionState: UInt64 = 0x4C53_4553 // 'LSES'
    static let queryKernelLog: UInt64 = 0x4C4C_4F47    // 'LLOG': tag, byte cursor
    static let sessionStateWords = 9
    static let probeStatusWords = 5

    static let flagClosing: UInt64 = 1 << 0
    static let flagQuarantined: UInt64 = 1 << 1
    static let flagReleasable: UInt64 = 1 << 6
    static let flagRestartRequired: UInt64 = 1 << 7

    static let sessionFlags: [(UInt64, String)] = [
        (1 << 0, "closing"),
        (1 << 1, "quarantined"),
        (1 << 2, "stopping"),
        (1 << 3, "pci-open"),
        (1 << 4, "modules-running"),
        (1 << 5, "final-cleanup"),
        (1 << 6, "releasable"),
        (1 << 7, "restart-required"),
        (1 << 8, "raw-bar-mapped"),
        (1 << 9, "runtime-device"),
        (1 << 10, "isolation-attempted"),
        (1 << 11, "device-removed"),
        (1 << 12, "retiring"),
    ]

    static let quarantineCauses = [
        "none", "raw-bar-mapping", "shutdown-hold", "compute-uncertain", "irq-cancel",
        "endpoint-isolation", "dma-retained", "pci-fault", "probe-hold", "probe-retained",
        "probe-commit", "client-release", "release-failed",
    ]

    static let releaseBlockers = [
        "ready", "not-quarantined", "irq-pending", "irq-failed", "upstream-retained",
        "compute-retained", "raw-bar-mapped", "participants", "dma-owned", "pci-fault",
        "pci-busy", "reset-failed",
    ]

    static func describeFlags(_ flags: UInt64) -> String {
        let names = sessionFlags.filter { flags & $0.0 != 0 }.map(\.1)
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    static func name(_ table: [String], _ value: UInt64) -> String {
        value < UInt64(table.count) ? table[Int(value)] : "unknown(\(value))"
    }

    /// QueryInfo 'LPRO': attempted, modules running, probe result (negative
    /// errno), PCI transport fault, fault offset.
    static func describeProbeStatus(_ s: [UInt64]) -> String {
        "attempted \(s[0]) modules-running \(s[1]) result \(Int64(bitPattern: s[2])) "
            + "transport-fault \(s[3]) fault-offset 0x\(String(s[4], radix: 16))"
    }

    /// QueryInfo 'LSES' (the cached session snapshot).
    static func describeSessionState(_ s: [UInt64]) -> String {
        "v\(s[0]) flags 0x\(String(s[1], radix: 16)) [\(describeFlags(s[1]))], "
            + "quarantine \(name(quarantineCauses, s[2])) code \(Int64(bitPattern: s[3])) step \(s[4]), "
            + "isolation \(Int64(bitPattern: s[5])), release \(name(releaseBlockers, s[6])), "
            + "generation \(s[7]), participants \(s[8])"
    }

    /// The host's advice for a quarantined session, or nil. A quarantined
    /// driver must never be killed: it can hold the GPU's PCI function.
    static func quarantineAdvice(_ s: [UInt64]) -> String? {
        let flags = s[1]
        if flags & flagRestartRequired != 0 {
            return "restart required (quarantine \(name(quarantineCauses, s[2]))); do not kill the driver"
        }
        if flags & flagReleasable != 0 {
            return "quarantined but quiescent (\(name(quarantineCauses, s[2]))); release it or turn the driver off and on, do not kill it"
        }
        if flags & flagQuarantined != 0 {
            return "quarantined, release pending (\(name(releaseBlockers, s[6]))); do not kill the driver"
        }
        return nil
    }

    static func barType(_ type: UInt64) -> String {
        switch type {
        case 0x00: return "mem32"
        case 0x01: return "io"
        case 0x04: return "mem64"
        case 0x08: return "mem32-prefetch"
        case 0x0C: return "mem64-prefetch"
        default: return String(format: "type 0x%llx", type)
        }
    }
}

/// An IOReturn as hex plus its IOKit name when it is a common one.
func describeIOReturn(_ kr: kern_return_t) -> String {
    let code = UInt32(bitPattern: kr)
    let names: [UInt32: String] = [
        0x0000_0000: "success",
        0xE000_02BC: "kIOReturnError",
        0xE000_02BD: "kIOReturnNoMemory",
        0xE000_02BE: "kIOReturnNoResources",
        0xE000_02C0: "kIOReturnNoDevice",
        0xE000_02C1: "kIOReturnNotPrivileged",
        0xE000_02C2: "kIOReturnBadArgument",
        0xE000_02C5: "kIOReturnExclusiveAccess",
        0xE000_02C7: "kIOReturnUnsupported",
        0xE000_02CA: "kIOReturnIOError",
        0xE000_02CD: "kIOReturnNotOpen",
        0xE000_02D5: "kIOReturnBusy",
        0xE000_02D7: "kIOReturnOffline",
        0xE000_02D8: "kIOReturnNotReady",
        0xE000_02D9: "kIOReturnNotAttached",
        0xE000_02E2: "kIOReturnNotPermitted",
        0xE000_02EB: "kIOReturnAborted",
        0xE000_02F0: "kIOReturnNotFound",
        0x1000_0003: "MACH_SEND_INVALID_DEST",
    ]
    let hex = String(format: "0x%08x", code)
    if let name = names[code] { return "\(hex) \(name)" }
    return hex
}

func formatBytes(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 B" }
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    let text = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    return "\(text) \(units[unit]) (0x\(String(bytes, radix: 16)))"
}

/// The registry service the dext publishes once it matched a GPU function.
struct DriverService {
    let service: io_service_t
    let registryID: UInt64
    let className: String
    let userServerName: String
    let matchCount: Int

    /// The dext process serving it; this app's driver is MLG.dextBundleID.
    var serverDescription: String {
        userServerName == MLG.dextBundleID ? userServerName : "\(userServerName) (not this app's driver)"
    }
}

enum DriverLookup {
    /// IOServiceGetMatchingServices(IOServiceNameMatching("MacLinuxGPU")).
    /// The caller releases `service`.
    static func find() -> (DriverService?, kern_return_t) {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                              IOServiceNameMatching(MLG.serviceName),
                                              &iterator)
        guard kr == KERN_SUCCESS else { return (nil, kr) }
        defer { IOObjectRelease(iterator) }
        var first: io_service_t = 0
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            count += 1
            if first == 0 { first = service } else { IOObjectRelease(service) }
        }
        guard first != 0 else { return (nil, KERN_SUCCESS) }
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(first, &registryID)
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(first, &name)
        let server = IORegistryEntryCreateCFProperty(first, "IOUserServerName" as CFString,
                                                     kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? "unknown"
        return (DriverService(service: first, registryID: registryID,
                              className: String(cString: name), userServerName: server,
                              matchCount: count), KERN_SUCCESS)
    }
}

/// One open user client.
final class UserClient {
    let connection: io_connect_t
    let type: MLG.ClientType
    /// Whether the driver serves session calls async (mlg_selector_call_on
    /// fills it in on the first async call).
    private var protocolState: Int32 = 0

    private init(connection: io_connect_t, type: MLG.ClientType) {
        self.connection = connection
        self.type = type
    }

    static func open(_ service: io_service_t, type: MLG.ClientType) -> (UserClient?, kern_return_t) {
        var connection: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, type.rawValue, &connection)
        guard kr == KERN_SUCCESS, connection != 0 else { return (nil, kr) }
        return (UserClient(connection: connection, type: type), kr)
    }

    /// Scalar-only call; returns the IOReturn and the scalars the dext wrote.
    /// Goes through mac_linuxgpu's mlg_selector_call (host/selector_call.h):
    /// synchronous for the calls that never sleep, an awaited async call for
    /// the rest (GetIdentity, GetBARInfo, InitDevice, HostWindow, ...), which
    /// build 243 on refuses to answer synchronously.
    func call(_ selector: MLG.Selector, _ input: [UInt64] = [], outputs: Int) -> (kern_return_t, [UInt64]) {
        var output = [UInt64](repeating: 0, count: max(outputs, 1))
        var outputCount = UInt32(outputs)
        let kr = input.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                mlg_selector_call_on(connection, &protocolState, selector.rawValue,
                                     inBuf.baseAddress, UInt32(input.count), nil, 0,
                                     outBuf.baseAddress, &outputCount, nil, nil)
            }
        }
        return (kr, Array(output.prefix(Int(min(outputCount, UInt32(outputs))))))
    }

    func close() -> kern_return_t {
        IOServiceClose(connection)
    }

    /// QueryInfo 'LPRO'. Cached; allowed on session and observer clients.
    func probeStatus() -> (kern_return_t, [UInt64]?) {
        let (kr, s) = call(.queryInfo, [MLG.queryProbeStatus], outputs: MLG.probeStatusWords)
        return (kr, kr == KERN_SUCCESS && s.count >= MLG.probeStatusWords ? s : nil)
    }

    /// QueryInfo 'LSES'. Cached; allowed on session and observer clients.
    func sessionState() -> (kern_return_t, [UInt64]?) {
        let (kr, s) = call(.queryInfo, [MLG.querySessionState], outputs: MLG.sessionStateWords)
        return (kr, kr == KERN_SUCCESS && s.count >= MLG.sessionStateWords ? s : nil)
    }

    /// The driver's retained log (the linuxu printk ring, the last 16 KiB).
    /// A port of read_snapshot() in mac_linuxgpu scripts/read-driver-log.py:
    /// QueryInfo 'LLOG' with a byte cursor returns end, next cursor, byte
    /// count and up to 104 bytes of text packed into the following scalars.
    /// Reads up to the end observed by the first call.
    func kernelLog(from start: UInt64 = 0) -> KernelLogRead {
        var read = KernelLogRead(first: start, next: start)
        var cursor = start
        var target: UInt64?
        var bytes: [UInt8] = []
        for _ in 0..<4096 {
            let (kr, v) = call(.queryInfo, [MLG.queryKernelLog, cursor], outputs: 16)
            guard kr == KERN_SUCCESS else { read.error = describeIOReturn(kr); break }
            guard v.count >= 3 else { read.error = "invalid log snapshot (\(v.count) words)"; break }
            let end = v[0], next = v[1], size = v[2]
            guard size <= UInt64(v.count - 3) * 8, size <= 104, size <= next else {
                read.error = "invalid log byte count \(size)"; break
            }
            let chunkStart = next - size
            if target == nil { target = end; read.first = chunkStart }
            let goal = target!
            var chunk: [UInt8] = []
            for word in v[3...] { withUnsafeBytes(of: word.littleEndian) { chunk.append(contentsOf: $0) } }
            chunk = Array(chunk.prefix(Int(size)))
            if goal > chunkStart { bytes.append(contentsOf: chunk.prefix(Int(min(goal - chunkStart, size)))) }
            cursor = min(next, goal)
            if next >= goal || size == 0 { break }
        }
        read.next = cursor
        read.text = String(decoding: bytes, as: UTF8.self)
        return read
    }
}

struct KernelLogRead {
    /// Byte offset of the first byte returned (older bytes were overwritten).
    var first: UInt64
    /// Cursor to resume at.
    var next: UInt64
    var text = ""
    var error: String?

    /// Lines that report a failure, for the report's summary.
    var errorLines: [Substring] {
        let marks = ["error", "fail", "timed out", "timeout", "not provided", "stopped responding",
                     "quarantine", "fault", "unable", "invalid"]
        return text.split(separator: "\n").filter { line in
            let lower = line.lowercased()
            return marks.contains { lower.contains($0) }
        }
    }
}

#endif
