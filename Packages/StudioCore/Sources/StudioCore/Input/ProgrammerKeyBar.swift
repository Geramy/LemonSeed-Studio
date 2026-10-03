import SwiftUI
import StudioDesign
#if canImport(UIKit)
import UIKit
#endif

/// A key on the programmer key bar shown above the on-screen keyboard.
public enum ProgrammerKey: Hashable, Sendable {
    case escape, tab
    case up, down, left, right
    case text(String)
    case undo, redo
    case dismiss

    /// The symbols row: brackets and the punctuation code needs most.
    public static let symbols: [String] = ["{", "}", "[", "]", "(", ")", "<", ">", ";", ":", "\"", "'", "/", "\\", "|"]
}

/// Sticky modifiers: tap Ctrl or Cmd, then a key.
public struct ProgrammerKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ProgrammerKeyModifiers(rawValue: 1 << 0)
    public static let command = ProgrammerKeyModifiers(rawValue: 1 << 1)
}

#if canImport(UIKit)
/// Adopted by a text view (LemonText's, for example) that wants to handle
/// key-bar keys itself: multi-caret moves, soft tabs, its own undo. Return
/// false to fall back to the default UITextInput handling.
@MainActor
public protocol ProgrammerKeyHandling: AnyObject {
    func handleProgrammerKey(_ key: ProgrammerKey, modifiers: ProgrammerKeyModifiers) -> Bool
}

/// Applies a key to a responder: through `ProgrammerKeyHandling` when the
/// responder adopts it, otherwise through UITextInput (insert, move the
/// caret, undo), which covers UITextView, UITextField and SwiftUI's text
/// views.
@MainActor
public enum ProgrammerKeyPerformer {
    /// What Tab inserts in generic text views (editors set it from their
    /// indentation settings).
    public static var tabText = "\t"

    public static func perform(_ key: ProgrammerKey, modifiers: ProgrammerKeyModifiers = [], on responder: UIResponder?) {
        guard let responder else { return }
        if let handler = responder as? ProgrammerKeyHandling, handler.handleProgrammerKey(key, modifiers: modifiers) { return }
        let input = responder as? (UIResponder & UITextInput)
        switch key {
        case .dismiss, .escape:
            responder.resignFirstResponder()
        case .undo:
            responder.undoManager?.undo()
        case .redo:
            responder.undoManager?.redo()
        case .tab:
            input?.insertText(tabText)
        case .text(let text):
            if modifiers.contains(.command), let input {
                performCommand(text.lowercased(), on: input)
            } else if modifiers.contains(.control), let scalar = text.lowercased().unicodeScalars.first,
                      scalar.value >= 0x61, scalar.value <= 0x7A {
                // Control characters (^A ... ^Z) for views that accept them.
                (responder as? UIKeyInput)?.insertText(String(UnicodeScalar(scalar.value - 0x60)!))
            } else {
                (responder as? UIKeyInput)?.insertText(text)
            }
        case .left, .right, .up, .down:
            guard let input, let range = input.selectedTextRange else { return }
            let direction: UITextLayoutDirection = switch key {
            case .left: .left
            case .right: .right
            case .up: .up
            default: .down
            }
            let backward = key == .left || key == .up
            let target: UITextPosition
            if !range.isEmpty, key == .left || key == .right {
                // A selection collapses to its start or end, as on a Mac.
                target = backward ? range.start : range.end
            } else {
                let from = backward ? range.start : range.end
                target = input.position(from: from, in: direction, offset: 1) ?? from
            }
            input.selectedTextRange = input.textRange(from: target, to: target)
        }
    }

    private static func performCommand(_ letter: String, on input: UIResponder & UITextInput) {
        switch letter {
        case "a": input.selectAll(nil)
        case "c": input.copy(nil)
        case "x": input.cut(nil)
        case "v": input.paste(nil)
        case "z": input.undoManager?.undo()
        default: break
        }
    }
}
#endif

