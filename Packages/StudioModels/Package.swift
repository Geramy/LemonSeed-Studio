// swift-tools-version: 6.2
//
// StudioModels: models for LemonSeed Engine on the iPad.
//
//  - StudioModels    catalog, persistent registry, Hugging Face client and
//                    compatibility search, background downloader with
//                    resumable range chunks and streaming SHA-256
//                    verification, LSE launch presets. Foundation only.
//  - StudioModelsUI  the Models screen and Hugging Face search, standalone
//                    so ProofOfLife can show it now and the Studio app later.
//
// The DFlash2 draft downloads as its BF16 source. LSE converts it to Q8 the
// first time it opens it, so this package has no converter.
//
// macOS is declared only so `swift test` runs on the build Mac.
import PackageDescription

let package = Package(
    name: "StudioModels",
    defaultLocalization: "en",
    platforms: [.iOS("26.2"), .macOS("26.0")],
    products: [
        .library(name: "StudioModels", targets: ["StudioModels"]),
        .library(name: "StudioModelsUI", targets: ["StudioModelsUI"]),
    ],
    targets: [
        .target(
            name: "StudioModels",
            resources: [.copy("Resources/Catalog.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "StudioModelsUI",
            dependencies: ["StudioModels"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StudioModelsTests",
            dependencies: ["StudioModels"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
