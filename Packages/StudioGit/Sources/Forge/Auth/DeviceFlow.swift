public import Foundation

/// What the user sees on the sign-in screen.
public struct DeviceAuthorization: Codable, Sendable, Hashable {
    public var deviceCode: String
    /// The short code the user types (e.g. `WDJB-MJHT`).
    public var userCode: String
    /// Where the user types it.
    public var verificationURI: URL
    /// The same page with the code filled in, when the forge offers one.
    public var verificationURIComplete: URL?
    public var expiresAt: Date
    /// Seconds between polls.
    public var interval: Int

    public init(deviceCode: String, userCode: String, verificationURI: URL, verificationURIComplete: URL? = nil,
                expiresAt: Date, interval: Int = 5) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

/// An OAuth access token (and, for GitLab, a refresh token).
public struct OAuthToken: Codable, Sendable, Hashable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scopes: [String]

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scopes: [String] = []) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    /// True when the token expires within `margin`.
    public func isExpiring(within margin: TimeInterval = 120, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < margin
    }
}

/// OAuth 2.0 device authorization grant (RFC 8628) for GitHub and GitLab
/// (17.9+, or 17.2–17.8 with the feature flag). No client secret and no
/// redirect URI: the app shows a code, the user approves it in a browser.
public struct DeviceFlow: Sendable {
    public var host: ForgeHost
    public var clientID: String
    public var scopes: [String]
    public var session: URLSession
    /// Injected for tests; defaults to `Task.sleep`.
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(host: ForgeHost, clientID: String, scopes: [String]? = nil, session: URLSession = .shared,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.host = host
        self.clientID = clientID
        self.scopes = scopes ?? host.defaultScopes
        self.session = session
        self.sleep = sleep
    }

    private struct Reply: Decodable {
        var deviceCode: String?
        var userCode: String?
        var verificationUri: String?
        var verificationUriComplete: String?
        var expiresIn: Int?
        var interval: Int?
        var accessToken: String?
        var refreshToken: String?
        var scope: String?
        var error: String?
        var errorDescription: String?
    }

    /// Step 1: request a device and user code.
    public func start() async throws -> DeviceAuthorization {
        let (status, reply) = try await post(host.deviceAuthorizationURL, [
            "client_id": clientID,
            "scope": scopes.joined(separator: " "),
        ])
        if status == 404 { throw ForgeError.deviceFlowUnsupported }
        if let error = reply?.error {
            if error == "unsupported_grant_type" || error == "invalid_grant" { throw ForgeError.deviceFlowUnsupported }
            throw ForgeError.validation(reply?.errorDescription ?? error)
        }
        guard (200..<300).contains(status), let reply, let device = reply.deviceCode, let user = reply.userCode,
              let uri = reply.verificationUri.flatMap(URL.init(string:)) else {
            throw ForgeError.http(status: status, message: "device authorization failed")
        }
        return DeviceAuthorization(
            deviceCode: device, userCode: user, verificationURI: uri,
            verificationURIComplete: reply.verificationUriComplete.flatMap(URL.init(string:)),
            expiresAt: Date().addingTimeInterval(TimeInterval(reply.expiresIn ?? 900)),
            interval: max(reply.interval ?? 5, 1))
    }

    /// Step 2: poll until the user approves, denies, or the code expires.
    /// Cancelling the Task stops polling.
    public func waitForToken(_ authorization: DeviceAuthorization) async throws -> OAuthToken {
        var interval = authorization.interval
        while true {
            try await sleep(.seconds(interval))
            try Task.checkCancellation()
            if Date() > authorization.expiresAt { throw ForgeError.authorizationExpired }
            let (status, reply) = try await post(host.tokenURL, [
                "client_id": clientID,
                "device_code": authorization.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let reply, let token = reply.accessToken {
                return OAuthToken(accessToken: token, refreshToken: reply.refreshToken,
                                  expiresAt: reply.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                                  scopes: (reply.scope ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
            }
            switch reply?.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw ForgeError.authorizationExpired
            case "access_denied": throw ForgeError.authorizationDenied
            case let other?: throw ForgeError.validation(reply?.errorDescription ?? other)
            case nil: throw ForgeError.http(status: status, message: "unexpected token response")
            }
        }
    }

    /// Exchanges a refresh token (GitLab tokens expire after two hours).
    public func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken else { throw ForgeError.unauthorized }
        let (status, reply) = try await post(host.tokenURL, [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        guard let reply, let access = reply.accessToken else {
            if status == 400 || status == 401 { throw ForgeError.unauthorized }
            throw ForgeError.http(status: status, message: reply?.errorDescription ?? reply?.error ?? "refresh failed")
        }
        return OAuthToken(accessToken: access, refreshToken: reply.refreshToken ?? refreshToken,
                          expiresAt: reply.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                          scopes: reply.scope.map { $0.split(separator: " ").map(String.init) } ?? token.scopes)
    }

    private func post(_ url: URL, _ form: [String: String]) async throws -> (Int, Reply?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.sorted { $0.key < $1.key }.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").utf8)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ForgeError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (status, try? decoder.decode(Reply.self, from: data))
    }
}

/// OAuth client IDs, configured per forge host.
///
/// The owner registers an OAuth app on GitHub (with "Enable Device Flow")
/// and on GitLab (non-confidential, with the device authorization grant)
/// and enters the client IDs here or in the app's Info.plist
/// (`StudioGitGitHubClientID`, `StudioGitGitLabClientID`). No client secret
/// is used or stored.
public enum OAuthAppSettings {
    public static let gitHubInfoKey = "StudioGitGitHubClientID"
    public static let gitLabInfoKey = "StudioGitGitLabClientID"

    static func defaultsKey(_ host: ForgeHost) -> String { "StudioGit.OAuthClientID.\(host.kind.rawValue).\(host.hostname)" }

    public static func clientID(for host: ForgeHost, defaults: UserDefaults = .standard, bundle: Bundle = .main) -> String? {
        if let saved = defaults.string(forKey: defaultsKey(host)), !saved.isEmpty { return saved }
        let key: String
        switch host.kind {
        case .github: key = gitHubInfoKey
        case .gitlab: key = gitLabInfoKey
        }
        // The Info.plist IDs belong to the github.com / gitlab.com apps.
        guard host == .github || host == .gitlab else { return nil }
        let value = bundle.object(forInfoDictionaryKey: key) as? String
        return value?.isEmpty == false ? value : nil
    }

    public static func setClientID(_ clientID: String?, for host: ForgeHost, defaults: UserDefaults = .standard) {
        let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: defaultsKey(host))
        } else {
            defaults.removeObject(forKey: defaultsKey(host))
        }
    }
}
