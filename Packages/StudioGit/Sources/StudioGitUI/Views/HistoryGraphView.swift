public import SwiftUI
import GitKit

/// Commit history with a lane graph, reference labels and filters.
/// Selecting a commit shows its changes.
public struct HistoryGraphView: View {
    @Bindable var model: HistoryModel
    @State private var newBranchFor: ObjectID?
    @State private var newBranchName = ""
    @Environment(\.gitTheme) private var theme
    let laneWidth: CGFloat = 14
    let rowHeight: CGFloat = 44

    public init(model: HistoryModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { model.selected }, set: { id in if let id { Task { await model.select(id) } } })) {
                Section {
                    ForEach(model.rows) { row in
                        rowView(row)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .tag(row.commit.id)
                            .contextMenu { menu(row.commit) }
                    }
                    if model.canLoadMore {
                        Button("Load More") { Task { await model.load(more: true) } }
                    }
                } header: {
                    filters
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, rowHeight)
            .frame(minWidth: 420)
            Divider()
            detail.frame(maxWidth: .infinity)
        }
        .task { await model.load() }
        .alert("New Branch", isPresented: Binding(get: { newBranchFor != nil }, set: { if !$0 { newBranchFor = nil } })) {
            TextField("Name", text: $newBranchName).plainTextEntry()
            Button("Create") {
                if let id = newBranchFor { Task { await model.createBranch(newBranchName, at: id) } }
                newBranchName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            TextField("Path", text: $model.pathFilter).plainTextEntry().onSubmit { Task { await model.load() } }
            TextField("Author", text: $model.authorFilter).plainTextEntry().onSubmit { Task { await model.load() } }
            Toggle("All Branches", isOn: $model.allBranches)
                .toggleStyle(.button)
                .onChange(of: model.allBranches) { Task { await model.load() } }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.vertical, 6)
    }

    private func rowView(_ row: GraphRow) -> some View {
        HStack(spacing: 8) {
            GraphCell(row: row, laneWidth: laneWidth, height: rowHeight, theme: theme)
                .frame(width: CGFloat(max(model.maxWidth, 1)) * laneWidth + 6, height: rowHeight)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    ForEach(model.labels[row.commit.id] ?? [], id: \.self) { ReferenceChip(label: $0) }
                    Text(row.commit.summary).lineLimit(1)
                        .fontWeight(row.commit.isMerge ? .regular : .medium)
                        .foregroundStyle(row.commit.isMerge ? .secondary : .primary)
                }
                HStack(spacing: 6) {
                    Text(row.commit.id.short).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(row.commit.author.name).font(.caption).foregroundStyle(.secondary)
                    Text(row.commit.author.date.relative).font(.caption).foregroundStyle(.tertiary)
                    if row.commit.isSigned {
                        Image(systemName: "checkmark.seal").font(.caption2).foregroundStyle(theme.added)
                            .accessibilityLabel("Signed")
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func menu(_ commit: CommitInfo) -> some View {
        Button("Copy Commit ID", systemImage: "doc.on.doc") { Pasteboard.copy(commit.id.hex) }
        Button("Create Branch Here…", systemImage: "arrow.triangle.branch") { newBranchFor = commit.id }
        Button("Check Out (Detached)", systemImage: "arrow.uturn.right") { Task { await model.checkout(commit.id) } }
        Divider()
        Button("Cherry-Pick", systemImage: "arrow.right.doc.on.clipboard") { Task { await model.cherryPick(commit.id) } }
        Button("Revert", systemImage: "arrow.uturn.backward") { Task { await model.revert(commit.id) } }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selected, let row = model.rows.first(where: { $0.commit.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(row.commit.summary).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if !row.commit.body.isEmpty {
                        Text(row.commit.body).font(.callout).textSelection(.enabled)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("Commit").foregroundStyle(.secondary); Text(row.commit.id.hex).font(.caption.monospaced()).textSelection(.enabled) }
                        GridRow { Text("Author").foregroundStyle(.secondary); Text("\(row.commit.author.name) <\(row.commit.author.email)>") }
                        GridRow { Text("Date").foregroundStyle(.secondary); Text(row.commit.author.date.formatted(date: .abbreviated, time: .shortened)) }
                        if !row.commit.parents.isEmpty {
                            GridRow { Text("Parents").foregroundStyle(.secondary); Text(row.commit.parents.map(\.short).joined(separator: ", ")).font(.caption.monospaced()) }
                        }
                    }
                    .font(.callout)
                    Divider()
                    ForEach(model.selectedDiff) { file in
                        DisclosureGroup {
                            DiffView(hunks: file.hunks, isBinary: file.isBinary)
                                .frame(minHeight: CGFloat(min(file.hunks.reduce(0) { $0 + $1.lines.count + 1 }, 30)) * theme.codeLineHeight)
                        } label: {
                            HStack {
                                ChangeBadge(file.change)
                                Text(file.path).font(.callout.monospaced()).lineLimit(1)
                                Spacer()
                                Text("+\(file.additions) −\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("Select a commit", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }
}

/// Draws one row's lanes and node.
struct GraphCell: View {
    let row: GraphRow
    let laneWidth: CGFloat
    let height: CGFloat
    let theme: GitTheme

    var body: some View {
        Canvas { context, size in
            func x(_ column: Int) -> CGFloat { CGFloat(column) * laneWidth + laneWidth / 2 + 3 }
            let mid = size.height / 2
            for seg in row.upper {
                var path = Path()
                path.move(to: CGPoint(x: x(seg.fromColumn), y: 0))
                if seg.fromColumn == seg.toColumn {
                    path.addLine(to: CGPoint(x: x(seg.toColumn), y: mid))
                } else {
                    path.addCurve(to: CGPoint(x: x(seg.toColumn), y: mid),
                                  control1: CGPoint(x: x(seg.fromColumn), y: mid * 0.6),
                                  control2: CGPoint(x: x(seg.toColumn), y: mid * 0.4))
                }
                context.stroke(path, with: .color(theme.laneColor(seg.color)), lineWidth: 2)
            }
            for seg in row.lower {
                var path = Path()
                path.move(to: CGPoint(x: x(seg.fromColumn), y: mid))
                if seg.fromColumn == seg.toColumn {
                    path.addLine(to: CGPoint(x: x(seg.toColumn), y: size.height))
                } else {
                    path.addCurve(to: CGPoint(x: x(seg.toColumn), y: size.height),
                                  control1: CGPoint(x: x(seg.fromColumn), y: mid + (size.height - mid) * 0.6),
                                  control2: CGPoint(x: x(seg.toColumn), y: mid + (size.height - mid) * 0.4))
                }
                context.stroke(path, with: .color(theme.laneColor(seg.color)), lineWidth: 2)
            }
            let r: CGFloat = row.commit.isMerge ? 4 : 5
            let node = CGRect(x: x(row.column) - r, y: mid - r, width: r * 2, height: r * 2)
            let color = theme.laneColor(row.color)
            if row.commit.isMerge {
                context.fill(Path(ellipseIn: node), with: .color(.white))
                context.stroke(Path(ellipseIn: node), with: .color(color), lineWidth: 2)
            } else {
                context.fill(Path(ellipseIn: node), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
