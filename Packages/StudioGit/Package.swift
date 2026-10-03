// swift-tools-version: 6.2
//
// StudioGit: Git, hosting and source control for LemonSeed Studio.
//
//   GitKit       libgit2 wrapper (actors), credentials, SSH keys, LFS
//   Forge        GitHub / GitLab accounts, OAuth device flow, REST/GraphQL
//   StudioGitUI  SwiftUI views: sign-in, repo browser, source control,
//                history graph, pull/merge requests
//
// Clibgit2.xcframework is built from source by scripts/build-libgit2.sh and
// is not committed. Run that script once before building this package.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "StudioGit",
    platforms: [.iOS("26.2")],
    products: [
        .library(name: "GitKit", targets: ["GitKit"]),
        .library(name: "Forge", targets: ["Forge"]),
        .library(name: "StudioGitUI", targets: ["StudioGitUI"]),
    ],
    targets: [
        .binaryTarget(name: "Clibgit2", path: "build/Clibgit2.xcframework"),
        .target(
            name: "CGitShim",
            dependencies: ["Clibgit2"],
            path: "Sources/CGitShim"
        ),
        .target(
            name: "GitKit",
            dependencies: ["Clibgit2", "CGitShim"],
            path: "Sources/GitKit",
            resources: [.copy("Resources/cacert.pem")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Forge",
            dependencies: ["GitKit"],
            path: "Sources/Forge",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "StudioGitUI",
            dependencies: ["GitKit", "Forge"],
            path: "Sources/StudioGitUI",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "GitKitTests",
            dependencies: ["GitKit"],
            path: "Tests/GitKitTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ForgeTests",
            dependencies: ["Forge", "GitKit"],
            path: "Tests/ForgeTests",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StudioGitUITests",
            dependencies: ["StudioGitUI", "GitKit", "Forge"],
            path: "Tests/StudioGitUITests",
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
