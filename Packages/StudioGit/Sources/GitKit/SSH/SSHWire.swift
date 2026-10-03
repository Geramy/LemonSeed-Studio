import Foundation

/// SSH wire encoding (RFC 4251) helpers.
enum SSHWire {
    static func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func string(_ data: Data) -> Data {
        uint32(UInt32(data.count)) + data
    }

    static func string(_ text: String) -> Data {
        string(Data(text.utf8))
    }

    /// A positive multiple-precision integer from big-endian magnitude bytes.
    static func mpint(_ magnitude: Data) -> Data {
        var bytes = Data(magnitude.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return string(bytes)
    }

    /// Reads SSH wire values sequentially.
    struct Reader {
        private let data: Data
        private(set) var offset: Int

        init(_ data: Data) {
            self.data = Data(data)
            self.offset = 0
        }

        var isAtEnd: Bool { offset >= data.count }

        mutating func uint32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw SSHKeyError.malformed("truncated uint32") }
            let value = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            offset += 4
            return value
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw SSHKeyError.malformed("truncated data") }
            defer { offset += count }
            return data[offset..<offset + count]
        }

        mutating func string() throws -> Data {
            let length = Int(try uint32())
            return Data(try bytes(length))
        }

        mutating func text() throws -> String {
            String(decoding: try string(), as: UTF8.self)
        }
    }
}

public enum SSHKeyError: Error, Sendable, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupportedKeyType(String)
    case encryptedKeyNeedsLibssh2
    case secureEnclaveUnavailable
    case notFound

    public var description: String {
        switch self {
        case .malformed(let why): return "Malformed SSH key: \(why)"
        case .unsupportedKeyType(let type): return "Unsupported SSH key type \(type)"
        case .encryptedKeyNeedsLibssh2: return "Passphrase-protected keys are used through libssh2 directly"
        case .secureEnclaveUnavailable: return "The Secure Enclave is not available on this device"
        case .notFound: return "SSH key not found"
        }
    }
}
