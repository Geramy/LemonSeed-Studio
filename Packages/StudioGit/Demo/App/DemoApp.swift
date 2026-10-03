import SwiftUI
import GitKit
import Forge
import StudioGitUI

/// Runs the StudioGit views on their own.
///
/// Launch arguments (for screenshots and UI checks):
///   -screen changes|history|repositories|clone|pulls|pull|signin|devicecode|conflict|accounts|keys
@main
struct StudioGitDemoApp: App {
    @State private var services: GitServices = {
        GitRuntime.configure({
            var c = GitRuntime.Configuration()
            c.globalConfigDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "StudioGit/config")
            return c
        }())
        return KeychainSecretStore.isAvailable ? .standard() : .inMemory()
    }()

    var body: some Scene {
        WindowGroup {
            DemoRoot(services: services)
        }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case changes, conflict, history, repositories, pulls, accounts, keys, signin
    var id: Self { self }
    var title: String {
        switch self {
        case .changes: return "Source Control"
        case .conflict: return "Merge Conflict"
        case .history: return "History"
        case .repositories: return "Repositories"
        case .pulls: return "Pull Requests"
        case .accounts: return "Accounts"
        case .keys: return "SSH Keys"
        case .signin: return "Sign In"
        }
    }
    var icon: String {
        switch self {
        case .changes: return "arrow.triangle.branch"
        case .conflict: return "exclamationmark.arrow.triangle.2.circlepath"
        case .history: return "point.3.connected.trianglepath.dotted"
        case .repositories: return "books.vertical"
        case .pulls: return "arrow.triangle.pull"
        case .accounts: return "person.crop.circle"
        case .keys: return "key"
        case .signin: return "person.badge.key"
        }
    }
}

struct DemoRoot: View {
    let services: GitServices
    @State private var screen: Screen? = .changes
    @State private var sourceControl: SourceControlModel?
    @State private var conflict: SourceControlModel?
    @State private var history: HistoryModel?
    @State private var repoBrowser: RepositoryBrowserModel?
    @State private var pullList: PullRequestListModel?
    @State private var pullSelection: PullRequest?
    @State private var signIn: SignInModel?
    @State private var setupError: String?
    @State private var clonedRepo: GitRepository?
    @State private var columns: NavigationSplitViewVisibility = .automatic

