import SwiftUI
import StudioCore
import StudioDesign

/// Raises or lowers the on-screen keyboard. Shown only when no hardware
/// keyboard is attached: it focuses where the user was last typing
/// (editor, terminal, search, agent prompt), and dismisses the keyboard
/// when it is up.
struct KeyboardButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.keyboard.hasHardwareKeyboard {
            let visible = app.keyboard.isSoftwareKeyboardVisible
            StudioIconButton(visible ? "keyboard.chevron.compact.down" : "keyboard",
                             help: visible ? "Hide Keyboard" : "Show Keyboard", isActive: visible) {
                app.textInput.toggleKeyboard(visible: visible)
            }
            .accessibilityIdentifier("toolbar.keyboard")
            .accessibilityValue(visible ? "shown" : "hidden")
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

/// The floating keyboard button over an editor that does not have focus.
struct EditorKeyboardButton: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    let document: EditorDocument

    var body: some View {
        Button {
            app.textInput.focus(id: TextInputCoordinator.editorID(for: document))
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary.color)
                .frame(width: 52, height: 52)
                .floatingSurface(cornerRadius: 26, interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityLabel("Show Keyboard")
        .accessibilityIdentifier("editor.keyboardButton")
        .padding(Space.l)
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}
