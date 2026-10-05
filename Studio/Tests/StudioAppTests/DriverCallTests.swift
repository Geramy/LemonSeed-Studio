import XCTest

/// The driver calls go through mac_linuxgpu's selector call, which makes the
/// async session calls build 243 on requires; and the copies of its headers
/// in StudioTelemetry are the submodule's.
final class DriverCallTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repository.appending(path: path), encoding: .utf8)
    }

    /// Code lines only: comments may name IOConnectCall*.
    private func code(_ text: String) -> String {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    func testDriverClientsCallThroughSelectorCall() throws {
        for path in ["Studio/App/Sources/Diagnostics/DriverClient.swift", "Engine/ProofOfLife/App/DriverClient.swift"] {
            let text = code(try source(path))
            XCTAssertTrue(text.contains("mlg_selector_call_on(connection, &protocolState, selector.rawValue"), path)
            XCTAssertFalse(text.contains("IOConnectCall"), "\(path) calls IOKit directly")
        }
        for header in ["Studio/App/Studio-Bridging-Header.h", "Engine/ProofOfLife/App/ProofOfLife-Bridging-Header.h"] {
            XCTAssertTrue(try source(header).contains("#include \"selector_call.h\""), header)
        }
    }

    func testTheObserverCallsThroughSelectorCall() throws {
        let shim = code(try source("Packages/StudioTelemetry/Sources/CMacLinuxGPUObserver/mlg_observer.c"))
        XCTAssertTrue(shim.contains("return mlg_selector_call(connection, selector,"))
        XCTAssertFalse(shim.contains("IOConnectCall"))
    }

    func testTheVendoredHeadersMatchTheSubmodule() throws {
        let vendored = "Packages/StudioTelemetry/Sources/CMacLinuxGPUObserver/mac_linuxgpu/"
        for header in ["host/selector_call.h", "host/owner_call.h", "dext/sources/session_state.h", "dext/sources/power_state.h"] {
            XCTAssertEqual(try source(vendored + header), try source("third_party/mac_linuxgpu/" + header),
                           "\(header): copy it again from third_party/mac_linuxgpu")
        }
    }
}
