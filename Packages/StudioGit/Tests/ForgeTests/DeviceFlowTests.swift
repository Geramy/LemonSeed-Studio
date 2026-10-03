import Foundation
import Testing
@testable import Forge

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    func record(_ d: Duration) { lock.withLock { values.append(d) } }
    var all: [Duration] { lock.withLock { values } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

@Suite struct DeviceFlowTests {
    @Test func gitHubDeviceFlowPollsUntilApproved() async throws {
        let server = StubServer()
        server.on("POST", "/login/device/code", json: """
        {"device_code":"dev123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
        """)
        let polls = Counter()
        server.on("POST", "/login/oauth/access_token") { _ in
            switch polls.next() {
            case 1: return .json(#"{"error":"authorization_pending"}"#)
            case 2: return .json(#"{"error":"slow_down","interval":10}"#)
            default: return .json(#"{"access_token":"gho_abc","token_type":"bearer","scope":"repo,read:org"}"#)
            }
        }
        let sleeps = SleepRecorder()
        let flow = DeviceFlow(host: .github, clientID: "Iv1.client", session: server.session) { sleeps.record($0) }
        let auth = try await flow.start()
        #expect(auth.userCode == "WDJB-MJHT")
        #expect(auth.verificationURI.absoluteString == "https://github.com/login/device")
        #expect(auth.interval == 5)

        let start = try #require(server.requests("POST", "/login/device/code").first)
        #expect(start.form["client_id"] == "Iv1.client")
        #expect(start.form["scope"] == "repo read:org workflow write:public_key write:ssh_signing_key")
        #expect(start.headers["Accept"] == "application/json")

        let token = try await flow.waitForToken(auth)
        #expect(token.accessToken == "gho_abc")
        #expect(token.scopes == ["repo", "read:org"])
        #expect(sleeps.all == [.seconds(5), .seconds(5), .seconds(10)])
        let poll = try #require(server.requests("POST", "/login/oauth/access_token").first)
        #expect(poll.form["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(poll.form["device_code"] == "dev123")
    }

    @Test func gitLabDeviceFlowWithRefreshToken() async throws {
        let host = ForgeHost(kind: .gitlab, webURL: URL(string: "https://gitlab.example.com")!)
        let server = StubServer()
        server.on("POST", "/oauth/authorize_device", json: """
        {"device_code":"d","user_code":"ABCD-1234","verification_uri":"https://gitlab.example.com/oauth/device",
         "verification_uri_complete":"https://gitlab.example.com/oauth/device?user_code=ABCD-1234","expires_in":300,"interval":5}
        """)
        server.on("POST", "/oauth/token") { req in
            if req.form["grant_type"] == "refresh_token" {
                return .json(#"{"access_token":"new","refresh_token":"r2","expires_in":7200,"scope":"api"}"#)
            }
            return .json(#"{"access_token":"glo","refresh_token":"r1","expires_in":7200,"scope":"api read_user"}"#)
        }
        let flow = DeviceFlow(host: host, clientID: "abc", session: server.session) { _ in }
        let auth = try await flow.start()
        #expect(auth.verificationURIComplete?.absoluteString.contains("user_code=ABCD-1234") == true)
        let token = try await flow.waitForToken(auth)
        #expect(token.refreshToken == "r1")
        #expect(token.scopes == ["api", "read_user"])
        #expect(token.expiresAt != nil)
        #expect(!token.isExpiring())
        let refreshed = try await flow.refresh(token)
        #expect(refreshed.accessToken == "new")
        #expect(refreshed.refreshToken == "r2")
        #expect(server.requests("POST", "/oauth/token").last?.form["refresh_token"] == "r1")
    }

    @Test func oldGitLabWithoutDeviceGrant() async throws {
        let host = ForgeHost(kind: .gitlab, webURL: URL(string: "https://old.example.com")!)
        let server = StubServer()
        server.on("POST", "/oauth/authorize_device", json: "{}", status: 404)
        let flow = DeviceFlow(host: host, clientID: "abc", session: server.session) { _ in }
        await #expect(throws: ForgeError.deviceFlowUnsupported) { try await flow.start() }
    }

    @Test func deniedAndExpired() async throws {
        let server = StubServer()
        server.on("POST", "/login/oauth/access_token", json: #"{"error":"access_denied"}"#)
        let flow = DeviceFlow(host: .github, clientID: "c", session: server.session) { _ in }
        let auth = DeviceAuthorization(deviceCode: "d", userCode: "u", verificationURI: URL(string: "https://x")!,
                                       verificationURIComplete: nil, expiresAt: Date().addingTimeInterval(60), interval: 1)
        await #expect(throws: ForgeError.authorizationDenied) { try await flow.waitForToken(auth) }
        var expired = auth
        expired.expiresAt = Date().addingTimeInterval(-1)
        await #expect(throws: ForgeError.authorizationExpired) { try await flow.waitForToken(expired) }
    }

    @Test func clientIDSettings() {
        let defaults = UserDefaults(suiteName: "studio.git.tests.\(UUID().uuidString)")!
        #expect(OAuthAppSettings.clientID(for: .github, defaults: defaults) == nil)
        OAuthAppSettings.setClientID("  Iv1.abc  ", for: .github, defaults: defaults)
        #expect(OAuthAppSettings.clientID(for: .github, defaults: defaults) == "Iv1.abc")
        let ghes = ForgeHost(kind: .github, webURL: URL(string: "https://ghe.corp.example")!)
        #expect(OAuthAppSettings.clientID(for: ghes, defaults: defaults) == nil)
        OAuthAppSettings.setClientID(nil, for: .github, defaults: defaults)
        #expect(OAuthAppSettings.clientID(for: .github, defaults: defaults) == nil)
    }

    @Test func hostEndpoints() {
        #expect(ForgeHost.github.apiURL.absoluteString == "https://api.github.com")
        #expect(ForgeHost.github.graphQLURL.absoluteString == "https://api.github.com/graphql")
        let ghes = ForgeHost(kind: .github, webURL: URL(string: "https://ghe.corp.example/")!)
        #expect(ghes.apiURL.absoluteString == "https://ghe.corp.example/api/v3")
        #expect(ghes.deviceAuthorizationURL.absoluteString == "https://ghe.corp.example/login/device/code")
        #expect(ForgeHost.gitlab.apiURL.absoluteString == "https://gitlab.com/api/v4")
        #expect(ForgeHost.gitlab.tokenURL.absoluteString == "https://gitlab.com/oauth/token")
    }
}
