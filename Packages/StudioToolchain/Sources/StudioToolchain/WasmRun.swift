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
}

public typealias WasmOutputHandler = @MainActor @Sendable (WasmOutput) -> Void

func milliseconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) * 1e3 + Double(duration.components.attoseconds) / 1e15
}
