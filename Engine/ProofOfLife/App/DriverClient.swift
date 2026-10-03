import Foundation

/// The mac_linuxgpu user-client ABI used by this milestone. Numbers match
/// dext/sources/MacLinuxGPUXcode.mm and dext/sources/session_state.h.
enum MLG {
    static let serviceName = "MacLinuxGPU"
    static let dextBundleID = "com.geramyloveless.MacAMDGPUHost.MacAMDGPU"

    enum ClientType: UInt32 {
        case session = 0
        case observer = 1
    }

    enum Selector: UInt32 {
        case ping = 0
        case getIdentity = 1
        case getBARInfo = 2
        case queryInfo = 21
        case getReBARInfo = 41
        case runtimeBuild = 43
    }

    static let pingMagic: UInt64 = 0xA117_AB1E
    static let queryProbeStatus: UInt64 = 0x4C50_524F  // 'LPRO'
    static let querySessionState: UInt64 = 0x4C53_4553 // 'LSES'
    static let sessionStateWords = 9

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
    let matchCount: Int
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
        return (DriverService(service: first, registryID: registryID,
                              className: String(cString: name), matchCount: count), KERN_SUCCESS)
    }
}

/// One open user client.
final class UserClient {
    let connection: io_connect_t
    let type: MLG.ClientType

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
    func call(_ selector: MLG.Selector, _ input: [UInt64] = [], outputs: Int) -> (kern_return_t, [UInt64]) {
        var output = [UInt64](repeating: 0, count: max(outputs, 1))
        var outputCount = UInt32(outputs)
        let kr = input.withUnsafeBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                IOConnectCallScalarMethod(connection, selector.rawValue,
                                          inBuf.baseAddress, UInt32(input.count),
                                          outBuf.baseAddress, &outputCount)
            }
        }
        return (kr, Array(output.prefix(Int(min(outputCount, UInt32(outputs))))))
    }

    func close() -> kern_return_t {
        IOServiceClose(connection)
    }
}
