// swift-tools-version: 6.2
//
// StudioCore: the contracts between the Studio shell and the packages that
// plug into it (editor, Git, agent, telemetry, terminal), plus the shared
// workspace model: documents, file tree, file operations, file watching,
// security-scoped bookmarks, workspace search, fuzzy matching and the
// built-in shell commands.

import PackageDescription

let package = Package(
    name: "StudioCore",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.2"),
        // macOS is listed only so `swift test` runs on a Mac; the product is iPad only.
        .macOS("26.0"),
    ],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
    ],
    dependencies: [
        .package(path: "../StudioDesign"),
    ],
    targets: [
        .target(
            name: "StudioCore",
            dependencies: ["StudioDesign"]
        ),
        .testTarget(
            name: "StudioCoreTests",
            dependencies: ["StudioCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
