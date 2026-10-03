import Foundation
import Testing
@testable import GitKit

/// SSH clone and push against a local OpenSSH server started by
/// scripts/ssh-test-server.sh. These exercise libssh2 calling back into
/// GitKit's in-process signers (the path Secure Enclave keys use).
enum SSHTestServer {
    struct Config: Sendable {
        var dir: String
        var port: String
        var user: String
        var url: String { "ssh://\(user)@127.0.0.1:\(port)\(dir)/server.git" }

        /// Adds a public key to the server's authorized_keys.
        func authorize(_ key: any SSHSigningKey) throws {
            let file = URL(fileURLWithPath: dir).appending(path: "authorized_keys")
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((key.openSSHPublicKey(comment: "gitkit-test") + "\n").utf8))
        }
    }

    static let config: Config? = {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["STUDIOGIT_SSH_TEST_DIR"], let port = env["STUDIOGIT_SSH_TEST_PORT"],
              let user = env["STUDIOGIT_SSH_TEST_USER"] else { return nil }
        return Config(dir: dir, port: port, user: user)
    }()
}

@Suite(.enabled(if: SSHTestServer.config != nil, "run through scripts/ssh-test-server.sh"), .serialized)
struct SSHTransportTests {
    let server = SSHTestServer.config!
    let trust = KnownHostsStore(file: nil, confirmNewHost: { _, _, _ in true })

    @Test(arguments: [SSHKeyKind.ed25519, .p256])
    func pushAndCloneWithInProcessSigner(kind: SSHKeyKind) async throws {
        let key: any SSHSigningKey = kind == .ed25519 ? Ed25519SSHKey() : P256SSHKey()
        try server.authorize(key)
        let network = NetworkContext(credentials: StaticCredentialProvider(.sshKey(username: server.user, key: key)), trust: trust)

        let (dir, repo) = try await makeRepo(["README.md": "over ssh (\(kind.rawValue))\n"], branch: "ssh-\(kind.rawValue)")
        _ = dir
        try await repo.addRemote("origin", url: server.url)
        try await repo.push(options: PushOptions(setUpstream: true), network: network)

        let dest = TempDir("ssh-clone")
        let clone = try await GitRepository.clone(
            CloneOptions(url: server.url, destination: dest.url, branch: "ssh-\(kind.rawValue)"), network: network)
        #expect(try dest.read("README.md") == "over ssh (\(kind.rawValue))\n")
        #expect(try await clone.currentBranch()?.upstream == "origin/ssh-\(kind.rawValue)")
    }

    @Test func libssh2ParsesPrivateKeyPEM() async throws {
        let store = SSHKeyStore(store: InMemorySecretStore())
        let info = try await store.generate(.ed25519, label: "pem")
        try server.authorize(try await store.signingKey(for: info.id))
        let pem = try await store.exportOpenSSHPrivateKey(info.id)
        let credential = GitCredential.sshPrivateKey(username: server.user, publicKey: info.openSSHPublicKey, privateKey: pem, passphrase: nil)
        let (_, repo) = try await makeRepo(["pem.txt": "pem\n"], branch: "pem")
        try await repo.addRemote("origin", url: server.url)
        try await repo.push(network: NetworkContext(credentials: StaticCredentialProvider(credential), trust: trust))
    }

    /// Leaves SSH-signed commits (Ed25519 and P-256) in $DIR/signed-*; the
    /// script then checks them with `git verify-commit` (OpenSSH's verifier).
    @Test(arguments: [SSHKeyKind.ed25519, .p256])
    func signedCommitForOpenSSHVerification(kind: SSHKeyKind) async throws {
        let key: any SSHSigningKey = kind == .ed25519 ? Ed25519SSHKey() : P256SSHKey()
        let dir = URL(fileURLWithPath: server.dir).appending(path: "signed-\(kind.rawValue)")
        let repo = try GitRepository.create(at: dir)
        try Data("signed\n".utf8).write(to: dir.appending(path: "file.txt"))
        try await repo.stageAll()
        try await repo.commit(message: "Signed with \(kind.rawValue)", options: CommitOptions(author: testAuthor, signer: SSHCommitSigner(key: key)))
        let allowed = "\(testAuthor.email) \(key.openSSHPublicKey())\n"
        try Data(allowed.utf8).write(to: dir.appending(path: "allowed_signers"))
    }

    @Test func unauthorizedKeyFails() async throws {
        let (_, repo) = try await makeRepo(branch: "nope")
        try await repo.addRemote("origin", url: server.url)
        let network = NetworkContext(credentials: StaticCredentialProvider(.sshKey(username: server.user, key: Ed25519SSHKey())), trust: trust)
        do {
            try await repo.push(network: network)
            Issue.record("push should fail")
        } catch let error as GitError {
            #expect(error.code == .authentication, "\(error)")
        }
    }

    @Test func untrustedHostIsRejected() async throws {
        let (_, repo) = try await makeRepo(branch: "untrusted")
        try await repo.addRemote("origin", url: server.url)
        let key = Ed25519SSHKey()
        try server.authorize(key)
        let network = NetworkContext(credentials: StaticCredentialProvider(.sshKey(username: server.user, key: key)),
                                     trust: KnownHostsStore(file: nil))
        do {
            try await repo.push(network: network)
            Issue.record("push should fail")
        } catch let error as GitError {
            #expect(error.code == .certificate, "\(error)")
        }
    }
}
