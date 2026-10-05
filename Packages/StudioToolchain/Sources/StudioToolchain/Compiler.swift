import CToolchainBridge
import Foundation

/// Where the WASI sysroots and clang's resource directory live. The app ships
/// them as a folder named "WASIToolchain" (see Toolchain/scripts/fetch-wasi-sysroot.sh).
public struct ToolchainResources: Sendable {
  public var root: URL
  /// wasi-libc (wasm32-wasip1 and wasm32-wasip1-threads).
  public var sysroot: URL { root.appending(path: "sysroot") }
  /// wasix-libc (wasm32-wasix).
  public var wasixSysroot: URL { root.appending(path: "wasix/sysroot") }
  public var resourceDir: URL { root.appending(path: "clang") }
  /// BSD sockets for wasi-libc targets (Toolchain/scripts/build-wasi-extensions.sh).
  public var socketHeaders: URL { root.appending(path: "extensions/sockets/include") }
  public func socketLibrary(_ target: CompileTarget) -> URL {
    root.appending(path: "extensions/sockets/lib/\(target.rawValue)")
  }

  public func sysroot(for target: CompileTarget) -> URL {
    target == .wasix ? wasixSysroot : sysroot
  }

  /// The targets whose libraries are present.
  public var availableTargets: [CompileTarget] {
    CompileTarget.allCases.filter {
      FileManager.default.fileExists(atPath: sysroot(for: $0).appending(path: "lib/\($0.clangTriple)").path)
    }
  }

  public init(root: URL) { self.root = root }

  /// The "WASIToolchain" folder in the given bundle, if it is there.
  public static func bundled(in bundle: Bundle = .main) -> ToolchainResources? {
    guard let url = bundle.url(forResource: "WASIToolchain", withExtension: nil) else { return nil }
    return ToolchainResources(root: url)
  }
}

public struct Diagnostic: Sendable, Hashable {
  public enum Level: Int, Sendable { case note, remark, warning, error, fatal }
  public var level: Level
  public var file: String
  public var line: Int
  public var column: Int
  public var message: String
}

public struct CompileResult: Sendable {
  public var exitCode: Int32
  public var output: URL
  /// What a command-line clang would have printed.
  public var log: String
  public var diagnostics: [Diagnostic]
  public var driverMilliseconds: Double
  public var compileMilliseconds: Double
  public var linkMilliseconds: Double
  /// Wall time including thread start-up.
  public var totalMilliseconds: Double
  public var succeeded: Bool { exitCode == 0 }
}

public enum SourceLanguage: Sendable {
  case c, cxx
  var driverFlag: String { self == .c ? "-std=gnu17" : "-std=gnu++20" }

  /// From a file's extension: C++ for .cc, .cpp, .cxx and .c++.
  public init(path: String) {
    let ext = (path as NSString).pathExtension.lowercased()
    self = ["cc", "cpp", "cxx", "c++", "cp"].contains(ext) ? .cxx : .c
  }
}

/// What programs are compiled for.
public enum CompileTarget: String, Sendable, CaseIterable, Codable {
  /// WASI preview 1 on wasi-libc, single-threaded, with BSD sockets (WAMR's
  /// socket extension). The default.
  case wasip1 = "wasm32-wasip1"
  /// The same with pthreads (wasi-threads on shared memory).
  case wasip1Threads = "wasm32-wasip1-threads"
  /// WASIX on wasix-libc: fuller POSIX (sockets, threads, signals raised by
  /// the program, the working directory) through the wasix_32v1 calls the
  /// app implements on WAMR. Always threaded (shared memory).
  case wasix = "wasm32-wasix"

  public var title: String {
    switch self {
    case .wasip1: "WASI"
    case .wasip1Threads: "WASI + threads"
    case .wasix: "WASIX"
    }
  }

  /// What a program built for the target can use, for target pickers.
  public var summary: String {
    switch self {
    case .wasip1: "Single-threaded. Files, stdin and BSD sockets."
    case .wasip1Threads: "WASI with pthreads on shared memory."
    case .wasix: "Fuller POSIX: getaddrinfo, poll, pthreads, signals, chdir."
    }
  }

  /// The triple clang compiles for.
  public var clangTriple: String { self == .wasix ? "wasm32-wasi" : rawValue }

  /// A --target value as users write it.
  public init?(triple: String) {
    switch triple {
    case "wasm32-wasip1", "wasm32-wasi", "wasm32-unknown-wasi", "wasm32-unknown-wasip1": self = .wasip1
    case "wasm32-wasip1-threads", "wasm32-wasi-threads", "wasm32-unknown-wasip1-threads": self = .wasip1Threads
    case "wasm32-wasix", "wasm32-wasmer-wasi": self = .wasix
    default: return nil
    }
  }
}

