// swift-tools-version: 6.2
//
// StudioAgent: the LemonSeed coding agent.
//
//  - StudioAgent    the engine-agnostic core: an OpenAI-compatible streaming
//                   client, the agent loop, tools, permissions, checkpoints,
//                   change review and pi v3 JSONL sessions. Foundation only.
//  - StudioAgentUI  SwiftUI surfaces over the core: chat panel, tool cards,
//                   diff review, session list and inline selection actions.
//                   Plain SwiftUI styled through `AgentTheme`, so the
//                   design package can restyle it without forking views.
//
// macOS is declared only so the core's unit tests also run with `swift test`
// on the build Mac; the product ships on iPadOS.
import PackageDescription

let package = Package(
    name: "StudioAgent",
    defaultLocalization: "en",
    platforms: [.iOS("26.2"), .macOS("26.0")],
    products: [
        .library(name: "StudioAgent", targets: ["StudioAgent"]),
        .library(name: "StudioAgentUI", targets: ["StudioAgentUI"]),
    ],
    targets: [
        .target(name: "StudioAgent"),
        .target(name: "StudioAgentUI", dependencies: ["StudioAgent"]),
        .testTarget(name: "StudioAgentTests", dependencies: ["StudioAgent"]),
        .testTarget(name: "StudioAgentUITests", dependencies: ["StudioAgentUI", "StudioAgent"]),
    ]
)
