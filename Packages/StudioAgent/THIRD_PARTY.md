# Third-party notices: StudioAgent

StudioAgent has no package dependencies. It uses Apple SDK frameworks
(Foundation, Synchronization, SwiftUI, Observation) only.

## Ported design and logic

### pi (pi-mono coding agent)

- Source: https://github.com/badlogic/pi-mono (`packages/coding-agent`, now
  https://github.com/earendil-works/pi)
- License: MIT, Copyright (c) 2025 Mario Zechner
- Used: no code is copied. StudioAgent re-implements in Swift:
  - pi's agent loop and event model;
  - its session file format (v3 JSONL, session-format.md), which StudioAgent
    reads and writes verbatim;
  - the edit tool's matching rules (`edit-diff.ts`): exact then normalized
    matching, uniqueness and overlap checks, line-preserving replacement;
  - its compaction approach and the compaction and branch-summary message
    wrappers;
  - the read tool's paging behavior.

```
MIT License

Copyright (c) 2025 Mario Zechner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Qwen3.x tool-call syntax

The text tool protocol (`TextToolProtocol`) uses the XML function-call format
Qwen3.x models are trained on, as LSE renders it (`third_party/LSE`,
`src/server/chat_protocol.cpp`). It is a message format, not code.

### Myers diff

`LineDiff` implements Eugene W. Myers, "An O(ND) Difference Algorithm and Its
Variations" (Algorithmica, 1986) from the paper; no code is copied.
