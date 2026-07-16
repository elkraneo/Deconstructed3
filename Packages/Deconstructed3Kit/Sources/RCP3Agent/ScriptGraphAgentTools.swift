import Foundation
import FoundationModels

public struct ScriptGraphAgentToolEnvironment: Sendable {
    public let executor: ScriptGraphAgentExecutor
    public let permitsMutation: Bool
    public let activity: @MainActor @Sendable (ScriptGraphAgentActivity) -> Void

    public init(
        executor: ScriptGraphAgentExecutor,
        permitsMutation: Bool,
        activity: @escaping @MainActor @Sendable (ScriptGraphAgentActivity) -> Void = { _ in }
    ) {
        self.executor = executor
        self.permitsMutation = permitsMutation
        self.activity = activity
    }

    func execute(
        toolID: ScriptGraphAgentToolID,
        summary: String,
        command: ScriptGraphAgentCommand
    ) async throws -> String {
        let activityID = UUID()
        await activity(.init(id: activityID, toolID: toolID, phase: .started, summary: summary))
        do {
            let result = try await executor.execute(command, permitsMutation: permitsMutation)
            await activity(.init(
                id: activityID,
                toolID: toolID,
                phase: .completed,
                summary: result.summary,
                detail: result.mutated ? "The live canvas was updated." : nil
            ))
            return result.toolOutput
        } catch {
            await activity(.init(
                id: activityID,
                toolID: toolID,
                phase: .failed,
                summary: "Tool failed",
                detail: error.localizedDescription
            ))
            throw error
        }
    }
}

public struct InspectScriptGraphTool: Tool {
    @Generable
    public struct Arguments {
        @Guide(description: "Action: overview, list_nodes, inspect_node, search_catalog, or inspect_node_type.")
        public var action: String
        @Guide(description: "Node id for inspect_node.")
        public var nodeID: String?
        @Guide(description: "Search text for search_catalog.")
        public var query: String?
        @Guide(description: "RCP3 node type for inspect_node_type.")
        public var nodeType: String?
        @Guide(description: "Maximum search results, from 1 through 100.")
        public var limit: Int?
    }

    public let name = ScriptGraphAgentToolID.inspect.rawValue
    public let description = "Read the open RCP3 Script Graph or search its authorable node catalog. Use this before editing to obtain exact node ids and pin ids."
    private let environment: ScriptGraphAgentToolEnvironment

    public init(environment: ScriptGraphAgentToolEnvironment) {
        self.environment = environment
    }

    @concurrent
    public func call(arguments: Arguments) async throws -> String {
        let command: ScriptGraphAgentCommand
        switch arguments.action {
        case "overview": command = .overview
        case "list_nodes": command = .listNodes
        case "inspect_node":
            guard let id = arguments.nodeID else {
                throw ScriptGraphAgentError.invalidArguments("inspect_node requires nodeID.")
            }
            command = .inspectNode(id: id)
        case "search_catalog":
            command = .searchCatalog(query: arguments.query ?? "", limit: arguments.limit ?? 30)
        case "inspect_node_type":
            guard let type = arguments.nodeType else {
                throw ScriptGraphAgentError.invalidArguments("inspect_node_type requires nodeType.")
            }
            command = .inspectNodeType(type: type)
        default:
            throw ScriptGraphAgentError.invalidAction(arguments.action)
        }
        return try await environment.execute(
            toolID: .inspect,
            summary: "Inspecting Script Graph",
            command: command
        )
    }
}

public struct EditScriptGraphTool: Tool {
    @Generable
    public struct Arguments {
        @Guide(description: "Action: add_node, remove_node, connect, remove_connection, set_literal, set_variable, set_label, move_node, or select_node.")
        public var action: String
        @Guide(description: "Primary node id for remove, literal, variable, label, move, or select.")
        public var nodeID: String?
        @Guide(description: "RCP3 node type for add_node, such as tm_update.")
        public var nodeType: String?
        @Guide(description: "Optional author-visible node label.")
        public var label: String?
        @Guide(description: "Source node id for connect.")
        public var fromNode: String?
        @Guide(description: "Exact source output pin id or label for connect.")
        public var fromPin: String?
        @Guide(description: "Destination node id for connect.")
        public var toNode: String?
        @Guide(description: "Exact destination input pin id or label for connect.")
        public var toPin: String?
        @Guide(description: "Connection id for remove_connection.")
        public var connectionID: String?
        @Guide(description: "Input pin id or label for set_literal.")
        public var pin: String?
        @Guide(description: "Literal kind: number, bool, string, or clear.")
        public var literalKind: String?
        @Guide(description: "Number value when literalKind is number.")
        public var numberValue: Double?
        @Guide(description: "Boolean value when literalKind is bool.")
        public var boolValue: Bool?
        @Guide(description: "Text value when literalKind is string; variable name for set_variable.")
        public var textValue: String?
        @Guide(description: "Canvas x coordinate for add_node or move_node.")
        public var x: Double?
        @Guide(description: "Canvas y coordinate for add_node or move_node.")
        public var y: Double?
    }

    public let name = ScriptGraphAgentToolID.edit.rawValue
    public let description = "Mutate the open RCP3 Script Graph through the live canvas model. Inspect first; connect using exact node and pin ids returned by inspection."
    private let environment: ScriptGraphAgentToolEnvironment

    public init(environment: ScriptGraphAgentToolEnvironment) {
        self.environment = environment
    }

