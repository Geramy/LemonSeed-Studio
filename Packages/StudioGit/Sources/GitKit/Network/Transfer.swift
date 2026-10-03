import Foundation
import Clibgit2
import Security

/// Progress of a clone, fetch, push or submodule update.
public struct TransferProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case connecting, receiving, resolving, checkingOut, packing, pushing, lfs, done
    }
    public var phase: Phase
    public var totalObjects = 0
    public var receivedObjects = 0
    public var indexedObjects = 0
    public var localObjects = 0
    public var totalDeltas = 0
    public var indexedDeltas = 0
    public var receivedBytes = 0
    /// For checkout/packing/pushing: items done and total.
    public var current = 0
    public var total = 0
    /// The latest server message ("Counting objects: ...").
    public var message: String?
    /// The step of a multi-step operation (resumable clone, submodules).
    public var step: String?

    public init(phase: Phase) { self.phase = phase }

    /// 0...1, best effort.
    public var fractionCompleted: Double {
        switch phase {
        case .receiving where totalObjects > 0:
            return Double(receivedObjects) / Double(totalObjects)
        case .resolving where totalDeltas > 0:
            return Double(indexedDeltas) / Double(totalDeltas)
        case .checkingOut, .packing, .pushing, .lfs:
            return total > 0 ? Double(current) / Double(total) : 0
        case .done:
            return 1
        default:
            return 0
        }
    }
}

public typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

/// State shared with libgit2's C callbacks during one network operation.
final class TransferContext: @unchecked Sendable {
    let credentials: any CredentialProvider
    let trust: any HostTrustEvaluator
    let progressHandler: TransferProgressHandler?

    private let lock = NSLock()
    private var cancelled = false
    private var attempts: [String: Int] = [:]
    private var keyBoxes: [SigningKeyBox] = []
    private(set) var pushRejections: [String: String] = [:]
    private(set) var updatedReferences: [(name: String, old: ObjectID?, new: ObjectID?)] = []
    private(set) var authenticationFailed = false
    private var progress = TransferProgress(phase: .connecting)
    private var lastReport = Date.distantPast
    var step: String? {
        didSet { lock.withLock { progress.step = step } }
    }

    init(credentials: any CredentialProvider, trust: any HostTrustEvaluator, progress: TransferProgressHandler?) {
        self.credentials = credentials
        self.trust = trust
        self.progressHandler = progress
    }

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    var payload: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    static func from(_ payload: UnsafeMutableRawPointer?) -> TransferContext {
        Unmanaged<TransferContext>.fromOpaque(payload!).takeUnretainedValue()
    }

    func retain(_ box: SigningKeyBox) { lock.withLock { keyBoxes.append(box) } }

    func nextAttempt(for url: String) -> Int {
        lock.withLock {
            attempts[url, default: 0] += 1
            return attempts[url]!
        }
    }

    func markAuthenticationFailed() { lock.withLock { authenticationFailed = true } }
    func recordRejection(_ ref: String, _ status: String) { lock.withLock { pushRejections[ref] = status } }
    func recordUpdate(_ name: String, _ old: ObjectID?, _ new: ObjectID?) {
        lock.withLock { updatedReferences.append((name, old, new)) }
    }

    /// Updates progress and reports it at most ~15 times a second (always
    /// for phase changes).
    func report(force: Bool = false, _ update: (inout TransferProgress) -> Void) {
        guard let handler = progressHandler else { return }
        let snapshot: TransferProgress? = lock.withLock {
            let before = progress.phase
            update(&progress)
            let now = Date()
            if force || before != progress.phase || now.timeIntervalSince(lastReport) > 0.066 {
                lastReport = now
                return progress
            }
            return nil
        }
        if let snapshot { handler(snapshot) }
    }

    /// Runs async work from a libgit2 callback thread and waits for it. The
    /// callback thread is a dedicated transfer thread, never the
    /// cooperative pool, so blocking here is safe.
    func waitFor<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> Result<T, any Error> {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.set(.success(try await work())) } catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return box.get()!
    }

    /// The callbacks every network operation installs.
    func install(into callbacks: inout git_remote_callbacks) {
        callbacks.payload = payload
        callbacks.credentials = transferCredentialsCallback
        callbacks.certificate_check = transferCertificateCallback
        callbacks.transfer_progress = transferProgressCallback
        callbacks.sideband_progress = transferSidebandCallback
        callbacks.pack_progress = transferPackCallback
        callbacks.push_transfer_progress = transferPushProgressCallback
        callbacks.push_update_reference = transferPushUpdateCallback
        callbacks.update_refs = transferUpdateRefsCallback
    }

    /// Maps a failed libgit2 call to the right error (cancellation and
    /// authentication failures get their own codes).
    func error(for result: Int32, operation: String) -> GitError {
        if isCancelled { return .cancelled(operation) }
        var error = GitError.from(result, operation: operation)
        if authenticationFailed && error.code != .certificate { error.code = .authentication }
        return error
    }
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
    private var value: Result<T, any Error>?
    private let lock = NSLock()
    func set(_ v: Result<T, any Error>) { lock.withLock { value = v } }
    func get() -> Result<T, any Error>? { lock.withLock { value } }
}

