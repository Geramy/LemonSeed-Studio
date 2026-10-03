import CToolchainBridge
import Foundation

/// Where the WASI sysroot and clang's resource directory live. The app ships
/// them as a folder named "WASIToolchain" (see Toolchain/scripts/fetch-wasi-sysroot.sh).
public struct ToolchainResources: Sendable {
  public var root: URL
  public var sysroot: URL { root.appending(path: "sysroot") }
  public var resourceDir: URL { root.appending(path: "clang") }

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
}

/// Compiles C and C++ to wasm32-wasip1 with clang and wasm-ld running inside
/// this process (no subprocesses). Compiles run on their own 8 MB-stack
/// threads, so several can run at once; links are serialized by the bridge.
public final class Compiler: Sendable {
  public let resources: ToolchainResources

  public init(resources: ToolchainResources) {
    self.resources = resources
  }

  public static var isAvailable: Bool { lst_toolchain_available() != 0 }
  public static var version: String { String(cString: lst_toolchain_version()) }

  /// Builds `sources` into a WASI command module at `output`.
  public func compile(
    sources: [URL], output: URL, language: SourceLanguage = .c,
    optimization: String = "-O2", extraArguments: [String] = []
  ) async -> CompileResult {
    var arguments = [
      language == .c ? "clang" : "clang++",
      "--target=wasm32-wasip1",
      "-resource-dir", resources.resourceDir.path,
      "--sysroot=\(resources.sysroot.path)",
      language.driverFlag, optimization,
      // C++ exceptions need a libc++ built for wasm exceptions; the stock
      // wasi-sdk 30 sysroot is built without them.
      language == .cxx ? "-fno-exceptions" : nil,
    ].compactMap { $0 }
    arguments += extraArguments
    arguments += sources.map(\.path)
    arguments += ["-o", output.path]
    return await run(arguments: arguments, output: output)
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