/// The programmer key bar: Esc, Tab, Ctrl and Cmd (sticky), arrows, the
/// symbols row, undo, redo and dismiss. Keys act on the current first
/// responder, so one bar serves every text view.
public struct ProgrammerKeyBar: View {
    @Environment(\.theme) private var theme
    @State private var modifiers: ProgrammerKeyModifiers = []

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc", .escape, id: "escape")
                    key("tab", .tab, id: "tab")
                    modifier("ctrl", .control)
                    modifier("⌘", .command)
                    separator
                    symbol("arrow.left", .left, id: "left")
                    symbol("arrow.up", .up, id: "up")
                    symbol("arrow.down", .down, id: "down")
                    symbol("arrow.right", .right, id: "right")
                    separator
                    ForEach(ProgrammerKey.symbols, id: \.self) { character in
                        key(character, .text(character), id: "sym.\(character)", monospaced: true)
                    }
                    separator
                    symbol("arrow.uturn.backward", .undo, id: "undo")
                    symbol("arrow.uturn.forward", .redo, id: "redo")
                }
                .padding(.horizontal, 8)
            }
            Divider().frame(height: 26)
            symbol("keyboard.chevron.compact.down", .dismiss, id: "dismiss")
                .padding(.horizontal, 8)
        }
        .frame(height: 48)
        .background(theme.palette.elevated.color)
        .overlay(alignment: .top) { Hairline() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keybar")
    }

    private var separator: some View {
        Rectangle().fill(theme.palette.separator.color).frame(width: 1, height: 22).padding(.horizontal, 2)
    }

    private func key(_ label: String, _ key: ProgrammerKey, id: String, monospaced: Bool = false) -> some View {
        Button {
            send(key)
        } label: {
            Text(label)
                .font(monospaced ? .system(size: 17, weight: .medium, design: .monospaced) : .system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary.color)
                .frame(minWidth: 40, minHeight: 36)
                .padding(.horizontal, 4)
                .background(theme.palette.hover.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label == "esc" ? "Escape" : label == "tab" ? "Tab" : label)
        .accessibilityIdentifier("keybar.\(id)")
    }

    private func symbol(_ name: String, _ key: ProgrammerKey, id: String) -> some View {
        Button {
            send(key)
        } label: {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary.color)
                .frame(width: 44, height: 36)
                .background(theme.palette.hover.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(id.capitalized)
        .accessibilityIdentifier("keybar.\(id)")
    }

    private func modifier(_ label: String, _ flag: ProgrammerKeyModifiers) -> some View {
        let on = modifiers.contains(flag)
        return Button {
            if on { modifiers.remove(flag) } else { modifiers.insert(flag) }
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? theme.palette.textOnAccent.color : theme.palette.textPrimary.color)
                .frame(minWidth: 44, minHeight: 36)
                .background(on ? theme.palette.accentFill.color : theme.palette.hover.color,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(flag == .control ? "Control" : "Command")
        .accessibilityIdentifier(flag == .control ? "keybar.control" : "keybar.command")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func send(_ key: ProgrammerKey) {
        #if canImport(UIKit)
        ProgrammerKeyPerformer.perform(key, modifiers: modifiers, on: UIResponder.currentFirstResponder)
        #endif
        modifiers = []
    }
}

#if canImport(UIKit)
public extension ProgrammerKeyBar {
    /// An `inputAccessoryView` for UIKit text views (LemonText's editor can
    /// set `inputAccessoryView = ProgrammerKeyBar.makeInputAccessoryView(theme:)`).
    /// When a first responder supplies its own accessory, the shell's
    /// floating key bar stays hidden so there is only ever one.
    @MainActor
    static func makeInputAccessoryView(theme: Theme) -> UIView {
        let host = UIHostingController(rootView: ProgrammerKeyBar().environment(\.theme, theme))
        host.view.backgroundColor = .clear
        let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        container.allowsSelfSizing = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 48),
        ])
        // Keep the hosting controller alive with its view.
        objc_setAssociatedObject(container, &hostKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return container
    }
}

nonisolated(unsafe) private var hostKey: UInt8 = 0
#endif