/// Keeps an SSH signing key alive while libssh2 may call back into it.
final class SigningKeyBox: @unchecked Sendable {
    let key: any SSHSigningKey
    init(_ key: any SSHSigningKey) { self.key = key }
}

/// A dedicated pool for blocking network work.
enum TransferQueue {
    static let queue = DispatchQueue(label: "studio.git.transfer", qos: .userInitiated, attributes: .concurrent)

    /// Runs `work` on the transfer queue; Task cancellation cancels `context`.
    static func run<T: Sendable>(_ context: TransferContext, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        GitRuntime.ensureInitialized()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async {
                    if context.isCancelled {
                        continuation.resume(throwing: GitError.cancelled())
                        return
                    }
                    continuation.resume(with: Result { try work() })
                }
            }
        } onCancel: {
            context.cancel()
        }
    }
}

// MARK: - C callbacks

private let transferCredentialsCallback: git_credential_acquire_cb = { out, url, usernameFromURL, allowedTypes, payload in
    let ctx = TransferContext.from(payload)
    if ctx.isCancelled { return GIT_EUSER.rawValue }
    let urlString = String(gitCString: url) ?? ""
    let user = String(gitCString: usernameFromURL)
    var allowed: CredentialRequest.Kinds = []
    if allowedTypes & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 { allowed.insert(.userPassword) }
    if allowedTypes & (GIT_CREDENTIAL_SSH_KEY.rawValue | GIT_CREDENTIAL_SSH_CUSTOM.rawValue | GIT_CREDENTIAL_SSH_MEMORY.rawValue) != 0 {
        allowed.insert(.sshKey)
    }
    if allowedTypes & GIT_CREDENTIAL_USERNAME.rawValue != 0 { allowed.insert(.username) }
    let usernameOnly = allowed == .username
    let attempt = usernameOnly ? 1 : ctx.nextAttempt(for: urlString)
    if attempt > 1 { ctx.markAuthenticationFailed() }
    if attempt > 5 {
        git_error_set_str(Int32(GIT_ERROR_NET.rawValue), "authentication failed for \(urlString)")
        return GIT_EAUTH.rawValue
    }
    let host = URL(string: urlString)?.host ?? urlString.split(separator: "@").last?.split(separator: ":").first.map(String.init)
    let request = CredentialRequest(url: urlString, host: host, usernameFromURL: user, allowed: allowed, attempt: attempt)
    let provider = ctx.credentials
    let result = ctx.waitFor { try await provider.credential(for: request) }
    guard case .success(let credential) = result, let credential else {
        ctx.markAuthenticationFailed()
        if case .failure(let error) = result {
            git_error_set_str(Int32(GIT_ERROR_NET.rawValue), "credentials: \(error.localizedDescription)")
        } else {
            git_error_set_str(Int32(GIT_ERROR_NET.rawValue), "no credentials for \(urlString)")
        }
        return GIT_EAUTH.rawValue
    }
    switch credential {
    case .userPassword(let username, let password):
        return git_credential_userpass_plaintext_new(out, username, password)
    case .username(let username):
        return git_credential_username_new(out, username)
    case .sshKey(let username, let key):
        if usernameOnly { return git_credential_username_new(out, username) }
        let box = SigningKeyBox(key)
        ctx.retain(box)
        let blob = key.publicKeyBlob
        return blob.withUnsafeBytes { raw in
            git_credential_ssh_custom_new(out, username, raw.baseAddress?.assumingMemoryBound(to: CChar.self), raw.count,
                                          sshSignCallback, Unmanaged.passUnretained(box).toOpaque())
        }
    case .sshPrivateKey(let username, let publicKey, let privateKey, let passphrase):
        if usernameOnly { return git_credential_username_new(out, username) }
        return git_credential_ssh_key_memory_new(out, username, publicKey, privateKey, passphrase)
    }
}

/// libssh2 sign callback: `*abstract` is the SigningKeyBox.
private let sshSignCallback: git_credential_sign_cb = { _, sig, sigLen, data, dataLen, abstract in
    guard let abstract, let boxPointer = abstract.pointee, let sig, let sigLen, let data else { return -1 }
    let box = Unmanaged<SigningKeyBox>.fromOpaque(boxPointer).takeUnretainedValue()
    let message = Data(bytes: data, count: dataLen)
    guard let body = try? box.key.signatureBody(for: message), let buffer = malloc(body.count) else { return -1 }
    body.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: body.count)
    sig.pointee = buffer.assumingMemoryBound(to: UInt8.self)
    sigLen.pointee = body.count
    return 0
}

