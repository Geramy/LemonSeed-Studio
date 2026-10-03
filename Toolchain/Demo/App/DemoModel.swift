import Foundation
import Observation
import StudioToolchain

/// Drives the spike: build hello.c in process, then run the .wasm in WebKit
/// and in WAMR, recording timings and memory.
@MainActor
@Observable
final class DemoModel {
  struct ConsoleLine: Identifiable {
    enum Kind { case info, stdout, stderr, error }
    let id = UUID()
    var kind: Kind
    var text: String
  }

  struct Timing: Identifiable {
    let id = UUID()
    var label: String
    var value: String
  }

  var source: String
  var console: [ConsoleLine] = []
  var diagnostics: [Diagnostic] = []
  var buildTimings: [Timing] = []
  var webKitTimings: [Timing] = []
  var wamrTimings: [Timing] = []
  var clangdTimings: [Timing] = []
  var busy = false
  var wasm: Data?
  var wasmOrigin = ""

  let resources = ToolchainResources.bundled()
  private let webKit = WebKitRunner()
  private let wamr = WAMRRunner()

  var compilerStatus: String {
    if !Compiler.isAvailable { return "In-process compiler not linked into this build" }
    if resources == nil { return "WASIToolchain resources missing from the bundle" }
    return Compiler.version
  }

  init() {
    let url = Bundle.main.url(forResource: "hello", withExtension: "c", subdirectory: "samples")
    source = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "int main(void) { return 0; }\n"
  }

  // MARK: - Actions

