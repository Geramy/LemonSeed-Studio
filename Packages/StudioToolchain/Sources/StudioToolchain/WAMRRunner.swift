import CWAMRRunner
import Foundation

/// Runs WASI command modules in this process on WAMR's fast interpreter.
/// Starts instantly (no web view), which suits try_run, ctest and quick runs;
/// it is several times slower than WebKit's JIT on long-running code.
public final class WAMRRunner: Sendable {
  public init() {}

  public static var version: String { String(cString: lst_wamr_version()) }

  private final class OutputSink: @unchecked Sendable {
    let handler: WasmOutputHandler
    init(handler: @escaping WasmOutputHandler) { self.handler = handler }
  }

  public func run(
    wasm: Data, arguments: [String], environment: [String: String] = [:],
    preopenDirectory: URL? = nil, output: @escaping WasmOutputHandler
  ) async -> WasmRunResult {
    let start = ContinuousClock.now
    let sink = OutputSink(handler: output)
    var result = await Compiler.onCompilerThread {
      Self.runBlocking(wasm: wasm, arguments: arguments, environment: environment,
                       preopen: preopenDirectory?.path, sink: sink)
    }
    result.totalMilliseconds = milliseconds(ContinuousClock.now - start)
    return result
  }

  private static func runBlocking(
    wasm: Data, arguments: [String], environment: [String: String],
    preopen: String?, sink: OutputSink
  ) -> WasmRunResult {
    let argStrings = arguments.map { strdup($0) }
    let envStrings = environment.map { strdup("\($0.key)=\($0.value)") }
    let preopenString = preopen.map { strdup($0) }
    defer {
      argStrings.forEach { free($0) }
      envStrings.forEach { free($0) }
      preopenString.map { free($0) }
    }
    let argv: [UnsafePointer<CChar>?] = argStrings.map { $0.map { UnsafePointer($0) } }
    let envp: [UnsafePointer<CChar>?] = envStrings.map { $0.map { UnsafePointer($0) } }

    let session = lst_wamr_session_create()
    defer { lst_wamr_session_destroy(session) }
    var result = lst_wamr_result()
    let user = Unmanaged.passUnretained(sink).toOpaque()

    _ = wasm.withUnsafeBytes { bytes in
      argv.withUnsafeBufferPointer { argvBuffer in
        envp.withUnsafeBufferPointer { envBuffer in
          withExtendedLifetime(sink) {
            var options = lst_wamr_options()
            options.wasm = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            options.wasm_length = bytes.count
            options.argv = argvBuffer.baseAddress
            options.argc = Int32(argvBuffer.count)
            options.env = envBuffer.baseAddress
            options.env_count = Int32(envBuffer.count)
            options.preopen_dir = preopenString.map { UnsafePointer($0!) }
            options.user = user
            options.output = { user, fd, data, length in
              guard let user, let data else { return }
              let sink = Unmanaged<OutputSink>.fromOpaque(user).takeUnretainedValue()
              let buffer = UnsafeBufferPointer(
                start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), count: length)
              let chunk = WasmOutput(stream: fd == 2 ? .stderr : .stdout,
                                     text: String(decoding: buffer, as: UTF8.self))
              let handler = sink.handler
              Task { @MainActor in handler(chunk) }
            }
            return lst_wamr_session_run(session, &options, &result)
          }
        }
      }
    }

    let error = withUnsafeBytes(of: result.error) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return WasmRunResult(
      exitCode: result.exit_code, error: error.isEmpty ? nil : error,
      loadMilliseconds: result.load_ms, instantiateMilliseconds: result.instantiate_ms,
      runMilliseconds: result.run_ms, totalMilliseconds: 0)
  }
}
