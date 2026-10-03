import Foundation
import Clibgit2

public struct Tag: Sendable, Hashable, Identifiable, Codable {
    public var name: String
    /// The commit the tag points to (annotated tags are peeled).
    public var target: ObjectID
    /// The tag object for annotated tags.
    public var tagObject: ObjectID?
    public var message: String?
    public var tagger: Signature?

    public var id: String { name }
    public var isAnnotated: Bool { tagObject != nil }
}

extension GitRepository {
    public func tags() throws -> [Tag] {
        var names = git_strarray()
        try check(git_tag_list(&names, handle), "git_tag_list")
        defer { git_strarray_dispose(&names) }
        var result: [Tag] = []
        for name in names.swiftStrings {
            if let tag = try? tag(named: name) { result.append(tag) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
    }

    public func tag(named name: String) throws -> Tag {
        var ref: OpaquePointer?
        try check(git_reference_lookup(&ref, handle, "refs/tags/\(name)"), "git_reference_lookup(\(name))")
        defer { git_reference_free(ref) }
        var obj: OpaquePointer?
        try check(git_reference_peel(&obj, ref, GIT_OBJECT_COMMIT), "git_reference_peel")
        defer { git_object_free(obj) }
        var tag = Tag(name: name, target: ObjectID(git_object_id(obj)))
        if let direct = git_reference_target(ref) {
            var annotated: OpaquePointer?
            var oid = direct.pointee
            if git_tag_lookup(&annotated, handle, &oid) == 0, let annotated {
                defer { git_tag_free(annotated) }
                tag.tagObject = ObjectID(direct)
                tag.message = String(gitCString: git_tag_message(annotated))
                if let tagger = git_tag_tagger(annotated) { tag.tagger = Signature(tagger) }
            } else {
                git_error_clear()
            }
        }
        return tag
    }

    /// Creates a tag. With a message it is annotated (needs a tagger).
    @discardableResult
    public func createTag(_ name: String, at revision: String = "HEAD", message: String? = nil, tagger: Signature? = nil, force: Bool = false) throws -> Tag {
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, handle, revision), "git_revparse_single(\(revision))")
        defer { git_object_free(obj) }
        var oid = git_oid()
        if let message {
            guard let tagger = try tagger ?? configuredIdentity() else {
                throw GitError.invalid("annotated tags need a tagger", "createTag")
            }
            let sig = try tagger.makeGitSignature()
            defer { git_signature_free(sig) }
            try check(git_tag_create(&oid, handle, name, obj, sig, message, force ? 1 : 0), "git_tag_create(\(name))")
        } else {
            try check(git_tag_create_lightweight(&oid, handle, name, obj, force ? 1 : 0), "git_tag_create_lightweight(\(name))")
        }
        return try tag(named: name)
    }

    public func deleteTag(_ name: String) throws {
        try check(git_tag_delete(handle, name), "git_tag_delete(\(name))")
    }
}
