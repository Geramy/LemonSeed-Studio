# Third-party components

Components LemonSeed Studio builds from source or ships in the app bundle,
with their licenses. Every shipped component's license text must also appear
in the app's acknowledgements screen.

## Toolchain (Toolchain/, Packages/StudioToolchain)

| Component | Version (pin in `Toolchain/versions.env`) | License | Ships in app | Use |
|---|---|---|---|---|
| LLVM, clang, lld, clang-tools-extra (clangd) | 21.1.8 | Apache-2.0 WITH LLVM-exception | Yes (static libraries linked into the app) | In-process compiler (driver, cc1, wasm-ld) and clangd |
| clang builtin headers (`clang/lib/Headers`) | 21.1.8 | Apache-2.0 WITH LLVM-exception | Yes (`WASIToolchain/clang/include`) | Resource directory for wasm compiles |
| wasi-sdk sysroot: wasi-libc | wasi-sdk 30 | Apache-2.0 WITH LLVM-exception, Apache-2.0 or MIT; musl-derived parts MIT; some files CC0 / BSD-2-Clause (see wasi-libc `LICENSE*`) | Yes (`WASIToolchain/sysroot`) | C library for user programs |
| wasi-sdk sysroot: libc++, libc++abi | wasi-sdk 30 (LLVM 21.1.4) | Apache-2.0 WITH LLVM-exception | Yes (`WASIToolchain/sysroot`) | C++ standard library for user programs |
| compiler-rt builtins (`libclang_rt.builtins.a`, wasm32) | wasi-sdk 30 | Apache-2.0 WITH LLVM-exception | Yes (`WASIToolchain/clang/lib`) | Runtime helpers linked into user programs |
| WebAssembly Micro Runtime (WAMR) | 2.4.5 | Apache-2.0 WITH LLVM-exception | Yes (static library) | In-process WASI interpreter |

Notes:

- Programs users build link wasi-libc, libc++ and compiler-rt into their own
  `.wasm`; those licenses permit that without obligations on the output
  (the LLVM exception covers the runtime pieces).
- The WASI preview 1 shim in
  `Packages/StudioToolchain/Sources/StudioToolchain/Resources/WASIRuntime/wasi.js`
  is original LemonSeed code (it does not copy browser_wasi_shim).
- Build-time only, not shipped: CMake, Ninja, ccache, Homebrew LLVM 21
  (used by `build-sample-wasm.sh` to compile a reference `.wasm` on the Mac).
