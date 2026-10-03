public import SwiftUI
import GitKit

/// Local and remote branches: switch, create, merge into current, delete.
public struct BranchPickerView: View {
    @Bindable var model: SourceControlModel
    var dismiss: () -> Void
    @State private var filter = ""
    @State private var newBranch = ""
    @State private var confirmDelete: Branch?
    @Environment(\.gitTheme) private var theme

    public init(model: SourceControlModel, dismiss: @escaping () -> Void = {}) {
        self.model = model
        self.dismiss = dismiss
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New branch name", text: $newBranch)
                            .plainTextEntry()
                            .onSubmit(create)
                        Button("Create", action: create)
                            .disabled(newBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Local") {
                    ForEach(filtered(remote: false)) { branch in row(branch) }
                }
                let remotes = filtered(remote: true)
                if !remotes.isEmpty {
                    Section("Remote") {
                        ForEach(remotes) { branch in row(branch) }
                    }
                }
            }
            .searchable(text: $filter, prompt: "Filter branches")
            .navigationTitle("Branches")
            .inlineTitle()
            .confirmationDialog("Delete branch?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                presenting: confirmDelete) { branch in
                Button("Delete \(branch.name)", role: .destructive) { Task { await model.deleteBranch(branch) } }
                Button("Force Delete (unmerged work is lost)", role: .destructive) { Task { await model.deleteBranch(branch, force: true) } }
            }
        }
    }

    private func filtered(remote: Bool) -> [Branch] {
        model.branches.filter { $0.isRemote == remote && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }
    }

    private func create() {
        let name = newBranch
        newBranch = ""
        Task {
            await model.createBranch(name)
            dismiss()
        }
    }

    private func row(_ branch: Branch) -> some View {
        Button {
            Task {
                await model.checkout(branch)
                dismiss()
            }
        } label: {
            HStack {
                Image(systemName: branch.isHead ? "checkmark.circle.fill" : (branch.isRemote ? "cloud" : "arrow.triangle.branch"))
                    .foregroundStyle(branch.isHead ? theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(branch.name).foregroundStyle(.primary)
                    if let upstream = branch.upstream {
                        Text(upstream).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if branch.behind > 0 { Text("\(branch.behind)↓").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if branch.ahead > 0 { Text("\(branch.ahead)↑").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
        .disabled(branch.isHead)
        .contextMenu {
            if !branch.isHead {
                Button("Merge into Current Branch", systemImage: "arrow.triangle.merge") { Task { await model.merge(branch) } }
            }
            if !branch.isRemote && !branch.isHead {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = branch }
            }
        }
    }
}
