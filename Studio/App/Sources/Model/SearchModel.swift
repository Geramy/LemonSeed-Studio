import Foundation
import Observation
import StudioCore

/// The Search sidebar's state: query, options, streamed results.
@MainActor
@Observable
final class SearchModel {
    let root: URL
    var query = ""
    var isRegex = false
    var caseSensitive = false
    var wholeWord = false
    var include = ""
    var exclude = ""
    var showsFilters = false
    /// Incremented to ask the search field to take focus.
    var focusRequest = 0

    private(set) var results: [SearchFileResult] = []
    private(set) var summary: SearchSummary?
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    var collapsed: Set<String> = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    init(root: URL) {
        self.root = root
    }

    var totalMatches: Int { results.reduce(0) { $0 + $1.matches.count } }

    func makeQuery() -> SearchQuery {
        SearchQuery(query, isRegex: isRegex, caseSensitivity: caseSensitive ? .sensitive : .smart, wholeWord: wholeWord,
                    includeGlobs: SearchQuery.globs(from: include), excludeGlobs: SearchQuery.globs(from: exclude))
    }

    /// Re-runs shortly after typing stops.
    func scheduleRun() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            run()
        }
    }

    func run() {
        task?.cancel()
        errorMessage = nil
        guard !query.isEmpty else {
            results = []
            summary = nil
            isSearching = false
            return
        }
        let query = makeQuery()
        do { _ = try SearchMatcher(query) } catch {
            errorMessage = error.localizedDescription
            results = []
            summary = nil
            return
        }
        isSearching = true
        results = []
        summary = nil
        let root = root
        task = Task {
            var batch: [SearchFileResult] = []
            var lastFlush = Date()
            do {
                for try await event in WorkspaceSearch.search(query, in: root) {
                    switch event {
                    case .file(let result):
                        batch.append(result)
                        if Date().timeIntervalSince(lastFlush) > 0.08 {
                            results = Self.sorted(results + batch)
                            batch.removeAll()
                            lastFlush = Date()
                        }
                    case .finished(let finished):
                        results = Self.sorted(results + batch)
                        batch.removeAll()
                        summary = finished
                    }
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            if !Task.isCancelled { isSearching = false }
        }
    }

    func cancel() {
        task?.cancel()
        debounce?.cancel()
        isSearching = false
    }

    func clear() {
        cancel()
        query = ""
        results = []
        summary = nil
        errorMessage = nil
    }

    private static func sorted(_ results: [SearchFileResult]) -> [SearchFileResult] {
        results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
