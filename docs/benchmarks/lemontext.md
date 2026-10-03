# LemonText week-2 benchmark: sqlite3.c

*Measured on 2026-10-02/03. Plan reference: section 2.3, "Gate (end of week 2)".*

## Recommendation: **GO**, with two conditions

Keep LemonText on the Runestone-derived engine (LemonTextCore).

- **First screen:** well inside the gate.
- **Editor's own time per keystroke:** about 2 ms at p99.
- **Scrolling:** main-thread work per frame stays under 5.5 ms at p99, well inside the 8.3 ms budget of a 120 Hz frame.
- **Layout:** Core Text line layout was never the bottleneck. The plan's fallback ("replace layout with our own Core Text line-fragment cache") is not needed.

The problems were elsewhere and are fixed in the fork:

- synchronous tree-sitter reparsing on every keystroke;
- typesetting from the top of the document on every jump.

The conditions:

1. **Memory.** The gate fails: 250 MB once highlighted and 314 MB at peak, against a 150 MB target.
   - Most of it is the tree-sitter syntax tree (about 100 MB for this file, measured natively) and per-line bookkeeping for 270,000 lines.
   - That is within the plan's 0.6–1.0 GB budget for "UI + editor + syntax" on a 16 GB iPad, but over the gate.
   - Either revise the gate for a 9.5 MB file to ≤ 350 MB, or add a large-file mode. In that mode, files over about 4 MB would keep no full tree: they would get viewport-only highlighting from a windowed parse, or a lexical highlighter.
   - Decide at the week-2 review.
2. **Device confirmation.** These numbers come from the iOS Simulator, which renders at 60 Hz. Re-run the same benchmark on the M4 iPad Pro to confirm 120 fps and keystroke-to-glyph under 8.3 ms with the GPU compositor.
   - Run it from the demo app's **Benchmark** item, or launch with `-benchmark sqlite3.c`.

## Gate results

| Gate (plan 2.3) | Target | Result | Verdict |
|---|---|---|---|
| sqlite3.c first screen | < 300 ms | **162–175 ms** open to first laid-out screen; highlighted after 520 ms | Pass |
| Typing p99 | < 8 ms | **2.1 ms** editor time per keystroke (input request to laid-out edit). Including `insertText` notifications and a forced Core Animation commit: 14.4 ms in the simulator | Pass for the editor; confirm the commit time on device |
| Scrolling | 120 fps | 59–60 fps on the simulator's 60 Hz display, 0–2 dropped frames in 4 s. Main-thread work per frame: p99 **4.9 ms** steady, **5.1 ms** fast flick | Pass on the frame budget (≤ 8.3 ms); confirm 120 Hz on device |
| Memory for the file | < 150 MB | **136 MB** after open (plain), **250 MB** highlighted, **314 MB** peak | **Fail**, see condition 1 |

## Setup

| | |
|---|---|
| File | `sqlite3.c` from sqlite-amalgamation-3530400: 9,515,341 bytes, 269,650 lines (downloaded from sqlite.org) |
| Device | iOS Simulator, "iPad Pro 13-inch (M5)" (iPad17,4), iPadOS 26.5. Shared simulator, 60 Hz display |
| Host | Apple M5 Max Mac. Other agents' simulators were running, so absolute numbers carry some noise |
| Build | Release (`-O`), LemonTextDemo app |
| Harness | `EditorBenchmark` in LemonText. Every phase is an `OSSignposter` interval (subsystem `LemonText`, category `Benchmark`), so a run can also be read in Instruments |
| Raw results | [`lemontext-sqlite3-simulator.json`](lemontext-sqlite3-simulator.json) |

How it measures:

- **Open:** time from `load(text:language:)` to the first laid-out screen. The document is read off the main thread (7 ms).
  - Line storage is built off the main thread (133 ms).
  - Installing it and laying out the first screen on the main thread takes 26 ms.
  - Files over 400,000 UTF-16 units appear unhighlighted at once. Tree-sitter parses them in the background (350 ms more) and highlighting appears when it finishes.
- **Scrolling:**
  - A display link moves the content offset each frame. One pass runs at 2,400 pt/s from the top; another runs at 9,000 pt/s (a fast flick) through the middle.
  - Each pass records frame intervals and the main-thread time spent scrolling and laying out.
- **Typing:**
  - 300 characters are typed at the end of a line in the middle of the file, then deleted again with 300 Deletes.
  - Each keystroke goes through the full input path: delegate, edit, decorations, layout, then a forced `CATransaction.flush()`.
  - The controller also records its own time per keystroke.
- **Jumps:** 40 random jumps through the file, each laying out a screen of lines that has never been laid out.
- **Memory:** the process's physical footprint (`phys_footprint`, which jetsam uses), sampled after every phase.

## Detailed results

