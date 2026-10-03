// swift-tools-version: 6.2
//
// StudioTelemetry: amdgpu_mtopg's MacLinuxGPU monitor as a LemonSeed Studio
// screen and status widget, on an observer-transport abstraction (IOKit,
// recorded fixtures, recording).

import PackageDescription

let package = Package(
    name: "StudioTelemetry",
    platforms: [
        .iOS("26.2"),
        // macOS: the same transport serves amdgpu_mtopg, and `swift test` runs on the host.
        .macOS(.v15),
    ],
    products: [
        .library(name: "StudioTelemetry", targets: ["StudioTelemetry"]),
    ],
    targets: [
        // The iPadOS SDK ships IOKitLib's headers and IOKit.tbd but no Swift
        // module, so the few user-client calls go through this C shim. Its
        // public header uses only fixed-width types.
        .target(
            name: "CMacLinuxGPUObserver",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "StudioTelemetry",
            dependencies: ["CMacLinuxGPUObserver"],
            resources: [.copy("Resources/Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Upstream struct gpu_metrics_v1_3, laid out by the C compiler: a
        // reference for the decoder that does not share its offset table.
        .target(name: "CGPUMetricsReference", path: "Tests/CGPUMetricsReference"),
        .testTarget(
            name: "StudioTelemetryTests",
            dependencies: ["StudioTelemetry", "CGPUMetricsReference"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
