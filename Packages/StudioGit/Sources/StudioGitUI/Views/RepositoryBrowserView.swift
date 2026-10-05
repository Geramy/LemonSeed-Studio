public import SwiftUI
public import GitKit
import Forge
import UniformTypeIdentifiers

/// Repositories of the signed-in accounts: the user's own, collaborations
/// and their organizations' (GitHub) or groups' (GitLab), with an owner
/// filter, search, fork and archive filters and paging; then a clone sheet.
/// Without an account it asks to sign in; cloning by URL always works.
public struct RepositoryBrowserView: View {
    @Bindable var model: RepositoryBrowserModel
    var onCloned: (GitRepository) -> Void
    /// A clone sheet to open as the browser appears (screenshots).
    var startingClone: RepositoryBrowserModel.CloneRequest?
    /// The clone being set up, with an identity that lasts while its sheet is up.
    @State private var cloning: IdentifiedRequest?
    @State private var signingIn: SignInModel?
    @Environment(\.gitTheme) private var theme

    public init(model: RepositoryBrowserModel, startingClone: RepositoryBrowserModel.CloneRequest? = nil,
                onCloned: @escaping (GitRepository) -> Void = { _ in }) {
        self.model = model
        self.startingClone = startingClone
        self.onCloned = onCloned
    }

