import Foundation
import StudioAgent
import GitKit
import Forge
import StudioGitUI

/// Git tools for the coding agent. They go through the agent's permission
/// gate classified like the shell commands they stand for: creating a
/// branch modifies the repository (asks in "Ask" and "Review", runs in
/// Autopilot, refused in read-only), and opening a draft request reaches
/// the network (always asks, refused in read-only).
enum GitAgentTools {
    @MainActor
    static func all(root: URL, services: GitServices) -> [any AgentTool] {
        [GitCreateBranchTool(root: root), GitOpenPullRequestDraftTool(root: root, services: services)]
    }

    static func repository(at root: URL) throws -> GitRepository {
        do {
            return try GitRepository.open(at: root, search: true)
        } catch {
            throw ToolError("The workspace is not in a Git repository.")
        }
    }
}

struct GitCreateBranchTool: AgentTool {
    let root: URL

    let name = "git_create_branch"
    let description = """
    Create a Git branch in the workspace's repository, from the current HEAD or from another branch, tag or commit, \
    and switch to it (uncommitted changes come along). Fails if the name is invalid or taken.
    """
    let promptSnippet = "create a Git branch (and switch to it)"
    var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "name": ["type": "string", "description": "The new branch name, e.g. fix/fan-curve"],
            "start_point": ["type": "string", "description": "Branch, tag or commit to start from (default: HEAD)"],
            "checkout": ["type": "boolean", "description": "Switch to the new branch (default true)"],
         ],
         "required": ["name"]]
    }

    func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect {
        let name = arguments["name"]?.stringValue ?? ""
        let start = arguments["start_point"]?.stringValue
        let checkout = arguments["checkout"]?.boolValue ?? true
        let command = (checkout ? "git switch -c \(name)" : "git branch \(name)") + (start.map { " \($0)" } ?? "")
        return .shell(command: command, commandClass: .mutating)
    }

    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let args = ToolArguments(arguments, tool: name)
        let branch = try args.string("name").trimmingCharacters(in: .whitespaces)
        let start = try args.optionalString("start_point") ?? "HEAD"
        let checkout = try args.optionalBool("checkout") ?? true
        guard GitRepository.isValidBranchName(branch) else { throw ToolError("\"\(branch)\" is not a valid branch name.") }
        let repository = try GitAgentTools.repository(at: root)
        let created: Branch
        do {
            created = try await repository.createBranch(branch, at: start)
        } catch let error as GitError {
            throw ToolError("Could not create \(branch): \(error.message)")
        }
        let at = created.target.map { String($0.description.prefix(7)) } ?? start
        guard checkout else { return ToolOutput(text: "Created \(branch) at \(at).") }
        do {
            try await repository.checkout(branch: branch)
        } catch let error as GitError {
            throw ToolError("Created \(branch) at \(at) but did not switch to it: \(error.message). "
                            + "Uncommitted changes conflict with it; commit or stash them, then switch.")
        }
        return ToolOutput(text: "Created and switched to \(branch) at \(at).")
    }
}

struct GitOpenPullRequestDraftTool: AgentTool {
    let root: URL
    let services: GitServices

    let name = "git_open_pull_request_draft"
    let description = """
    Open a draft pull request (GitHub) or draft merge request (GitLab) from the current branch, pushing the branch first \
    if the remote does not have its commits. Uses the account signed in for the repository's remote. Commit your \
    changes before calling it. Returns the request's number and URL.
    """
    let promptSnippet = "push the current branch and open a draft pull/merge request"
    var parameters: JSONValue {
        ["type": "object",
         "properties": [
            "title": ["type": "string", "description": "The request's title"],
            "body": ["type": "string", "description": "The description (Markdown)"],
            "base": ["type": "string", "description": "The branch to merge into (default: the repository's default branch)"],
         ],
         "required": ["title"]]
    }

    func effect(of arguments: JSONValue, context: ToolContext) -> ToolEffect {
        let title = arguments["title"]?.stringValue ?? ""
        let base = arguments["base"]?.stringValue.map { " into \($0)" } ?? ""
        return .shell(command: "git push -u (if needed) && open draft pull request \"\(title)\"\(base)", commandClass: .network)
    }

    func execute(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let args = ToolArguments(arguments, tool: name)
        let title = try args.string("title")
        let body = try args.optionalString("body") ?? ""
        let base = try args.optionalString("base")
        let repository = try GitAgentTools.repository(at: root)
        return try await Self.open(repository: repository, services: services, title: title, body: body, base: base)
    }

    @MainActor
    static func open(repository: GitRepository, services: GitServices, title: String, body: String, base: String?) async throws -> ToolOutput {
        let sourceControl = SourceControlModel(repository: repository, services: services)
        await sourceControl.refresh()
        guard sourceControl.currentBranch != nil else { throw ToolError("HEAD is detached; create or switch to a branch first.") }
        if !sourceControl.staged.isEmpty || sourceControl.unstaged.contains(where: { $0.unstaged != .untracked }) {
            throw ToolError("The working tree has uncommitted changes. Commit them (or stash them) before opening a request.")
        }
        let hosting = RepositoryHosting(repository: repository, services: services)
        await hosting.resolve()
        switch hosting.state {
        case .ready: break
        case .noForgeRemote: throw ToolError("The repository has no GitHub or GitLab remote.")
        case .notSignedIn(let hosts): throw ToolError("No account is signed in for \(hosts.joined(separator: ", ")). Ask the user to sign in under Source Control › Accounts.")
        case .failed(let message): throw ToolError(message)
        case .loading: throw ToolError("Could not read the repository's remotes.")
        }
        let composer = PullRequestComposerModel(sourceControl: sourceControl, hosting: hosting)
        composer.title = title
        composer.body = body
        composer.isDraft = true
        if let base { composer.targetBranch = base }
        await composer.prepare()
        if let error = composer.errorMessage { throw ToolError(error) }
        guard composer.targetBranch != sourceControl.currentBranch?.name else {
            throw ToolError("The current branch is the base branch \(composer.targetBranch); create a branch for the change first.")
        }
        guard let pr = await composer.submit() else {
            throw ToolError(composer.errorMessage ?? "The request could not be opened.")
        }
        let kind = hosting.kind ?? .github
        var text = "Opened draft \(kind.requestNoun) \(kind.requestSigil)\(pr.number): \(pr.title)"
        if let url = pr.webURL { text += "\n\(url.absoluteString)" }
        if let warning = composer.errorMessage { text += "\nNote: \(warning)" }
        return ToolOutput(text: text)
    }
}
