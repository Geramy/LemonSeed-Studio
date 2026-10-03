import Foundation
import Testing
@testable import GitKit

/// Real network tests against GitHub. Skipped when github.com is unreachable
/// or STUDIOGIT_NETWORK_TESTS=0.
@Suite(.enabled(if: Network.available, "github.com unreachable or network tests disabled"))
struct NetworkTests {
    static let url = "https://github.com/lemonade-sdk/amdgpu_mtopg.git"

    @Test func shallowHTTPSClone() async throws {
        let dir = TempDir("mtopg-shallow")
        let phases = PhaseRecorder()
        let repo = try await GitRepository.clone(
            CloneOptions(url: Self.url, destination: dir.url, depth: 1),
            network: NetworkContext(progress: { phases.add($0.phase) }))
        #expect(await repo.isShallow())
        let shallowLog = try await repo.log()
        #expect(shallowLog.count == 1, "\(shallowLog.map(\.summary))")
        #expect(FileManager.default.fileExists(atPath: dir.url.appending(path: "README.md").path))
        let branch = try #require(try await repo.currentBranch())
        #expect(branch.upstream == "origin/\(branch.name)")
        #expect(phases.all.contains(.receiving))
        #expect(try await repo.status().isEmpty)
    }

    @Test func resumableFullCloneDeepensShallowBase() async throws {
        let dir = TempDir("mtopg-full")
        let steps = StepRecorder()
        let repo = try await GitRepository.clone(
            CloneOptions(url: Self.url, destination: dir.url),
            network: NetworkContext(progress: { p in if let s = p.step { steps.add(s) } }))
        #expect(steps.all.contains("Fetching latest snapshot"))
        #expect(steps.all.contains("Fetching history"))
        #expect(await !repo.isShallow())
        #expect(try await repo.log().count > 1)
        #expect(try await repo.remoteDefaultBranch() == (try await repo.head().branch))
    }

    @Test func cancelledCloneCanBeResumed() async throws {
        let dir = TempDir("mtopg-cancel")
        let options = CloneOptions(url: Self.url, destination: dir.url)
        let started = StepRecorder()
        let task = Task {
            try await GitRepository.clone(options, network: NetworkContext(progress: { p in
                if p.step == "Fetching history" { started.add("history") }
            }))
        }
        // Cancel once the shallow base is in and the deepening fetch began.
        for _ in 0..<600 where !started.all.contains("history") {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        let outcome = await task.result
        if case .failure(let error as GitError) = outcome {
            #expect(error.code == .cancelled)
            let pending = try #require(GitRepository.pendingClone(at: dir.url))
            #expect(pending.stage == .shallowBase)
        }
        // Either way, resuming (or re-cloning into the folder) completes it.
        let repo = try await GitRepository.clone(options)
        #expect(GitRepository.pendingClone(at: dir.url) == nil)
        #expect(await !repo.isShallow())
        #expect(try await repo.status().isEmpty)
    }

    @Test func fetchUpdatesRemoteTrackingBranches() async throws {
        let dir = TempDir("mtopg-fetch")
        let repo = try await GitRepository.clone(CloneOptions(url: Self.url, destination: dir.url, depth: 1))
        let summary = try await repo.fetch(FetchOptions(depth: 1))
        #expect(summary.updates.allSatisfy { $0.reference.hasPrefix("refs/") })
        #expect(try await repo.branches(.remote).contains { $0.name.hasPrefix("origin/") })
    }

    /// SSH transport: libssh2 connects to github.com, the pinned host key is
    /// accepted, and an unregistered key is refused at authentication (not
    /// at host verification).
    @Test func sshHandshakeWithPinnedHostKey() async throws {
        let dir = TempDir("ssh-auth")
        let key = Ed25519SSHKey()
        let credentials = StaticCredentialProvider(.sshKey(username: "git", key: key))
        do {
            _ = try await GitRepository.clone(
                CloneOptions(url: "git@github.com:lemonade-sdk/amdgpu_mtopg.git", destination: dir.url, resumable: false),
                network: NetworkContext(credentials: credentials, trust: KnownHostsStore(file: nil)))
            Issue.record("an unregistered key should not authenticate")
        } catch let error as GitError {
            #expect(error.code == .authentication, "\(error)")
        }
    }

    @Test func unknownSSHHostIsRejectedWithoutConfirmation() async throws {
        let dir = TempDir("ssh-unknown")
        // github.com's pinned keys are not used for an alias host name.
        let trust = KnownHostsStore(file: nil)
        do {
            _ = try await GitRepository.clone(
                CloneOptions(url: "ssh://git@ssh.github.com:443/lemonade-sdk/amdgpu_mtopg.git", destination: dir.url, resumable: false),
                network: NetworkContext(credentials: StaticCredentialProvider(.sshKey(username: "git", key: Ed25519SSHKey())), trust: trust))
            Issue.record("unknown host should be rejected")
        } catch let error as GitError {
            #expect(error.code == .certificate, "\(error)")
        }
    }
}

enum Network {
    static let available: Bool = {
        if ProcessInfo.processInfo.environment["STUDIOGIT_NETWORK_TESTS"] == "0" { return false }
        var request = URLRequest(url: URL(string: "https://github.com")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        let semaphore = DispatchSemaphore(value: 0)
        let ok = ResultBox<Bool>()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok.set(.success((response as? HTTPURLResponse) != nil))
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        if case .success(true)? = ok.get() { return true }
        return false
    }()
}

final class StepRecorder: @unchecked Sendable {
    private var steps: [String] = []
    private let lock = NSLock()
    func add(_ s: String) { lock.withLock { steps.append(s) } }
    var all: [String] { lock.withLock { steps } }
}
