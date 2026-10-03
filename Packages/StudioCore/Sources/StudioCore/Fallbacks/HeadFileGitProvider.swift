import SwiftUI
import StudioDesign

/// What can be learned about a repository without a Git library: where it
/// is, the branch HEAD points at, and the origin remote.
public struct RepositoryInfo: Hashable, Sendable {
    /// The working tree root (the folder containing `.git`).
    public var workTree: URL
    /// The git directory (`.git`, or the target of a `gitdir:` file).
    public var gitDirectory: URL
    public var head: GitStatusSummary
    public var originURL: String?

    /// Finds the repository containing `url`, walking up to the filesystem
    /// root. Handles worktrees and submodules (`.git` files with `gitdir:`).
    public static func find(containing url: URL) -> RepositoryInfo? {
        var directory = url.standardizedFileURL
        let fm = FileManager.default
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDirectory = dotGit
                if !isDirectory.boolValue {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDirectory = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                        : directory.appendingPathComponent(path).standardizedFileURL
                }
                guard let head = readHead(gitDirectory) else { return nil }
                return RepositoryInfo(workTree: directory, gitDirectory: gitDirectory, head: head,
                                      originURL: readOrigin(gitDirectory))
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    static func readHead(_ gitDirectory: URL) -> GitStatusSummary? {
        guard let text = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            return GitStatusSummary(branch: branch)
        }
        guard head.count >= 7, head.allSatisfy(\.isHexDigit) else { return nil }
        return GitStatusSummary(branch: nil, detachedAt: String(head.prefix(7)))
    }

    /// `[remote "origin"] url = ...` from the repository's config. For
    /// worktrees the config lives in the common directory.
    static func readOrigin(_ gitDirectory: URL) -> String? {
        var configDirectory = gitDirectory
        if let common = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
            let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
            configDirectory = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : gitDirectory.appendingPathComponent(path).standardizedFileURL
        }
        guard let config = try? String(contentsOf: configDirectory.appendingPathComponent("config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
            } else if inOrigin, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }
}

/// The built-in source-control fallback: reads HEAD and the origin remote
/// straight from the `.git` directory, so the status bar shows the branch
/// before the full Git package is installed.
@MainActor
@Observable
public final class HeadFileGitProvider: GitProviding {
    public let id = "com.geramyloveless.LemonSeedStudio.git-head"
    public let displayName = "Repository (read-only)"

    public init() {}

    public func status(for root: URL) async -> GitStatusSummary? {
        await Task.detached { RepositoryInfo.find(containing: root)?.head }.value
    }

    public func makeSourceControlView(context: any WorkspaceContext) -> AnyView {
        AnyView(RepositorySummaryView(root: context.rootURL))
    }
}

struct RepositorySummaryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let root: URL
    @State private var info: RepositoryInfo?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let info {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label {
                        Text(info.head.headDescription)
                            .font(.studio(type.body, weight: .semibold))
                            .foregroundStyle(theme.palette.textPrimary.color)
                    } icon: {
                        Image(systemName: StudioSymbol.sourceControl)
                            .foregroundStyle(theme.palette.accent.color)
                    }
                    if let origin = info.originURL {
                        Text(origin)
                            .font(.studio(type.caption))
                            .foregroundStyle(theme.palette.textSecondary.color)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Text(info.workTree.lastPathComponent)
                        .font(.studio(type.caption))
                        .foregroundStyle(theme.palette.textTertiary.color)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .elevatedSurface()
                Text("Changes, staging, commits, branches and history appear here once the Git package is installed.")
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else if loaded {
                StudioEmptyState(symbol: StudioSymbol.sourceControl, title: "Not a Git repository",
                                 message: "This folder is not inside a Git repository.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, Space.m)
        .task(id: root) {
            let root = root
            info = await Task.detached { RepositoryInfo.find(containing: root) }.value
            loaded = true
        }
    }
}
