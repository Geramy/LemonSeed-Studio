public import Foundation
import Clibgit2

/// A SHA-1 object id (20 bytes), stored inline.
public struct ObjectID: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    private var a: UInt64
    private var b: UInt64
    private var c: UInt32

    init(_ oid: git_oid) {
        var copy = oid
        (a, b, c) = withUnsafeBytes(of: &copy.id) { raw in
            (raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
             raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
             raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
        }
    }

    init(_ pointer: UnsafePointer<git_oid>) { self.init(pointer.pointee) }

    /// Parses a full 40-character hex id.
    public init?(hex: String) {
        guard hex.utf8.count == 40 else { return nil }
        var oid = git_oid()
        guard git_oid_fromstr(&oid, hex) == 0 else { return nil }
        self.init(oid)
    }

    var oid: git_oid {
        var oid = git_oid()
        withUnsafeMutableBytes(of: &oid.id) { raw in
            raw.storeBytes(of: a, toByteOffset: 0, as: UInt64.self)
            raw.storeBytes(of: b, toByteOffset: 8, as: UInt64.self)
            raw.storeBytes(of: c, toByteOffset: 16, as: UInt32.self)
        }
        return oid
    }

    public var bytes: [UInt8] {
        var o = oid
        return withUnsafeBytes(of: &o.id) { Array($0.prefix(20)) }
    }

    public var hex: String {
        var out = ""
        out.reserveCapacity(40)
        for byte in bytes {
            out.append(Self.digits[Int(byte >> 4)])
            out.append(Self.digits[Int(byte & 0xF)])
        }
        return out
    }

    /// The abbreviated form shown in the UI (7 characters).
    public var short: String { String(hex.prefix(7)) }
    public var description: String { hex }
    public var isZero: Bool { a == 0 && b == 0 && c == 0 }
    public static let zero = ObjectID(git_oid())

    public static func < (lhs: ObjectID, rhs: ObjectID) -> Bool { lhs.hex < rhs.hex }

    private static let digits = Array("0123456789abcdef")

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let id = ObjectID(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad object id \(hex)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Author or committer identity with a timestamp.
public struct Signature: Hashable, Sendable, Codable {
    public var name: String
    public var email: String
    public var date: Date
    /// Offset from UTC in minutes.
    public var timeZoneOffsetMinutes: Int

    public init(name: String, email: String, date: Date = Date(), timeZone: TimeZone = .current) {
        self.name = name
        self.email = email
        self.date = date
        self.timeZoneOffsetMinutes = timeZone.secondsFromGMT(for: date) / 60
    }

    public init(name: String, email: String, date: Date, timeZoneOffsetMinutes: Int) {
        self.name = name
        self.email = email
        self.date = date
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
    }

    init(_ sig: UnsafePointer<git_signature>) {
        name = sig.pointee.name.map { String(cString: $0) } ?? ""
        email = sig.pointee.email.map { String(cString: $0) } ?? ""
        date = Date(timeIntervalSince1970: TimeInterval(sig.pointee.when.time))
        timeZoneOffsetMinutes = Int(sig.pointee.when.offset)
    }

    /// Creates a libgit2 signature; the caller frees it with git_signature_free.
    func makeGitSignature() throws -> UnsafeMutablePointer<git_signature> {
        var out: UnsafeMutablePointer<git_signature>?
        try check(git_signature_new(&out, name, email, git_time_t(date.timeIntervalSince1970), Int32(timeZoneOffsetMinutes)),
                  "git_signature_new")
        guard let out else { throw GitError.invalid("could not create signature") }
        return out
    }
}

/// The repository's in-progress operation (from `git_repository_state`).
public enum RepositoryState: String, Sendable, Codable {
    case none
    case merge
    case revert
    case revertSequence
    case cherryPick
    case cherryPickSequence
    case bisect
    case rebase
    case rebaseInteractive
    case rebaseMerge
    case applyMailbox
    case applyMailboxOrRebase

    init(_ raw: Int32) {
        switch UInt32(bitPattern: raw) {
        case GIT_REPOSITORY_STATE_MERGE.rawValue: self = .merge
        case GIT_REPOSITORY_STATE_REVERT.rawValue: self = .revert
        case GIT_REPOSITORY_STATE_REVERT_SEQUENCE.rawValue: self = .revertSequence
        case GIT_REPOSITORY_STATE_CHERRYPICK.rawValue: self = .cherryPick
        case GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE.rawValue: self = .cherryPickSequence
        case GIT_REPOSITORY_STATE_BISECT.rawValue: self = .bisect
        case GIT_REPOSITORY_STATE_REBASE.rawValue: self = .rebase
        case GIT_REPOSITORY_STATE_REBASE_INTERACTIVE.rawValue: self = .rebaseInteractive
        case GIT_REPOSITORY_STATE_REBASE_MERGE.rawValue: self = .rebaseMerge
        case GIT_REPOSITORY_STATE_APPLY_MAILBOX.rawValue: self = .applyMailbox
        case GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE.rawValue: self = .applyMailboxOrRebase
        default: self = .none
        }
    }

    /// True while a merge, rebase, cherry-pick or revert waits for the user.
    public var isInProgress: Bool { self != .none }
}

/// The file mode stored in trees and the index.
public enum FileMode: UInt32, Sendable, Codable {
    case unreadable = 0
    case tree = 0o040000
    case blob = 0o100644
    case blobExecutable = 0o100755
    case link = 0o120000
    case commit = 0o160000
}

// MARK: - C string helpers

extension String {
    init?(gitCString pointer: UnsafePointer<CChar>?) {
        guard let pointer else { return nil }
        self.init(cString: pointer)
    }
}

/// A git_strarray holding malloc'd copies of Swift strings. Call `free()`
/// (usually in a `defer`) once libgit2 no longer needs it.
struct CStringArray {
    private(set) var array: git_strarray

    init(_ strings: [String]) {
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: max(strings.count, 1))
        for (i, s) in strings.enumerated() { buffer[i] = strdup(s) }
        array = git_strarray(strings: buffer, count: strings.count)
    }

    var isEmpty: Bool { array.count == 0 }

    func free() {
        guard let strings = array.strings else { return }
        for i in 0..<array.count { Foundation.free(strings[i]) }
        strings.deallocate()
    }
}

extension git_strarray {
    var swiftStrings: [String] {
        guard let strings else { return [] }
        return (0..<count).compactMap { String(gitCString: strings[$0]) }
    }
}

extension git_buf {
    /// Copies the buffer into Data and frees it.
    mutating func takeData() -> Data {
        defer { git_buf_dispose(&self) }
        guard let ptr else { return Data() }
        return Data(bytes: ptr, count: size)
    }

    mutating func takeString() -> String {
        String(decoding: takeData(), as: UTF8.self)
    }
}
