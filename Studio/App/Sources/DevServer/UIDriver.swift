#if DEBUG
import SwiftUI
import UIKit
import StudioCore

/// Drives the app's UI from inside, for the development remote control:
/// the accessibility hierarchy of the key window, activation of elements
/// (what VoiceOver does on a double tap), text and key input into the
/// first responder (the way the keyboard stress replay does), scrolling,
/// adjustable elements, and navigation to the main screens.
@MainActor
enum UIDriver {
    struct Found {
        var object: NSObject
        var frame: CGRect
    }

    // MARK: Accessibility

    /// SwiftUI builds its accessibility elements only while an assistive
    /// client (VoiceOver, XCTest) is attached. Debug builds turn on the
    /// accessibility automation flag XCTest uses, so the tree is there for
    /// the remote control. Private (libAccessibility), debug builds only.
    static func enableAccessibilityTree() {
        guard !accessibilityEnabled else { return }
        accessibilityEnabled = true
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return }
        typealias SetEnabled = @convention(c) (Bool) -> Void
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let symbol = dlsym(handle, name) {
                unsafeBitCast(symbol, to: SetEnabled.self)(true)
            }
        }
    }

    private static var accessibilityEnabled = false

    // MARK: Tree

    /// Every accessibility element and identified container in the key
    /// window, flattened in reading order with its depth.
    static func tree(includeAll: Bool = false) -> [[String: Any]] {
        enableAccessibilityTree()
        guard let window = DevSupport.keyWindow else { return [] }
        var out: [[String: Any]] = []
        visit(window, depth: 0, includeAll: includeAll) { node, depth, object in
            var n = node
            n["depth"] = depth
            out.append(n)
            _ = object
        }
        return out
    }

    private static func describe(_ object: NSObject) -> [String: Any]? {
        let identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
        let isElement = object.isAccessibilityElement
        guard isElement || !identifier.isEmpty else { return nil }
        let f = object.accessibilityFrame
        var node: [String: Any] = [
            "frame": [Double(f.origin.x), Double(f.origin.y), Double(f.size.width), Double(f.size.height)],
            "element": isElement,
        ]
        if !identifier.isEmpty { node["id"] = identifier }
        if let label = object.accessibilityLabel, !label.isEmpty { node["label"] = label }
        if let value = object.accessibilityValue, !value.isEmpty { node["value"] = value }
        let traits = traitNames(object.accessibilityTraits)
        if !traits.isEmpty { node["traits"] = traits }
        return node
    }

    private static func traitNames(_ t: UIAccessibilityTraits) -> [String] {
        var names: [String] = []
        let all: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"), (.searchField, "searchField"),
            (.image, "image"), (.selected, "selected"), (.staticText, "text"), (.adjustable, "adjustable"),
            (.notEnabled, "disabled"), (.tabBar, "tabBar"), (.keyboardKey, "key"),
        ]
        for (trait, name) in all where t.contains(trait) { names.append(name) }
        return names
    }

    private static func children(of object: NSObject) -> [NSObject] {
        if let elements = object.accessibilityElements as? [NSObject], !elements.isEmpty { return elements }
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            return (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = object as? UIView {
            return view.subviews.filter { !$0.isHidden && $0.alpha > 0.01 }
        }
        return []
    }

    private static func visit(_ object: NSObject, depth: Int, includeAll: Bool,
                              _ body: ([String: Any], Int, NSObject) -> Void) {
        guard depth < 80 else { return }
        var childDepth = depth
        if let node = describe(object) {
            body(node, depth, object)
            childDepth = depth + 1
            // An element's children are its own (SwiftUI combines them).
            if object.isAccessibilityElement && !includeAll { return }
        }
        for child in children(of: object) { visit(child, depth: childDepth, includeAll: includeAll, body) }
    }

    /// The first element with this identifier (or, failing that, label).
    static func find(id: String? = nil, label: String? = nil) -> Found? {
        enableAccessibilityTree()
        guard let window = DevSupport.keyWindow else { return nil }
        var match: Found?
        func search(_ object: NSObject, depth: Int) {
            guard match == nil, depth < 80 else { return }
            let identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
            if let id, identifier == id { match = Found(object: object, frame: object.accessibilityFrame); return }
            if id == nil, let label, object.accessibilityLabel == label {
                match = Found(object: object, frame: object.accessibilityFrame); return
            }
            for child in children(of: object) { search(child, depth: depth + 1) }
        }
        search(window, depth: 0)
        if match == nil, let label, id != nil { return find(id: nil, label: label) }
        return match
    }

    // MARK: Actions

    /// Activates an element (its primary action, as VoiceOver's double
    /// tap), or the control at a point.
    static func tap(id: String?, label: String?, point: CGPoint?) -> (Bool, String) {
        if let point {
            guard let window = DevSupport.keyWindow, let hit = window.hitTest(window.convert(point, from: nil), with: nil) else {
                return (false, "nothing at \(point)")
            }
            var view: UIView? = hit
            while let v = view {
                if let control = v as? UIControl {
                    control.sendActions(for: .touchUpInside)
                    return (true, "sent touchUpInside to \(Swift.type(of: control))")
                }
                if v.accessibilityActivate() { return (true, "activated \(Swift.type(of: v))") }
                view = v.superview
            }
            return (false, "no control at \(point)")
        }
        guard let found = find(id: id, label: label) else { return (false, "no element \(id ?? label ?? "")") }
        if found.object.accessibilityActivate() { return (true, "activated") }
        // Containers: activate the first activatable element inside.
        for child in children(of: found.object) where child.accessibilityActivate() { return (true, "activated a child") }
        // Last resort: the control under its center.
        let center = CGPoint(x: found.frame.midX, y: found.frame.midY)
        return tap(id: nil, label: nil, point: center)
    }

    /// Types into the first responder, focusing an element first if given.
    static func type(_ text: String, into id: String?) async -> (Bool, String) {
        if let id {
            _ = tap(id: id, label: nil, point: nil)
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard let input = UIResponder.currentFirstResponder as? (UIResponder & UIKeyInput) else {
            return (false, "no text input has focus")
        }
        for chunk in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if chunk.offset > 0 { input.insertText("\n") }
            if !chunk.element.isEmpty { input.insertText(String(chunk.element)) }
        }
        return (true, "typed \(text.count) characters into \(Swift.type(of: input))")
    }

    /// A key: a Studio command when its shortcut matches (⌘P, ⌘B…), else
    /// the key into the focused text input.
    static func key(_ name: String, modifiers: [String], app: AppModel) -> (Bool, String) {
        var mods = KeyShortcut.Modifiers()
        for m in modifiers {
            switch m.lowercased() {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: break
            }
        }
        if !mods.isEmpty, let controller = app.activeRouter?.controller,
           let command = app.commands.commands.first(where: { $0.shortcut == KeyShortcut(name.lowercased(), mods) }) {
            command.run(controller)
            return (true, "ran \(command.id)")
        }
        let responder = UIResponder.currentFirstResponder
        guard responder != nil else { return (false, "no focused input for \(name)") }
        var keyMods = ProgrammerKeyModifiers()
        if mods.contains(.command) { keyMods.insert(.command) }
        if mods.contains(.control) { keyMods.insert(.control) }
        let key: ProgrammerKey
        switch name.lowercased() {
        case "escape", "esc": key = .escape
        case "tab": key = .tab
        case "up": key = .up
        case "down": key = .down
        case "left": key = .left
        case "right": key = .right
        case "return", "enter":
            (responder as? UIKeyInput)?.insertText("\n")
            return (true, "return")
        case "delete", "backspace":
            (responder as? UIKeyInput)?.deleteBackward()
            return (true, "delete")
        default: key = .text(name)
        }
        ProgrammerKeyPerformer.perform(key, modifiers: keyMods, on: responder)
        return (true, "key \(name)")
    }

    /// Scrolls the scroll view under an element (or the point) by dy/dx.
    static func scroll(id: String?, point: CGPoint?, dx: CGFloat, dy: CGFloat) -> (Bool, String) {
        guard let window = DevSupport.keyWindow else { return (false, "no window") }
        var p = point
        if p == nil, let id, let found = find(id: id) { p = CGPoint(x: found.frame.midX, y: found.frame.midY) }
        let target = p ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        var view = window.hitTest(window.convert(target, from: nil), with: nil)
        while let v = view, !(v is UIScrollView) { view = v.superview }
        guard let scroll = view as? UIScrollView else { return (false, "no scroll view there") }
        let maxX = max(0, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let next = CGPoint(x: min(max(scroll.contentOffset.x + dx, -scroll.adjustedContentInset.left), maxX),
                           y: min(max(scroll.contentOffset.y + dy, -scroll.adjustedContentInset.top), maxY))
        scroll.setContentOffset(next, animated: true)
        return (true, "scrolled \(Swift.type(of: scroll)) to \(Int(next.x)),\(Int(next.y))")
    }

    /// A drag on an adjustable element (the sidebar and panel handles): the
    /// distance becomes increments of its accessibility step (20 points).
    static func drag(id: String, dx: CGFloat, dy: CGFloat, app: AppModel) -> (Bool, String) {
        if let controller = app.activeRouter?.controller {
            switch id {
            case "sidebar.resize":
                controller.sidebarWidth = clamp(controller.sidebarWidth + dx, WorkspaceController.minSidebarWidth,
                                                windowWidth * 0.5)
                return (true, "sidebar width \(Int(controller.sidebarWidth))")
            case "panel.resize":
                controller.panelHeight = clamp(controller.panelHeight - dy, WorkspaceController.minPanelHeight,
                                               windowHeight * 0.8)
                return (true, "panel height \(Int(controller.panelHeight))")
            default: break
            }
        }
        guard let found = find(id: id) else { return (false, "no element \(id)") }
        let steps = Int((abs(dx) > abs(dy) ? dx : -dy) / 20)
        for _ in 0..<abs(steps) {
            if steps > 0 { found.object.accessibilityIncrement() } else { found.object.accessibilityDecrement() }
        }
        return (true, "\(steps) step(s)")
    }

    private static var windowWidth: CGFloat { DevSupport.keyWindow?.bounds.width ?? 1366 }
    private static var windowHeight: CGFloat { DevSupport.keyWindow?.bounds.height ?? 1024 }
    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }

    // MARK: Navigation

    static let screens = ["explorer", "editor", "search", "source-control", "ai", "models", "models-manager",
                          "gpu", "gpu-monitor", "engine", "diagnostics", "load-settings", "settings", "terminal",
                          "extensions", "close-sheets"]

    /// Shows one of the main screens in the active window.
    static func navigate(_ screen: String, app: AppModel) async -> (Bool, String) {
        guard let router = app.activeRouter else { return (false, "no window") }
        if router.controller == nil {
            router.openProject(named: DevSupport.sampleWorkspaceName)
            _ = DevSupport.prepareSampleWorkspace(app: app)
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let controller = router.controller else { return (false, "no workspace open") }
        closeSheets(app: app, router: router)
        if !controller.isSidebarVisible, !["editor", "terminal", "settings", "close-sheets"].contains(screen) {
            controller.toggleSidebar()
        }
        switch screen {
        case "explorer": controller.show(SidebarItem.explorer)
        case "editor": if controller.isSidebarVisible { controller.toggleSidebar() }
        case "search": controller.show(SidebarItem.search)
        case "source-control": controller.show(SidebarItem.sourceControl)
        case "ai": controller.show(SidebarItem.agent)
        case "models": controller.show(SidebarItem.models)
        case "models-manager": controller.show(SidebarItem.models); app.isModelsManagerPresented = true
        case "gpu": controller.show(SidebarItem.gpu); app.gpuPage = "Monitor"
        case "gpu-monitor": controller.show(SidebarItem.gpu); app.isGPUMonitorPresented = true
        case "engine": controller.show(SidebarItem.gpu); app.gpuPage = "Engine"
        case "diagnostics": controller.show(SidebarItem.gpu); app.gpuPage = "Diagnostics"
        case "load-settings":
            controller.show(SidebarItem.gpu); app.gpuPage = "Engine"
            app.loadSettingsModelID = app.gpu.selectedModel?.id
        case "settings": router.showSettings()
        case "terminal": controller.show(PanelTab.terminal)
        case "extensions": controller.show(SidebarItem.extensions)
        case "close-sheets": break
        default: return (false, "unknown screen \(screen); one of \(screens.joined(separator: ", "))")
        }
        return (true, screen)
    }

    static func closeSheets(app: AppModel, router: SceneRouter) {
        app.isModelsManagerPresented = false
        app.isGPUMonitorPresented = false
        app.loadSettingsModelID = nil
        router.isSettingsPresented = false
    }
}
#endif
