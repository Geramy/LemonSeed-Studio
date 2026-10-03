import Foundation
public import Observation
public import GitKit

/// Commit history with graph lanes and reference labels.
@MainActor
@Observable
public final class HistoryModel {
    public let repository: GitRepository
    public private(set) var rows: [GraphRow] = []
    public private(set) var labels: [ObjectID: [ReferenceLabel]] = [:]
    public var selected: ObjectID?
    public private(set) var selectedDiff: [FileDiff] = []
    public var pathFilter = ""
    public var authorFilter = ""
    public var allBranches = true
    public var errorMessage: String?
    public private(set) var canLoadMore = false
    private let pageSize = 300

    public init(repository: GitRepository) {
        self.repository = repository
    }

    public var maxWidth: Int { rows.map(\.width).max() ?? 1 }

    public func load(more: Bool = false) async {
        do {
            var options = LogOptions()
            options.allReferences = allBranches
            options.limit = more ? rows.count + pageSize : pageSize
            options.path = pathFilter.isEmpty ? nil : pathFilter
            options.author = authorFilter.isEmpty ? nil : authorFilter
            let commits = try await repository.log(options)
            canLoadMore = commits.count == options.limit
            rows = HistoryGraph.layout(commits)
            labels = try await repository.referenceLabels()
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func select(_ id: ObjectID) async {
        selected = id
        selectedDiff = (try? await repository.diff(.commit(id))) ?? []
    }

    public func checkout(_ id: ObjectID) async {
        do { try await repository.checkout(commit: id) } catch { errorMessage = "\(error)" }
        await load()
    }

    public func cherryPick(_ id: ObjectID) async {
        do { _ = try await repository.cherryPick(id) } catch { errorMessage = "\(error)" }
        await load()
    }

    public func revert(_ id: ObjectID) async {
        do { _ = try await repository.revert(id) } catch { errorMessage = "\(error)" }
        await load()
    }

    public func createBranch(_ name: String, at id: ObjectID) async {
        do { try await repository.createBranch(name, at: id.hex) } catch { errorMessage = "\(error)" }
        await load()
    }
}
