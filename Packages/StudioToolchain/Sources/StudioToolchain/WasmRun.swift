import Foundation

/// A chunk of program output.
public struct WasmOutput: Sendable {
  public enum Stream: Sendable { case stdout, stderr }
  public var stream: Stream
  public var text: String
}

/// How a WASI program run ended, with timings.
public struct WasmRunResult: Sendable {
  public var exitCode: Int32
  /// Trap, load error or runtime failure; nil when the program ran to exit.
  public var error: String?
  /// Parse/validate (WAMR) or WebAssembly.compile (WebKit).
  public var loadMilliseconds: Double
  public var instantiateMilliseconds: Double
  public var runMilliseconds: Double
  /// Wall time seen by the caller, including runtime start-up.
  public var totalMilliseconds: Double
  /// Imports the program called that the runtime does not provide.
  public var unsupportedImports: [String] = []

  public init(exitCode: Int32, error: String? = nil, loadMilliseconds: Double = 0, instantiateMilliseconds: Double = 0,
              runMilliseconds: Double = 0, totalMilliseconds: Double = 0, unsupportedImports: [String] = []) {
    self.exitCode = exitCode
    self.error = error
    self.loadMilliseconds = loadMilliseconds
    self.instantiateMilliseconds = instantiateMilliseconds
    self.runMilliseconds = runMilliseconds
    self.totalMilliseconds = totalMilliseconds
    self.unsupportedImports = unsupportedImports
  }
}

public typealias WasmOutputHandler = @MainActor @Sendable (WasmOutput) -> Void

func milliseconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
}

/// Input for a running program's stdin (fd 0): a pipe whose read end the
/// runner hands to the program. Write what the user types; close for end of
/// file.
public final class WasmInput: @unchecked Sendable {
  private let lock = NSLock()
  private var writeFD: Int32
  let readFD: Int32

  public init() {
    var fds: [Int32] = [-1, -1]
    if pipe(&fds) != 0 { fds = [-1, -1] }
    readFD = fds[0]
    writeFD = fds[1]
  }

  /// Input given all at once, then end of file (a pipeline's stdin).
  public convenience init(text: String) {
    self.init()
    write(Data(text.utf8))
    close()
  }

  public func write(_ data: Data) {
    lock.lock(); defer { lock.unlock() }
    guard writeFD >= 0 else { return }
    data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(writeFD, raw.baseAddress! + offset, raw.count - offset)
        if n <= 0 { break }
        offset += n
      }
    }
  }

  /// End of file for the program.
  public func close() {
    lock.lock(); defer { lock.unlock() }
    if writeFD >= 0 { Darwin.close(writeFD); writeFD = -1 }
  }

  deinit {
    close()
    if readFD >= 0 { Darwin.close(readFD) }
  }
}