/// Compiles C and C++ to WebAssembly (WASI) with clang and wasm-ld running inside
/// this process (no subprocesses). Compiles run on their own 8 MB-stack
/// threads, so several can run at once; links are serialized by the bridge.
public final class Compiler: Sendable {
  public let resources: ToolchainResources

  public init(resources: ToolchainResources) {
    self.resources = resources
  }

  public static var isAvailable: Bool { lst_toolchain_available() != 0 }
  public static var version: String { String(cString: lst_toolchain_version()) }

  /// Builds `sources` into a WASI command module at `output`. With a working
  /// directory, clang runs as if started there (-working-directory, no chdir)
  /// and sources inside it are named relative to it, so diagnostics read
  /// "hello.c:3:5" instead of carrying the full container path.
  public func compile(
    sources: [URL], output: URL, language: SourceLanguage = .c,
    optimization: String = "-O2", extraArguments: [String] = [],
    workingDirectory: URL? = nil, target: CompileTarget = .wasip1
  ) async -> CompileResult {
    var user = ["--target=\(target.rawValue)", language.driverFlag, optimization] + extraArguments
    if let workingDirectory {
      let base = workingDirectory.standardizedFileURL.path + "/"
      user += sources.map { url in
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.path
      }
    } else {
      user += sources.map(\.path)
    }
    user += ["-o", output.path]
    do {
      let arguments = try driverArguments(user, cxx: language == .cxx, workingDirectory: workingDirectory)
      return await run(arguments: arguments, output: output)
    } catch {
      return CompileResult(exitCode: 1, output: output, log: "error: \(error.localizedDescription)\n", diagnostics: [],
                           driverMilliseconds: 0, compileMilliseconds: 0, linkMilliseconds: 0, totalMilliseconds: 0)
    }
  }

  /// A clang command line as a user typed it (after `clang` or `clang++`),
  /// completed for this toolchain: the target (wasm32-wasip1 unless the
  /// arguments name one or ask for -pthread), its sysroot and the resource
  /// directory, and what the target needs besides:
  /// - wasm32-wasip1(-threads): the socket headers and, when linking, the
  ///   socket library; wasi-libc's emulations (signal, mmap, getpid, clock);
  /// - threaded targets: shared memory with room to grow;
  /// - wasm32-wasix: atomics, bulk memory and an imported shared memory, as
  ///   wasix-libc expects.
  /// Unknown targets are an error, never silently replaced.
  public func driverArguments(_ userArguments: [String], cxx: Bool, workingDirectory: URL?) throws -> [String] {
    var target: CompileTarget?
    var rest: [String] = []
    var i = 0
    var linking = true
    var hasSysroot = false, hasResourceDir = false, wantsThreads = false, hasExceptions = false
    while i < userArguments.count {
      let a = userArguments[i]
      var triple: String?
      if a.hasPrefix("--target=") { triple = String(a.dropFirst(9)) }
      else if a == "-target" || a == "--target", i + 1 < userArguments.count { triple = userArguments[i + 1]; i += 1 }
      if let triple {
        guard let t = CompileTarget(triple: triple) else { throw DriverError.unsupportedTarget(triple) }
        target = t
        i += 1
        continue
      }
      switch a {
      case "-c", "-S", "-E", "-fsyntax-only", "-M", "-MM": linking = false
      case "-pthread", "-pthreads": wantsThreads = true
      case "-fexceptions": hasExceptions = true
      default:
        if a.hasPrefix("--sysroot") { hasSysroot = true }
        if a == "-resource-dir" || a.hasPrefix("-resource-dir=") { hasResourceDir = true }
      }
      if a != "-pthread" && a != "-pthreads" { rest.append(a) }
      i += 1
    }
    let chosen = target ?? (wantsThreads ? .wasip1Threads : .wasip1)
    if wantsThreads, chosen == .wasip1 { throw DriverError.threadsNeedThreadsTarget }
    guard resources.availableTargets.contains(chosen) else { throw DriverError.targetNotInstalled(chosen.rawValue) }
    var arguments = [cxx ? "clang++" : "clang", "--target=\(chosen.clangTriple)"]
    if !hasResourceDir { arguments += ["-resource-dir", resources.resourceDir.path] }
    if !hasSysroot { arguments.append("--sysroot=\(resources.sysroot(for: chosen).path)") }
    // C++ exceptions need a libc++ built for wasm exceptions; neither sysroot's is.
    if cxx, !hasExceptions { arguments.append("-fno-exceptions") }
    switch chosen {
    case .wasip1, .wasip1Threads:
      if chosen == .wasip1Threads { arguments.append("-pthread") }
      arguments += ["-isystem", resources.socketHeaders.path] + Self.emulationDefines
    case .wasix:
      arguments += ["-pthread", "-matomics", "-mbulk-memory", "-mmutable-globals"]
    }
    if let workingDirectory { arguments += ["-working-directory", workingDirectory.path] }
    arguments += rest
    if linking {
      if chosen != .wasix {
        arguments += ["-L\(resources.socketLibrary(chosen).path)", "-lwasi_socket_ext"] + Self.emulationLibraries
      }
      if chosen == .wasix { arguments += ["-Wl,--shared-memory", "-Wl,--import-memory"] }
      // Shared memory (threads) cannot grow past its declared maximum, and
      // wasm-ld makes that maximum the initial size: no room for thread
      // stacks. 1 GiB unless the user sets one; the runtime commits only what
      // the program touches.
      if chosen != .wasip1, !userArguments.contains(where: { $0.contains("--max-memory") }) {
        arguments.append("-Wl,--max-memory=\(Self.threadsMaxMemory)")
      }
    }
    return arguments
  }