    @concurrent
    public func call(arguments: Arguments) async throws -> String {
        guard environment.permitsMutation else { throw ScriptGraphAgentError.mutationNotPermitted }
        let command: ScriptGraphAgentCommand
        switch arguments.action {
        case "add_node":
            guard let type = arguments.nodeType else {
                throw ScriptGraphAgentError.invalidArguments("add_node requires nodeType.")
            }
            command = .addNode(
                type: type,
                label: arguments.label,
                x: arguments.x ?? 0,
                y: arguments.y ?? 0
            )
        case "remove_node":
            command = .removeNode(id: try required(arguments.nodeID, name: "nodeID"))
        case "connect":
            command = .connect(
                fromNode: try required(arguments.fromNode, name: "fromNode"),
                fromPin: try required(arguments.fromPin, name: "fromPin"),
                toNode: try required(arguments.toNode, name: "toNode"),
                toPin: try required(arguments.toPin, name: "toPin")
            )
        case "remove_connection":
            command = .removeConnection(id: try required(arguments.connectionID, name: "connectionID"))
        case "set_literal":
            command = .setLiteral(
                nodeID: try required(arguments.nodeID, name: "nodeID"),
                pin: try required(arguments.pin, name: "pin"),
                value: try literal(arguments)
            )
        case "set_variable":
            command = .setVariable(nodeID: try required(arguments.nodeID, name: "nodeID"), name: arguments.textValue)
        case "set_label":
            command = .setLabel(
                nodeID: try required(arguments.nodeID, name: "nodeID"),
                label: arguments.label ?? ""
            )
        case "move_node":
            command = .moveNode(
                id: try required(arguments.nodeID, name: "nodeID"),
                x: try required(arguments.x, name: "x"),
                y: try required(arguments.y, name: "y")
            )
        case "select_node":
            command = .selectNode(id: arguments.nodeID)
        default:
            throw ScriptGraphAgentError.invalidAction(arguments.action)
        }
        return try await environment.execute(toolID: .edit, summary: "Editing Script Graph", command: command)
    }

    private func required<Value>(_ value: Value?, name: String) throws -> Value {
        guard let value else { throw ScriptGraphAgentError.invalidArguments("\(name) is required.") }
        return value
    }

    private func literal(_ arguments: Arguments) throws -> ScriptGraphAgentLiteral? {
        switch arguments.literalKind {
        case "clear": nil
        case "number": .number(try required(arguments.numberValue, name: "numberValue"))
        case "bool": .bool(try required(arguments.boolValue, name: "boolValue"))
        case "string": .string(try required(arguments.textValue, name: "textValue"))
        case let .some(kind): throw ScriptGraphAgentError.invalidArguments("Unknown literalKind: \(kind).")
        case .none: throw ScriptGraphAgentError.invalidArguments("literalKind is required.")
        }
    }
}

public struct CompileScriptGraphTool: Tool {
    @Generable
    public struct Arguments {
        @Guide(description: "Action: validate or compile.")
        public var action: String
    }

    public let name = ScriptGraphAgentToolID.compile.rawValue
    public let description = "Validate the live unsaved graph or compile it to canonical RealityKitScripting JavaScript. Unsupported behavior is reported honestly."
    private let environment: ScriptGraphAgentToolEnvironment

    public init(environment: ScriptGraphAgentToolEnvironment) {
        self.environment = environment
    }

    @concurrent
    public func call(arguments: Arguments) async throws -> String {
        let command: ScriptGraphAgentCommand = switch arguments.action {
        case "validate": .validate
        case "compile": .compile
        default: throw ScriptGraphAgentError.invalidAction(arguments.action)
        }
        return try await environment.execute(toolID: .compile, summary: "Checking Script Graph", command: command)
    }
}

public struct ControlGraphWorkspaceTool: Tool {
    @Generable
    public struct Arguments {
        @Guide(description: "Action: save, run_preview, play, or stop.")
        public var action: String
    }

    public let name = ScriptGraphAgentToolID.workspace.rawValue
    public let description = "Invoke the authoring workspace's real Save, Run Preview, Play, or Stop action for the current graph."
    private let environment: ScriptGraphAgentToolEnvironment

    public init(environment: ScriptGraphAgentToolEnvironment) {
        self.environment = environment
    }

    @concurrent
    public func call(arguments: Arguments) async throws -> String {
        guard environment.permitsMutation else { throw ScriptGraphAgentError.mutationNotPermitted }
        let command: ScriptGraphAgentCommand = switch arguments.action {
        case "save": .save
        case "run_preview": .runPreview
        case "play": .play
        case "stop": .stop
        default: throw ScriptGraphAgentError.invalidAction(arguments.action)
        }
        return try await environment.execute(toolID: .workspace, summary: "Controlling workspace", command: command)
    }
}

public enum ScriptGraphAgentToolset {
    public static func tools(
        for profile: ScriptGraphAgentProfile,
        environment: ScriptGraphAgentToolEnvironment
    ) -> [any Tool] {
        var tools: [any Tool] = []
        if profile.toolIDs.contains(.inspect) { tools.append(InspectScriptGraphTool(environment: environment)) }
        if profile.toolIDs.contains(.edit) { tools.append(EditScriptGraphTool(environment: environment)) }
        if profile.toolIDs.contains(.compile) { tools.append(CompileScriptGraphTool(environment: environment)) }
        if profile.toolIDs.contains(.workspace) { tools.append(ControlGraphWorkspaceTool(environment: environment)) }
        return tools
    }
}
