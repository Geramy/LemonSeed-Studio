public import SwiftUI
public import GitKit
public import Forge
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Copies text to the system pasteboard.
@MainActor
public enum Pasteboard {
    public static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

extension View {
    /// Inline navigation titles on iPad; nothing on the Mac.
    func inlineTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }

    /// The URL keyboard on iPad, no autocapitalization or autocorrection.
    func urlEntry() -> some View {
        #if os(iOS)
        return keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        return autocorrectionDisabled()
        #endif
    }

    /// No autocapitalization or autocorrection (URLs, tokens, names).
    func plainTextEntry() -> some View {
        #if os(iOS)
        return textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        return autocorrectionDisabled()
        #endif
    }
}

/// The one-letter change badge used in change lists (M, A, D, R, U, C).
public struct ChangeBadge: View {
    let change: FileChange
    @Environment(\.gitTheme) private var theme

    public init(_ change: FileChange) { self.change = change }

    public var body: some View {
        Text(letter)
            .font(.caption.weight(.bold).monospaced())
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(change.rawValue)
    }

    var letter: String {
        switch change {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .ignored: return "I"
        case .conflicted: return "C"
        }
    }

    var color: Color {
        switch change {
        case .added: return theme.added
        case .modified, .typeChanged: return theme.modified
        case .deleted: return theme.deleted
        case .renamed: return theme.renamed
        case .untracked: return theme.untracked
        case .ignored: return theme.secondaryText
        case .conflicted: return theme.conflict
        }
    }
}

/// CI state as a small symbol.
public struct CIBadge: View {
    let state: CIState
    @Environment(\.gitTheme) private var theme

    public init(_ state: CIState) { self.state = state }

    public var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityLabel("CI \(state.rawValue)")
    }

    var symbol: String {
        switch state {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .pending: return "clock.fill"
        case .canceled: return "slash.circle"
        case .skipped, .neutral: return "minus.circle"
        case .none: return "circle.dotted"
        }
    }

    var color: Color {
        switch state {
        case .success: return theme.ciSuccess
        case .failure: return theme.ciFailure
        case .running, .pending: return theme.ciPending
        default: return theme.secondaryText
        }
    }
}

/// A dismissible error line.
struct ErrorBanner: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    self.message = nil
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(10)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// "Receiving objects 42%" style description of transfer progress.
public struct TransferProgressView: View {
    let progress: TransferProgress

    public init(_ progress: TransferProgress) { self.progress = progress }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fractionCompleted > 0 ? progress.fractionCompleted : nil) {
                Text(title).font(.callout)
            }
            if let message = progress.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    var title: String {
        if let step = progress.step { return step }
        switch progress.phase {
        case .connecting: return "Connecting…"
        case .receiving:
            let mb = Double(progress.receivedBytes) / 1_048_576
            return "Receiving objects \(progress.receivedObjects)/\(progress.totalObjects) · \(mb.formatted(.number.precision(.fractionLength(1)))) MB"
        case .resolving: return "Resolving deltas \(progress.indexedDeltas)/\(progress.totalDeltas)"
        case .checkingOut: return "Checking out files \(progress.current)/\(progress.total)"
        case .packing: return "Packing objects \(progress.current)/\(progress.total)"
        case .pushing: return "Pushing objects \(progress.current)/\(progress.total)"
        case .lfs: return "Downloading LFS files \(progress.current)/\(progress.total)"
        case .done: return "Done"
        }
    }
}

/// A capsule label for a branch, tag or HEAD.
struct ReferenceChip: View {
    let label: ReferenceLabel
    @Environment(\.gitTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(label.name).font(.caption2.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }

    var icon: String {
        switch label.kind {
        case .head: return "smallcircle.filled.circle"
        case .localBranch: return "arrow.triangle.branch"
        case .remoteBranch: return "cloud"
        case .tag: return "tag"
        }
    }

    var color: Color {
        switch label.kind {
        case .head: return theme.accent
        case .localBranch: return theme.added
        case .remoteBranch: return theme.renamed
        case .tag: return theme.modified
        }
    }
}

extension Date {
    var relative: String { formatted(.relative(presentation: .named)) }
}
