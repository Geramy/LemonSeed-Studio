import Foundation
import Testing
@testable import StudioToolchain

/// A 257-byte WASI command: writes "hi from wasm\n" to stdout, then proc_exit(3).
/// Built from a freestanding C file with clang --target=wasm32 -nostdlib.
private let miniWasm = Data(base64Encoded: "AGFzbQEAAAABEANgBH9/f38Bf2ABfwBgAAACRgIWd2FzaV9zbmFwc2hvdF9wcmV2aWV3MQhmZF93cml0ZQAAFndhc2lfc25hcHNob3RfcHJldmlldzEJcHJvY19leGl0AAEDAgECBAUBcAEBAQUDAQACBggBfwFBoIgECwcTAgZtZW1vcnkCAAZfc3RhcnQAAgpNAUsBAX8jgICAgABBEGsiACSAgICAACAAQQApA5CIgIAANwMIQQEgAEEIakEBIABBBGoQgICAgAAaQQMQgYCAgAAgAEEQaiSAgICAAAsLHwEAQYAICxhoaSBmcm9tIHdhc20KAAAAAAQAAA0AAAA=")!

private final class Captured: @unchecked Sendable {
  var text = ""
}

@Suite struct WAMRRunnerTests {
  @Test func runsAWASICommand() async {
    let captured = Captured()
    let result = await WAMRRunner().run(wasm: miniWasm, arguments: ["mini"]) { chunk in
      captured.text += chunk.text
    }
    await Task.yield()
    #expect(result.error == nil)
    #expect(result.exitCode == 3)
    #expect(captured.text == "hi from wasm\n")
  }

  @Test func reportsInvalidModules() async {
    let result = await WAMRRunner().run(wasm: Data([0, 1, 2, 3]), arguments: ["bad"]) { _ in }
    #expect(result.exitCode == -1)
    #expect(result.error != nil)
  }
}

/// Uses the WASIToolchain resources from Toolchain/build when they exist (the
/// simulator can read the Mac's file system).
@Suite struct CompilerTests {
  static let resources: ToolchainResources? = {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Toolchain/build/resources/WASIToolchain")
    return FileManager.default.fileExists(atPath: root.path) ? ToolchainResources(root: root) : nil
  }()

  @Test(.enabled(if: Compiler.isAvailable && resources != nil))
  func compilesAndRunsC() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appending(path: "t.c")
    try "#include <stdio.h>\nint main(void) { printf(\"%d\\n\", 6 * 7); return 0; }\n"
      .write(to: source, atomically: true, encoding: .utf8)
    let output = dir.appending(path: "t.wasm")
    let result = await Compiler(resources: Self.resources!).compile(sources: [source], output: output)
    #expect(result.succeeded, "\(result.log)")
    let captured = Captured()
    let run = await WAMRRunner().run(wasm: try Data(contentsOf: output), arguments: ["t"]) { captured.text += $0.text }
    await Task.yield()
    #expect(run.exitCode == 0)
    #expect(captured.text == "42\n")
  }

  @Test(.enabled(if: Compiler.isAvailable && resources != nil))
  func reportsStructuredDiagnostics() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appending(path: "bad.c")
    try "int main(void) {\n  return y;\n}\n".write(to: source, atomically: true, encoding: .utf8)
    let result = await Compiler(resources: Self.resources!)
      .compile(sources: [source], output: dir.appending(path: "bad.wasm"))
    #expect(!result.succeeded)
    let error = try #require(result.diagnostics.first { $0.level == .error })
    #expect(error.line == 2)
    #expect(error.column == 10)
    #expect(error.message.contains("undeclared identifier 'y'"))
  }

  @Test(.enabled(if: Compiler.isAvailable && resources != nil))
  func compilesInParallel() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let compiler = Compiler(resources: Self.resources!)
    let results = await withTaskGroup(of: Bool.self) { group in
      for i in 0..<4 {
        group.addTask {
          let source = dir.appending(path: "p\(i).c")
          try? "int main(void) { return \(i); }\n".write(to: source, atomically: true, encoding: .utf8)
          return await compiler.compile(sources: [source], output: dir.appending(path: "p\(i).wasm")).succeeded
        }
      }
      return await group.reduce(into: [Bool]()) { $0.append($1) }
    }
    #expect(results.count == 4 && results.allSatisfy { $0 })
  }
}
