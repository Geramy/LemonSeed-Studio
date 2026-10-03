// StudioModels: Hugging Face URLs, HTTP transport and the access token.

import Foundation
import Security

public struct HubEndpoint: Sendable, Hashable {
    public var base: URL

    public init(base: URL) { self.base = base }

    public static let huggingFace = HubEndpoint(base: URL(string: "https://huggingface.co")!)

    /// `<base>/<repo>/resolve/<revision>/<path>`: the file, after a redirect
    /// to the CDN for LFS content.
    public func resolve(repository: String, revision: String, path: String) -> URL {
        var url = base.appending(path: repository).appending(path: "resolve").appending(path: revision)
        for component in path.split(separator: "/") { url.append(path: String(component)) }
        return url
    }

    public func api(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base.appending(path: "api").appending(path: path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// Whether a request to `url` may carry the token: only the endpoint's own host.
    public func mayAuthorize(_ url: URL?) -> Bool { url?.host() == base.host() }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The Hugging Face access token, for gated and private repositories.
/// Stored in the Keychain, this device only, never synced.
public struct HubTokenStore: Sendable {
    public var service: String
    public var account: String

    public init(service: String = "com.geramyloveless.LemonSeedStudio.huggingface", account: String = "token") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func token() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    public func setToken(_ token: String?) throws {
        SecItemDelete(query as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
