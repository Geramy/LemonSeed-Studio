// swift-tools-version: 6.2

import PackageDescription

/// Grammars that come prebuilt from TreeSitterLanguages. Each one contributes a parser
/// module (`TreeSitterX`) and a queries module (`TreeSitterXQueries`).
let sharedGrammars = [
    "Bash", "C", "CPP", "CSS", "Go", "HTML", "JavaScript", "JSON", "Markdown",
    "MarkdownInline", "Python", "Rust", "Swift", "TypeScript", "TSX", "YAML"
]

let grammarDependencies: [Target.Dependency] = sharedGrammars.flatMap { name -> [Target.Dependency] in
    [
        .product(name: "TreeSitter\(name)", package: "TreeSitterLanguages"),
        .product(name: "TreeSitter\(name)Queries", package: "TreeSitterLanguages")
    ]
}

let package = Package(
    name: "LemonText",
    defaultLocalization: "en",
    platforms: [
        .iOS("26.2")
    ],
    products: [
        .library(name: "LemonText", targets: ["LemonText"])
    ],
    dependencies: [
        // Tree-sitter runtime. Pinned to the 0.20 line, which the vendored core and the
        // TreeSitterLanguages grammars (ABI 13/14) are built against.
        .package(url: "https://github.com/tree-sitter/tree-sitter", .upToNextMinor(from: "0.20.9")),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages", revision: "15cf3a9ec3ab95e0d058b7df9f35619123c9e02d")
    ],
    targets: [
        // Fork of Runestone (MIT). Text storage, line manager, Core Text line layout,
        // UITextInput and the tree-sitter integration. Kept in the Swift 5 language mode
        // so that upstream changes stay easy to merge.
        .target(
            name: "LemonTextCore",
            dependencies: [
                .product(name: "TreeSitter", package: "tree-sitter")
            ],
            exclude: ["LICENSE"],
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
                .process("TextView/Appearance/Theme.xcassets")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // Grammars not available in TreeSitterLanguages, vendored as generated C.
        .target(
            name: "TreeSitterObjC",
            path: "Sources/Grammars/TreeSitterObjC",
            exclude: ["LICENSE"],
            cSettings: [.headerSearchPath("src"), .unsafeFlags(["-w"])]
        ),
        .target(
            name: "TreeSitterCMake",
            path: "Sources/Grammars/TreeSitterCMake",
            exclude: ["LICENSE"],
            cSettings: [.headerSearchPath("src"), .unsafeFlags(["-w"])]
        ),
        .target(
            name: "TreeSitterMake",
            path: "Sources/Grammars/TreeSitterMake",
            exclude: ["LICENSE"],
            cSettings: [.headerSearchPath("src"), .unsafeFlags(["-w"])]
        ),
        .target(
            name: "LemonText",
            dependencies: [
                "LemonTextCore",
                "TreeSitterObjC",
                "TreeSitterCMake",
                "TreeSitterMake"
            ] + grammarDependencies,
            resources: [
                .copy("Resources/Queries")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LemonTextTests",
            dependencies: ["LemonText", "LemonTextCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
