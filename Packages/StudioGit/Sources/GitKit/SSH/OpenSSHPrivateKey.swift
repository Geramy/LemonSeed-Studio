import Foundation

/// Reads and writes unencrypted `openssh-key-v1` private keys
/// (PROTOCOL.key in OpenSSH).
enum OpenSSHPrivateKey {
    enum Parsed {
        case ed25519(seed: Data, comment: String)
        case p256(scalar: Data, comment: String)
    }

    static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let end = "-----END OPENSSH PRIVATE KEY-----"
    static let magic = Data("openssh-key-v1\0".utf8)

    static func parse(_ pem: String) throws -> Parsed {
        guard let b = pem.range(of: begin), let e = pem.range(of: end) else {
            throw SSHKeyError.malformed("not an OpenSSH private key")
        }
        let body = pem[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)), data.starts(with: magic) else {
            throw SSHKeyError.malformed("bad base64 or magic")
        }
        var r = SSHWire.Reader(data.dropFirst(magic.count))
        let cipher = try r.text()
        let kdf = try r.text()
        _ = try r.string()
        guard cipher == "none", kdf == "none" else { throw SSHKeyError.encryptedKeyNeedsLibssh2 }
        guard try r.uint32() == 1 else { throw SSHKeyError.malformed("expected one key") }
        _ = try r.string() // public key
        var p = SSHWire.Reader(try r.string())
        guard try p.uint32() == p.uint32() else { throw SSHKeyError.malformed("check bytes differ") }
        let type = try p.text()
        switch type {
        case "ssh-ed25519":
            _ = try p.string()
            let priv = try p.string()
            guard priv.count == 64 else { throw SSHKeyError.malformed("ed25519 key length") }
            let comment = try p.text()
            return .ed25519(seed: priv.prefix(32), comment: comment)
        case "ecdsa-sha2-nistp256":
            guard try p.text() == "nistp256" else { throw SSHKeyError.malformed("curve") }
            _ = try p.string()
            var d = try p.string()
            while d.count > 32, d.first == 0 { d.removeFirst() }
            while d.count < 32 { d.insert(0, at: 0) }
            let comment = try p.text()
            return .p256(scalar: d, comment: comment)
        default:
            throw SSHKeyError.unsupportedKeyType(type)
        }
    }

    static func format(ed25519 key: Ed25519SSHKey, comment: String) -> String {
        let pub = key.privateKey.publicKey.rawRepresentation
        let priv = SSHWire.string("ssh-ed25519") + SSHWire.string(pub)
            + SSHWire.string(key.rawRepresentation + pub) + SSHWire.string(comment)
        return armor(publicBlob: key.publicKeyBlob, privateSection: priv)
    }

    static func format(p256 key: P256SSHKey, comment: String) -> String {
        let q = key.privateKey.publicKey.x963Representation
        let priv = SSHWire.string("ecdsa-sha2-nistp256") + SSHWire.string("nistp256") + SSHWire.string(q)
            + SSHWire.mpint(key.rawRepresentation) + SSHWire.string(comment)
        return armor(publicBlob: key.publicKeyBlob, privateSection: priv)
    }

    private static func armor(publicBlob: Data, privateSection: Data) -> String {
        let check = UInt32.random(in: .min ... .max)
        var section = SSHWire.uint32(check) + SSHWire.uint32(check) + privateSection
        var pad: UInt8 = 1
        while section.count % 8 != 0 { section.append(pad); pad += 1 }
        let data = magic + SSHWire.string("none") + SSHWire.string("none") + SSHWire.string(Data())
            + SSHWire.uint32(1) + SSHWire.string(publicBlob) + SSHWire.string(section)
        let b64 = data.base64EncodedString()
        var lines: [String] = [begin]
        var index = b64.startIndex
        while index < b64.endIndex {
            let next = b64.index(index, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[index..<next]))
            index = next
        }
        lines.append(end)
        return lines.joined(separator: "\n") + "\n"
    }
}