    let arguments = ProcessInfo.processInfo.arguments

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(Screen.allCases, selection: $screen) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationTitle("StudioGit")
            .toolbar {
                Button("Reset Samples", systemImage: "arrow.counterclockwise") { Task { await setUp(reset: true) } }
            }
        } detail: {
            NavigationStack {
                detail
                    .alert("Trust this SSH host?", isPresented: Binding(get: { services.pendingHostKey != nil }, set: { _ in })) {
                        Button("Trust") { services.answerHostKey(true) }
                        Button("Cancel", role: .cancel) { services.answerHostKey(false) }
                    } message: {
                        if let q = services.pendingHostKey { Text("\(q.host)\n\(q.keyType) \(q.fingerprint)") }
                    }
            }
        }
        .task { await setUp(reset: false) }
    }

    @ViewBuilder
    private var detail: some View {
        if let setupError {
            ContentUnavailableView("Setup failed", systemImage: "exclamationmark.triangle", description: Text(setupError))
        } else {
            switch screen {
            case .changes:
                if let sourceControl {
                    SourceControlWorkspaceView(model: sourceControl).navigationTitle(sourceControl.name)
                }
            case .conflict:
                if let conflict {
                    SourceControlWorkspaceView(model: conflict).navigationTitle("gpu-monitor-merge")
                }
            case .history:
                if let history { HistoryGraphView(model: history).navigationTitle("History") }
            case .repositories:
                if let repoBrowser {
                    RepositoryBrowserView(model: repoBrowser) { repo in
                        clonedRepo = repo
                        sourceControl = SourceControlModel(repository: repo, services: services)
                        screen = .changes
                    }
                }
            case .pulls:
                if let pullList {
                    HStack(spacing: 0) {
                        PullRequestListView(model: pullList, selection: $pullSelection).frame(width: 420)
                        Divider()
                        if let pr = pullSelection {
                            PullRequestDetailView(model: PullRequestDetailModel(client: pullList.client, repository: pr.repository, number: pr.number))
                                .id(pr.id)
                        } else {
                            ContentUnavailableView("Select a pull request", systemImage: "arrow.triangle.pull")
                        }
                    }
                }
            case .accounts:
                AccountsView(services: services)
            case .keys:
                SSHKeysView(services: services)
            case .signin:
                if let signIn { SignInView(model: signIn) }
            case nil:
                Text("Choose a screen")
            }
        }
    }

    private func setUp(reset: Bool) async {
        do {
            let workspaces = CloneLocation.workspacesDirectory
            try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
            let sampleURL = workspaces.appending(path: "gpu-monitor")
            let mergeURL = workspaces.appending(path: "gpu-monitor-merge")
            let repo: GitRepository
            if reset || !GitRepository.exists(at: sampleURL) {
                repo = try await SampleRepository.make(at: sampleURL)
            } else {
                repo = try GitRepository.open(at: sampleURL)
            }
            let mergeRepo: GitRepository
            if reset || !GitRepository.exists(at: mergeURL) {
                mergeRepo = try await SampleRepository.make(at: mergeURL, withConflict: true)
            } else {
                mergeRepo = try GitRepository.open(at: mergeURL)
            }
            sourceControl = SourceControlModel(repository: clonedRepo ?? repo, services: services)
            conflict = SourceControlModel(repository: mergeRepo, services: services)
            history = HistoryModel(repository: repo)
            let accounts = await services.accounts.accounts()
            let useSample = accounts.isEmpty
            repoBrowser = RepositoryBrowserModel(services: services, makeClient: useSample ? { _ in SampleForgeClient() } : nil,
                                                 fixedAccounts: useSample ? [SampleForgeClient.sampleAccount] : nil)
            let client: any ForgeClient = useSample ? SampleForgeClient() : services.accounts.client(for: accounts[0])
            pullList = PullRequestListModel(client: client, filter: useSample ? .repository("lemonade-sdk/amdgpu_mtopg") : .authoredByMe)
            signIn = SignInModel(accounts: services.accounts)
            if services.authorName.isEmpty {
                services.authorName = "Alice Moreau"
                services.authorEmail = "alice@example.com"
            }
            applyArguments(repoBrowser: repoBrowser!, conflict: conflict!)
        } catch {
            setupError = "\(error)"
        }
    }

    private func applyArguments(repoBrowser: RepositoryBrowserModel, conflict: SourceControlModel) {
        guard let i = arguments.firstIndex(of: "-screen"), i + 1 < arguments.count else { return }
        // Screenshots: give the screen the whole width.
        columns = .detailOnly
        switch arguments[i + 1] {
        case "changes":
            screen = .changes
            Task {
                await sourceControl?.refresh()
                if let model = sourceControl, let entry = model.unstaged.first(where: { $0.path.hasSuffix("QueueRow.swift") }) {
                    await model.select(entry, staged: false)
                    if let hunk = model.selectedDiff?.hunks.last, let line = hunk.lines.first(where: { $0.kind == .addition }) {
                        model.toggleLine(line, in: hunk)
                    }
                }
            }
        case "conflict":
            screen = .conflict
            Task {
                await conflict.refresh()
                if let entry = conflict.conflicted.first { await conflict.select(entry, staged: false) }
            }
        case "history":
            screen = .history
            Task {
                await history?.load()
                if let merge = history?.rows.first(where: { $0.commit.isMerge }) { await history?.select(merge.commit.id) }
            }
        case "repositories": screen = .repositories
        case "pulls":
            screen = .pulls
            pullSelection = SampleForgeClient.samplePulls.first
        case "accounts": screen = .accounts
        case "keys":
            // Show a populated list: one Secure Enclave key (when the
            // hardware has one) and one Ed25519 key.
            Task {
                if (try? await services.sshKeys.keys().isEmpty) ?? true {
                    if SecureEnclaveSSHKey.isAvailable {
                        _ = try? await services.sshKeys.generate(.secureEnclave, label: "Studio iPad")
                    }
                    _ = try? await services.sshKeys.generate(.ed25519, label: "Portable key")
                }
                screen = .keys
            }
        case "signin": screen = .signin
        case "devicecode":
            screen = .signin
            signIn?.showSampleCode(DeviceAuthorization(
                deviceCode: "sample", userCode: "WDJB-MJHT",
                verificationURI: URL(string: "https://github.com/login/device")!,
                expiresAt: Date().addingTimeInterval(899), interval: 5))
        default: break
        }
    }
}
