import Foundation

/// A project's build description, `studio-build.json` at its root:
///
///     {
///       "name": "server",
///       "target": "wasm32-wasip1",        // or "wasm32-wasip1-threads"; default wasm32-wasip1
///       "sources": ["src/*.c", "src/**/*.cpp", "main.c"],
///       "includes": ["include"],
///       "defines": ["VERSION=2"],
///       "flags": ["-O2", "-Wall"],        // compile flags
///       "linkFlags": ["-lm"],
///       "output": "build/server.wasm",    // default build/<name>.wasm
///       "args": ["8080"]                  // what Run passes to the program
///     }
///
/// Paths are relative to the file. Sources may use `*` (one directory
/// level) and `**` (any depth).
public struct ProjectManifest: Codable, Sendable, Equatable {
  public var name: String
  public var target: CompileTarget?
  public var sources: [String]
  public var includes: [String]?
  public var defines: [String]?
  public var flags: [String]?
  public var linkFlags: [String]?
  public var output: String?
  public var args: [String]?

  public static let fileName = "studio-build.json"

  public init(name: String, target: CompileTarget? = nil, sources: [String], includes: [String]? = nil,
              defines: [String]? = nil, flags: [String]? = nil, linkFlags: [String]? = nil,
              output: String? = nil, args: [String]? = nil) {
    self.name = name
    self.target = target
    self.sources = sources
    self.includes = includes
    self.defines = defines
    self.flags = flags
    self.linkFlags = linkFlags
    self.output = output
    self.args = args
  }

  public static func load(from root: URL) throws -> ProjectManifest {
    let url = root.appending(path: fileName)
    let data = try Data(contentsOf: url)
    do {
      return try JSONDecoder().decode(ProjectManifest.self, from: data)
    } catch let DecodingError.dataCorrupted(context) {
      throw ManifestError.invalid(context.debugDescription)
    } catch let DecodingError.keyNotFound(key, _) {
      throw ManifestError.invalid("missing \"\(key.stringValue)\"")
    } catch let DecodingError.typeMismatch(_, context) {
      throw ManifestError.invalid("\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)")
    }
  }

  public enum ManifestError: Error, LocalizedError {
    case invalid(String)
    case noSources([String])
    public var errorDescription: String? {
      switch self {
      case .invalid(let why): "\(ProjectManifest.fileName): \(why)"
      case .noSources(let patterns): "\(ProjectManifest.fileName): no source matches \(patterns.joined(separator: ", "))"
      }
    }
  }

  public func outputURL(root: URL) -> URL {
    root.appending(path: output ?? "build/\(name).wasm")
  }

  /// The source files the patterns name, sorted.
  public func sourceFiles(root: URL) throws -> [URL] {
    var found: Set<String> = []
    for pattern in sources {
      if !pattern.contains("*") {
        let url = root.appending(path: pattern)
        if FileManager.default.fileExists(atPath: url.path) { found.insert(url.standardizedFileURL.path) }
        continue
      }
      for path in Glob.match(pattern, in: root) { found.insert(path) }
    }
    guard !found.isEmpty else { throw ManifestError.noSources(sources) }
    return found.sorted().map { URL(fileURLWithPath: $0) }
  }
}

/// `*` within one path component, `**` across components, `?` one character.
enum Glob {
  static func match(_ pattern: String, in root: URL) -> [String] {
    let base = root.standardizedFileURL.path
    guard let walker = FileManager.default.enumerator(atPath: base) else { return [] }
    var out: [String] = []
    while let relative = walker.nextObject() as? String {
      if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "build" }) { continue }
      if matches(pattern: Array(pattern.split(separator: "/").map(String.init)),
                 path: Array(relative.split(separator: "/").map(String.init))) {
        out.append(base + "/" + relative)
      }
    }
    return out
  }

  static func matches(pattern: [String], path: [String]) -> Bool {
    guard let head = pattern.first else { return path.isEmpty }
    if head == "**" {
      for skip in 0...path.count where matches(pattern: Array(pattern.dropFirst()), path: Array(path.dropFirst(skip))) {
        return true
      }
      return false
    }
    guard let component = path.first, fnmatch(head, component, 0) == 0 else { return false }
    return matches(pattern: Array(pattern.dropFirst()), path: Array(path.dropFirst()))
  }
}

/// The outcome of a project build.
public struct ProjectBuildResult: Sendable {
  public var succeeded: Bool
  public var output: URL
  /// What the compiler printed, in order.
  public var log: String
  public var diagnostics: [Diagnostic]
  public var compiled: Int
  public var upToDate: Int
  public var linked: Bool
  public var milliseconds: Double
}

/// Builds a `ProjectManifest`: each source to an object under build/obj
/// (again only when it, a header it includes or the flags changed, from
/// clang's dependency files), in parallel, then links when any object is
/// newer than the program.
public struct ProjectBuilder: Sendable {
  public let compiler: Compiler
  public let root: URL
  public let manifest: ProjectManifest

  public init(compiler: Compiler, root: URL, manifest: ProjectManifest) {
    self.compiler = compiler
    self.root = root.standardizedFileURL
    self.manifest = manifest
  }

  var objectDirectory: URL { root.appending(path: "build/obj") }

