// swift-tools-version: 6.2
//
// StudioDesign: the LemonSeed Studio design system. Colors and themes,
// typography, spacing, iconography, materials, motion and a few shared
// components. Every Studio package can depend on it; it depends on nothing
// but SwiftUI.

import PackageDescription

let package = Package(
    name: "StudioDesign",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.2"),
        // macOS is listed only so `swift test` runs on a Mac; the product is iPad only.
        .macOS("26.0"),
    ],
    products: [
        .library(name: "StudioDesign", targets: ["StudioDesign"]),
    ],
    targets: [
        .target(
            name: "StudioDesign",
            resources: [
                .copy("Resources/Fonts"),
            ]
        ),
        .testTarget(
            name: "StudioDesignTests",
            dependencies: ["StudioDesign"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
