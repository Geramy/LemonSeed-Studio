// swift-tools-version: 6.2
//
// StudioToolchain: build and run C/C++ on iPad without spawning processes.
//
//   Compiler      clang driver + cc1 + wasm-ld, in process (LemonSeedLLVM)
//   WAMRRunner    WASI on WAMR's fast interpreter, in process (LemonSeedWAMR)
//   WebKitRunner  WASI in a hidden WKWebView (JavaScriptCore JITs the wasm in
//                 the WebContent process)
//
// The two XCFrameworks are build products of Toolchain/scripts and are reached
// through the Frameworks symlink (Frameworks -> ../../Toolchain/build/xcframeworks).
// When one is missing the package still builds: the matching C bridge compiles
// to a stub that reports how to build it.

import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
func hasFramework(_ name: String) -> Bool {
  FileManager.default.fileExists(atPath: "\(packageDir)/Frameworks/\(name).xcframework/Info.plist")
}
let hasLLVM = hasFramework("LemonSeedLLVM")
let hasWAMR = hasFramework("LemonSeedWAMR")

var targets: [Target] = [
  .target(
    name: "CToolchainBridge",
    dependencies: hasLLVM ? ["LemonSeedLLVM"] : [],
    cxxSettings: [
      .define("LST_HAVE_LLVM", to: hasLLVM ? "1" : "0"),
      // Match how LLVM itself is built (no RTTI, release headers).
      .define("NDEBUG"),
      .unsafeFlags(["-fno-rtti", "-Wno-deprecated-declarations"]),
    ]
  ),
  .target(
    name: "CWAMRRunner",
    dependencies: hasWAMR ? ["LemonSeedWAMR"] : [],
    cSettings: [.define("LST_HAVE_WAMR", to: hasWAMR ? "1" : "0")]
  ),
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
if hasLLVM {
  targets.append(.binaryTarget(name: "LemonSeedLLVM", path: "Frameworks/LemonSeedLLVM.xcframework"))
}
if hasWAMR {
  targets.append(.binaryTarget(name: "LemonSeedWAMR", path: "Frameworks/LemonSeedWAMR.xcframework"))
}

let package = Package(
  name: "StudioToolchain",
  platforms: [.iOS("26.2")],
  products: [
    .library(name: "StudioToolchain", targets: ["StudioToolchain"])
  ],
  targets: targets,
  cxxLanguageStandard: .cxx17
)
