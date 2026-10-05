// StudioTelemetry: the observer transport.
//
// amdgpu_mtopg's LinuxTransport opened IOServiceOpen(..., 1) itself and
// called IOConnectCallMethod on a raw io_connect_t. Here every read goes
// through ObserverConnection, so the same transport and model run on a live
// MacLinuxGPU observer (IOKit), a recorded fixture, or a recorder wrapping
// either. The ABI the calls carry is mac_linuxgpu dext/sources/session_state.h.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import Foundation

/// An IOReturn. Spelled out (rather than Darwin's kern_return_t) so fixtures
/// and tests can name values without IOKit.
public typealias IOReturnCode = Int32

public enum IOReturnValue {
    public static let success: IOReturnCode = 0
    public static let error = IOReturnCode(bitPattern: 0xe00002bc)
    public static let noDevice = IOReturnCode(bitPattern: 0xe00002c0)
    public static let badArgument = IOReturnCode(bitPattern: 0xe00002c2)
    public static let unsupported = IOReturnCode(bitPattern: 0xe00002c7)
    public static let notAttached = IOReturnCode(bitPattern: 0xe00002d9)
    public static let notReady = IOReturnCode(bitPattern: 0xe00002d8)
    public static let notFound = IOReturnCode(bitPattern: 0xe00002f0)
    public static let notPermitted = IOReturnCode(bitPattern: 0xe00002e2)
    /// A bounded read (SysfsRead, DrmInfo) that ran out of its 250 ms.
    public static let timeout = IOReturnCode(bitPattern: 0xe00002d6)
    /// A bounded read refused while an earlier one is still running.
    public static let busy = IOReturnCode(bitPattern: 0xe00002d5)
    /// MACH_SEND_INVALID_DEST: the connection's port is gone.
    public static let machSendInvalidDest: IOReturnCode = 0x10000003

    public static func hex(_ code: IOReturnCode) -> String {
        String(format: "0x%08x", UInt32(bitPattern: code))
    }
}

/// One IOConnectCallMethod reply.
public struct ObserverReply: Sendable, Equatable {
    public var status: IOReturnCode
    public var words: [UInt64]
    public var bytes: [UInt8]

    public init(status: IOReturnCode, words: [UInt64] = [], bytes: [UInt8] = []) {
        self.status = status
        self.words = words
        self.bytes = bytes
    }
}

/// A MacLinuxGPU observer user client (type 1). The observer never claims
/// PCI, joins a session or touches queues; it reads cached state and the
/// Linux data paths (SysfsRead, DrmInfo).
///
/// A connection is used from one thread at a time (the telemetry queue).
public protocol ObserverConnection: AnyObject {
    /// IOConnectCallMethod: `scalars` and `input` in, up to `outputWords`
    /// scalars and `outputBytes` struct bytes out.
    func call(selector: UInt32, scalars: [UInt64], input: [UInt8]?,
              outputWords: Int, outputBytes: Int) -> ObserverReply
    func close()
}

/// A GPU an observer can be opened on.
public struct ObserverDevice: Sendable, Hashable, Identifiable {
    public var registryID: UInt64
    public var label: String
    public var id: UInt64 { registryID }

    public init(registryID: UInt64, label: String) {
        self.registryID = registryID
        self.label = label
    }
}

public enum ObserverError: Error, Equatable, CustomStringConvertible {
    case open(IOReturnCode)
    case noSuchDevice(UInt64)

    public var description: String {
        switch self {
        case .open(let kr): return "observer open: \(IOReturnValue.hex(kr))"
        case .noSuchDevice(let id): return "no MacLinuxGPU service with registry ID 0x\(String(id, radix: 16))"
        }
    }
}

/// Enumerates MacLinuxGPU services and opens observers on them.
public protocol ObserverDirectory: Sendable {
    /// A short name for where the data comes from ("IOKit MacLinuxGPU",
    /// "fixture r9700-idle"), shown with every readout.
    var sourceName: String { get }
    /// Provenance shown in the data-source panel (capture date, host, ...).
    var sourceDetails: [LabeledText] { get }
    func devices() -> [ObserverDevice]
    func openObserver(registryID: UInt64) throws -> any ObserverConnection
}

extension ObserverDirectory {
    public var sourceDetails: [LabeledText] { [] }
}

// MARK: - The MacLinuxGPU observer ABI

/// Selectors and constants of the observer client (session_state.h), and
/// the AMDGPU_INFO / register constants the monitor uses.
public enum LinuxABI {
    public static let serviceName = "MacLinuxGPU"
    public static let observerClient: UInt32 = 1
    public static let selQuery: UInt32 = 21        // cached state only
    public static let selRuntimeBuild: UInt32 = 43
    public static let selSysfsRead: UInt32 = 80
    public static let selDrmInfo: UInt32 = 81
    public static let opRead: UInt64 = 0
    public static let opList: UInt64 = 1
    public static let chunk = 4096
    public static let pathMax = 256
    public static let tagProbeStatus: UInt64 = 0x4c50524f   // "LPRO"
    // include/uapi/drm/amdgpu_drm.h
    public static let infoReadMMRReg: UInt64 = 0x15
    // SOC15 GC register layout (gc_*_offset.h regGRBM_STATUS, base index 0;
    // gc_*_sh_mask.h GRBM_STATUS__GUI_ACTIVE). The segment base is the
    // device's own, from its IP discovery table in sysfs.
    public static let grbmStatusOffset: UInt32 = 0x0da4
    public static let grbmGuiActive: UInt32 = 1 << 31
}