  /// wasi-libc's emulations of what WASI lacks, on by default so ordinary
  /// code compiles: signal() and raise() (handlers run for raise in the same
  /// program, nothing is delivered from outside), mmap of anonymous and
  /// private file mappings, getpid, and process CPU clocks (clock()).
  public static let emulationDefines = [
    "-D_WASI_EMULATED_SIGNAL", "-D_WASI_EMULATED_MMAN", "-D_WASI_EMULATED_GETPID",
    "-D_WASI_EMULATED_PROCESS_CLOCKS",
  ]
  public static let emulationLibraries = [
    "-lwasi-emulated-signal", "-lwasi-emulated-mman", "-lwasi-emulated-getpid",
    "-lwasi-emulated-process-clocks",
  ]

  /// The shared memory maximum for threaded programs, in bytes.
  public static let threadsMaxMemory = 1 << 30

  public enum DriverError: Error, LocalizedError, Equatable {
    case unsupportedTarget(String)
    case targetNotInstalled(String)
    case threadsNeedThreadsTarget

    public var errorDescription: String? {
      switch self {
      case .unsupportedTarget(let t):
        "unsupported target '\(t)': use wasm32-wasip1 (the default), wasm32-wasip1-threads or wasm32-wasix"
      case .targetNotInstalled(let t): "the \(t) libraries are not installed in this app"
      case .threadsNeedThreadsTarget: "-pthread needs --target=wasm32-wasip1-threads (or wasm32-wasix)"
      }
    }
  }

  /// Runs an arbitrary clang command line in process.
  public func run(arguments: [String], output: URL) async -> CompileResult {
    let start = ContinuousClock.now
    var result = await Self.onCompilerThread { Self.invoke(arguments) }
    result.output = output
    let elapsed = ContinuousClock.now - start
    result.totalMilliseconds = Double(elapsed.components.seconds) * 1e3
      + Double(elapsed.components.attoseconds) / 1e15
    return result
  }

  // MARK: - Bridge

  private final class Collector {
    var log = ""
    var diagnostics: [Diagnostic] = []
  }

  private static func invoke(_ arguments: [String]) -> CompileResult {
    let collector = Collector()
    let user = Unmanaged.passUnretained(collector).toOpaque()
    var callbacks = lst_callbacks(
      user: user,
      text: { user, _, data, length in
        guard let user, let data else { return }
        let collector = Unmanaged<Collector>.fromOpaque(user).takeUnretainedValue()
        let buffer = UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), count: length)
        collector.log += String(decoding: buffer, as: UTF8.self)
      },
      diagnostic: { user, diagnostic in
        guard let user, let d = diagnostic?.pointee else { return }
        let collector = Unmanaged<Collector>.fromOpaque(user).takeUnretainedValue()
        collector.diagnostics.append(Diagnostic(
          level: Diagnostic.Level(rawValue: Int(d.level.rawValue)) ?? .error,
          file: d.file.map { String(cString: $0) } ?? "",
          line: Int(d.line), column: Int(d.column),
          message: d.message.map { String(cString: $0) } ?? ""))
      })
    var timings = lst_timings()

    // Keep the C strings alive for the duration of the call.
    let cStrings = arguments.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    let argv = cStrings.map { UnsafePointer<CChar>($0) }
    let code = argv.withUnsafeBufferPointer { buffer in
      withExtendedLifetime(collector) {
        lst_clang_main(Int32(buffer.count), buffer.baseAddress, &callbacks, &timings)
      }
    }
    return CompileResult(
      exitCode: code, output: URL(fileURLWithPath: "/"), log: collector.log,
      diagnostics: collector.diagnostics,
      driverMilliseconds: timings.driver_ms, compileMilliseconds: timings.compile_ms,
      linkMilliseconds: timings.link_ms, totalMilliseconds: 0)
  }

  /// Runs body on a new thread with an 8 MB stack (clang and clangd expect
  /// about that; secondary threads on iOS get 512 KB).
  public static func onCompilerThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      let thread = Thread { continuation.resume(returning: body()) }
      thread.stackSize = 8 << 20
      thread.qualityOfService = .userInitiated
      thread.name = "clang"
      thread.start()
    }
  }
}
