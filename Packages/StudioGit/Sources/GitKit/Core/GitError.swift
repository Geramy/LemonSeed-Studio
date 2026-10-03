public import Foundation
import Clibgit2

/// An error from libgit2 or from GitKit itself.
public struct GitError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public enum Code: Sendable, Equatable {
        case generic
        case notFound
        case exists
        case ambiguous
        case bufferTooSmall
        case user
        case bareRepository
        case unbornBranch
        case unmerged
        case nonFastForward
        case invalidSpec
        case conflict
        case locked
        case modified
        case authentication
        case certificate
        case applied
        case peel
        case endOfFile
        case invalid
        case uncommitted
        case directory
        case mergeConflict
        case passthrough
        case iterationOver
        case retry
        case mismatch
        case indexDirty
        case applyFailed
        case owner
        case timeout
        case unchanged
        case notSupported
        case readOnly
        /// The operation was cancelled (Task cancellation or a callback).
        case cancelled
        /// GitKit refused the request before calling libgit2.
        case invalidArgument
        /// A push was rejected by the remote for one or more references.
        case pushRejected
        case other(Int32)
    }

    public var code: Code
    /// libgit2's error class (GIT_ERROR_*), 0 when not from libgit2.
    public var errorClass: Int32
    public var message: String
    /// The GitKit operation that failed, e.g. "git_remote_fetch".
    public var operation: String

    public init(code: Code, message: String, operation: String = "", errorClass: Int32 = 0) {
        self.code = code
        self.message = message
        self.operation = operation
        self.errorClass = errorClass
    }

    public var description: String {
        operation.isEmpty ? message : "\(operation): \(message)"
    }

    public var errorDescription: String? { message }

    static func cancelled(_ operation: String = "") -> GitError {
        GitError(code: .cancelled, message: "The operation was cancelled.", operation: operation)
    }

    static func invalid(_ message: String, _ operation: String = "") -> GitError {
        GitError(code: .invalidArgument, message: message, operation: operation)
    }

    /// Builds an error from a libgit2 return code and `git_error_last()`.
    static func from(_ result: Int32, operation: String) -> GitError {
        var message = "libgit2 error \(result)"
        var klass: Int32 = 0
        if let last = git_error_last(), let text = last.pointee.message {
            message = String(cString: text)
            klass = last.pointee.klass
        }
        return GitError(code: Code(result), message: message, operation: operation, errorClass: klass)
    }
}

extension GitError.Code {
    init(_ raw: Int32) {
        switch raw {
        case GIT_ERROR.rawValue: self = .generic
        case GIT_ENOTFOUND.rawValue: self = .notFound
        case GIT_EEXISTS.rawValue: self = .exists
        case GIT_EAMBIGUOUS.rawValue: self = .ambiguous
        case GIT_EBUFS.rawValue: self = .bufferTooSmall
        case GIT_EUSER.rawValue: self = .user
        case GIT_EBAREREPO.rawValue: self = .bareRepository
        case GIT_EUNBORNBRANCH.rawValue: self = .unbornBranch
        case GIT_EUNMERGED.rawValue: self = .unmerged
        case GIT_ENONFASTFORWARD.rawValue: self = .nonFastForward
        case GIT_EINVALIDSPEC.rawValue: self = .invalidSpec
        case GIT_ECONFLICT.rawValue: self = .conflict
        case GIT_ELOCKED.rawValue: self = .locked
        case GIT_EMODIFIED.rawValue: self = .modified
        case GIT_EAUTH.rawValue: self = .authentication
        case GIT_ECERTIFICATE.rawValue: self = .certificate
        case GIT_EAPPLIED.rawValue: self = .applied
        case GIT_EPEEL.rawValue: self = .peel
        case GIT_EEOF.rawValue: self = .endOfFile
        case GIT_EINVALID.rawValue: self = .invalid
        case GIT_EUNCOMMITTED.rawValue: self = .uncommitted
        case GIT_EDIRECTORY.rawValue: self = .directory
        case GIT_EMERGECONFLICT.rawValue: self = .mergeConflict
        case GIT_PASSTHROUGH.rawValue: self = .passthrough
        case GIT_ITEROVER.rawValue: self = .iterationOver
        case GIT_RETRY.rawValue: self = .retry
        case GIT_EMISMATCH.rawValue: self = .mismatch
        case GIT_EINDEXDIRTY.rawValue: self = .indexDirty
        case GIT_EAPPLYFAIL.rawValue: self = .applyFailed
        case GIT_EOWNER.rawValue: self = .owner
        case GIT_TIMEOUT.rawValue: self = .timeout
        case GIT_EUNCHANGED.rawValue: self = .unchanged
        case GIT_ENOTSUPPORTED.rawValue: self = .notSupported
        case GIT_EREADONLY.rawValue: self = .readOnly
        default: self = .other(raw)
        }
    }
}

/// Throws a `GitError` for a negative libgit2 return code.
@discardableResult
@inline(__always)
func check(_ result: Int32, _ operation: @autoclosure () -> String) throws(GitError) -> Int32 {
    if result < 0 { throw GitError.from(result, operation: operation()) }
    return result
}
