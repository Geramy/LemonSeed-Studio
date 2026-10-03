public import SwiftUI
public import GitKit
import Forge
import UniformTypeIdentifiers

/// Repositories of the signed-in accounts, with search and a clone sheet.
public struct RepositoryBrowserView: View {
    @Bindable var model: RepositoryBrowserModel
    var onCloned: (GitRepository) -> Void
    @State private var cloning: ForgeRepository?
    @Environment(\.gitTheme) private var theme

    public init(model: RepositoryBrowserModel, onCloned: @escaping (GitRepository) -> Void = { _ in }) {
        self.model = model
        self.onCloned = onCloned
    }

    public var body: some View {
        List {
            if model.accounts.count > 1 {
                Picker("Account", selection: Binding(get: { model.account?.id }, set: { id in
                    model.account = model.accounts.first { $0.id == id }
                    Task { await model.reload() }
                })) {
                    ForEach(model.accounts) { Text($0.displayName).tag(Optional($0.id)) }
                }
            }
            if model.accounts.isEmpty && !model.isLoading {
                ContentUnavailableView("No accounts", systemImage: "person.crop.circle.badge.plus",
                                       description: Text("Add a GitHub or GitLab account to browse repositories."))
            }
            ErrorBanner(message: $model.errorMessage)
            if model.searchResults != nil {
                Section("Search results") { rows }
            } else {
                Section { rows }
            }
            if model.nextCursor != nil && model.searchResults == nil {
                Button("Load More") { Task { await model.loadMore() } }
            }
        }
        .overlay { if model.isLoading && model.visibleRepositories.isEmpty { ProgressView() } }
        .searchable(text: $model.query, prompt: "Filter, or search \(model.account?.host.kind.displayName ?? "the forge")")
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.query) { _, q in if q.isEmpty { Task { await model.reload() } } }
        .refreshable { await model.reload() }
        .task { await model.load() }
        .navigationTitle("Repositories")
        .sheet(item: $cloning) { repo in
            NavigationStack {
                CloneSheet(model: model, request: RepositoryBrowserModel.CloneRequest(repository: repo)) { cloned in
                    cloning = nil
                    if let cloned { onCloned(cloned) }
                }
            }
        }
    }

    private var rows: some View {
        ForEach(model.visibleRepositories) { repo in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: repo.isPrivate ? "lock.fill" : (repo.isFork ? "tuningfork" : "book.closed"))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(repo.fullName).font(.body.weight(.semibold))
                    if let d = repo.description, !d.isEmpty {
                        Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        if let lang = repo.language { Label(lang, systemImage: "chevron.left.forwardslash.chevron.right") }
                        Label("\(repo.stars)", systemImage: "star")
                        if let branch = repo.defaultBranch { Label(branch, systemImage: "arrow.triangle.branch") }
                        if let size = repo.sizeKB { Text(ByteCountFormatter.string(fromByteCount: Int64(size) * 1024, countStyle: .file)) }
                        if repo.hasLFS == true { Text("LFS").font(.caption2.weight(.bold)) }
                        if let updated = repo.updatedAt { Text(updated.relative) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
                Spacer()
                Button("Clone") { cloning = repo }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 2)
        }
    }
}

/// Clone options: location (app container or a Files folder), protocol,
/// depth, submodules and LFS; then live progress.
struct CloneSheet: View {
    @Bindable var model: RepositoryBrowserModel
    @State var request: RepositoryBrowserModel.CloneRequest
    var done: (GitRepository?) -> Void
    @State private var folders: [SavedFolder] = []
    @State private var picking = false
    @State private var running = false

    var body: some View {
        Form {
            Section("Repository") {
                LabeledContent("Name", value: request.repository.fullName)
                Picker("Protocol", selection: $request.useSSH) {
                    Text("HTTPS").tag(false)
                    Text("SSH").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(request.repository.sshCloneURL == nil)
                Text(request.useSSH ? (request.repository.sshCloneURL ?? "") : request.repository.httpsCloneURL)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section {
                Picker("Location", selection: $request.location) {
                    Label("On My iPad", systemImage: "ipad").tag(CloneLocation.appContainer)
                    ForEach(folders) { folder in
                        Label(folder.name, systemImage: "folder").tag(CloneLocation.folder(folder))
                    }
                }
                Button("Choose Folder in Files…", systemImage: "folder.badge.plus") { picking = true }
                TextField("Folder name", text: $request.folderName).plainTextEntry()
            } header: {
                Text("Location")
            } footer: {
                Text(request.location == .appContainer
                     ? "Workspaces/\(request.folderName) in the app's folder, visible in Files under On My iPad. Fastest, with live file watching."
                     : "A folder from Files (iCloud Drive, another provider or an external drive). Access is kept with a bookmark.")
            }
            Section("Options") {
                Toggle("Shallow Clone", isOn: $request.shallow)
                if request.shallow {
                    Stepper("Depth: \(request.depth) commit\(request.depth == 1 ? "" : "s")", value: $request.depth, in: 1...1000)
                }
                Toggle("Submodules (recursive)", isOn: $request.submodules)
                Toggle("Git LFS Files", isOn: $request.lfs)
            }
            if let job = model.cloneJob {
                Section("Progress") {
                    TransferProgressView(job.progress)
                    if job.finished, let dest = job.destination {
                        Label("Cloned to \(dest.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            ErrorBanner(message: $model.errorMessage)
        }
        .navigationTitle("Clone")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { model.dismissCloneJob(); done(nil) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Clone") {
                    running = true
                    Task {
                        let repo = await model.clone(request)
                        running = false
                        if let repo {
                            try? await Task.sleep(for: .milliseconds(600))
                            model.dismissCloneJob()
                            done(repo)
                        }
                    }
                }
                .disabled(running || request.folderName.isEmpty)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, let folder = try? model.folders.add(url) {
                folders = model.folders.folders
                request.location = .folder(folder)
            }
        }
        .onAppear { folders = model.folders.folders }
    }
}
