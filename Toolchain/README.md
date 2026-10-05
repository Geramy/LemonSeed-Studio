# Toolchain

Build and run C/C++ on the iPad without spawning processes: clang and
wasm-ld run inside the app, and programs run as WASI modules in a hidden
WKWebView (JIT, out of process) or in WAMR's interpreter (in process).

```
Toolchain/
  versions.env                 pins: LLVM 21.1.8, wasi-sdk 30, WAMR 2.4.5, iOS 26.2
  scripts/
    build-llvm-ios.sh          LLVM -> build/xcframeworks/LemonSeedLLVM.xcframework
    build-wamr-ios.sh          WAMR -> build/xcframeworks/LemonSeedWAMR.xcframework
    fetch-wasi-sysroot.sh      sysroot (wasm32-wasip1, -threads) + clang resource dir -> build/resources/WASIToolchain
    build-wasi-extensions.sh   BSD socket headers and libwasi_socket_ext.a -> WASIToolchain/extensions
    make-stub-xcframeworks.sh  placeholders, so the package builds without LLVM
    build-sample-wasm.sh       hello.wasm built on the Mac (run-side fallback)
  patches/llvm/                applied to the LLVM source on extraction
  extensions/sockets/          <sys/socket.h> and <netdb.h> overlays, netdb_extra.c
  samples/                     hello.c (the demo), medium.cpp (clangd spike)
  Demo/                        spike app (XcodeGen; ./build.sh)
  build/                       everything generated (gitignored)
Packages/StudioToolchain/      Compiler, ProjectBuilder, WasmModuleInfo, WAMRRunner, WebKitRunner
Studio/App/Sources/Toolchain/  the app: clang/clang++/cc/c++ and run in the terminal, Build panel
```

## Building

```sh
Toolchain/scripts/build-llvm-ios.sh        # ~20 min per slice at JOBS=10
Toolchain/scripts/build-wamr-ios.sh        # seconds
Toolchain/scripts/fetch-wasi-sysroot.sh    # needs the LLVM source (first step above)
Toolchain/scripts/build-wasi-extensions.sh # needs brew llvm@21 (same LLVM as the app's clang)
Toolchain/Demo/build.sh                    # demo app for the simulator
```

The app bundles `build/resources/WASIToolchain` as a folder and links
StudioToolchain (Studio/project.yml).

`build-llvm-ios.sh` takes steps (`fetch host sim device package`, default all).
It builds clang, lld and clang-tools-extra (`WITH_CLANGD=0` to skip) with only
the WebAssembly backend (`LLVM_TARGETS="WebAssembly;AMDGPU"` for the Kernel
Lab later), uses ccache, and logs each step to `build/logs/` with wall times in
`build/logs/timings.txt`. Without the LLVM build, run
`make-stub-xcframeworks.sh`: the package then builds and the demo falls back to
the Mac-built `hello.wasm`.

## How it works

**Compile** (`lst_compiler.cpp`): `clang::driver::Driver` plans the jobs for
`clang --target=wasm32-wasip1 ...`; each `-cc1` job runs through
`CompilerInvocation::CreateFromArgs` + `ExecuteCompilerInvocation` (what
`cc1_main` does, minus `-disable-free`), and the link job through
`lld::lldMain` with the wasm driver only. Everything runs on an 8 MB-stack
thread inside `CrashRecoveryContext`, with LLVM's fatal-error handler routed
through it. Links are serialized (lld has global state); compiles run in
parallel (tested with four at once). Diagnostics come back as rendered text and
as structured records (file, line, column, level, message).

**Run in WebKit** (`WebKitRunner`, `Resources/WASIRuntime/wasi.js`): a hidden
WKWebView loads `lsx://runtime/index.html` from a `WKURLSchemeHandler`, fetches
the module from the same handler, and runs `_start` against a small WASI
preview 1 shim (args, environ, clocks, random, stdout/stderr, stdin at EOF,
proc_exit; unknown imports return ENOSYS). Output streams back through a script
message handler while the module runs. A dead WebContent process fails the run
without touching the app.

**Run in WAMR** (`WAMRRunner`, `lst_wamr.c`): fast interpreter, no AOT or JIT,
software bounds checks (the hardware scheme reserves 8 GB per instance and
installs a SIGSEGV handler in the host). stdout and stderr are pipes drained by
reader threads.

