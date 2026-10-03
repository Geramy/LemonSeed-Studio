import Foundation
import Testing
@testable import Forge

enum LiveNetwork {
    static let available: Bool = {
        if ProcessInfo.processInfo.environment["STUDIOGIT_NETWORK_TESTS"] == "0" { return false }
        var request = URLRequest(url: URL(string: "https://api.github.com")!)
        request.timeoutInterval = 5
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse) != nil
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return ok
    }()
}

/// Unauthenticated read calls against the real APIs (skipped offline).
@Suite(.enabled(if: LiveNetwork.available, "network unavailable or disabled"))
struct LiveForgeTests {
    @Test func gitHubPublicRepository() async throws {
        let client = GitHubClient { nil }
        let repo = try await client.repository("lemonade-sdk/amdgpu_mtopg")
        #expect(repo.fullName == "lemonade-sdk/amdgpu_mtopg")
        #expect(repo.httpsCloneURL == "https://github.com/lemonade-sdk/amdgpu_mtopg.git")
        let branches = try await client.branches("lemonade-sdk/amdgpu_mtopg")
        #expect(branches.contains { $0.isDefault })
        let readme = try await client.readme("lemonade-sdk/amdgpu_mtopg")
        #expect(readme?.isEmpty == false)
    }

    @Test func gitLabPublicProject() async throws {
        let client = GitLabClient { nil }
        let repo = try await client.repository("gitlab-org/gitlab-runner")
        #expect(repo.fullName == "gitlab-org/gitlab-runner")
        #expect(repo.httpsCloneURL.hasPrefix("https://gitlab.com/"))
    }
}
