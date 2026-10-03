# Third-party software in LemonText

Every dependency of the LemonText package, with its license. All of them are permissive (MIT, plus Apache-2.0 for some query files), so they are compatible with an open-source Studio and with App Store distribution.

| Component | Version | Where it is used | License |
|---|---|---|---|
| [Runestone](https://github.com/simonbs/Runestone) by Simon Støvring | 0.5.2 (`592434a`), vendored and modified | `Sources/LemonTextCore`, the engine fork (license copy: `Sources/LemonTextCore/LICENSE`) | MIT |
| [tree-sitter](https://github.com/tree-sitter/tree-sitter) runtime | 0.20.9, SwiftPM | Parsing in `LemonTextCore` | MIT |
| [TreeSitterLanguages](https://github.com/simonbs/TreeSitterLanguages) by Simon Støvring | `15cf3a9`, SwiftPM | Generated parsers and highlight queries for the grammars below | MIT |
| [tree-sitter-objc](https://github.com/tree-sitter-grammars/tree-sitter-objc) (Amaan Qureshi) | `181a81b`, vendored | `Sources/Grammars/TreeSitterObjC` and `Resources/Queries/objc` | MIT |
| [tree-sitter-cmake](https://github.com/uyha/tree-sitter-cmake) (Uy Ha) | `58993af`, vendored | `Sources/Grammars/TreeSitterCMake` and `Resources/Queries/cmake` | MIT |
| [tree-sitter-make](https://github.com/alemuller/tree-sitter-make) (Alexandre A. Muller) | `a4b9187`, vendored | `Sources/Grammars/TreeSitterMake` and `Resources/Queries/make` | MIT |

Each vendored grammar directory keeps its upstream `LICENSE` file.

## Grammars from TreeSitterLanguages

TreeSitterLanguages packages these upstream grammars; their licenses carry over.

| Language | Upstream grammar | License |
|---|---|---|
| C | tree-sitter/tree-sitter-c | MIT |
| C++ | tree-sitter/tree-sitter-cpp | MIT |
| Swift | alex-pinkus/tree-sitter-swift | MIT |
| Python | tree-sitter/tree-sitter-python | MIT |
| JavaScript | tree-sitter/tree-sitter-javascript | MIT |
| TypeScript, TSX | tree-sitter/tree-sitter-typescript | MIT |
| Rust | tree-sitter/tree-sitter-rust | MIT |
| Go | tree-sitter/tree-sitter-go | MIT |
| Markdown, Markdown inline | MDeiml/tree-sitter-markdown | MIT |
| JSON | tree-sitter/tree-sitter-json | MIT |
| YAML | ikatyang/tree-sitter-yaml | MIT |
| HTML | tree-sitter/tree-sitter-html | MIT |
| CSS | tree-sitter/tree-sitter-css | MIT |
| Shell (Bash) | tree-sitter/tree-sitter-bash | MIT |

## Highlight queries

- Most queries come from the grammar repositories (MIT).
- The Markdown queries in TreeSitterLanguages, and the Objective-C and CMake queries, follow [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) conventions and partly derive from it. nvim-treesitter is **Apache-2.0**.
- Shipping Apache-2.0 material requires keeping its notices. The query files are distributed unmodified.

## Not dependencies

- The demo app's sample files (`Demo/Samples`) were written for this project.
- The SQLite amalgamation used by the benchmark is downloaded at benchmark time and is not part of the repository. SQLite is in the public domain.
