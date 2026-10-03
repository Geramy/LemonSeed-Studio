import SwiftUI
import StudioCore
import StudioDesign

/// The workspace window: top bar, activity bar, sidebar, editor area,
/// bottom panel and status bar, with the command palette floating above.
struct WorkspaceWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Bindable var controller: WorkspaceController

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
                    ResizeHandle(axis: .vertical, value: $controller.sidebarWidth, range: 200...560, identifier: "sidebar.resize")
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
                            ResizeHandle(axis: .horizontal, value: $controller.panelHeight, range: 120...900,
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
        }
        .background(theme.palette.canvas.color)
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

/// A draggable divider: a hairline with a wider invisible grip.
struct ResizeHandle: View {
    @Environment(\.theme) private var theme
    let axis: Axis
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var inverted = false
    var identifier = "resize"
    @State private var start: CGFloat?
    @State private var active = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(active ? theme.palette.accent.opacity(0.7).color : theme.palette.hairline.color)
                .frame(width: axis == .vertical ? (active ? 2 : 1) : nil, height: axis == .horizontal ? (active ? 2 : 1) : nil)
        }
        .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
        .overlay {
            Color.clear
                .frame(width: axis == .vertical ? 14 : nil, height: axis == .horizontal ? 14 : nil)
                .contentShape(.rect)
                .onHover { inside in withAnimation(Motion.feedback) { active = inside } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        if start == nil { start = value }
                        let delta = axis == .vertical ? drag.translation.width : drag.translation.height
                        let next = (start ?? value) + (inverted ? -delta : delta)
                        value = min(max(next, range.lowerBound), range.upperBound)
                        active = true
                    }
                    .onEnded { _ in
                        start = nil
                        withAnimation(Motion.feedback) { active = false }
                    })
                .accessibilityIdentifier(identifier)
        }
        .zIndex(1)
    }
}
