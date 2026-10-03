import Foundation
public import Observation
public import GitKit
public import Forge

/// Pull/merge request list for a repository or for the signed-in user.
@MainActor
@Observable
public final class PullRequestListModel {
    public let client: any ForgeClient
    public var filter: PullRequestFilter
    public private(set) var requests: [PullRequest] = []
    public private(set) var ciStates: [String: CIState] = [:]
    public private(set) var isLoading = false
    public var errorMessage: String?

    public init(client: any ForgeClient, filter: PullRequestFilter) {
        self.client = client
        self.filter = filter
    }

    public var title: String {
        switch filter {
        case .repository(let repo, _): return repo
        case .authoredByMe: return "Created by me"
        case .reviewRequested: return "Review requested"
        }
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            requests = try await client.pullRequests(filter)
            errorMessage = nil
            for pr in requests.prefix(20) {
                let ref = pr.headSHA ?? pr.sourceBranch
                guard !ref.isEmpty, !pr.repository.isEmpty else { continue }
                if let status = try? await client.ciStatus(pr.repository, ref: ref) { ciStates[pr.id] = status.state }
            }
        } catch {
            errorMessage = "\(error)"
        }
    }
}

/// One pull/merge request: description, files with diffs, comments, CI,
/// review and merge.
@MainActor
@Observable
public final class PullRequestDetailModel {
    public let client: any ForgeClient
    public let repository: String
    public let number: Int
    public private(set) var request: PullRequest?
    public private(set) var files: [PullRequestFile] = []
    public private(set) var comments: [PullRequestComment] = []
    public private(set) var ci: CIStatus?
    public var selectedFile: String?
    public var draftComment = ""
    public var reviewBody = ""
    public private(set) var isWorking = false
    public var errorMessage: String?
    public private(set) var notice: String?

    public init(client: any ForgeClient, repository: String, number: Int) {
        self.client = client
        self.repository = repository
        self.number = number
    }

    /// Hunks of the selected file, parsed from the forge's patch.
    public var selectedHunks: [DiffHunk] {
        guard let file = files.first(where: { $0.path == selectedFile }), let patch = file.patch else { return [] }
        return UnifiedDiff.parseHunks(patch)
    }

    public func comments(onLine line: Int, path: String) -> [PullRequestComment] {
        comments.filter { $0.path == path && $0.line == line }
    }

    public func load() async {
        do {
            async let pr = client.pullRequest(repository, number: number)
            async let files = client.pullRequestFiles(repository, number: number)
            async let comments = client.comments(repository, number: number)
            let loaded = try await pr
            request = loaded
            self.files = try await files
            self.comments = try await comments
            if selectedFile == nil { selectedFile = self.files.first?.path }
            if let ref = loaded.headSHA ?? Optional(loaded.sourceBranch), !ref.isEmpty {
                ci = try? await client.ciStatus(repository, ref: ref)
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func postComment() async {
        let body = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        await work("Comment posted") {
            try await client.addComment(repository, number: number, body: body)
            draftComment = ""
        }
    }

    public func postLineComment(_ body: String, path: String, line: DiffLine) async {
        guard let lineNumber = line.newLineNumber ?? line.oldLineNumber else { return }
        await work("Comment posted") {
            try await client.addLineComment(repository, number: number,
                                            LineCommentDraft(body: body, path: path, line: lineNumber, onRemovedLine: line.kind == .deletion))
        }
    }

    public func review(_ event: ReviewEvent) async {
        let body = reviewBody
        await work(event == .approve ? "Approved" : event == .requestChanges ? "Changes requested" : "Review posted") {
            try await client.review(repository, number: number, event: event, body: body)
            reviewBody = ""
        }
    }

    public func merge(_ method: MergeMethod) async {
        await work("Merged") { try await client.merge(repository, number: number, method: method, commitMessage: nil) }
    }

    private func work(_ success: String, _ body: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await body()
            notice = success
            await load()
        } catch {
            errorMessage = (error as? any LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// Parses unified diff text (a forge's per-file patch) into hunks.
public enum UnifiedDiff {
    public static func parseHunks(_ patch: String) -> [DiffHunk] {
        var hunks: [DiffHunk] = []
        var oldLine = 0, newLine = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                let (os, oc, ns, nc) = parseHeader(line)
                oldLine = os
                newLine = ns
                hunks.append(DiffHunk(id: hunks.count, header: line, oldStart: os, oldCount: oc, newStart: ns, newCount: nc, lines: []))
                continue
            }
            guard !hunks.isEmpty else { continue }
            var hunk = hunks.removeLast()
            if line.hasPrefix("\\") {
                if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].hasNewline = false }
            } else if line.hasPrefix("+") {
                hunk.lines.append(DiffLine(id: hunk.lines.count, kind: .addition, oldLineNumber: nil, newLineNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                hunk.lines.append(DiffLine(id: hunk.lines.count, kind: .deletion, oldLineNumber: oldLine, newLineNumber: nil, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix(" ") || (line.isEmpty && hunk.lines.count < hunk.oldCount + hunk.newCount) {
                hunk.lines.append(DiffLine(id: hunk.lines.count, kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            }
            hunks.append(hunk)
        }
        // A trailing empty split element is not a context line.
        return hunks.map { h in
            var h = h
            let expected = h.lines.filter { $0.kind != .addition }.count
            if expected > h.oldCount, let last = h.lines.last, last.kind == .context, last.text.isEmpty { h.lines.removeLast() }
            return h
        }
    }

    static func parseHeader(_ header: String) -> (Int, Int, Int, Int) {
        // @@ -a,b +c,d @@ section
        let parts = header.split(separator: " ")
        func range(_ s: Substring?) -> (Int, Int) {
            guard let s else { return (0, 0) }
            let nums = s.dropFirst().split(separator: ",").compactMap { Int($0) }
            return (nums.first ?? 0, nums.count > 1 ? nums[1] : 1)
        }
        let old = range(parts.count > 1 ? parts[1] : nil)
        let new = range(parts.count > 2 ? parts[2] : nil)
        return (old.0, old.1, new.0, new.1)
    }
}
