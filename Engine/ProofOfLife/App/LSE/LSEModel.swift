import Foundation
import LSEKit
import UIKit
import os

let lseLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "lse")

/// The in-process engine for the "LSE" screen and the `--auto-lse` run.
///
/// Models live in Documents/Models/<name> (MLX safetensors directories).
/// The engine is reached through `lse_request` only; HTTP on 127.0.0.1:8080 is
/// an option for clients outside this process.
@MainActor
final class LSEModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, stopping, failed(String) }

    @Published private(set) var models: [String] = []
    @Published var targetModel: String?
    @Published var draftModel: String?
    @Published var serveHTTP = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var loadDetail = ""
    @Published private(set) var log: [String] = []
    @Published private(set) var lastResult = ""
    @Published private(set) var testing = false

    private var engine: LSEEngine?
    private var statusTimer: Timer?

    static let autoRun = ProcessInfo.processInfo.arguments.contains("--auto-lse")

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var modelsDirectory: URL { documents.appendingPathComponent("Models", isDirectory: true) }

    init() {
        LSEEngine.setLogHandler { line in
            lseLog.log("\(line, privacy: .public)")
            Task { @MainActor [weak self] in self?.append(line) }
        }
        refreshModels()
        if Self.autoRun {
            Task { await self.runAutomatically() }
        }
    }

    // MARK: Models

    func refreshModels() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: Self.modelsDirectory.path)) ?? []
        models = names.filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: Self.modelsDirectory.appendingPathComponent(name).path,
                                 isDirectory: &isDir) && isDir.boolValue
        }.sorted()
        let drafts = models.filter { $0.localizedCaseInsensitiveContains("dflash") }
        let targets = models.filter { !$0.localizedCaseInsensitiveContains("dflash") }
        if targetModel == nil || !models.contains(targetModel!) {
            targetModel = Self.argument("--lse-model") ?? targets.first(where: { $0.localizedCaseInsensitiveContains("q4") }) ?? targets.first
        }
        if draftModel == nil || !models.contains(draftModel!) {
            draftModel = Self.argument("--lse-draft") ?? drafts.first
        }
    }

    private static func argument(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: Engine

    /// The lse-server settings the Mac runs Qwen3.8-27B Q4 with DFlash2 under.
    func configuration() -> LSEEngine.Configuration? {
        guard let target = targetModel else { return nil }
        var c = LSEEngine.Configuration(model: Self.modelsDirectory.appendingPathComponent(target).path)
        if let draft = draftModel {
            c.dflash2 = true
            c.dflash2Model = Self.modelsDirectory.appendingPathComponent(draft).path
        }
        c.pool = "hrx:0"
        c.dialect = "loom"
        c.kvCacheDType = "bf16"
        c.kvLength = 32768
        c.temperature = 0.6
        c.batchSize = 1024
        c.ubatchSize = 1024
        c.servedName = "qwen-q4"
        c.host = "127.0.0.1"
        c.port = 8080
        return c
    }

    var running: Bool { engine != nil }

    func start() {
        guard engine == nil, phase != .loading, let config = configuration() else { return }
        phase = .loading
        log.removeAll()
        UIApplication.shared.isIdleTimerDisabled = true
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollLoadStatus() }
        }
        let serveHTTP = self.serveHTTP
        Task {
            do {
                let opened = try await LSEEngine.open(config)
                if serveHTTP { try opened.startHTTP() }
                engine = opened
                phase = .ready
            } catch {
                phase = .failed(String(describing: error))
            }
            statusTimer?.invalidate()
            statusTimer = nil
            loadDetail = ""
        }
    }

    func stop() {
        guard let engine else { return }
        phase = .stopping
        self.engine = nil
        Task.detached {
            engine.close()
            await MainActor.run {
                self.phase = .idle
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private func pollLoadStatus() {
        let status = LSEEngine.loadStatus()
        let phase = status["phase"] as? String ?? ""
        let detail = status["detail"] as? String ?? ""
        if let progress = status["progress"] as? Double {
            loadDetail = "\(phase) \(Int(progress * 100))% \(detail)"
        } else {
            loadDetail = "\(phase) \(detail)"
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    // MARK: Test completion

    struct Completion {
        var text = ""
        var promptTokens = 0
        var completionTokens = 0
        var promptPerSecond = 0.0
        var decodePerSecond = 0.0
        var acceptance: Double?
        var seconds = 0.0
    }

    /// One chat completion through lse_request (no socket).
    func testCompletion() async -> Result<Completion, Error> {
        guard let engine else { return .failure(LSEEngine.OpenError(invalidConfiguration: false, message: "not running")) }
        testing = true
        defer { testing = false }
        let request: [String: Any] = [
            "model": "qwen-q4",
            "messages": [["role": "user", "content": "Write a short paragraph about lemon trees."]],
            "max_tokens": 256,
            "temperature": 0.6,
        ]
        let started = Date()
        do {
            let data = try await engine.send(path: "/v1/chat/completions", json: request)
            var c = Completion()
            c.seconds = Date().timeIntervalSince(started)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let choice = (object["choices"] as? [[String: Any]])?.first,
               let message = choice["message"] as? [String: Any] {
                c.text = message["content"] as? String ?? ""
            }
            if let usage = object["usage"] as? [String: Any] {
                c.promptTokens = usage["prompt_tokens"] as? Int ?? 0
                c.completionTokens = usage["completion_tokens"] as? Int ?? 0
            }
            if let timings = object["timings"] as? [String: Any] {
                c.promptPerSecond = timings["prompt_per_second"] as? Double ?? 0
                c.decodePerSecond = timings["decode_per_second"] as? Double ?? 0
                c.acceptance = timings["acceptance_rate"] as? Double
            }
            lastResult = Self.summary(c)
            return .success(c)
        } catch {
            lastResult = "failed: \(error)"
            return .failure(error)
        }
    }

    static func summary(_ c: Completion) -> String {
        var s = String(format: "prompt %d tok @ %.1f tok/s, decode %d tok @ %.1f tok/s",
                       c.promptTokens, c.promptPerSecond, c.completionTokens, c.decodePerSecond)
        if let a = c.acceptance { s += String(format: ", DFlash2 acceptance %.1f%%", a * 100) }
        s += String(format: ", %.1f s", c.seconds)
        return s
    }

    // MARK: --auto-lse

    /// Starts the engine with the Q4 + DFlash2 settings, runs one completion
    /// and appends the outcome to Documents/probe-report.txt.
    private func runAutomatically() async {
        var report = ["== LSE \(ISO8601DateFormatter().string(from: Date())) (engine \(LSEEngine.version), ABI \(LSEEngine.abiVersion))"]
        report.append("models: target=\(targetModel ?? "none") draft=\(draftModel ?? "none") in \(Self.modelsDirectory.path)")
        guard configuration() != nil else {
            report.append("FAIL no model directory under Documents/Models")
            Self.appendReport(report)
            return
        }
        let loadStart = Date()
        start()
        while phase == .loading { try? await Task.sleep(for: .milliseconds(250)) }
        report.append(String(format: "load: %.1f s, footprint %@ (peak %@)",
                             Date().timeIntervalSince(loadStart),
                             Self.bytes(Self.footprint().current), Self.bytes(Self.footprint().peak)))
        if case .failed(let message) = phase {
            report.append("FAIL open: \(message)")
            report.append(contentsOf: log.suffix(40).map { "  log: \($0)" })
            Self.appendReport(report)
            return
        }
        switch await testCompletion() {
        case .success(let c):
            report.append("OK   completion: " + Self.summary(c))
            report.append("     text: " + c.text.prefix(200).replacingOccurrences(of: "\n", with: " "))
        case .failure(let error):
            report.append("FAIL completion: \(error)")
            report.append(contentsOf: log.suffix(40).map { "  log: \($0)" })
        }
        let f = Self.footprint()
        report.append("memory: footprint \(Self.bytes(f.current)), peak \(Self.bytes(f.peak)), available \(Self.bytes(UInt64(os_proc_available_memory())))")
        if let engine {
            if let data = try? JSONSerialization.data(withJSONObject: engine.status()),
               let text = String(data: data, encoding: .utf8) {
                report.append("status: \(text)")
            }
        }
        Self.appendReport(report)
    }

    static func appendReport(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        print(text, terminator: "")
        lseLog.log("\(text, privacy: .public)")
        let url = documents.appendingPathComponent("probe-report.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, info.ledger_phys_footprint_peak > 0 ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint)
    }

    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }
}