    public var body: some View {
        Group {
            if model.needsSignIn {
                signInPrompt
            } else {
                list
            }
        }
        .task { await model.load() }
        .onAppear {
            if let startingClone, cloning == nil { cloning = IdentifiedRequest(request: startingClone) }
        }
        .navigationTitle("Clone a Repository")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    cloning = IdentifiedRequest(request: RepositoryBrowserModel.CloneRequest(url: ""))
                } label: {
                    Label("Clone by URL", systemImage: "link")
                }
                .accessibilityIdentifier("git.cloneByURL")
            }
        }
        .sheet(item: $cloning) { item in
            NavigationStack {
                CloneSheet(model: model, request: item.request, editableURL: item.request.httpsURL.isEmpty && item.request.sshURL == nil) { cloned in
                    cloning = nil
                    if let cloned { onCloned(cloned) }
                }
            }
        }
        .sheet(item: Binding(get: { signingIn.map(IdentifiedSignIn.init) }, set: { signingIn = $0?.model })) { item in
            NavigationStack {
                SignInView(model: item.model) { _ in
                    signingIn = nil
                    Task { await model.accountsChanged() }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { item.model.cancel(); signingIn = nil }
                    }
                }
            }
        }
    }

    private var signInPrompt: some View {
        ContentUnavailableView {
            Label("Sign in to see your repositories", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Connect a GitHub or GitLab account (GitHub Enterprise and self-hosted GitLab work too) to browse and clone your repositories and your organizations'. Public repositories can be cloned by URL without signing in.")
        } actions: {
            Button("Sign In…") { signingIn = SignInModel(accounts: model.services.accounts) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("git.browser.signIn")
            Button("Clone by URL…") { cloning = IdentifiedRequest(request: RepositoryBrowserModel.CloneRequest(url: "")) }
                .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.browser.signInPrompt")
    }

    private var list: some View {
        List {
            Section {
                filterBar
                    .listRowSeparator(.hidden)
            }
            if let message = model.errorMessage {
                ErrorBanner(message: Binding(get: { message }, set: { model.errorMessage = $0 }))
                    .listRowSeparator(.hidden)
            }
            if model.searchResults != nil {
                Section {
                    rows
                } header: {
                    HStack {
                        Text("Search results · \(model.scopeTitle)")
                        Spacer()
                        Button("Clear") { model.clearSearch() }.font(.caption)
                    }
                }
            } else {
                Section {
                    rows
                    if model.nextCursor != nil {
                        HStack {
                            Spacer()
                            if model.isLoading {
                                ProgressView()
                            } else {
                                Button("Load More") { Task { await model.loadMore() } }
                            }
                            Spacer()
                        }
                        .task { await model.loadMore() }
                    }
                } header: {
                    Text(model.scopeTitle)
                }
            }
            if model.visibleRepositories.isEmpty && !model.isLoading && model.errorMessage == nil && model.hasLoadedAccounts {
                ContentUnavailableView(model.query.isEmpty ? "No repositories" : "No matches", systemImage: "books.vertical",
                                       description: Text(model.query.isEmpty
                                                         ? "Nothing here with the current filters."
                                                         : "Press Search to look on \(model.account?.host.kind.displayName ?? "the forge")."))
            }
        }
        .overlay { if model.isLoading && model.visibleRepositories.isEmpty { ProgressView() } }
        .searchable(text: $model.query, prompt: "Filter, or search \(model.account?.host.kind.displayName ?? "the forge")")
        .onSubmit(of: .search) { Task { await model.search() } }
        .onChange(of: model.query) { _, q in if q.isEmpty { model.clearSearch() } }
        .refreshable { await model.reload() }
        .accessibilityIdentifier("git.browser.list")
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            if model.accounts.count > 1 {
                Menu {
                    ForEach(model.accounts) { account in
                        Button(account.displayName) { Task { await model.selectAccount(account) } }
                    }
                } label: {
                    Label(model.account?.displayName ?? "Account", systemImage: "person.crop.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
            } else if let account = model.account {
                Label(account.displayName, systemImage: "person.crop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Menu {
                ForEach(model.scopeChoices, id: \.title) { choice in
                    Button {
                        Task { await model.selectScope(choice.scope) }
                    } label: {
                        if choice.scope == model.scope { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
                    }
                }
            } label: {
                Label(model.scopeTitle, systemImage: "building.2")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("git.browser.owner")
            Menu {
                Toggle("Show Forks", isOn: $model.showForks)
                Toggle("Show Archived", isOn: $model.showArchived)
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("git.browser.filter")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var rows: some View {
        ForEach(model.visibleRepositories) { repo in
            RepositoryRow(repo: repo) {
                cloning = IdentifiedRequest(request: RepositoryBrowserModel.CloneRequest(repository: repo, accountID: model.account?.id))
            }
            .task { await model.loadMoreIfNeeded(after: repo) }
        }
    }
}

private struct IdentifiedRequest: Identifiable {
    let id = UUID()
    let request: RepositoryBrowserModel.CloneRequest
}

private struct IdentifiedSignIn: Identifiable {
    let model: SignInModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
}

/// One repository with its visibility, fork and archive badges.
struct RepositoryRow: View {
    let repo: ForgeRepository
    let clone: () -> Void
    @Environment(\.gitTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: repo.isPrivate ? "lock.fill" : (repo.isFork ? "tuningfork" : "book.closed"))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(repo.fullName).font(.body.weight(.semibold)).lineLimit(1)
                    if repo.isPrivate { Badge(text: "Private", color: theme.modified) }
                    if repo.isFork { Badge(text: "Fork", color: theme.renamed) }
                    if repo.isArchived { Badge(text: "Archived", color: theme.secondaryText) }
                    if repo.hasLFS == true { Badge(text: "LFS", color: theme.accent) }
                }
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 12) {
                    if let lang = repo.language { Label(lang, systemImage: "chevron.left.forwardslash.chevron.right") }
                    Label("\(repo.stars)", systemImage: "star")
                    if let branch = repo.defaultBranch { Label(branch, systemImage: "arrow.triangle.branch") }
                    if let size = repo.sizeKB { Text(ByteCountFormatter.string(fromByteCount: Int64(size) * 1024, countStyle: .file)) }
                    if let updated = repo.updatedAt { Text(updated.relative) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            }
            Spacer()
            Button("Clone", action: clone)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("git.clone.\(repo.fullName)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A small capsule label.
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// Clone options: URL (when cloning by URL), location (the app's folder or
/// a folder from Files), protocol, depth, submodules and LFS; then live
/// progress with Cancel.
struct CloneSheet: View {
    @Bindable var model: RepositoryBrowserModel
    @State var request: RepositoryBrowserModel.CloneRequest
    let editableURL: Bool
    var done: (GitRepository?) -> Void
    @State private var urlText = ""
    @State private var folders: [SavedFolder] = []
    @State private var picking = false
    @State private var folderNameEdited = false

    var body: some View {
        Form {
            Section("Repository") {
                if editableURL {
                    TextField("https://github.com/owner/name.git or git@host:owner/name.git", text: $urlText)
                        .urlEntry()
                        .accessibilityIdentifier("git.clone.url")
                        .onChange(of: urlText) { _, text in
                            let folder = request.folderName
                            request = RepositoryBrowserModel.CloneRequest(url: text)
                            if folderNameEdited { request.folderName = folder }
                        }
                    Text("Credentials come from the signed-in account for the URL's host, or your SSH key for SSH URLs.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Name", value: request.displayName)
                    Picker("Protocol", selection: $request.useSSH) {
                        Text("HTTPS").tag(false)
                        Text("SSH").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(request.sshURL == nil)
                    Text(request.url)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                Picker("Location", selection: $request.location) {
                    Label("On My iPad", systemImage: "ipad").tag(CloneLocation.appContainer)
                    ForEach(folders) { folder in
                        Label(folder.name, systemImage: "folder").tag(CloneLocation.folder(folder))
                    }
                }
                Button("Choose Folder in Files…", systemImage: "folder.badge.plus") { picking = true }
                TextField("Folder name", text: Binding(get: { request.folderName }, set: { request.folderName = $0; folderNameEdited = true }))
                    .plainTextEntry()
                    .accessibilityIdentifier("git.clone.folderName")
            } header: {
                Text("Location")
            } footer: {
                Text(request.location == .appContainer
                     ? "\(model.appFolder.lastPathComponent)/\(request.folderName) in the app's folder, visible in Files under On My iPad. Fastest, with live file watching."
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
            ErrorBanner(message: $model.errorMessage)
        }
        // The clone's progress stays at the top, above the options, for as
        // long as it runs.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let job = model.cloneJob {
                CloneProgressHeader(repository: job.repository, progress: job.progress, finished: job.finished) {
                    model.cancelClone()
                }
            }
        }
        .navigationTitle(editableURL ? "Clone by URL" : "Clone")
        .inlineTitle()
        .interactiveDismissDisabled(model.cloneJob != nil)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { model.dismissCloneJob(); done(nil) }
                    .disabled(model.cloneJob != nil)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Clone") {
                    Task {
                        let repo = await model.clone(request)
                        if let repo {
                            try? await Task.sleep(for: .milliseconds(500))
                            model.dismissCloneJob()
                            done(repo)
                        }
                    }
                }
                .disabled(model.cloneJob != nil || request.problem != nil)
                .accessibilityIdentifier("git.clone.start")
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do {
                    let folder = try model.folders.add(url)
                    folders = model.folders.folders
                    request.location = .folder(folder)
                } catch {
                    model.errorMessage = "Couldn't keep access to \(url.lastPathComponent): \(error.localizedDescription)"
                }
            case .failure(let error):
                model.errorMessage = "Couldn't open the folder: \(error.localizedDescription)"
            }
        }
        .onAppear {
            folders = model.folders.folders
            model.errorMessage = nil
        }
    }
}
