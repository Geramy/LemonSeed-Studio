# LemonSeed Studio app: third-party components

Components the app target pulls in directly or through the shell's
packages. Each package lists its own in its THIRD_PARTY.md; the build
bundles every THIRD_PARTY.md in the repository into Settings › About.

| Component | License | In the app | Notes |
|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 | MIT | yes (StudioTerminal) | Terminal view |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) 2.304 | OFL-1.1 | yes (StudioDesign) | Bundled font |
| swift-argument-parser, swift-docc-plugin | Apache-2.0 | no | SwiftTerm's package dependencies, build tooling only |
| [mac_linuxgpu](https://github.com/lemonade-sdk/mac_linuxgpu) (`third_party/mac_linuxgpu`) | Original code MIT OR GPL-2.0-only; upstream Linux sources compiled into the dext include GPL-2.0 files | device builds only, as the separate embedded dext executable | Risk L1 in planning/PLAN.md: the shipped dext binary is GPL-2.0 as a whole. The app talks to it over IOKit; it is a separate program. Simulator builds do not include it. |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT | no | Generates the Xcode project at build time |

The app itself uses only Apple SDK frameworks otherwise (SwiftUI, UIKit,
IOKit, SystemExtensions, GameController, UniformTypeIdentifiers).
