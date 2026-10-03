import Foundation
import GitKit
import Testing
@testable import Forge

@Suite struct AccountStoreTests {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "accounts-\(UUID().uuidString).json")
    }

    func gitHubStub() -> StubServer {
        let server = StubServer()
        server.on("GET", "/user") { req in
            req.headers["Authorization"] == "Bearer ghp_valid"
                ? .json(#"{"id":42,"login":"alice","name":"Alice"}"#)
                : .json(#"{"message":"Bad credentials"}"#, status: 401)
        }
        server.on("GET", "/user/orgs", json: #"[{"id":1,"login":"lemonade-sdk"}]"#)
        return server
    }

    @Test func personalAccessTokenSignInPersists() async throws {
        let server = gitHubStub()
        let secrets = InMemorySecretStore()
        let file = tempFile()
        let store = AccountStore(file: file, secrets: secrets, session: server.session)
        let account = try await store.signIn(host: .github, personalAccessToken: " ghp_valid\n")
        #expect(account.user.login == "alice")
        #expect(account.owners == ["alice", "lemonade-sdk"])
        #expect(account.method == .personalAccessToken)
        #expect(try await store.accessToken(for: account.id) == "ghp_valid")
        #expect(try secrets.accounts(service: AccountStore.tokenService) == [account.id.uuidString])

        // A new store instance reads the same accounts back.
        let reloaded = AccountStore(file: file, secrets: secrets, session: server.session)
        #expect(await reloaded.accounts().map(\.id) == [account.id])

        // Signing in again as the same user replaces, not duplicates.
        _ = try await store.signIn(host: .github, personalAccessToken: "ghp_valid")
        #expect(await store.accounts().count == 1)

        try await store.signOut(account.id)
        #expect(await store.accounts().isEmpty)
        #expect(try secrets.accounts(service: AccountStore.tokenService).isEmpty)
    }

    @Test func invalidTokenIsRejected() async throws {
        let store = AccountStore(file: nil, secrets: InMemorySecretStore(), session: gitHubStub().session)
        await #expect(throws: ForgeError.unauthorized) { try await store.signIn(host: .github, personalAccessToken: "nope") }
        await #expect(throws: ForgeError.validation("Enter a token.")) { try await store.signIn(host: .github, personalAccessToken: "  ") }
        #expect(await store.accounts().isEmpty)
    }

    @Test func multipleAccountsMatchRemotesByOwner() async throws {
        let personal = StubServer()
        personal.on("GET", "/user", json: #"{"id":1,"login":"me"}"#)
        personal.on("GET", "/user/orgs", json: "[]")
        let work = StubServer()
        work.on("GET", "/user", json: #"{"id":2,"login":"me-work"}"#)
        work.on("GET", "/user/orgs", json: #"[{"id":9,"login":"acme"}]"#)
        let secrets = InMemorySecretStore()
        // Each stub answers as a different user, so the two accounts are
        // added through two stores sharing one accounts file.
        let file = tempFile()
        let s1 = AccountStore(file: file, secrets: secrets, session: personal.session)
        let first = try await s1.signIn(host: .github, personalAccessToken: "t1")
        let s2 = AccountStore(file: file, secrets: secrets, session: work.session)
        let second = try await s2.signIn(host: .github, personalAccessToken: "t2")
        let merged = AccountStore(file: file, secrets: secrets)
        let all = await merged.accounts()
        #expect(all.count == 2)
        #expect(await merged.account(forRemoteURL: "https://github.com/acme/rocket.git")?.id == second.id)
        #expect(await merged.account(forRemoteURL: "git@github.com:me/dotfiles.git")?.id == first.id)
        #expect(await merged.account(forRemoteURL: "https://gitlab.com/acme/x.git") == nil)
    }

    @Test func gitLabOAuthTokenRefreshesWhenExpiring() async throws {
        let host = ForgeHost(kind: .gitlab, webURL: URL(string: "https://gitlab.example.com")!)
        let server = StubServer()
        server.on("GET", "/api/v4/user", json: #"{"id":5,"username":"gl"}"#)
        server.on("GET", "/api/v4/groups", json: "[]")
        server.on("POST", "/oauth/token", json: #"{"access_token":"fresh","refresh_token":"r2","expires_in":7200}"#)
        let defaults = UserDefaults(suiteName: "studio.git.tests.\(UUID().uuidString)")!
        OAuthAppSettings.setClientID("gl-client", for: host, defaults: defaults)
        let store = AccountStore(file: nil, secrets: InMemorySecretStore(), session: server.session, defaults: defaults)
        let stale = OAuthToken(accessToken: "stale", refreshToken: "r1", expiresAt: Date().addingTimeInterval(30), scopes: ["api"])
        let account = try await store.signIn(host: host, token: stale, method: .oauthDevice)
        #expect(try await store.accessToken(for: account.id) == "fresh")
        #expect(server.requests("POST", "/oauth/token").first?.form["client_id"] == "gl-client")
        // Now valid for two hours: no second refresh.
        #expect(try await store.accessToken(for: account.id) == "fresh")
        #expect(server.requests("POST", "/oauth/token").count == 1)
    }

    @Test func credentialProviderAnswersHTTPSAndSSH() async throws {
        let server = gitHubStub()
        let store = AccountStore(file: nil, secrets: InMemorySecretStore(), session: server.session)
        _ = try await store.signIn(host: .github, personalAccessToken: "ghp_valid")
        let keys = SSHKeyStore(store: InMemorySecretStore())
        let key = try await keys.generate(.ed25519, label: "ipad")
        let provider = ForgeCredentialProvider(accounts: store, sshKeys: keys)

        let https = CredentialRequest(url: "https://github.com/lemonade-sdk/amdgpu_mtopg.git", host: "github.com",
                                      usernameFromURL: nil, allowed: .userPassword, attempt: 1)
        guard case .userPassword(let user, let password)? = try await provider.credential(for: https) else {
            Issue.record("expected a token"); return
        }
        #expect(user == "alice" && password == "ghp_valid")
        var third = https
        third.attempt = 3
        #expect(try await provider.credential(for: third) == nil)

        let ssh = CredentialRequest(url: "git@github.com:lemonade-sdk/amdgpu_mtopg.git", host: "github.com",
                                    usernameFromURL: "git", allowed: .sshKey, attempt: 1)
        guard case .sshKey(let sshUser, let signer)? = try await provider.credential(for: ssh) else {
            Issue.record("expected an SSH key"); return
        }
        #expect(sshUser == "git")
        #expect(signer.publicKeyBlob == key.publicKeyBlob)

        let unknown = CredentialRequest(url: "https://example.com/a/b.git", host: "example.com", usernameFromURL: nil, allowed: .userPassword, attempt: 1)
        #expect(try await provider.credential(for: unknown) == nil)
    }

    @Test func hostAndOwnerParsing() {
        #expect(AccountStore.hostAndOwner(of: "https://github.com/o/r.git")! == ("github.com", "o"))
        #expect(AccountStore.hostAndOwner(of: "git@gitlab.com:group/sub/r.git")! == ("gitlab.com", "group"))
        #expect(AccountStore.hostAndOwner(of: "ssh://git@git.example.com:2222/o/r.git")! == ("git.example.com", "o"))
    }

    @Test func repositoryRemembersAccount() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "acct-\(UUID().uuidString)")
        let repo = try GitRepository.create(at: dir)
        let id = UUID()
        try await repo.setForgeAccount(id)
        #expect(try await repo.forgeAccount() == id)
        try await repo.setForgeAccount(nil)
        #expect(try await repo.forgeAccount() == nil)
    }
}

extension GitCredential: Equatable {
    static func == (lhs: GitCredential, rhs: GitCredential) -> Bool {
        switch (lhs, rhs) {
        case let (.userPassword(a, b), .userPassword(c, d)): return a == c && b == d
        case let (.username(a), .username(b)): return a == b
        case let (.sshKey(a, k1), .sshKey(b, k2)): return a == b && k1.publicKeyBlob == k2.publicKeyBlob
        default: return false
        }
    }
}
