// swift-tools-version:5.10
//
// LSEKit: Swift access to the Lemon Seed Engine running in-process.
//
// LSE.xcframework is the engine built for iOS arm64 by the LemonSeed-Engine
// repository (scripts/ios/build-ios.sh). It is a build input, not a source
// file: ./update-xcframework.sh copies (or builds) it here.
import PackageDescription

let package = Package(
    name: "LSEKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "LSEKit", targets: ["LSEKit"]),
    ],
    targets: [
        .binaryTarget(name: "LSE", path: "LSE.xcframework"),
        .target(
            name: "LSEKit",
            dependencies: ["LSE"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("iconv"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
