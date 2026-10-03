# LemonText

The code editor engine of LemonSeed Studio: a native iPad editor with tree-sitter highlighting, a minimap, folding, several carets, find/replace, diagnostics, completion hooks, and Apple Pencil and trackpad input. It provides a UIKit view controller and a SwiftUI view.

LemonText builds on **LemonTextCore**, a fork of [Runestone](https://github.com/simonbs/Runestone) (MIT). Runestone supplies the text storage, line manager, Core Text line layout, `UITextInput` and tree-sitter integration. The fork's changes are listed under [Engine changes](#engine-changes).

Requirements: iPadOS 26.2, Swift 6.

## Using it

### SwiftUI

```swift
import LemonText

struct EditorView: View {
    @State private var model = LemonTextEditorModel(language: .cpp, theme: .lemonDark)

    var body: some View {
        LemonTextEditor(model: model)
            .task { model.load(text: source, fileName: "engine.cpp") }
    }
}
```

`LemonTextEditorModel` is `@Observable`. It publishes the caret line and column, the selection length, the caret count, the line count and whether highlighting is in progress. Assign `theme`, `configuration`, `diagnostics` and `gutterMarkers` to change the editor. Call `perform(_:)` to run a command (find, go to line, toggle comment, fold all, show completions, inline suggestion and so on). The text stays in the editor; reading `model.text` copies it on demand.

### UIKit

```swift
let editor = LemonTextViewController(configuration: .defaults(for: .c), theme: .lemonDark)
editor.delegate = self
editor.load(text: contents, fileName: url.lastPathComponent) { metrics in
    print("first screen after \(metrics.totalToFirstScreen)")
}
editor.diagnostics = [Diagnostic(range: range, severity: .error, message: "use of undeclared identifier", source: "clangd")]
```

## API surface

| Type | Purpose |
|---|---|
| `LemonTextViewController` | The editor. Loading (`load(text:language:)`, `load(text:fileName:)`, `text`, `textSnapshot()`), selection (`selectedRange`, `selections`, `caretPosition`), commands (`toggleComment`, `indentLines`, `outdentLines`, `moveLinesUp/Down`, `selectNextOccurrence`, `selectAllOccurrences`, `goToLine`, `showFind`, `findNext/Previous`, `showGoToLine`, `fold(atLine:)`, `unfold`, `foldAll`, `unfoldAll`, `toggleSoftWrap`), decorations (`diagnostics`, `gutterMarkers`, `foldingRanges`), completion (`completionProvider`, `triggerCompletion`, `showCompletions`, `setInlineSuggestion`, `acceptInlineSuggestion`), `keystrokeLatency()`, `showsSoftwareKeyboard`, and the underlying `textView` |
| `LemonTextViewControllerDelegate` | Text and selection changes, load metrics, highlighting finished, pointer and Pencil hover (for hover cards), Pencil double tap and squeeze |
| `LemonTextEditor`, `LemonTextEditorModel`, `EditorCommand` | SwiftUI wrapper |
| `EditorConfiguration`, `EditorFont` | Line numbers, current line, indentation guides, invisibles, soft wrap, minimap, bracket matching, auto-closing pairs, suggestions as you type, folding controls, tab width, spaces or tabs, page guide, scroll past end, read-only; the font, with line heights snapped to a 4 pt grid |
| `EditorTheme`, `ThemePalette`, `ThemeColor`, `SyntaxStyle` | Themes as values. `EditorTheme(name:palette:)` derives every editor color from a design palette (background, text tiers, separator, accent and eight hues), so a StudioDesign palette maps one to one. Built in: Lemon Dark, Lemon Light, Seed High-Contrast. Capture styles resolve through the dotted hierarchy and aliases for Neovim-style capture names |
| `VSCodeThemeImporter` | Imports VS Code color themes (JSON with comments), mapping workbench colors and TextMate scopes |
| `LemonLanguage`, `LanguageDetector`, `LanguageRegistry` | 17 languages plus plain text, detection by file name, extension, shebang and header contents, and the tree-sitter grammars |
| `FindEngine`, `FindQuery`, `FindMatch` | Find and replace (plain or regex, case, whole word, in selection, `$1` and `${1}` templates), usable off the main thread |
| `EditCommands`, `TextEdit`, `EditResult` | The edit model: pure functions for several carets, select next occurrence, toggle comment, indent and outdent |
| `BracketMatcher`, `IndentGuides`, `FoldingRangeCalculator`, `FoldState`, `FoldingRange` | Structure helpers behind bracket matching, guides and folding |
| `Diagnostic`, `DiagnosticSeverity`, `LineStartTable`, `GutterMarker` | Diagnostics layer API, shaped like LSP (UTF-16 positions), plus gutter markers (dot, bar, deletion, SF Symbol) |
| `CompletionProvider`, `CompletionItem`, `CompletionContext`, `CompletionFilter`, `WordCompletionProvider` | Completion hooks for clangd and the agent. The popup ranks items with a fuzzy filter; the default provider offers keywords and nearby identifiers |
| `EditorBenchmark` | The week-2 gate benchmark: open, highlight, scroll, jumps, typing, memory |

## Features

| Feature | Status |
|---|---|
| Syntax highlighting, themeable | Done. tree-sitter for C, C++, Objective-C, Swift, Python, JavaScript, TypeScript/TSX, Rust, Go, CMake, Make, Markdown (with injected code blocks), JSON, YAML, HTML (with CSS and JS), CSS, shell |
| Line numbers, current-line highlight | Done |
| Indentation guides | Done, with the guide of the caret's block emphasised |
| Bracket matching, auto-close | Done |
| Soft wrap | Done (⌥Z) |
| Invisibles | Done |
| Find/replace with regex | Done (⌘F, ⌥⌘F, ⌘G, ⇧⌘G, ⌘E) |
| Go to line | Done (⌃G, accepts `line:column`) |
| Several carets | Done: ⌘D, ⇧⌘L, ⌥-click; typing, deleting and arrows apply at every caret as one undo step. Column (box) selection with ⌥-drag is not done |
| Code folding | Done: brackets and comments, or indentation for Python, YAML, Make and Markdown; gutter chevrons, placeholders, ⌥⌘[ and ⌥⌘], fold all. A language server can supply the ranges instead |
| Minimap | Done: highlighted line runs, viewport slider, tap and drag, markers for diagnostics, find matches and gutter markers |
| Smooth scrolling of large files | Done; see `docs/benchmarks/lemontext.md` |
| Keyboard shortcuts | ⌘F ⌘G ⌘/ ⌘] ⌘[ ⌥↑ ⌥↓ ⌘D ⇧⌘L ⌃G ⌃Space ⌥Z ⌘= ⌘- ⌃A ⌃E ⌃K, all listed in the ⌘ overlay |
| Trackpad | I-beam pointer, click-and-drag selection, ⌥-click adds a caret, gutter click and drag selects lines, minimap pointer effect |
| Apple Pencil | Drag to select, without scrolling; hover shows where the caret will land and reports the location (hover-card hook); double tap and squeeze reach the delegate; the system selection handles work with Pencil |
| Diagnostics layer | Done: squiggles per severity, gutter dots, hover and tap cards, minimap markers; ranges follow edits until replaced |
| Completion popup and inline suggestions | Done |

## Engine changes

These are changes to LemonTextCore relative to Runestone 0.5.2:

- **Background reparsing for large documents.** Tree-sitter's incremental reparse is not proportional to the edit: in the SQLite amalgamation it costs about 56 ms natively. Above 1 MB, edits now shift the tree and reparse on a background queue.
- **Hidden lines**, the primitive for folding.
- **Line geometry and highlight capture APIs** for decoration layers and the minimap.
- **Incremental batch replace.** Runestone's batch replace swaps in a whole new string.
- **`deleteBackward()` works with a collapsed selection.**
- **Return never drops indentation** when the syntax tree is incomplete.
- **Programmatic edits notify the text input system.**
- **More query predicates:** `any-of?` and `lua-match?`, a fixed `eq?` between two captures, and query length passed in bytes.
- **A transparent text layer**, so decorations can sit beneath the text.
- **A custom input view.**

## Demo app

```sh
cd Packages/LemonText/Demo
xcodegen generate
open LemonTextDemo.xcodeproj
```

The demo opens a sample in every language and adds theme, view and demo menus (sample diagnostics, inline suggestion, carets on every match). It also runs the benchmark.

It accepts these launch arguments:

| Argument | Effect |
|---|---|
| `-sample <file>` | Opens a sample |
| `-theme dark\|light\|contrast` | Picks a theme |
| `-stage find+diagnostics+…` | Sets up a state for screenshots |
| `-nokeyboard` | Hides the software keyboard, as with a Magic Keyboard |
| `-benchmark sqlite3.c` | Runs the benchmark |
| `-keyboardStress` | Runs the keyboard stress suite |

## Tests

```sh
cd Packages/LemonText
xcodebuild test -scheme LemonText -destination 'platform=iOS Simulator,id=<simulator>' -parallel-testing-enabled NO
cd Demo && xcodegen generate
xcodebuild test -project LemonTextDemo.xcodeproj -scheme LemonTextDemo -destination 'platform=iOS Simulator,id=<simulator>' -parallel-testing-enabled NO
```

- **Package tests** cover:
  - language detection and every grammar and query;
  - theme mapping and VS Code import;
  - find/replace;
  - the edit model;
  - brackets, guides and folding;
  - diagnostics and completion ranking;
  - the engine's keyboard paths, hidden lines and background reparsing.
- **Demo UI tests** run two suites:
  - the keyboard stress suite: hardware-keyboard input replayed through `UITextInput`, plus bursts in a large file with a latency assertion;
  - typing with real key events.

See [THIRD_PARTY.md](THIRD_PARTY.md) for licenses.