## Results (iPad Pro 13-inch (M5) simulator, iOS 26.5, Release)

| Step | Time |
|---|---|
| In-process build of hello.c (driver / cc1 / wasm-ld / total) | 1–7 / 40–85 / 17–25 / 56–120 ms |
| WebKit: runtime page load, first run | 350–575 ms (2.8 s on the very first launch) |
| WebKit: compile + instantiate + run (sieve of 2M) | 1 + 0–12 + 5–9 ms |
| WAMR: load + instantiate + run (same sieve) | 1 + 0.2 + 25–43 ms |
| Same module in Node (V8 JIT) on the Mac, for reference | 8 ms |
| App footprint during a build | 31 MB -> 36 MB |

The WebKit run is 4–5x faster than WAMR and matches V8's JIT, so JSC is
JIT-compiling the WebAssembly in the WebContent process. That is the simulator
(a macOS process); confirming it on a device is still open.

Sizes:

| Item | Size |
|---|---|
| `libLemonSeedLLVM.a` per slice (Release, all clang/lld/clangd libraries) | 263 MB |
| LemonSeedLLVM.xcframework (2 slices, with 69 MB of headers each) | 665 MB (build machine only) |
| App executable, compiler only (dead-stripped) | 74 MB |
| App executable with the clangd spike linked as well | 90 MB |
| WASIToolchain resource (wasm32-wasip1 sysroot + clang resource dir) | 36 MB (8 MB zipped) |
| Whole demo app, device build, unsigned | 126 MB (40 MB zipped) |
| WAMR static library | 0.5 MB |

Build times on this Mac (18 cores, JOBS=10, cold ccache): host tablegen 43 s;
iOS simulator slice about 17 min; iOS device slice 17.8 min; packaging 10 s.
With a warm ccache, a reconfigured slice rebuilds in about a minute.

## clangd memory spike

Approach: link clangd's library (`ClangdServer`) from the same LLVM build and
drive it in process (`Demo/App/ClangdSpike.cpp`): an `OverlayCDB` with fallback
flags for wasm32-wasip1, `RealThreadsafeFS`, two async workers, dynamic index
on. Open `samples/medium.cpp` (about 86k lines after preprocessing, mostly
libc++), wait until idle, edit the body, wait again, code-complete after
`spike.`, then read clangd's `MemoryTree` and the process `phys_footprint`.
For the production host, the plan's route stays: `ClangdLSPServer` with an
in-memory `Transport`.

| | Preambles on disk | Preambles in memory |
|---|---|---|
| First build (preamble + AST + index) | 1.7–3.0 s | 1.6–2.3 s |
| Rebuild after an edit (preamble reused) | 130–230 ms | 130–180 ms |
| Completion (`std::vector<int>` member) | 60–100 ms, 40 items | 60–85 ms, 40 items |
| clangd's own accounting | 37 MB (AST 21.7, dynamic index 15.1) | 68 MB (AST 37.4, preamble 15.7, index 15.1) |
| App footprint: before / file open / after shutdown | 31 / 47 / 37 MB | 37 / 54 / 38 MB |

