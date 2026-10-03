import Foundation

/// How much the agent may do without asking.
///
/// | Mode      | Read tools | Edits                          | Shell                                      |
/// |-----------|------------|--------------------------------|--------------------------------------------|
/// | readOnly  | auto       | refused                        | read-only commands auto; others refused    |
/// | ask       | auto       | ask each time                  | ask each time                              |
/// | review    | auto       | applied, checkpointed, reviewed | read-only and build auto; mutating asks    |
/// | autopilot | auto       | auto, checkpointed             | auto, except network and unknown commands  |
///
/// Every edit is checkpointed in every mode that allows edits.
public enum PermissionMode: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case readOnly, ask, review, autopilot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .readOnly: "Read only"
        case .ask: "Ask before changes"
        case .review: "Review after"
        case .autopilot: "Autopilot"
        }
    }

    public var summary: String {
        switch self {
        case .readOnly: "Reads and searches. Never changes files."
        case .ask: "Asks before every edit and command."
        case .review: "Edits freely with checkpoints; you review each change afterwards."
        case .autopilot: "Edits and runs commands without asking. Still checkpointed."
        }
    }

    public var symbol: String {
        switch self {
        case .readOnly: "eye"
        case .ask: "hand.raised"
        case .review: "checklist"
        case .autopilot: "bolt"
        }
    }
}

/// A call waiting for the user's decision.
public struct PermissionRequest: Sendable, Hashable, Identifiable {
    public var id: String { callID }
    public var callID: String
    public var toolName: String
    public var effect: ToolEffect
    public var arguments: JSONValue

    public var title: String {
        switch effect {
        case .read: "Read files"
        case .write(let paths): paths.count == 1 ? "Change \(paths[0])" : "Change \(paths.count) files"
        case .shell: "Run a command"
        }
    }

    public var detail: String {
        switch effect {
        case .read: return toolName
        case .write: return toolName
        case .shell(let command, let c): return "\(command)\n(\(c.label))"
        }
    }
}

public enum PermissionResponse: Sendable, Hashable {
    case allowOnce
    /// Allow this kind of call for the rest of the session.
    case allowForSession
    case deny(reason: String?)
}

/// The UI side of the gate.
public protocol PermissionApprover: Sendable {
    func requestPermission(_ request: PermissionRequest) async -> PermissionResponse
}

/// Denies everything that needs asking (headless runs and tests).
public struct DenyingApprover: PermissionApprover {
    public init() {}
    public func requestPermission(_ request: PermissionRequest) async -> PermissionResponse {
        .deny(reason: "No one is available to approve this.")
    }
}

/// Approves everything (tests).
public struct AllowingApprover: PermissionApprover {
    public init() {}
    public func requestPermission(_ request: PermissionRequest) async -> PermissionResponse { .allowOnce }
}

public enum PermissionDecision: Sendable, Hashable {
    case allow
    case deny(String)
    case ask
}

/// The pure policy: mode × effect → decision, plus session-scoped grants.
public struct PermissionPolicy: Sendable, Hashable {
    public var mode: PermissionMode
    /// Grants from "allow for this session", keyed by `grantKey`.
    public private(set) var grants: Set<String> = []

    public init(mode: PermissionMode) { self.mode = mode }

    public func decide(_ effect: ToolEffect) -> PermissionDecision {
        let base = baseDecision(effect)
        // A session grant only ever turns "ask" into "allow"; it never
        // overrides a refusal (switching to read-only always wins).
        if base == .ask, grants.contains(Self.grantKey(effect)) { return .allow }
        return base
    }

    private func baseDecision(_ effect: ToolEffect) -> PermissionDecision {
        switch (mode, effect) {
        case (_, .read):
            return .allow
        case (.readOnly, .write(let paths)):
            return .deny("The agent is in read-only mode, so \(paths.joined(separator: ", ")) was not changed. "
                         + "Describe the change instead, or ask the user to switch modes.")
        case (.readOnly, .shell(_, let c)):
            return c == .readOnly ? .allow
                : .deny("The agent is in read-only mode; only read-only commands may run (this one \(c.label)).")
        case (.ask, _):
            return .ask
        case (.review, .write):
            return .allow
        case (.review, .shell(_, let c)):
            return c <= .build ? .allow : .ask
        case (.autopilot, .write):
            return .allow
        case (.autopilot, .shell(_, let c)):
            return c <= .mutating ? .allow : .ask
        }
    }

    /// A session grant covers all edits, or one exact shell command class.
    static func grantKey(_ effect: ToolEffect) -> String {
        switch effect {
        case .read: "read"
        case .write: "write"
        case .shell(_, let c): "shell.\(c.rawValue)"
        }
    }

    public mutating func grant(_ effect: ToolEffect) {
        // Unknown and network commands are never granted wholesale.
        if case .shell(_, let c) = effect, c >= .network { return }
        grants.insert(Self.grantKey(effect))
    }

    public mutating func resetGrants() { grants = [] }
}
