public import Foundation
public import GitKit

/// Builds a small repository with history, branches, a merge, tags and
/// uncommitted work, for the demo app, previews and tests.
public enum SampleRepository {
    static let author = Signature(name: "Alice Moreau", email: "alice@example.com",
                                  date: Date(timeIntervalSince1970: 1_789_000_000), timeZoneOffsetMinutes: 0)
    static let bob = Signature(name: "Bob Tanaka", email: "bob@example.com",
                               date: Date(timeIntervalSince1970: 1_789_000_000), timeZoneOffsetMinutes: 0)

    /// Creates (or replaces) the sample at `url`.
    @discardableResult
    public static func make(at url: URL, withConflict: Bool = false) async throws -> GitRepository {
        try? FileManager.default.removeItem(at: url)
        let repo = try GitRepository.create(at: url, initialBranch: "main")
        try await repo.setConfigValue("user.name", author.name)
        try await repo.setConfigValue("user.email", author.email)
        var clock = author.date

        func write(_ path: String, _ text: String) throws {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func commit(_ message: String, by who: Signature = author) async throws {
            clock.addTimeInterval(3_600)
            var sig = who
            sig.date = clock
            try await repo.stageAll()
            try await repo.commit(message: message, options: CommitOptions(author: sig, allowEmpty: true))
        }

        try write("README.md", "# GPU Monitor\n\nLive telemetry for AMD GPUs on iPad.\n")
        try write("Sources/Monitor/QueueRow.swift", queueRow)
        try write("Sources/Monitor/Sampler.swift", sampler)
        try await commit("Initial commit")
        try await repo.createTag("v0.1.0", message: "First preview\n", tagger: author)

        try await repo.createBranch("feature/sparkline", checkout: true)
        try write("Sources/Monitor/Sparkline.swift", "import SwiftUI\n\n/// A tiny line chart.\nstruct Sparkline: View {\n    var samples: [Double]\n    var body: some View { Canvas { _, _ in } }\n}\n")
        try await commit("Add Sparkline view", by: bob)
        try write("Sources/Monitor/Sparkline.swift", "import SwiftUI\n\n/// A tiny line chart of recent samples.\nstruct Sparkline: View {\n    var samples: [Double]\n    var body: some View { Canvas { context, size in } }\n}\n")
        try await commit("Sparkline: document the view", by: bob)

        try await repo.checkout(branch: "main")
        try write("Sources/Monitor/Sampler.swift", sampler.replacingOccurrences(of: "interval: Duration = .seconds(1)", with: "interval: Duration = .milliseconds(100)"))
        try await commit("Sampler: 10 Hz while visible")
        try await repo.createBranch("fix/fan-curve")
        _ = try await repo.merge("feature/sparkline", options: MergeOptions(fastForward: .never, author: author))
        try write("CHANGELOG.md", "## 0.2.0\n\n- Sparkline per queue\n- 10 Hz sampling\n")
        try await commit("Changelog for 0.2.0")
        try await repo.createTag("v0.2.0")

        try await repo.checkout(branch: "fix/fan-curve")
        try write("Sources/Monitor/Fan.swift", "struct FanCurve {\n    var points: [(temperature: Int, percent: Int)]\n}\n")
        try await commit("Parse RDNA4 fan curve", by: bob)
        try await repo.checkout(branch: "main")

        if withConflict {
            try await repo.createBranch("conflict", checkout: true)
            try write("README.md", "# GPU Monitor\n\nTelemetry for Radeon GPUs over Thunderbolt.\n")
            try await commit("README: Thunderbolt wording", by: bob)
            try await repo.checkout(branch: "main")
            try write("README.md", "# GPU Monitor\n\nLive telemetry and charts for AMD GPUs on iPad.\n")
            try await commit("README: mention charts")
            _ = try await repo.merge("conflict")
            return repo
        }

        // Uncommitted work: one staged file, a file with two hunks, an
        // untracked file.
        try write("CHANGELOG.md", "## 0.2.0\n\n- Sparkline per queue\n- 10 Hz sampling\n- Fan curve fixes\n")
        try await repo.stage(["CHANGELOG.md"])
        var lines = queueRow.components(separatedBy: "\n")
        lines[5] = "            Text(queue.name).font(.headline)"
        lines[8] = "            Text(queue.occupancy, format: .percent).monospacedDigit()"
        lines.insert("        .accessibilityElement(children: .combine)", at: 22)
        try write("Sources/Monitor/QueueRow.swift", lines.joined(separator: "\n"))
        try write("Sources/Monitor/Theme.swift", "import SwiftUI\n\nenum MonitorTheme {\n    static let accent = Color.orange\n}\n")
        return repo
    }

    static let queueRow = """
    import SwiftUI

    struct QueueRow: View {
        let queue: QueueStats
        var body: some View {
            Text(queue.name)
            HStack {
                Spacer()
                Text("\\(queue.occupancy)%")
            }
            .padding(.vertical, 4)
        }
    }

    struct QueueStats: Identifiable {
        var id: Int
        var name: String
        var occupancy: Double
        var history: [Double]
    }

    extension QueueRow {
        static let placeholder = QueueRow(queue: QueueStats(id: 0, name: "gfx", occupancy: 0, history: []))
    }

    """

    static let sampler = """
    import Foundation

    /// Polls GPU counters while the screen is visible.
    actor Sampler {
        var interval: Duration = .seconds(1)
        private var running = false

        func start(_ body: @Sendable () async -> Void) async {
            running = true
            while running {
                await body()
                try? await Task.sleep(for: interval)
            }
        }

        func stop() { running = false }
    }

    """
}
