public import Foundation
public import Observation
public import Forge

/// The sign-in flow: pick a forge, then device flow or a personal token.
@MainActor
@Observable
public final class SignInModel {
    public enum Phase: Equatable {
        case choosing
        case requestingCode
        case waitingForApproval(DeviceAuthorization)
        case signingIn
        case signedIn(ForgeAccount)
        case failed(String)
    }

    public enum Target: Hashable, CaseIterable, Identifiable {
        case github, gitlab, gitHubEnterprise, selfHostedGitLab
        public var id: Self { self }
        public var title: String {
            switch self {
            case .github: return "GitHub"
            case .gitlab: return "GitLab.com"
            case .gitHubEnterprise: return "GitHub Enterprise"
            case .selfHostedGitLab: return "Self-hosted GitLab"
            }
        }
        public var needsURL: Bool { self == .gitHubEnterprise || self == .selfHostedGitLab }
    }

    public let accounts: AccountStore
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let session: URLSession
    public var target: Target = .github
    public var serverURL = ""
    public var personalAccessToken = ""
    public var clientIDDraft = ""
    public private(set) var phase: Phase = .choosing
    @ObservationIgnored private var flowTask: Task<Void, Never>?

    public init(accounts: AccountStore, defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.accounts = accounts
        self.defaults = defaults
        self.session = session
    }

    public var host: ForgeHost? {
        switch target {
        case .github: return .github
        case .gitlab: return .gitlab
        case .gitHubEnterprise, .selfHostedGitLab:
            var text = serverURL.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !text.contains("://") { text = "https://" + text }
            guard let url = URL(string: text), url.host != nil else { return nil }
            return ForgeHost(kind: target == .gitHubEnterprise ? .github : .gitlab, webURL: url)
        }
    }

    public var clientID: String? {
        host.flatMap { OAuthAppSettings.clientID(for: $0, defaults: defaults) }
    }

    public func saveClientID() {
        guard let host else { return }
        OAuthAppSettings.setClientID(clientIDDraft, for: host, defaults: defaults)
        clientIDDraft = ""
    }

    /// Starts the device flow; the phase moves to `.waitingForApproval`
    /// with the code to show, then to `.signedIn`.
    public func startDeviceFlow() {
        guard let host else { phase = .failed("Enter the server address."); return }
        guard let clientID else { phase = .failed(ForgeError.missingClientID(host.kind).description); return }
        flowTask?.cancel()
        phase = .requestingCode
        let flow = DeviceFlow(host: host, clientID: clientID, session: session)
        flowTask = Task {
            do {
                let authorization = try await flow.start()
                phase = .waitingForApproval(authorization)
                let token = try await flow.waitForToken(authorization)
                phase = .signingIn
                let account = try await accounts.signIn(host: host, token: token, method: .oauthDevice)
                phase = .signedIn(account)
            } catch is CancellationError {
                phase = .choosing
            } catch {
                phase = .failed((error as? any LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    public func signInWithToken() {
        guard let host else { phase = .failed("Enter the server address."); return }
        let token = personalAccessToken
        phase = .signingIn
        flowTask = Task {
            do {
                let account = try await accounts.signIn(host: host, personalAccessToken: token)
                phase = .signedIn(account)
                personalAccessToken = ""
            } catch {
                phase = .failed((error as? any LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    public func cancel() {
        flowTask?.cancel()
        flowTask = nil
        phase = .choosing
    }

    public func reset() { phase = .choosing }

    /// For previews and screenshots: show a device code without a network.
    public func showSampleCode(_ authorization: DeviceAuthorization) {
        phase = .waitingForApproval(authorization)
    }
}
