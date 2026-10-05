import CWAMRRunner
import Foundation

/// Runs WASI command modules in this process on WAMR's fast interpreter.
/// Starts instantly (no web view) and its host calls are synchronous, so a
/// program can read stdin, use files in its directory, open sockets and
/// start threads; it is several times slower than WebKit's JIT on
/// long-running computation.
public final class WAMRRunner: Sendable {
  public init() {}

  public static var version: String { String(cString: lst_wamr_version()) }

  /// How each WASIX (wasix_32v1) call is handled: implemented, or ENOSYS.
  public static var wasixCoverage: [(call: String, implemented: Bool)] {
    String(cString: lst_wasix_coverage()).split(separator: "\n").compactMap { line in
      let parts = line.split(separator: ":")
      guard parts.count == 2 else { return nil }
      return (String(parts[0]), parts[1] == "implemented")
    }
  }

  /// Output from the reader threads, in order, to the handler on the main actor.
  private final class OutputSink: @unchecked Sendable {
    let continuation: AsyncStream<WasmOutput>.Continuation
    let consumer: Task<Void, Never>
    init(handler: @escaping WasmOutputHandler) {
      let (stream, continuation) = AsyncStream<WasmOutput>.makeStream()
      self.continuation = continuation
      consumer = Task { @MainActor in
        for await chunk in stream { handler(chunk) }
      }
    }
    func finish() async {
      continuation.finish()
      await consumer.value
    }
  }

  /// `preopenDirectory` is the program's "." and "/" (nothing outside it is
  /// reachable); `input` its stdin (end of file when nil); with
  /// `allowNetwork` it may open sockets to any address. Cancelling the task
  /// stops the program.
  public func run(
    wasm: Data, arguments: [String], environment: [String: String] = [:],
    preopenDirectory: URL? = nil, input: WasmInput? = nil, allowNetwork: Bool = true,
    output: @escaping WasmOutputHandler
  ) async -> WasmRunResult {
    let start = ContinuousClock.now
    let sink = OutputSink(handler: output)
    let session = Session()
    var result = await withTaskCancellationHandler {
      await Compiler.onCompilerThread {
        Self.runBlocking(wasm: wasm, arguments: arguments, environment: environment,
                         preopen: preopenDirectory?.path, stdinFD: input?.readFD ?? -1,
                         allowNetwork: allowNetwork, session: session, sink: sink)
      }
    } onCancel: {
      session.terminate()
    }
    await sink.finish()
    result.totalMilliseconds = milliseconds(ContinuousClock.now - start)
    return result
  }

  /// The C session, shared with the cancellation handler.
  private final class Session: @unchecked Sendable {
    let handle = lst_wamr_session_create()
    func terminate() { lst_wamr_session_terminate(handle) }
    deinit { lst_wamr_session_destroy(handle) }
  }

  private static func runBlocking(
    wasm: Data, arguments: [String], environment: [String: String],
    preopen: String?, stdinFD: Int32, allowNetwork: Bool, session: Session, sink: OutputSink
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
            options.stdin_fd = stdinFD
            options.allow_network = allowNetwork ? 1 : 0
            options.user = user
            options.output = { user, fd, data, length in
              guard let user, let data else { return }
              let sink = Unmanaged<OutputSink>.fromOpaque(user).takeUnretainedValue()
              let buffer = UnsafeBufferPointer(
                start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), count: length)
              let chunk = WasmOutput(stream: fd == 2 ? .stderr : .stdout,
                                     text: String(decoding: buffer, as: UTF8.self))
              sink.continuation.yield(chunk)
            }
            return lst_wamr_session_run(session.handle, &options, &result)
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
