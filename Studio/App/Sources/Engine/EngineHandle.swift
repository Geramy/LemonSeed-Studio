import Foundation
#if canImport(LSEKit)
import LSEKit
#endif

/// One event of an engine request (LSE's lse_response_cb events).
enum EngineEvent: Sendable {
    case chunk(Data)
    case done
    case response(status: Int, body: Data)
    case error(status: Int, body: Data)
}

/// The outcome of a power call: the state after it, the driver's cause of
/// the last transition (13: the device was removed), and any error.
struct EnginePowerResult: Sendable {
    var state: GPUPowerState
    var cause: UInt32?
    var error: String?
}

/// An open engine. LSE in-process on device builds (LSEHandle); tests use a
/// fake. Every call may come from any thread.
protocol EngineHandle: AnyObject, Sendable {
    @discardableResult
    func request(method: String, path: String, body: Data?,
                 handler: @escaping @Sendable (EngineEvent) -> Void) throws -> UInt64
    func cancel(_ id: UInt64)
    /// Releases the model and the device session. Safe after a device loss:
    /// the runtime's errors from a removed device are expected there.
    func close()
    func status() -> [String: Any]
    func closeSession(_ id: String) -> Bool
    func prepareLowPower(drainMilliseconds: UInt32) -> EnginePowerResult
    func resumeFromLowPower() -> EnginePowerResult
}

/// How the service opens engines: LSE on device builds; tests inject fakes.
struct EngineOpener: Sendable {
    var isAvailable: Bool
    var version: String
    var supportsPower: Bool
    var supportsSessions: Bool
    var open: @Sendable (EngineLaunch) async throws -> any EngineHandle
    /// Load progress while an open is running (lse_status with no engine).
    var loadStatus: @Sendable () -> [String: Any]

    static let unavailable = EngineOpener(
        isAvailable: false, version: "not in this build", supportsPower: false, supportsSessions: false,
        open: { _ in throw EngineUnavailable() }, loadStatus: { [:] })

    struct EngineUnavailable: Error, CustomStringConvertible {
        var description: String { "This build has no GPU engine (simulator)." }
    }

    static var standard: EngineOpener {
        #if canImport(LSEKit)
        EngineOpener(isAvailable: true, version: "LSE \(LSEEngine.version) (ABI \(LSEEngine.abiVersion))",
                     supportsPower: LSEEngine.supportsPower, supportsSessions: LSEEngine.supportsSessions,
                     open: { launch in LSEHandle(try await LSEEngine.open(EngineService.configuration(for: launch))) },
                     loadStatus: { LSEEngine.loadStatus() })
        #else
        .unavailable
        #endif
    }
}

/// The JSON power object (lse_status "power") as a result.
func powerResult(_ power: [String: Any]?, error: String? = nil) -> EnginePowerResult {
    EnginePowerResult(state: GPUPowerState(rawValue: power?["state"] as? String ?? "") ?? .unknown,
                      cause: (power?["cause"] as? NSNumber)?.uint32Value, error: error)
}

#if canImport(LSEKit)
/// LSE in this process.
final class LSEHandle: EngineHandle, @unchecked Sendable {
    let engine: LSEEngine
    init(_ engine: LSEEngine) { self.engine = engine }

    func request(method: String, path: String, body: Data?,
                 handler: @escaping @Sendable (EngineEvent) -> Void) throws -> UInt64 {
        try engine.request(method: method, path: path, body: body) { event in
            switch event {
            case .chunk(let d): handler(.chunk(d))
            case .done: handler(.done)
            case .response(let s, let b): handler(.response(status: s, body: b))
            case .error(let s, let b): handler(.error(status: s, body: b))
            }
        }
    }

    func cancel(_ id: UInt64) { engine.cancel(id) }
    func close() { engine.close() }
    func status() -> [String: Any] { engine.status() }
    func closeSession(_ id: String) -> Bool { engine.closeSession(id) }

    func prepareLowPower(drainMilliseconds: UInt32) -> EnginePowerResult {
        let r = engine.prepareLowPower(drainMilliseconds: drainMilliseconds)
        return powerResult(r.json, error: r.error)
    }

    func resumeFromLowPower() -> EnginePowerResult {
        let r = engine.resumeFromLowPower()
        return powerResult(r.json, error: r.error)
    }
}
#endif
