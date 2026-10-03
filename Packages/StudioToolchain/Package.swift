// swift-tools-version: 6.2
//
// StudioToolchain: build and run C/C++ on iPad without spawning processes.
//
//   Compiler      clang driver + cc1 + wasm-ld, in process (LemonSeedLLVM)
//   WAMRRunner    WASI on WAMR's fast interpreter, in process (LemonSeedWAMR)
//   WebKitRunner  WASI in a hidden WKWebView (JavaScriptCore JITs the wasm in
//                 the WebContent process)
//
// The two XCFrameworks are build products of Toolchain/scripts, reached
// through the Frameworks symlink (Frameworks -> ../../Toolchain/build/xcframeworks):
//
//   build-llvm-ios.sh   LemonSeedLLVM.xcframework  (about 20 minutes per slice at -j10)
//   build-wamr-ios.sh   LemonSeedWAMR.xcframework  (seconds)
//
// To build the package without them, run make-stub-xcframeworks.sh: it fills
// in placeholders whose config header tells the C bridges to compile to stubs
// that report how to build the real thing. (The decision lives in a header,
// not in this manifest, because SwiftPM caches manifest evaluation.)

import PackageDescription

let targets: [Target] = [
  .binaryTarget(name: "LemonSeedLLVM", path: "Frameworks/LemonSeedLLVM.xcframework"),
  .binaryTarget(name: "LemonSeedWAMR", path: "Frameworks/LemonSeedWAMR.xcframework"),
  .target(
    name: "CToolchainBridge",
    dependencies: ["LemonSeedLLVM"],
    cxxSettings: [
      // Match how LLVM itself is built (no RTTI, release headers).
      .define("NDEBUG"),
      .unsafeFlags(["-fno-rtti", "-Wno-deprecated-declarations"]),
    ]
  ),
  .target(name: "CWAMRRunner", dependencies: ["LemonSeedWAMR"]),
  .target(
    name: "StudioToolchain",
    dependencies: ["CToolchainBridge", "CWAMRRunner"],
    resources: [.copy("Resources/WASIRuntime")]
  ),
  .testTarget(
    name: "StudioToolchainTests",
    dependencies: ["StudioToolchain"]
  ),
]

let package = Package(
  name: "StudioToolchain",
  platforms: [.iOS("26.2")],
  products: [
    .library(name: "StudioToolchain", targets: ["StudioToolchain"])
  ],
  targets: targets,
  cxxLanguageStandard: .cxx17
)