  func build() async {
    busy = true
    defer { busy = false }
    diagnostics = []
    buildTimings = []
    guard Compiler.isAvailable, let resources else {
      // Run-side fallback: the same hello.c compiled on the Mac.
      if let url = Bundle.main.url(forResource: "hello", withExtension: "wasm", subdirectory: "prebuilt"),
         let data = try? Data(contentsOf: url) {
        wasm = data
        wasmOrigin = "prebuilt on the Mac"
        log(.info, "\(compilerStatus). Using hello.wasm built on the Mac (\(data.count) bytes).")
      } else {
        log(.error, "\(compilerStatus), and no prebuilt hello.wasm is bundled.")
      }
      return
    }

    let dir = FileManager.default.temporaryDirectory.appending(path: "toolchain-demo", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sourceURL = dir.appending(path: "hello.c")
    let outputURL = dir.appending(path: "hello.wasm")
    do {
      try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    } catch {
      log(.error, "Could not save hello.c: \(error.localizedDescription)")
      return
    }
    try? FileManager.default.removeItem(at: outputURL)

    log(.info, "$ clang --target=wasm32-wasip1 -O2 hello.c -o hello.wasm   (in process)")
    let before = MemoryFootprint.current()
    let result = await Compiler(resources: resources).compile(sources: [sourceURL], output: outputURL)
    let after = MemoryFootprint.current()
    diagnostics = result.diagnostics
    if !result.log.isEmpty { log(result.succeeded ? .stderr : .error, result.log) }

    buildTimings = [
      Timing(label: "driver", value: ms(result.driverMilliseconds)),
      Timing(label: "cc1 (compile)", value: ms(result.compileMilliseconds)),
      Timing(label: "wasm-ld (link)", value: ms(result.linkMilliseconds)),
      Timing(label: "total", value: ms(result.totalMilliseconds)),
      Timing(label: "app footprint", value: "\(MemoryFootprint.format(before)) → \(MemoryFootprint.format(after))"),
    ]
    if result.succeeded, let data = try? Data(contentsOf: outputURL) {
      wasm = data
      wasmOrigin = "compiled on this device"
      buildTimings.append(Timing(label: "hello.wasm", value: "\(data.count.formatted()) bytes"))
      log(.info, "Built hello.wasm (\(data.count) bytes) in \(ms(result.totalMilliseconds)).")
    } else {
      wasm = nil
      log(.error, "Build failed (exit code \(result.exitCode)).")
    }
    report("build", buildTimings)
  }

  func runWebKit() async {
    guard let wasm = await ensureBuilt() else { return }
    busy = true
    defer { busy = false }
    log(.info, "$ run hello.wasm   (WKWebView, JavaScriptCore)")
    do {
      let result = try await webKit.run(wasm: wasm, arguments: ["hello.wasm"], environment: ["LANG": "C.UTF-8"]) { [weak self] chunk in
        self?.log(chunk.stream == .stderr ? .stderr : .stdout, chunk.text)
      }
      var timings = runTimings(result)
      if let info = webKit.engineInfo {
        timings.insert(Timing(label: "page load (first run)", value: ms(info.pageLoadMilliseconds)), at: 0)
        timings.append(Timing(label: "cross-origin isolated", value: info.crossOriginIsolated ? "yes" : "no"))
      }
      webKitTimings = timings
      finish(result)
      report("webkit", webKitTimings)
    } catch {
      log(.error, error.localizedDescription)
    }
  }

  func runWAMR() async {
    guard let wasm = await ensureBuilt() else { return }
    busy = true
    defer { busy = false }
    log(.info, "$ run hello.wasm   (\(WAMRRunner.version), in process)")
    let result = await wamr.run(wasm: wasm, arguments: ["hello.wasm"], environment: ["LANG": "C.UTF-8"]) { [weak self] chunk in
      self?.log(chunk.stream == .stderr ? .stderr : .stdout, chunk.text)
    }
    wamrTimings = runTimings(result)
    // WAMR's output reaches the main actor through Tasks; let them land first.
    await Task.yield()
    finish(result)
    report("wamr", wamrTimings)
  }

  func buildAndRunAll() async {
    await build()
    guard wasm != nil else { return }
    await runWebKit()
    await runWAMR()
  }

  func clearConsole() { console = [] }

  /// The plan's clangd memory spike: ClangdServer in process on medium.cpp
  /// (about 86k lines after preprocessing, mostly libc++).
  func measureClangd() async {
    guard let resources,
          let file = Bundle.main.url(forResource: "medium", withExtension: "cpp", subdirectory: "samples")
    else {
      log(.error, "medium.cpp or the WASI resources are missing from the bundle.")
      return
    }
    busy = true
    defer { busy = false }
    let flags = [
      "--target=wasm32-wasip1",
      "-resource-dir=\(resources.resourceDir.path)",
      "--sysroot=\(resources.sysroot.path)",
      "-std=gnu++20", "-fno-exceptions",
    ]
    clangdTimings = []
    for inMemory in [false, true] {
      log(.info, "clangd: opening medium.cpp, preambles \(inMemory ? "in memory" : "on disk")…")
      let path = file.path
      let stats = await Compiler.onCompilerThread {
        let cStrings = flags.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        let argv = cStrings.map { UnsafePointer<CChar>($0) }
        var stats = lst_clangd_stats()
        argv.withUnsafeBufferPointer {
          lst_clangd_measure(path, $0.baseAddress, Int32($0.count), inMemory ? 1 : 0, &stats)
        }
        return ClangdStats(stats)
      }
      guard stats.available else {
        log(.error, stats.breakdown)
        return
      }
      let mode = inMemory ? "memory" : "disk"
      clangdTimings += [
        Timing(label: "preambles", value: inMemory ? "in memory" : "on disk"),
        Timing(label: "first build", value: ms(stats.firstBuild)),
        Timing(label: "rebuild after edit", value: ms(stats.rebuild)),
        Timing(label: "completion", value: "\(ms(stats.completion)), \(stats.completionItems) items"),
        Timing(label: "clangd memory (own)", value: MemoryFootprint.format(stats.clangdBytes)),
        Timing(label: "app footprint", value: "\(MemoryFootprint.format(stats.before)) → \(MemoryFootprint.format(stats.open)) → \(MemoryFootprint.format(stats.after))"),
      ]
      log(.info, "clangd (\(mode)) memory breakdown:\n" + stats.breakdown)
      report("clangd-\(mode)", clangdTimings.suffix(6).map { $0 })
    }
  }

  // MARK: - Helpers

  private func ensureBuilt() async -> Data? {
    if wasm == nil { await build() }
    return wasm
  }

  private func runTimings(_ result: WasmRunResult) -> [Timing] {
    [
      Timing(label: "load / compile", value: ms(result.loadMilliseconds)),
      Timing(label: "instantiate", value: ms(result.instantiateMilliseconds)),
      Timing(label: "run", value: ms(result.runMilliseconds)),
      Timing(label: "total", value: ms(result.totalMilliseconds)),
      Timing(label: "exit code", value: "\(result.exitCode)"),
    ]
  }

  private func finish(_ result: WasmRunResult) {
    if let error = result.error { log(.error, error) }
    if !result.unsupportedImports.isEmpty {
      log(.info, "Unsupported WASI calls: \(result.unsupportedImports.joined(separator: ", "))")
    }
    log(.info, "Exited with code \(result.exitCode) after \(ms(result.totalMilliseconds)).")
  }

  private func log(_ kind: ConsoleLine.Kind, _ text: String) {
    // Merge streamed chunks of the same stream into the current line.
    if kind == .stdout || kind == .stderr, let last = console.last, last.kind == kind,
       !last.text.hasSuffix("\n") {
      console[console.count - 1].text += text
    } else {
      console.append(ConsoleLine(kind: kind, text: text))
    }
    print("[console] \(text)", terminator: text.hasSuffix("\n") ? "" : "\n")
  }

  /// Machine-readable timings in the device log, for scripted runs.
  private func report(_ name: String, _ timings: [Timing]) {
    print("[timings] \(name): " + timings.map { "\($0.label)=\($0.value)" }.joined(separator: "; "))
  }

  private func ms(_ value: Double) -> String {
    value < 10 ? String(format: "%.2f ms", value) : String(format: "%.1f ms", value)
  }
}

/// Swift copy of lst_clangd_stats (Sendable, strings decoded).
struct ClangdStats: Sendable {
  var available: Bool
  var firstBuild, rebuild, completion: Double
  var completionItems: Int
  var clangdBytes, before, open, after: UInt64
  var breakdown: String

  init(_ s: lst_clangd_stats) {
    available = s.available != 0
    firstBuild = s.first_build_ms
    rebuild = s.rebuild_ms
    completion = s.completion_ms
    completionItems = Int(s.completion_items)
    clangdBytes = s.clangd_bytes
    before = s.footprint_before
    open = s.footprint_open
    after = s.footprint_after
    breakdown = withUnsafeBytes(of: s.breakdown) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }
}

/// The app's physical memory footprint (what jetsam counts).
enum MemoryFootprint {
  static func current() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
  }

  static func format(_ bytes: UInt64) -> String {
    String(format: "%.0f MB", Double(bytes) / 1_048_576)
  }
}
