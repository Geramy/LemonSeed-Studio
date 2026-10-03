public import Foundation
import CryptoKit

/// SSH signatures in the `sshsig` format (OpenSSH PROTOCOL.sshsig), as
/// produced by `ssh-keygen -Y sign` and verified by Git, GitHub and GitLab.
public enum SSHSignature {
    /// Signs `message` and returns the armored signature.
    public static func sign(_ message: Data, namespace: String = "git", key: any SSHSigningKey) throws -> String {
        let hash = Data(SHA512.hash(data: message))
        let signedData = Data("SSHSIG".utf8) + SSHWire.string(namespace) + SSHWire.string(Data())
            + SSHWire.string("sha512") + SSHWire.string(hash)
        let signature = try key.signatureBlob(for: signedData)
        let blob = Data("SSHSIG".utf8) + SSHWire.uint32(1) + SSHWire.string(key.publicKeyBlob)
            + SSHWire.string(namespace) + SSHWire.string(Data()) + SSHWire.string("sha512")
            + SSHWire.string(signature)
        return armor(blob)
    }

    /// Verifies an armored `sshsig` signature made by `publicKeyBlob`.
    /// Supports ssh-ed25519 and ecdsa-sha2-nistp256.
    public static func verify(_ armored: String, message: Data, namespace: String = "git") throws -> Bool {
        let body = armored
            .replacingOccurrences(of: "-----BEGIN SSH SIGNATURE-----", with: "")
            .replacingOccurrences(of: "-----END SSH SIGNATURE-----", with: "")
            .filter { !$0.isWhitespace }
        guard let blob = Data(base64Encoded: String(body)), blob.starts(with: Data("SSHSIG".utf8)) else {
            throw SSHKeyError.malformed("not an SSH signature")
        }
        var r = SSHWire.Reader(blob.dropFirst(6))
        guard try r.uint32() == 1 else { throw SSHKeyError.malformed("sshsig version") }
        let publicKey = try r.string()
        guard try r.text() == namespace else { return false }
        _ = try r.string()
        let hashAlgorithm = try r.text()
        var sig = SSHWire.Reader(try r.string())
        let algorithm = try sig.text()
        let body2 = try sig.string()
        let hash: Data = hashAlgorithm == "sha256" ? Data(SHA256.hash(data: message)) : Data(SHA512.hash(data: message))
        let signedData = Data("SSHSIG".utf8) + SSHWire.string(namespace) + SSHWire.string(Data())
            + SSHWire.string(hashAlgorithm) + SSHWire.string(hash)
        var pk = SSHWire.Reader(publicKey)
        let keyType = try pk.text()
        guard keyType == algorithm else { return false }
        switch keyType {
        case "ssh-ed25519":
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: try pk.string())
            return key.isValidSignature(body2, for: signedData)
        case "ecdsa-sha2-nistp256":
            _ = try pk.text()
            let key = try P256.Signing.PublicKey(x963Representation: try pk.string())
            var parts = SSHWire.Reader(body2)
            func fixed(_ d: Data) -> Data {
                var d = Data(d.drop { $0 == 0 })
                while d.count < 32 { d.insert(0, at: 0) }
                return d
            }
            let raw = fixed(try parts.string()) + fixed(try parts.string())
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
            return key.isValidSignature(signature, for: signedData)
        default:
            throw SSHKeyError.unsupportedKeyType(keyType)
        }
    }

    static func armor(_ blob: Data) -> String {
        let b64 = blob.base64EncodedString()
        var lines = ["-----BEGIN SSH SIGNATURE-----"]
        var index = b64.startIndex
        while index < b64.endIndex {
            let next = b64.index(index, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[index..<next]))
            index = next
        }
        lines.append("-----END SSH SIGNATURE-----")
        return lines.joined(separator: "\n")
    }
}

/// Signs commits with an SSH key (`gpg.format = ssh`).
public struct SSHCommitSigner: CommitSigner {
    public let key: any SSHSigningKey
    public init(key: any SSHSigningKey) { self.key = key }

    public func signCommit(_ content: Data) throws -> String {
        try SSHSignature.sign(content, namespace: "git", key: key)
    }
}
