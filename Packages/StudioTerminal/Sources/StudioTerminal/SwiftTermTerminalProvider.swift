import SwiftUI
import UIKit
@preconcurrency import SwiftTerm
import StudioCore
import StudioDesign

/// The built-in terminal: SwiftTerm views running the in-process shell.
@MainActor
public final class SwiftTermTerminalProvider: TerminalProviding {
    public let id = "com.geramyloveless.LemonSeedStudio.terminal"
    public let displayName = "Terminal"

    public init() {}

    public func makeSession(workingDirectory: URL, context: (any WorkspaceContext)?) -> any TerminalSession {
        ShellTerminalSession(root: context?.rootURL ?? workingDirectory, workingDirectory: workingDirectory, context: context)
    }

    public func makeTerminalView(for session: any TerminalSession) -> AnyView {
        guard let session = session as? ShellTerminalSession else {
            return AnyView(StudioEmptyState(symbol: StudioSymbol.terminal, title: "Unsupported session",
                                            message: "This terminal session came from another provider."))
        }
        return AnyView(TerminalHostView(session: session))
    }
}

/// Hosts a session's long-lived TerminalView inside a container, so the
/// view (and its scrollback) can move between SwiftUI hierarchies.
struct TerminalHostView: UIViewRepresentable {
    @Environment(\.theme) private var theme
    @Environment(\.codeFont) private var codeFont
    let session: ShellTerminalSession

    func makeUIView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        container.host(session.terminalView)
        return container
    }

    func updateUIView(_ container: TerminalContainer, context: Context) {
        if session.terminalView.superview !== container { container.host(session.terminalView) }
        container.backgroundColor = theme.terminal.background.uiColor
        let size = max(CodeFont.sizeRange.lowerBound, codeFont.size - 1)
        session.apply(theme: theme, font: CodeFont(family: codeFont.family, size: size))
        session.startIfNeeded()
    }

    static func dismantleUIView(_ container: TerminalContainer, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

final class TerminalContainer: UIView {
    private let inset = UIEdgeInsets(top: 6, left: 12, bottom: 4, right: 6)

    func host(_ view: UIView) {
        view.removeFromSuperview()
        addSubview(view)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds.inset(by: inset)
    }
}