So one medium C++ file costs about 16–17 MB of footprint with preambles on
disk. The on-disk preamble is mapped from a file and is not counted by jetsam.
Device numbers, the LSE tree and a mid-size CMake project are still to be
measured (the plan's week-2 clangd spike).

## In the app

- **Terminal:** `clang`, `clang++`, `cc` and `c++` take clang's own command
  line and compile to `wasm32-wasip1` unless it names `--target=wasm32-wasip1-threads`
  (or `-pthread`); other targets are an error. `run [--runner wamr|webkit]
  prog.wasm [args]` runs a program with stdin, stdout and stderr on the
  terminal (Ctrl-C stops it, Ctrl-D ends its input), its files confined to the
  current directory (WASI preopen), and returns its exit code. The runner and
  why it was chosen are printed after the program's output.
- **Build panel:** Build (⌘⇧B) compiles the project's `studio-build.json`
  (`ProjectBuilder`: incremental from clang's dependency files, parallel
  compiles, then one link) or the C/C++ file in the editor; Run (⌘R) builds and
  runs in the terminal. Diagnostics go to Problems (file:line:column).
- **Runner choice** (`WasmRunner.choose`, from the module's import section):
  WebKit's JIT when every import is one its JavaScript shim implements (output,
  arguments, environment, clocks, random); WAMR for anything else: stdin,
  files, sockets, threads.

### What WASI programs can and cannot do

| | |
|---|---|
| Standard C and C++ (C17, C++20 libc++) | Yes. C++ exceptions no (`-fno-exceptions`); no RTTI limits |
| stdin, stdout, stderr | Yes; stdin is typed in the terminal or piped |
| Files | Yes, inside the directory the program runs in (and below); nothing outside it |
| Sockets | TCP and UDP over BSD sockets: `socket`, `bind`, `listen`, `accept`, `connect`, `send`/`recv`, `getaddrinfo`, `poll`/`select`, socket options. No raw sockets, no Unix domain sockets, no ports below 1024 (iOS). The local network needs the user's permission (iOS prompt) |
| Threads | pthreads with `--target=wasm32-wasip1-threads` (or `-pthread`): mutexes, condition variables, atomics, up to 64 threads |
| Time | Wall and monotonic clocks, `nanosleep`/`sleep` |
| SIMD | 128-bit WebAssembly SIMD (`-msimd128`) in both runtimes |
| Processes | No `fork`, `exec`, `system` or `popen`; one program, one process |
| Signals | No signal delivery (`signal()` compiles, handlers never run) |
| Dynamic loading | No `dlopen`; programs link statically |
| GPU, graphics, windows | No; text in, text out |
| Speed | WebKit's JIT runs near native speed; WAMR, an interpreter, is about 4-5x slower on pure computation |

## Findings and open items

- **C++ exceptions:** the stock wasi-sdk 30 libc++/libc++abi are built without
  exceptions (`__cxa_throw` is absent), so C++ compiles with
  `-fno-exceptions` for now. Exceptions need libc++, libc++abi and libunwind
  rebuilt with `-fwasm-exceptions` (a runtimes build with the host clang 21).
  WAMR's wasm exception handling exists only in the classic interpreter, not
  the fast one, so the interpreter path stays `-fno-exceptions` either way.
- **Cross-origin isolation:** the scheme handler sends COOP/COEP, but the
  `lsx:` page reports `crossOriginIsolated == false` (WebKit does not treat a
  custom scheme as a secure context). wasi-threads needs SharedArrayBuffer,
  so the threads bridge needs another origin strategy (a loopback HTTP server
  inside the app, or a WebKit setting).
- **WKWebView placement:** the runner parks a 1x1, nearly transparent web view
  in the key window so WebKit does not throttle it.
- **SwiftPM manifest cache:** SwiftPM caches manifest evaluation by content,
  so the package cannot decide on disk whether LLVM is present. Each
  XCFramework carries `lemonseed/<name>_config.h` saying whether it is real.
- **LLVM CMake on iOS:** LLVM matches `CMAKE_SYSTEM_NAME` against "Darwin"
  for linker flags; `patches/llvm/0001` extends that to iOS. `ninja install`
  insists on tools that are not built, so the script stages libraries and
  headers itself. `LLVM_APPEND_VC_REV=OFF` keeps the build machine's paths out
  of the version strings.
- **wasm-opt** is not bundled; the driver's optional post-link wasm-opt job is
  skipped.

## Next steps

1. Run the demo on an M4/M5 iPad (needs signing): confirm JIT timings, measure
   build time and memory on device, and check page-load cost.
2. Build libc++/libc++abi/libunwind with wasm exceptions; bundle the variant.
3. Promote `ClangdSpike` to the `ClangdHost` module (`ClangdLSPServer` + an
   in-memory `Transport`) and measure the LSE tree on device.
4. Package one dynamic `Toolchain.framework` (plan 2.6) so clang, lld and clangd
   share one copy of LLVM between the app and any extensions.
5. WASIX target (wasix-libc sysroot, host shim over WAMR) for fuller POSIX.
6. llvm-ar / llvm-objdump / llvm-nm entry points and the AMDGPU target for the
   GPU Kernel Lab; CI caching of the XCFrameworks.
