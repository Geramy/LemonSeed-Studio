# Third-party components

Components LemonSeed Studio builds from source or ships in the app bundle,
with their licenses. Every shipped component's license text must also appear
in the app's acknowledgements screen. Plain GPL/LGPL code stays out of the
app binary (planning/PLAN.md, section 3); exceptions are called out below.

## Git (Packages/StudioGit)

`scripts/build-libgit2.sh` builds these from pinned, checksummed release
tarballs into `Clibgit2.xcframework` (one static library, statically linked
into the app). The license texts are copied to `build/licenses/` by the build.

| Component | Version | License | Ships in app | Use |
|---|---|---|---|---|
| [libgit2](https://github.com/libgit2/libgit2) | 1.9.7 | GPL-2.0 with the libgit2 linking exception (unmodified) | Yes | Git engine behind GitKit |
| libgit2 bundled: LibXDiff (`deps/xdiff`) | in libgit2 1.9.7 | **LGPL-2.1-or-later** | Yes | Diff and merge algorithms. See the note below. |
| libgit2 bundled: PCRE2 (`deps/pcre2`, `REGEX_BACKEND=builtin`) | in libgit2 1.9.7 | BSD-3-Clause (PCRE2 licence) | Yes | Regular expressions (pathspecs, config) |
| libgit2 bundled: llhttp (`deps/llhttp`) | in libgit2 1.9.7 | MIT | Yes | HTTP parser for the smart HTTP transport |
| libgit2 bundled: SHA-1 collision detection (`src/util/hash/sha1dc`) | in libgit2 1.9.7 | MIT | Yes | SHA-1 |
| libgit2 bundled: wildmatch, `git_fs_path_basename_r`, xoroshiro256** | in libgit2 1.9.7 | BSD / BSD / public domain | Yes | Glob matching, paths, random numbers |
| [libssh2](https://libssh2.org) | 1.11.1 | BSD-3-Clause | Yes | SSH transport (crypto backend: OpenSSL) |
| [OpenSSL](https://www.openssl.org) | 3.5.9 (LTS) | Apache-2.0 | Yes (symbols kept private to Clibgit2) | TLS for HTTPS, crypto for libssh2 |
| zlib, libiconv | iOS SDK | system libraries | No (linked from the OS) | Compression, path encoding |
| Mozilla CA certificate list (`Sources/GitKit/Resources/cacert.pem`, extracted by curl, data as of 2026-09-25) | 2026-09-25 | MPL-2.0 (unmodified file) | Yes | Fallback trust store for OpenSSL; the system trust store is checked first |
| GitHub and GitLab.com SSH host keys (`KnownHosts.swift`) | from api.github.com/meta and ssh-keyscan, 2026-10-02 | public data | Yes | Pinned host keys |

Not shipped, build or test only: CMake, Ninja, Perl (OpenSSL's configure),
XcodeGen (demo project), OpenSSH `sshd`/`ssh-keygen` and `git` on the Mac
(`scripts/ssh-test-server.sh` uses them to check SSH transport and to verify
GitKit's commit signatures).

Everything else in StudioGit (GitKit, Forge, StudioGitUI, CGitShim, the LFS
client) is original LemonSeed code using only system frameworks: Foundation,
Security, CryptoKit, SwiftUI, Observation, UniformTypeIdentifiers. No GitHub
or GitLab SDKs are used.

### Note: LibXDiff inside libgit2 is LGPL-2.1

libgit2's linking exception covers libgit2's own code. Its bundled LibXDiff
(`deps/xdiff`, the same code Git uses) keeps its own license, LGPL-2.1 or
later, and libgit2 1.9 has no option to build without it. A statically linked
App Store binary therefore contains LGPL code. This is the same situation as
every shipping iOS app built on libgit2, but it conflicts with the plan's rule
"no LGPL in the app binary" and needs a decision before App Store submission:

1. **Comply with LGPL-2.1 section 6** for the static link: publish the
   corresponding xdiff source (unmodified, from the pinned libgit2 tarball)
   and provide the app's object files so a user can relink against a
   modified xdiff. The StudioGit source is already available; the app's
   other objects would have to be offered too. The App Store's usage rules
   may still be read as an added restriction.
2. **Ship libgit2 as a dynamic framework** (`Clibgit2.framework`) inside the
   app. xdiff would then be replaceable in principle; whether that satisfies
   LGPL on iOS (code signing prevents replacement in practice) needs legal
   review.
3. **Replace xdiff** with a permissively licensed diff implementation in a
   libgit2 patch (for example a Myers/histogram diff written for the
   project), published as required by libgit2's GPL for modified copies.

Recommendation: track as risk L1-git next to L1 (the GPL dext) and get the
same legal review; option 3 removes the question entirely.

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

## Packages/StudioTelemetry

| Component | Where it is used | License | In the app binary |
|---|---|---|---|
| [amdgpu_mtopg](https://github.com/lemonade-sdk/amdgpu_mtopg) (`third_party/amdgpu_mtopg`, at afe1509) | Ported: `Sources/StudioTelemetry/Mtopg/` (LinuxDriver.swift → LinuxTransport.swift, LinuxModel.swift, the shared helpers of MonitorModel.swift); the views in `UI/` are rewritten from LinuxViews.swift and Views.swift | MIT, Copyright (c) 2026 Geramy Loveless | yes |
| `GPUMetricsLayout.swift` | Copied unchanged from amdgpu_mtopg; generated by its `gen_gpu_metrics.py` from `kgd_pp_interface.h` | MIT (amdgpu_mtopg) | yes |
| `kgd_pp_interface.h` (Linux `drivers/gpu/drm/amd/include/`, vendored in amdgpu_mtopg) | Source of the gpu_metrics struct layouts above; not compiled into the Studio | MIT (X11-style), Copyright 2017 Advanced Micro Devices, Inc. | layouts only |
| [mac_linuxgpu](https://github.com/lemonade-sdk/mac_linuxgpu) observer ABI (`dext/sources/session_state.h`) | Selector numbers, op codes and limits in `Transport/ObserverConnection.swift` | MIT OR GPL-2.0-only (used under MIT) | constants only |
| mac_linuxgpu `scripts/read-sysfs.py` | Imported at run time by `Tools/capture_fixture.py` (a developer tool, not shipped); nothing is copied | MIT OR GPL-2.0-only | no |
| Recorded fixtures (`Resources/Fixtures/*.json`) | Sysfs, gpu_metrics and GRBM_STATUS payloads recorded from the project owner's own AMD Radeon AI PRO R9700 through mac_linuxgpu; no third-party content | project's own data | yes (fixture mode) |

System frameworks only otherwise: SwiftUI, Observation, Synchronization,
Foundation, IOKit and CoreFoundation (through the `CMacLinuxGPUObserver` C
shim; iPadOS ships IOKitLib's headers but no Swift module).
