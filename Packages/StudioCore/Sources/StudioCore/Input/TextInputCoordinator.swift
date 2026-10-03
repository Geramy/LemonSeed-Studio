import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Something the user types into: an editor, the terminal, the search
/// field, the agent prompt. Targets register with the coordinator so the
/// on-screen keyboard button can focus "where the user was typing".
public struct TextInputTarget: Sendable {
    public enum Kind: String, Sendable {
        case editor, terminal, search, prompt, other
    }

    /// Stable identity, e.g. "editor:<document id>" (see `editorID(for:)`).
    public let id: String
    public let kind: Kind
    /// Makes the target first responder, raising the on-screen keyboard.
    /// Returns false if it cannot take focus right now.
    public let focus: @MainActor @Sendable () -> Bool

    public init(id: String, kind: Kind, focus: @escaping @MainActor @Sendable () -> Bool) {
        self.id = id
        self.kind = kind
        self.focus = focus
    }
}

/// Tracks text targets and which one the user used last, and shows or
/// hides the on-screen keyboard on request.
///
/// Editors (the built-in one, LemonText), the terminal, search and the agent
/// prompt call `register(_:)` when they appear, `didFocus(id:)` when they
/// become first responder, and `unregister(id:)` when they go away.
@MainActor
@Observable
public final class TextInputCoordinator {
    public static let shared = TextInputCoordinator()

    public private(set) var targets: [String: TextInputTarget] = [:]
    /// Most recently focused first.
    public private(set) var recent: [String] = []

    public init() {}

    public func register(_ target: TextInputTarget) {
        targets[target.id] = target
    }

    public func unregister(id: String) {
        targets[id] = nil
        recent.removeAll { $0 == id }
    }

    /// The conventional id of an editor target for a document.
    public static func editorID(for document: EditorDocument) -> String {
        "editor:" + document.id.uuidString
    }

    /// Records that a target took focus (it becomes the default target).
    public func didFocus(id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
    }

    /// The target the keyboard button focuses: the last one used, else an
    /// editor, else anything registered.
    public var preferredTarget: TextInputTarget? {
        if let key = recent.first(where: { targets[$0] != nil }) { return targets[key] }
        return targets.values.first { $0.kind == .editor } ?? targets.values.first
    }

    /// Focuses a specific target, or the preferred one.
    @discardableResult
    public func focus(id: String? = nil) -> Bool {
        if let id, let target = targets[id], target.focus() {
            didFocus(id: id)
            return true
        }
        guard let target = preferredTarget else { return false }
        let focused = target.focus()
        if focused { didFocus(id: target.id) }
        return focused
    }

    /// Ends editing everywhere, which lowers the on-screen keyboard.
    public func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    /// The keyboard button: hide the keyboard if it is up, else focus the
    /// preferred target.
    public func toggleKeyboard(visible: Bool) {
        if visible { dismissKeyboard() } else { focus() }
    }
}

#if canImport(UIKit)
public extension UIResponder {
    /// The current first responder, found by sending an action down the chain.
    @MainActor
    static var currentFirstResponder: UIResponder? {
        FirstResponderProbe.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.studioReportFirstResponder(_:)), to: nil, from: nil, for: nil)
        return FirstResponderProbe.found
    }

    @objc func studioReportFirstResponder(_ sender: Any?) {
        MainActor.assumeIsolated { FirstResponderProbe.found = self }
    }
}

@MainActor
private enum FirstResponderProbe {
    static weak var found: UIResponder?
}
#endif

/// A tiny observable trigger a SwiftUI view watches to move its own
/// `@FocusState` when a `TextInputTarget` asks it to take focus.
@MainActor
@Observable
public final class FocusRequest {
    public private(set) var count = 0

    public init() {}

    public func fire() { count += 1 }
}