  public func build(progress: (@Sendable (String) -> Void)? = nil) async throws -> ProjectBuildResult {
    let start = ContinuousClock.now
    let sources = try manifest.sourceFiles(root: root)
    let output = manifest.outputURL(root: root)
    try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let target = manifest.target ?? .wasip1
    let compileFlags = (manifest.flags ?? ["-O2"]) + (manifest.includes ?? []).map { "-I" + $0 }
      + (manifest.defines ?? []).map { "-D" + $0 }
    let flagStamp = ([target.rawValue] + compileFlags).joined(separator: "\u{1F}")

    var log = ""
    var diagnostics: [Diagnostic] = []
    var compiled = 0, upToDate = 0
    var objects: [URL] = []
    var failed = false

    struct Job: Sendable { let source: URL; let object: URL; let language: SourceLanguage }
    var jobs: [Job] = []
    for source in sources {
      let object = self.object(for: source)
      objects.append(object)
      if isUpToDate(object: object, stamp: flagStamp) { upToDate += 1; continue }
      jobs.append(Job(source: source, object: object, language: SourceLanguage(path: source.path)))
    }

    let width = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6))
    var index = 0
    while index < jobs.count {
      let batch = jobs[index..<min(index + width, jobs.count)]
      index += batch.count
      let results = await withTaskGroup(of: (Job, CompileResult?, String?).self) { group in
        for job in batch {
          group.addTask {
            progress?("compile \(relative(job.source))")
            try? FileManager.default.createDirectory(at: job.object.deletingLastPathComponent(), withIntermediateDirectories: true)
            let depfile = job.object.appendingPathExtension("d")
            let user = compileFlags + ["-c", relative(job.source), "-o", job.object.path, "-MMD", "-MF", depfile.path]
            do {
              let arguments = try compiler.driverArguments(
                (target == .wasip1Threads ? ["-pthread", "--target=\(target.rawValue)"] : ["--target=\(target.rawValue)"]) + user,
                cxx: job.language == .cxx, workingDirectory: root)
              return (job, await compiler.run(arguments: arguments, output: job.object), nil)
            } catch {
              return (job, nil, error.localizedDescription)
            }
          }
        }
        var collected: [(Job, CompileResult?, String?)] = []
        for await r in group { collected.append(r) }
        return collected.sorted { $0.0.source.path < $1.0.source.path }
      }
      for (job, result, error) in results {
        if let error { log += "error: \(error)\n"; failed = true; continue }
        guard let result else { continue }
        log += result.log
        diagnostics += result.diagnostics
        if result.succeeded {
          compiled += 1
          try? Data(flagStamp.utf8).write(to: job.object.appendingPathExtension("flags"))
        } else {
          failed = true
          try? FileManager.default.removeItem(at: job.object)
        }
      }
    }

    var linked = false
    if !failed, needsLink(output: output, objects: objects) {
      progress?("link \(relative(output))")
      let hasCxx = sources.contains { SourceLanguage(path: $0.path) == .cxx }
      var user = (target == .wasip1Threads ? ["-pthread"] : []) + ["--target=\(target.rawValue)"]
      user += objects.map(\.path) + (manifest.linkFlags ?? []) + ["-o", output.path]
      let arguments = try compiler.driverArguments(user, cxx: hasCxx, workingDirectory: root)
      let result = await compiler.run(arguments: arguments, output: output)
      log += result.log
      diagnostics += result.diagnostics
      failed = !result.succeeded
      linked = result.succeeded
    }
    return ProjectBuildResult(succeeded: !failed, output: output, log: log, diagnostics: diagnostics,
                              compiled: compiled, upToDate: upToDate, linked: linked,
                              milliseconds: milliseconds(ContinuousClock.now - start))
  }

  func relative(_ url: URL) -> String {
    let path = url.standardizedFileURL.path
    let base = root.path + "/"
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
  }

  func object(for source: URL) -> URL {
    objectDirectory.appending(path: relative(source) + ".o")
  }

  /// Up to date: the object exists, was built with these flags, and is newer
  /// than every file its dependency file lists (the source and its headers).
  func isUpToDate(object: URL, stamp: String) -> Bool {
    guard let built = modificationDate(object),
          (try? String(contentsOf: object.appendingPathExtension("flags"), encoding: .utf8)) == stamp,
          let deps = try? String(contentsOf: object.appendingPathExtension("d"), encoding: .utf8) else { return false }
    for path in Self.dependencies(deps) {
      let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appending(path: path)
      guard let changed = modificationDate(url), changed <= built else { return false }
    }
    return true
  }

  func needsLink(output: URL, objects: [URL]) -> Bool {
    guard let linked = modificationDate(output) else { return true }
    return objects.contains { (modificationDate($0) ?? .distantFuture) > linked }
  }

  /// The prerequisites of a make-style dependency file ("obj: a.c b.h \ ...").
  static func dependencies(_ text: String) -> [String] {
    let joined = text.replacingOccurrences(of: "\\\n", with: " ")
    guard let colon = joined.range(of: ": ") else { return [] }
    var out: [String] = []
    var current = ""
    var escaped = false
    for ch in joined[colon.upperBound...] {
      if escaped { current.append(ch); escaped = false; continue }
      if ch == "\\" { escaped = true; continue }
      if ch == " " || ch == "\n" || ch == "\t" {
        if !current.isEmpty { out.append(current); current = "" }
      } else {
        current.append(ch)
      }
    }
    if !current.isEmpty { out.append(current) }
    return out
  }

  private func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
