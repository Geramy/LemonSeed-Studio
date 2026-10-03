public import SwiftUI
import GitKit

/// Three-way conflict resolution for one file: ours and theirs side by
/// side, and an editable result that starts as Git's merge with conflict
/// markers. (The full editor-based merge view lives in LemonText; this is
/// the self-contained fallback.)
public struct ConflictResolutionView: View {
    @Bindable var model: SourceControlModel
    let path: String
    @State private var versions: ConflictVersions?
    @State private var result = ""
    @State private var loadError: String?
    @Environment(\.gitTheme) private var theme

    public init(model: SourceControlModel, path: String) {
        self.model = model
        self.path = path
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ChangeBadge(.conflicted)
                Text(path).font(.callout.monospaced()).lineLimit(1)
                Spacer()
                Button("Use Ours") { Task { await model.resolve(path, with: .ours) } }
                Button("Use Theirs") { Task { await model.resolve(path, with: .theirs) } }
                Button {
                    Task { await model.resolve(path, with: .content(Data(result.utf8))) }
                } label: {
                    Label("Mark Resolved", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(markerCount > 0)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let versions {
                HStack(spacing: 0) {
                    side("Ours (\(model.head?.branch ?? "HEAD"))", versions.ours)
                    Divider()
                    side("Theirs", versions.theirs)
                }
                .frame(maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Result").font(.caption.weight(.semibold))
                        if markerCount > 0 {
                            Text("\(markerCount) conflict\(markerCount == 1 ? "" : "s") left").font(.caption).foregroundStyle(theme.conflict)
                        } else {
                            Text("No markers left").font(.caption).foregroundStyle(theme.added)
                        }
                        Spacer()
                        Button("Reset") { result = String(decoding: versions.merged, as: UTF8.self) }.controlSize(.mini)
                    }
                    TextEditor(text: $result)
                        .font(theme.codeFont)
                        .plainTextEntry()
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Merged result")
                }
                .padding(10)
                .frame(maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Cannot load conflict", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task(id: path) { await load() }
    }

    private var markerCount: Int {
        result.split(separator: "\n", omittingEmptySubsequences: false).count { $0.hasPrefix("<<<<<<<") }
    }

    private func load() async {
        do {
            let v = try await model.repository.conflictVersions(path)
            versions = v
            result = String(decoding: v.merged, as: UTF8.self)
        } catch {
            loadError = "\(error)"
        }
    }

    private func side(_ title: String, _ data: Data?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).padding([.top, .horizontal], 10)
            ScrollView([.vertical, .horizontal]) {
                Text(data.map { String(decoding: $0, as: UTF8.self) } ?? "(deleted)")
                    .font(theme.codeFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
