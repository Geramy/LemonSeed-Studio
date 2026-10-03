public import Foundation
import CryptoKit

/// A private key that can sign SSH authentication requests and SSH
/// signatures in-process. The private key material never leaves the object
/// (and for the Secure Enclave, never leaves the hardware).
public protocol SSHSigningKey: Sendable {
    /// `ssh-ed25519` or `ecdsa-sha2-nistp256`.
    var algorithm: String { get }
    /// The public key in SSH wire format.
    var publicKeyBlob: Data { get }
    /// The signature body as libssh2 expects it from a sign callback: the
    /// raw 64 bytes for ed25519, `mpint r || mpint s` for ECDSA.
    func signatureBody(for data: Data) throws -> Data
}

extension SSHSigningKey {
    /// The complete SSH signature blob: `string algorithm || string body`.
    public func signatureBlob(for data: Data) throws -> Data {
        SSHWire.string(algorithm) + SSHWire.string(try signatureBody(for: data))
    }

    /// `ssh-ed25519 AAAA... comment`.
    public func openSSHPublicKey(comment: String? = nil) -> String {
        SSHPublicKey.openSSH(algorithm: algorithm, blob: publicKeyBlob, comment: comment)
    }

    /// `SHA256:...` fingerprint as printed by `ssh-keygen -l`.
    public var fingerprint: String { SSHPublicKey.fingerprint(of: publicKeyBlob) }
}

public enum SSHPublicKey {
    public static func openSSH(algorithm: String, blob: Data, comment: String?) -> String {
        var line = "\(algorithm) \(blob.base64EncodedString())"
        if let comment, !comment.isEmpty { line += " \(comment)" }
        return line
    }

    public static func fingerprint(of blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    /// Parses `type base64 [comment]` into the algorithm and blob.
    public static func parse(_ line: String) throws -> (algorithm: String, blob: Data, comment: String?) {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let blob = Data(base64Encoded: parts[1]) else { throw SSHKeyError.malformed("not an OpenSSH public key") }
        var reader = SSHWire.Reader(blob)
        guard try reader.text() == parts[0] else { throw SSHKeyError.malformed("key type mismatch") }
        return (parts[0], blob, parts.count > 2 ? parts[2] : nil)
    }

    static func ed25519Blob(_ raw: Data) -> Data {
        SSHWire.string("ssh-ed25519") + SSHWire.string(raw)
    }

    /// `x963Representation` is the uncompressed point 0x04 || X || Y.
    static func p256Blob(x963: Data) -> Data {
        SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string("nistp256") + SSHWire.string(x963)
    }
}

// MARK: - Key implementations

public struct Ed25519SSHKey: SSHSigningKey {
    let privateKey: Curve25519.Signing.PrivateKey

    public init() { privateKey = Curve25519.Signing.PrivateKey() }
    public init(rawRepresentation: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var algorithm: String { "ssh-ed25519" }
    public var publicKeyBlob: Data { SSHPublicKey.ed25519Blob(privateKey.publicKey.rawRepresentation) }
    var rawRepresentation: Data { privateKey.rawRepresentation }

    public func signatureBody(for data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }
}

/// ECDSA P-256 with the private key in software (importable/exportable).
public struct P256SSHKey: SSHSigningKey {
    let privateKey: P256.Signing.PrivateKey

    public init() { privateKey = P256.Signing.PrivateKey() }
    public init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var algorithm: String { "ecdsa-sha2-nistp256" }
    public var publicKeyBlob: Data { SSHPublicKey.p256Blob(x963: privateKey.publicKey.x963Representation) }
    var rawRepresentation: Data { privateKey.rawRepresentation }

    public func signatureBody(for data: Data) throws -> Data {
        let raw = try privateKey.signature(for: data).rawRepresentation
        return SSHWire.mpint(raw.prefix(32)) + SSHWire.mpint(raw.suffix(32))
    }
}

/// ECDSA P-256 held by the Secure Enclave: non-exportable, bound to this
/// device. `dataRepresentation` is an opaque, device-encrypted handle.
public struct SecureEnclaveSSHKey: SSHSigningKey {
    let privateKey: SecureEnclave.P256.Signing.PrivateKey

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public init() throws {
        guard SecureEnclave.isAvailable else { throw SSHKeyError.secureEnclaveUnavailable }
        privateKey = try SecureEnclave.P256.Signing.PrivateKey()
    }

    public init(dataRepresentation: Data) throws {
        guard SecureEnclave.isAvailable else { throw SSHKeyError.secureEnclaveUnavailable }
        privateKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
    }

    public var algorithm: String { "ecdsa-sha2-nistp256" }
    public var publicKeyBlob: Data { SSHPublicKey.p256Blob(x963: privateKey.publicKey.x963Representation) }
    var dataRepresentation: Data { privateKey.dataRepresentation }

    public func signatureBody(for data: Data) throws -> Data {
        let raw = try privateKey.signature(for: data).rawRepresentation
        return SSHWire.mpint(raw.prefix(32)) + SSHWire.mpint(raw.suffix(32))
    }
}
