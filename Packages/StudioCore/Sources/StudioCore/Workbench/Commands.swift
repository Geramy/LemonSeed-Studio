import Foundation
import Observation

/// A keyboard shortcut, independent of UIKit and SwiftUI so packages can
/// declare shortcuts for their commands. The app turns it into a
/// `KeyboardShortcut` for the menu bar.
public struct KeyShortcut: Hashable, Sendable, Codable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// A single character ("p", "\\", "`", "1"), or a named key:
    /// "return", "escape", "tab", "delete", "up", "down", "left", "right",
    /// "f1"..."f12".
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "⌃⌥⇧⌘P", in Apple's modifier order.
    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.glyph(for: key)
    }

    static func glyph(for key: String) -> String {
        switch key {
        case "return": "↩"
        case "escape": "⎋"
        case "tab": "⇥"
        case "delete": "⌫"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case " ": "Space"
        default: key.count == 1 ? key.uppercased() : key.uppercased()
        }
    }
}

/// A command in the palette, menus and keymap. Packages register their own
/// (e.g. "Git: Commit", "Agent: Explain Selection").
public struct StudioCommand: Identifiable, Sendable {
    /// Namespaced identifier, e.g. "view.toggleSidebar", "git.commit".
    public let id: String
    public var title: String
    /// Palette prefix and menu grouping: "File", "View", "Go", "Git", ...
    public var category: String
    public var symbol: String?
    public var shortcut: KeyShortcut?
    /// Whether the command can run in this context.
    public var isEnabled: @MainActor @Sendable (any WorkspaceContext) -> Bool
    public var run: @MainActor @Sendable (any WorkspaceContext) -> Void

    public init(id: String, title: String, category: String, symbol: String? = nil, shortcut: KeyShortcut? = nil,
                isEnabled: @escaping @MainActor @Sendable (any WorkspaceContext) -> Bool = { _ in true },
                run: @escaping @MainActor @Sendable (any WorkspaceContext) -> Void) {
        self.id = id
        self.title = title
        self.category = category
        self.symbol = symbol
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.run = run
    }

    /// "View: Toggle Sidebar".
    public var paletteTitle: String { "\(category): \(title)" }
}

/// Every command the Studio knows. The palette searches it; the keymap
/// screen lists it.
@MainActor
@Observable
public final class CommandRegistry {
    public private(set) var commands: [StudioCommand] = []
    /// Most recently run first.
    public private(set) var recentIDs: [String] = []
    public var maximumRecents = 12

    public init() {}

    /// Adds commands, replacing any with the same id.
    public func register(_ newCommands: [StudioCommand]) {
        for command in newCommands {
            if let index = commands.firstIndex(where: { $0.id == command.id }) {
                commands[index] = command
            } else {
                commands.append(command)
            }
        }
    }

    public func register(_ command: StudioCommand) {
        register([command])
    }

    public func unregister(id: String) {
        commands.removeAll { $0.id == id }
    }

    public func command(id: String) -> StudioCommand? {
        commands.first { $0.id == id }
    }

    /// The command bound to `shortcut`, if any.
    public func command(for shortcut: KeyShortcut) -> StudioCommand? {
        commands.first { $0.shortcut == shortcut }
    }

    /// Commands that share a shortcut (a keymap conflict).
    public var conflicts: [KeyShortcut: [String]] {
        var byShortcut: [KeyShortcut: [String]] = [:]
        for command in commands { if let shortcut = command.shortcut { byShortcut[shortcut, default: []].append(command.id) } }
        return byShortcut.filter { $0.value.count > 1 }
    }

    /// Runs a command if it is enabled; records it as recent.
    @discardableResult
    public func run(id: String, in context: any WorkspaceContext) -> Bool {
        guard let command = command(id: id), command.isEnabled(context) else { return false }
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > maximumRecents { recentIDs.removeLast(recentIDs.count - maximumRecents) }
        command.run(context)
        return true
    }

    /// Palette search: recent commands first for an empty query, else fuzzy
    /// ranked on "Category: Title" with a boost for recent ones.
    public func search(_ query: String, limit: Int = 60) -> [(command: StudioCommand, match: FuzzyMatch)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let recent = recentIDs.compactMap(command(id:))
            let rest = commands.filter { !recentIDs.contains($0.id) }
                .sorted { $0.paletteTitle.localizedStandardCompare($1.paletteTitle) == .orderedAscending }
            return (recent + rest).prefix(limit).map { ($0, FuzzyMatch(score: 0, positions: [])) }
        }
        let matcher = FuzzyMatcher(trimmed)
        var scored: [(command: StudioCommand, match: FuzzyMatch)] = []
        for command in commands {
            guard var match = matcher.match(command.paletteTitle) else { continue }
            if let rank = recentIDs.firstIndex(of: command.id) {
                match.score += max(0, 24 - rank * 2)
            }
            scored.append((command, match))
        }
        scored.sort { lhs, rhs in
            if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
            return lhs.command.paletteTitle.count < rhs.command.paletteTitle.count
        }
        return Array(scored.prefix(limit))
    }
}
