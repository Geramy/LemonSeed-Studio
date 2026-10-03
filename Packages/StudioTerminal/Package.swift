// swift-tools-version: 6.2
//
// StudioTerminal: the Terminal panel. SwiftTerm (MIT) renders the VT100 /
// xterm screen; StudioCore's in-process shell runs the commands.

import PackageDescription

let package = Package(
    name: "StudioTerminal",
    platforms: [
        .iOS("26.2"),
    ],
    products: [
        .library(name: "StudioTerminal", targets: ["StudioTerminal"]),
    ],
    dependencies: [
        .package(path: "../StudioCore"),
        .package(path: "../StudioDesign"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .target(
            name: "StudioTerminal",
            dependencies: [
                "StudioCore",
                "StudioDesign",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
