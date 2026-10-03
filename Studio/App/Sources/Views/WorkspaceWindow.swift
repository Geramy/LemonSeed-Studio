import SwiftUI
import StudioCore
import StudioDesign

/// The workspace window: top bar, activity bar, sidebar, editor area,
/// bottom panel and status bar, with the command palette floating above.
struct WorkspaceWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Bindable var controller: WorkspaceController
    @State private var windowSize = CGSize(width: 1366, height: 1024)

    /// The sidebar: at least 200 points, at most half the window.
    private var sidebarRange: ClosedRange<CGFloat> {
        let minimum = WorkspaceController.minSidebarWidth
        return minimum...max(minimum, windowSize.width * 0.5)
    }

    /// The bottom panel: at least 120 points, at most 80% of the window.
    private var panelRange: ClosedRange<CGFloat> {
        let minimum = WorkspaceController.minPanelHeight
        return minimum...max(minimum, windowSize.height * 0.8)
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(controller: controller)
            Hairline()
            HStack(spacing: 0) {
                if app.settings.showActivityBar {
                    ActivityBar(controller: controller)
                    Hairline(.vertical)
                }
                if controller.isSidebarVisible {
                    SidebarContainer(controller: controller)
                        .frame(width: controller.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ResizeHandle(axis: .vertical, value: $controller.sidebarWidth, range: sidebarRange,
                                 defaultValue: WorkspaceController.defaultSidebarWidth,
                                 onCollapse: { withAnimation(Motion.present) { controller.isSidebarVisible = false } },
                                 identifier: "sidebar.resize")
                }
                VStack(spacing: 0) {
                    if !(controller.isPanelVisible && controller.isPanelMaximized) {
                        EditorArea(controller: controller)
                            // Simultaneous, never an overlay: taps and text
                            // input near the edge stay with the editor.
                            .simultaneousGesture(edgeSwipe)
                    }
                    if controller.isPanelVisible {
                        if !controller.isPanelMaximized {
                            ResizeHandle(axis: .horizontal, value: $controller.panelHeight, range: panelRange,
                                         defaultValue: WorkspaceController.defaultPanelHeight,
                                         onCollapse: { withAnimation(Motion.present) { controller.togglePanel() } },
                                         inverted: true, identifier: "panel.resize")
                        }
                        BottomPanel(controller: controller)
                            .frame(height: controller.isPanelMaximized ? nil : controller.panelHeight)
                            .frame(maxHeight: controller.isPanelMaximized ? .infinity : nil)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Hairline()
            StatusBar(controller: controller)
            if let stress = controller.keyboardStress {
                KeyboardStressStatus(stress: stress)
            }
            if LaunchOptions.exposeEditorText, let document = controller.activeDocument {
                EditorContentsProbe(document: document)
            }
        }
        .background(theme.palette.canvas.color)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            windowSize = size
            // Keep the sidebar within half of a window that got narrower.
            if controller.sidebarWidth > sidebarRange.upperBound { controller.sidebarWidth = sidebarRange.upperBound }
            if controller.panelHeight > panelRange.upperBound { controller.panelHeight = panelRange.upperBound }
        }
        .overlay {
            if controller.paletteMode != nil {
                ZStack(alignment: .top) {
                    Color.black.opacity(theme.appearance == .dark ? 0.28 : 0.10)
                        .ignoresSafeArea()
                        .onTapGesture { controller.dismissPalette() }
                        .accessibilityIdentifier("palette.backdrop")
                    CommandPalette(controller: controller)
                        .padding(.top, 72)
                        .transition(.studioFloat)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = controller.toast {
                Text(toast)
                    .font(.studio(13, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary.color)
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.s + 2)
                    .floatingSurface(cornerRadius: Radius.capsule)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("toast")
            }
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { controller.pendingDeletion != nil },
                                                                 set: { if !$0 { controller.pendingDeletion = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let url = controller.pendingDeletion { controller.delete(url) }
            }
            .accessibilityIdentifier("confirm.delete")
        } message: {
            Text("This cannot be undone.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            controller.importItems(urls, into: controller.rootURL)
            return true
        }
        // With the on-screen keyboard up the window resizes above it, and the
        // programmer key bar sits between the window and the keyboard
        // (unless the focused view brings its own row, like the terminal).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsKeyBar {
                ProgrammerKeyBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.present, value: showsKeyBar)
    }

    private var showsKeyBar: Bool {
        !app.keyboard.hasHardwareKeyboard && app.keyboard.isSoftwareKeyboardVisible && !app.keyboard.responderHasAccessory
    }

    private var deletionTitle: String {
        "Delete “\(controller.pendingDeletion?.lastPathComponent ?? "")”?"
    }

    /// With the sidebar hidden, a swipe in from the left edge brings it back.
    private var edgeSwipe: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            guard !controller.isSidebarVisible, value.startLocation.x < 20,
                  value.translation.width > 60, abs(value.translation.height) < 40 else { return }
            controller.toggleSidebar()
        }
    }
}

/// A draggable divider: a hairline with a wide grip (22 points, mostly over
/// the side that resizes, so taps at the editor's edge stay with the editor).
/// Works with touch, Pencil, trackpad and mouse; shows a resize pointer on
/// hover. Double-tap resets to the default; dragging well past the minimum
/// collapses the pane, as VS Code does.
struct ResizeHandle: View {
    @Environment(\.theme) private var theme
    let axis: Axis
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var defaultValue: CGFloat? = nil
    /// Dragging this far below the minimum collapses the pane.
    var collapseThreshold: CGFloat = 60
    var onCollapse: (() -> Void)? = nil
    var inverted = false
    var identifier = "resize"
    @State private var start: CGFloat?
    @State private var active = false

    static let grip: CGFloat = 22
    /// How much of the grip lies on the resized pane's side.
    static let paneShare: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(active ? theme.palette.accent.opacity(0.7).color : theme.palette.hairline.color)
            .frame(width: axis == .vertical ? (active ? 2 : 1) : nil, height: axis == .horizontal ? (active ? 2 : 1) : nil)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .overlay { grip }
            .zIndex(1)
    }

    private var grip: some View {
        // The sidebar is leading (pane side = before the line); the bottom
        // panel is below (inverted: pane side = after the line).
        let paneOffset = (Self.grip / 2 - (Self.grip - Self.paneShare)) * (inverted ? 1 : -1)
        return Color.clear
            .frame(width: axis == .vertical ? Self.grip : nil, height: axis == .horizontal ? Self.grip : nil)
            .contentShape(.rect)
            .offset(x: axis == .vertical ? paneOffset : 0, y: axis == .horizontal ? paneOffset : 0)
            .onHover { inside in withAnimation(Motion.feedback) { active = inside } }
            .modifier(ResizePointer(axis: axis))
            .gesture(drag)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard let defaultValue else { return }
                withAnimation(Motion.present) { value = min(max(defaultValue, range.lowerBound), range.upperBound) }
            })
            .accessibilityElement()
            .accessibilityLabel(axis == .vertical ? "Sidebar width" : "Panel height")
            .accessibilityValue("\(Int(value)) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 20
                let next = direction == .increment ? value + step : value - step
                value = min(max(next, range.lowerBound), range.upperBound)
            }
            .accessibilityIdentifier(identifier)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { drag in
                if start == nil { start = value }
                let delta = axis == .vertical ? drag.translation.width : drag.translation.height
                let proposed = (start ?? value) + (inverted ? -delta : delta)
                value = min(max(proposed, range.lowerBound), range.upperBound)
                active = true
            }
            .onEnded { drag in
                let delta = axis == .vertical ? drag.translation.width : drag.translation.height
                let proposed = (start ?? value) + (inverted ? -delta : delta)
                start = nil
                withAnimation(Motion.feedback) { active = false }
                if proposed < range.lowerBound - collapseThreshold, let onCollapse {
                    value = range.lowerBound
                    onCollapse()
                }
            }
    }
}

/// A resize pointer for the grip: UIKit's pointer interaction with a beam
/// along the divider (iPadOS has no system resize cursor; the beam is the
/// standard shape for a line you can drag).
private struct ResizePointer: ViewModifier {
    let axis: Axis

    func body(content: Content) -> some View {
        content.overlay(PointerBeam(axis: axis))
    }
}

private struct PointerBeam: UIViewRepresentable {
    let axis: Axis

    func makeUIView(context: Context) -> BeamView {
        let view = BeamView()
        view.axis = axis
        view.backgroundColor = .clear
        view.addInteraction(UIPointerInteraction(delegate: view))
        return view
    }

    func updateUIView(_ view: BeamView, context: Context) { view.axis = axis }

    final class BeamView: UIView, UIPointerInteractionDelegate {
        var axis: Axis = .vertical

        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            let length = (axis == .vertical ? bounds.height : bounds.width)
            let shape: UIPointerShape = axis == .vertical
                ? .verticalBeam(length: min(max(length, 24), 44))
                : .horizontalBeam(length: min(max(length, 24), 44))
            return UIPointerStyle(shape: shape)
        }
    }
}
