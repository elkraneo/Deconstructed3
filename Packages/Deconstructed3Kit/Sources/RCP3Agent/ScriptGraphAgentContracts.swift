import Foundation

/// Stable tool identities exposed by the Script Graph agent.
///
/// The list is intentionally consolidated: a model sees a small schema surface,
/// while each tool dispatches to explicit, audited operations. Profiles grant tools
/// by identity, so changing a profile changes actual capability, not only wording.
public enum ScriptGraphAgentToolID: String, CaseIterable, Codable, Hashable, Sendable {
    case inspect = "inspect_script_graph"
    case edit = "edit_script_graph"
    case compile = "compile_script_graph"
    case workspace = "control_graph_workspace"

    public var isMutating: Bool {
        switch self {
        case .inspect, .compile: false
        case .edit, .workspace: true
        }
    }
}

/// A user-selectable macOS 27 Dynamic Profile.
///
/// Review is read-only. Build can author using the on-device model. Deep Build
/// carries the same authoring permissions to Private Cloud Compute with deeper
/// reasoning. The session preserves history when switching between them.
public enum ScriptGraphAgentProfile: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case review
    case build
    case deepBuild = "deep-build"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .review: "Review"
        case .build: "Build"
        case .deepBuild: "Deep Build"
        }
    }

    public var summary: String {
        switch self {
        case .review:
            "Inspect and validate without changing the graph."
        case .build:
            "Create and edit with the on-device model."
        case .deepBuild:
            "Create and edit with deeper cloud reasoning."
        }
    }

    public var toolIDs: Set<ScriptGraphAgentToolID> {
        switch self {
        case .review: [.inspect, .compile]
        case .build, .deepBuild: Set(ScriptGraphAgentToolID.allCases)
        }
    }

    public var permitsMutation: Bool { toolIDs.contains(where: { $0.isMutating }) }
}

public struct ScriptGraphAgentProfileStatus: Equatable, Sendable {
    public let profile: ScriptGraphAgentProfile
    public let isAvailable: Bool
    public let detail: String
    public let contextSize: Int?

    public init(
        profile: ScriptGraphAgentProfile,
        isAvailable: Bool,
        detail: String,
        contextSize: Int? = nil
    ) {
        self.profile = profile
        self.isAvailable = isAvailable
        self.detail = detail
        self.contextSize = contextSize
    }
}

/// One model-visible tool execution event, suitable for an activity timeline.
public struct ScriptGraphAgentActivity: Equatable, Identifiable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case started
        case completed
        case failed
    }

    public let id: UUID
    public let toolID: ScriptGraphAgentToolID
    public let phase: Phase
    public let summary: String
    public let detail: String?

    public init(
        id: UUID = UUID(),
        toolID: ScriptGraphAgentToolID,
        phase: Phase,
        summary: String,
        detail: String? = nil
    ) {
        self.id = id
        self.toolID = toolID
        self.phase = phase
        self.summary = summary
        self.detail = detail
    }
}

public struct ScriptGraphAgentMessage: Equatable, Identifiable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case assistant
        case system
    }

    public let id: UUID
    public let role: Role
    public var text: String

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public enum ScriptGraphAgentStreamEvent: Equatable, Sendable {
    case activity(ScriptGraphAgentActivity)
    /// Cumulative response text; replace the current draft instead of appending it.
    case text(String)
    case context(Double?)
    case finished
}

public enum ScriptGraphAgentError: Error, Equatable, LocalizedError, Sendable {
    case graphUnavailable
    case invalidAction(String)
    case invalidArguments(String)
    case mutationNotPermitted
    case nodeNotFound(String)
    case pinNotFound(nodeID: String, pin: String)
    case connectionNotFound(String)
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .graphUnavailable: "No Script Graph is open."
        case let .invalidAction(action): "Unknown agent action: \(action)."
        case let .invalidArguments(message): message
        case .mutationNotPermitted: "The active profile is read-only."
        case let .nodeNotFound(id): "Node not found: \(id)."
        case let .pinNotFound(nodeID, pin): "Pin \(pin) was not found on node \(nodeID)."
        case let .connectionNotFound(id): "Connection not found: \(id)."
        case let .modelUnavailable(detail): detail
        }
    }
}