private let transferCertificateCallback: git_transport_certificate_check_cb = { cert, valid, host, payload in
    let ctx = TransferContext.from(payload)
    guard let cert else { return GIT_ECERTIFICATE.rawValue }
    let hostname = String(gitCString: host) ?? ""
    switch cert.pointee.cert_type {
    case GIT_CERT_X509:
        let x509 = UnsafeRawPointer(cert).assumingMemoryBound(to: git_cert_x509.self).pointee
        guard let bytes = x509.data else { return GIT_ECERTIFICATE.rawValue }
        let der = Data(bytes: bytes, count: x509.len)
        if SystemTrust.evaluate(der: der, host: hostname) || valid != 0 { return 0 }
        let trust = ctx.trust
        let decision = ctx.waitFor { await trust.trustTLSCertificate(hostname, certificate: der) }
        if case .success(true) = decision { return 0 }
        git_error_set_str(Int32(GIT_ERROR_SSL.rawValue), "the certificate for \(hostname) is not trusted")
        return GIT_ECERTIFICATE.rawValue
    case GIT_CERT_HOSTKEY_LIBSSH2:
        let hostkey = UnsafeRawPointer(cert).assumingMemoryBound(to: git_cert_hostkey.self).pointee
        guard hostkey.type.rawValue & GIT_CERT_SSH_RAW.rawValue != 0, let raw = hostkey.hostkey else {
            git_error_set_str(Int32(GIT_ERROR_SSH.rawValue), "no raw host key from \(hostname)")
            return GIT_ECERTIFICATE.rawValue
        }
        let key = Data(bytes: raw, count: hostkey.hostkey_len)
        var reader = SSHWire.Reader(key)
        let keyType = (try? reader.text()) ?? "unknown"
        let fingerprint = SSHPublicKey.fingerprint(of: key)
        let trust = ctx.trust
        let decision = ctx.waitFor { await trust.trustSSHHost(hostname, keyType: keyType, fingerprint: fingerprint, hostKey: key) }
        if case .success(true) = decision { return 0 }
        git_error_set_str(Int32(GIT_ERROR_SSH.rawValue), "the host key of \(hostname) (\(fingerprint)) is not trusted")
        return GIT_ECERTIFICATE.rawValue
    default:
        return valid != 0 ? 0 : GIT_ECERTIFICATE.rawValue
    }
}

private let transferProgressCallback: git_indexer_progress_cb = { stats, payload in
    let ctx = TransferContext.from(payload)
    if ctx.isCancelled { return -1 }
    guard let s = stats?.pointee else { return 0 }
    ctx.report { p in
        p.phase = (s.received_objects < s.total_objects || s.total_deltas == 0) ? .receiving : .resolving
        p.totalObjects = Int(s.total_objects)
        p.receivedObjects = Int(s.received_objects)
        p.indexedObjects = Int(s.indexed_objects)
        p.localObjects = Int(s.local_objects)
        p.totalDeltas = Int(s.total_deltas)
        p.indexedDeltas = Int(s.indexed_deltas)
        p.receivedBytes = s.received_bytes
    }
    return 0
}

private let transferSidebandCallback: git_transport_message_cb = { str, len, payload in
    let ctx = TransferContext.from(payload)
    if ctx.isCancelled { return -1 }
    if let str, len > 0 {
        let text = String(decoding: UnsafeRawBufferPointer(start: str, count: Int(len)), as: UTF8.self)
        let line = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last.map(String.init)
        ctx.report { $0.message = line }
    }
    return 0
}

private let transferPackCallback: git_packbuilder_progress = { _, current, total, payload in
    let ctx = TransferContext.from(payload)
    if ctx.isCancelled { return -1 }
    ctx.report { p in
        p.phase = .packing
        p.current = Int(current)
        p.total = Int(total)
    }
    return 0
}

private let transferPushProgressCallback: git_push_transfer_progress_cb = { current, total, bytes, payload in
    let ctx = TransferContext.from(payload)
    if ctx.isCancelled { return -1 }
    ctx.report { p in
        p.phase = .pushing
        p.current = Int(current)
        p.total = Int(total)
        p.receivedBytes = bytes
    }
    return 0
}

private let transferPushUpdateCallback: git_push_update_reference_cb = { refname, status, payload in
    let ctx = TransferContext.from(payload)
    if let status {
        ctx.recordRejection(String(gitCString: refname) ?? "", String(cString: status))
    }
    return 0
}

private let transferUpdateRefsCallback: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<git_oid>?, UnsafePointer<git_oid>?, OpaquePointer?, UnsafeMutableRawPointer?) -> Int32 = { refname, a, b, _, payload in
    let ctx = TransferContext.from(payload)
    let old = a.flatMap { $0.pointee.isZero ? nil : ObjectID($0) }
    let new = b.flatMap { $0.pointee.isZero ? nil : ObjectID($0) }
    ctx.recordUpdate(String(gitCString: refname) ?? "", old, new)
    return 0
}

/// TLS evaluation against the system trust store.
enum SystemTrust {
    static func evaluate(der: Data, host: String) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return false }
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess, let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