| Phase | p50 | p95 | p99 | max |
|---|---|---|---|---|
| Keystroke, editor time (588 keystrokes) | 1.26 ms | 1.91 ms | 2.06 ms | 2.15 ms |
| Keystroke, end to end with Core Animation commit | 12.9 ms | 14.2 ms | 14.4 ms | 14.7 ms |
| `insertText` incl. text-input notifications | 6.0 ms | 6.5 ms | 6.8 ms | 7.0 ms |
| Layout + commit after it | 6.9 ms | 7.9 ms | 8.1 ms | 8.3 ms |
| Delete, end to end | 4.1 ms | 4.5 ms | 5.0 ms | 9.9 ms |
| Typing `/*` (turns the rest of the file into a comment) | 7.1 ms | 7.5 ms | 8.4 ms | 8.4 ms |
| Scroll frame work, steady | 2.2 ms | 2.7 ms | 4.9 ms | 5.3 ms |
| Scroll frame work, fast flick | 2.6 ms | 5.0 ms | 5.1 ms | 5.4 ms |
| Jump to an unseen region | 47.5 ms | 53.8 ms | 64.0 ms | 64.0 ms |

| Memory after | MB |
|---|---|
| Launch | 25 |
| Open (plain text) | 136 |
| Highlighted | 250 |
| Steady scroll | 255 |
| Fast scroll | 269 |
| Jumps | 314 |
| Typing | 306 |

A jump to a region that has never been laid out takes about 48 ms: a dropped frame or three when scrubbing the minimap across the whole file. Ordinary scrolling never hits this. The cost is typesetting a fresh screen of Core Text lines; caching or pre-warming typesetting is a follow-up if it shows on device.

## What the benchmark found, and what changed

The first run used the engine essentially as Runestone ships it. It failed badly on typing and memory:

| | First run | Now |
|---|---|---|
| Keystroke, end to end p99 | **151 ms** | 14.4 ms (editor time 2.1 ms) |
| Peak memory | **1,116 MB** | 314 MB |
| First screen | 204 ms | 162–175 ms |

Two causes, both fixed in LemonTextCore:

1. **Tree-sitter reparsed the whole file on the main thread on every keystroke.**
   - Incremental parsing is not proportional to the edit. Tree-sitter re-walks the children of the root node, and sqlite3.c has almost 10,000 top-level nodes.
   - A standalone C program shows the cost natively on the M5 Max: a full parse takes 334 ms, and an incremental parse after a one-character edit takes **56 ms**.
   - Above 1 MB, an edit now only shifts the existing tree on the main thread, which is cheap and keeps highlighting correct for the unchanged text.
   - The reparse runs on a background queue against a snapshot of the text, and the lines whose highlighting changed are redrawn when it finishes.
   - A burst of key repeats coalesces into one parse.
2. **Jumping to a line typeset every line above it.**
   - `goToLine` and `scrollRangeToVisible` laid out all lines from the start of the document.
   - Jumping to the middle of sqlite3.c built 135,757 line controllers and their Core Text lines, about 900 MB found with `heap`.
   - Only the target lines are typeset now. Lines above keep estimated heights until they scroll into view.

Smaller fixes from the same investigation:

- free the changed-ranges array tree-sitter allocates;
- drain an autorelease pool after each background parse;
- rank completions off the main thread.

## Hardware keyboard

The keyboard stress suite replays Magic Keyboard input through the same `UITextInput` calls UIKit makes. It covers:

- characters, Return with auto-indent, Delete, Option-Delete, Command-Delete and forward delete;
- arrows with Shift, Option and Command;
- undo and redo, held keys and several carets;
- bursts in the middle of sqlite3.c.

All 21 cases pass (demo UI test `testKeyboardStressSuite`). Keystroke p99 on sqlite3.c in a Debug build is 3.75 ms over 420 keystrokes, and the buffer comes back byte for byte.

## Reproducing

```sh
# Get the amalgamation (public domain).
curl -LO https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip && unzip sqlite-amalgamation-3530400.zip

cd Packages/LemonText/Demo && xcodegen generate
xcodebuild build -project LemonTextDemo.xcodeproj -scheme LemonTextDemo -configuration Release \
  -destination 'platform=iOS Simulator,id=<simulator>' -derivedDataPath build
xcrun simctl install <simulator> build/Build/Products/Release-iphonesimulator/LemonTextDemo.app
cp sqlite-amalgamation-3530400/sqlite3.c "$(xcrun simctl get_app_container <simulator> com.geramyloveless.LemonSeedStudio.LemonTextDemo data)/Documents/"
xcrun simctl launch <simulator> com.geramyloveless.LemonSeedStudio.LemonTextDemo -benchmark sqlite3.c -nokeyboard -fullscreen
# Results: Documents/lemontext-benchmark.json in the same container.
```

Keep the demo app in the foreground for the whole run. Its display link pauses in the background, so a shared simulator must be idle.
