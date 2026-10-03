// StudioTelemetry: the live transport, a MacLinuxGPU observer over IOKit.
//
// IOServiceGetMatchingServices(IOServiceNameMatching("MacLinuxGPU")) and
// IOServiceOpen(service, task, 1), as amdgpu_mtopg's LinuxDriver.swift does,
// through the CMacLinuxGPUObserver shim (iPadOS has no IOKit Swift module).
// On iPadOS the app needs com.apple.developer.driverkit.communicates-with-drivers;
// on macOS an IOKit user-client read needs no entitlement.
//
// MIT License (amdgpu_mtopg); see THIRD_PARTY.md.

import CMacLinuxGPUObserver
import Foundation

public struct IOKitObserverDirectory: ObserverDirectory {
    public let serviceName: String

    public init(serviceName: String = LinuxABI.serviceName) {
        self.serviceName = serviceName
    }

    public var sourceName: String { "IOKit \(serviceName) observer" }

    public func devices() -> [ObserverDevice] {
        var ids = [UInt64](repeating: 0, count: 16)
        let count = ids.withUnsafeMutableBufferPointer { buffer in
            mlg_service_ids(serviceName, buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0 else { return [] }
        return ids.prefix(Int(min(count, Int64(ids.count)))).map {
            ObserverDevice(registryID: $0, label: "0x" + String($0, radix: 16))
        }
    }

    public func openObserver(registryID: UInt64) throws -> any ObserverConnection {
        var port: UInt32 = 0
        let kr = mlg_open(registryID, LinuxABI.observerClient, &port)
        guard kr == IOReturnValue.success else { throw ObserverError.open(kr) }
        return IOKitObserverConnection(port: port)
    }
}

/// One open observer user client. Closed on `close()` or deinit.
public final class IOKitObserverConnection: ObserverConnection {
    private var port: UInt32

    init(port: UInt32) {
        self.port = port
    }

    deinit { close() }

    public func call(selector: UInt32, scalars: [UInt64], input: [UInt8]?,
                     outputWords: Int, outputBytes: Int) -> ObserverReply {
        guard port != 0 else { return ObserverReply(status: IOReturnValue.notAttached) }
        var outWords = [UInt64](repeating: 0, count: max(outputWords, 1))
        var outCount = UInt32(outputWords)
        var outBytes = [UInt8](repeating: 0, count: max(outputBytes, 1))
        var outSize = outputBytes
        let kr: Int32 = scalars.withUnsafeBufferPointer { scalarsPtr in
            outWords.withUnsafeMutableBufferPointer { wordsPtr in
                outBytes.withUnsafeMutableBufferPointer { bytesPtr in
                    let outStruct = outputBytes > 0 ? UnsafeMutableRawPointer(bytesPtr.baseAddress) : nil
                    if let input, !input.isEmpty {
                        return input.withUnsafeBufferPointer { inputPtr in
                            mlg_call(port, selector, scalarsPtr.baseAddress, UInt32(scalars.count),
                                     inputPtr.baseAddress, input.count,
                                     wordsPtr.baseAddress, &outCount, outStruct, &outSize)
                        }
                    }
                    return mlg_call(port, selector, scalarsPtr.baseAddress, UInt32(scalars.count),
                                    nil, 0, wordsPtr.baseAddress, &outCount, outStruct, &outSize)
                }
            }
        }
        let words = Array(outWords.prefix(Int(min(outCount, UInt32(outWords.count)))))
        let bytes = Array(outBytes.prefix(min(outSize, outputBytes)))
        return ObserverReply(status: kr, words: words, bytes: bytes)
    }

    public func close() {
        guard port != 0 else { return }
        _ = mlg_close(port)
        port = 0
    }
}
