import Foundation
import Observation

/// Diagnostics for a workspace, from every source. Compilers, language
/// servers, linters and the agent publish here; the Problems panel, the
/// status bar and editors read from here.
@MainActor
@Observable
public final class DiagnosticsCenter {
    /// file -> source -> diagnostics
    public private(set) var store: [URL: [String: [Diagnostic]]] = [:]

    public init() {}

    /// Replaces `source`'s diagnostics for `url`.
    public func set(_ diagnostics: [Diagnostic], for url: URL, source: String) {
        let key = url.standardizedFileURL
        var bySource = store[key] ?? [:]
        bySource[source] = diagnostics.isEmpty ? nil : diagnostics
        store[key] = bySource.isEmpty ? nil : bySource
    }

    /// Removes everything `source` published (e.g. at the start of a build).
    public func clear(source: String) {
        for (url, var bySource) in store {
            bySource[source] = nil
            store[url] = bySource.isEmpty ? nil : bySource
        }
    }

    public func diagnostics(for url: URL) -> [Diagnostic] {
        (store[url.standardizedFileURL] ?? [:]).values.flatMap { $0 }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Every diagnostic, files sorted by path, then by severity and position.
    public var all: [Diagnostic] {
        store.keys.sorted { $0.path < $1.path }.flatMap { diagnostics(for: $0) }
    }

    public var errorCount: Int { count(.error) }
    public var warningCount: Int { count(.warning) }

    public func count(_ severity: Diagnostic.Severity) -> Int {
        store.values.reduce(0) { total, bySource in
            total + bySource.values.reduce(0) { $0 + $1.filter { $0.severity == severity }.count }
        }
    }

    /// Follows a rename or move.
    public func move(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        for url in store.keys where url.path == oldPath || url.path.hasPrefix(oldPath + "/") {
            let moved = URL(fileURLWithPath: new.standardizedFileURL.path + url.path.dropFirst(oldPath.count))
            store[moved] = store.removeValue(forKey: url)
        }
    }
}

/// Named output channels ("Studio", "Build", "Git", "Agent", ...), shown in
/// the Output panel.
@MainActor
@Observable
public final class OutputCenter {
    public struct Line: Identifiable, Hashable, Sendable {
        public let id: Int
        public let date: Date
        public let text: String
    }

    public private(set) var channels: [String: [Line]] = [:]
    public private(set) var channelOrder: [String] = []
    private var nextID = 0
    /// Lines kept per channel.
    public var limit = 5_000

    public init() {}

    public func append(_ text: String, channel: String) {
        if channels[channel] == nil { channelOrder.append(channel) }
        var lines = channels[channel] ?? []
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(Line(id: nextID, date: Date(), text: String(piece)))
            nextID += 1
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        channels[channel] = lines
    }

    public func clear(channel: String) {
        channels[channel] = []
    }

    public func lines(_ channel: String) -> [Line] {
        channels[channel] ?? []
    }
}
