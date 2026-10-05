import Foundation

/// What a WebAssembly module imports, read from its binary (the import
/// section only; nothing is compiled or run).
public struct WasmModuleInfo: Sendable, Hashable {
  public struct Import: Sendable, Hashable {
    public enum Kind: UInt8, Sendable { case function = 0, table, memory, global, tag }
    public var module: String
    public var name: String
    public var kind: Kind
    /// For an imported memory: whether it is shared (threads).
    public var sharedMemory: Bool = false

    public var qualifiedName: String { "\(module).\(name)" }
  }

  public enum ParseError: Error, LocalizedError {
    case notWasm
    case truncated
    public var errorDescription: String? {
      switch self {
      case .notWasm: "not a WebAssembly module"
      case .truncated: "the WebAssembly module is truncated"
      }
    }
  }

  public var imports: [Import]
  /// A memory the module defines itself is shared.
  public var definesSharedMemory: Bool

  public init(data: Data) throws {
    var reader = Reader(bytes: [UInt8](data))
    guard reader.bytes.count >= 8, reader.bytes[0..<4] == [0x00, 0x61, 0x73, 0x6D] else { throw ParseError.notWasm }
    reader.position = 8
    var imports: [Import] = []
    var sharedDefined = false
    while !reader.atEnd {
      let section = try reader.byte()
      let size = try reader.leb()
      let end = reader.position + size
      guard end <= reader.bytes.count else { throw ParseError.truncated }
      switch section {
      case 2:  // imports
        let count = try reader.leb()
        for _ in 0..<count {
          let module = try reader.name()
          let name = try reader.name()
          guard let kind = Import.Kind(rawValue: try reader.byte()) else { throw ParseError.truncated }
          var shared = false
          switch kind {
          case .function: _ = try reader.leb()
          case .table:
            _ = try reader.byte()  // element type
            try reader.limits(shared: &shared)
          case .memory: try reader.limits(shared: &shared)
          case .global: _ = try reader.byte(); _ = try reader.byte()
          case .tag: _ = try reader.byte(); _ = try reader.leb()
          }
          imports.append(Import(module: module, name: name, kind: kind, sharedMemory: kind == .memory && shared))
        }
      case 5:  // memories
        let count = try reader.leb()
        for _ in 0..<count {
          var shared = false
          try reader.limits(shared: &shared)
          sharedDefined = sharedDefined || shared
        }
      default: break
      }
      reader.position = end
    }
    self.imports = imports
    self.definesSharedMemory = sharedDefined
  }

  public var functionImports: [Import] { imports.filter { $0.kind == .function } }

  /// The module uses threads: shared memory, or a thread-spawn import.
  public var usesThreads: Bool {
    definesSharedMemory || imports.contains { $0.sharedMemory }
      || functionImports.contains { $0.name == "thread-spawn" || $0.name.hasPrefix("thread_spawn") }
  }

  /// The module calls WASIX (the wasix_32v1 or wasix_64v1 namespaces).
  public var usesWASIX: Bool { functionImports.contains { $0.module.hasPrefix("wasix_") } }

  /// The module opens sockets or resolves names.
  public var usesSockets: Bool {
    functionImports.contains { $0.name.hasPrefix("sock_") || $0.name == "resolve" }
  }

  private struct Reader {
    let bytes: [UInt8]
    var position = 0
    var atEnd: Bool { position >= bytes.count }

    mutating func byte() throws -> UInt8 {
      guard position < bytes.count else { throw ParseError.truncated }
      defer { position += 1 }
      return bytes[position]
    }

    mutating func leb() throws -> Int {
      var result = 0, shift = 0
      while true {
        let b = try byte()
        result |= Int(b & 0x7F) << shift
        if b & 0x80 == 0 { return result }
        shift += 7
        guard shift < 64 else { throw ParseError.truncated }
      }
    }

    mutating func name() throws -> String {
      let length = try leb()
      guard position + length <= bytes.count else { throw ParseError.truncated }
      defer { position += length }
      return String(decoding: bytes[position..<position + length], as: UTF8.self)
    }

    /// limits: flags, min, [max]; bit 1 of the flags is "shared", bit 2 memory64.
    mutating func limits(shared: inout Bool) throws {
      let flags = try leb()
      shared = flags & 0x02 != 0
      _ = try leb()
      if flags & 0x01 != 0 { _ = try leb() }
    }
  }
}

/// Which runtime runs a program.
public enum WasmRunner: String, Sendable, CaseIterable {
  /// A hidden WKWebView: JavaScriptCore JIT-compiles the module in WebKit's
  /// process. Fast, but the host calls are asynchronous JavaScript, so it can
  /// offer only what needs no blocking: output, arguments, environment,
  /// clocks and random numbers.
  case webKit = "webkit"
  /// WAMR's fast interpreter in this process: synchronous host calls, so
  /// stdin, files in the project, sockets and threads.
  case wamr

  public var title: String {
    switch self {
    case .webKit: "WebKit (JIT)"
    case .wamr: "WAMR (interpreter)"
    }
  }

  /// The WASI preview 1 calls the WebKit runner implements in full.
  public static let webKitCalls: Set<String> = [
    "args_get", "args_sizes_get", "environ_get", "environ_sizes_get",
    "clock_res_get", "clock_time_get", "random_get", "sched_yield", "proc_exit",
    "fd_write", "fd_close", "fd_seek", "fd_sync", "fd_fdstat_get", "fd_fdstat_set_flags", "fd_filestat_get",
  ]

  /// The runner for a module, and why: WebKit only when every call the
  /// module imports is one it implements (pure compute that prints); WAMR
  /// for anything that reads stdin, touches files, uses sockets or threads,
  /// or calls WASIX.
  public static func choose(for info: WasmModuleInfo) -> (runner: WasmRunner, reason: String) {
    if info.usesWASIX { return (.wamr, "calls WASIX") }
    if info.usesThreads { return (.wamr, "uses threads") }
    if info.usesSockets { return (.wamr, "uses sockets") }
    let needs = info.functionImports.filter {
      $0.module != "wasi_snapshot_preview1" || !webKitCalls.contains($0.name)
    }
    guard needs.isEmpty else {
      let names = needs.prefix(3).map(\.name).joined(separator: ", ")
      return (.wamr, "needs \(names)\(needs.count > 3 ? ", \u{2026}" : "") (stdin, files or other host calls)")
    }
    return (.webKit, "pure computation and output")
  }
}
