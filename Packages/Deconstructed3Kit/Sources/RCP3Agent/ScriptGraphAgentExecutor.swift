import CoreGraphics
import Foundation
import RCP3Document
import RCP3GraphEditor
import RCP3Runtime
import TMFormat

/// Strongly typed operations behind the model-facing tool schemas.
public enum ScriptGraphAgentCommand: Equatable, Sendable {
    case overview
    case listNodes
    case inspectNode(id: String)
    case searchCatalog(query: String, limit: Int)
    case inspectNodeType(type: String)
    case validate
    case compile
    case addNode(type: String, label: String?, x: Double, y: Double)
    case removeNode(id: String)
    case connect(fromNode: String, fromPin: String, toNode: String, toPin: String)
    case removeConnection(id: String)
    case setLiteral(nodeID: String, pin: String, value: ScriptGraphAgentLiteral?)
    case setVariable(nodeID: String, name: String?)
    case setLabel(nodeID: String, label: String)
    case moveNode(id: String, x: Double, y: Double)
    case selectNode(id: String?)
    case save
    case runPreview
    case play
    case stop
}

public enum ScriptGraphAgentLiteral: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)

    var graphValue: TMGraphValue {
        switch self {
        case let .number(value): .number(value)
        case let .bool(value): .bool(value)
        case let .string(value): .string(value)
        }
    }
}

public struct ScriptGraphAgentExecutionResult: Equatable, Sendable {
    public let summary: String
    public let detail: String
    public let mutated: Bool

    public init(summary: String, detail: String, mutated: Bool = false) {
        self.summary = summary
        self.detail = detail
        self.mutated = mutated
    }

    public var toolOutput: String {
        detail.isEmpty ? summary : "\(summary)\n\(detail)"
    }
}

/// Host-owned actions that sit outside the graph model itself.
///
/// The document view supplies these closures, allowing an agent to invoke the same
/// Save, Run Preview, and Play commands as the toolbar. Tests can omit them and still
/// exercise the full graph-authoring command set.
public struct ScriptGraphAgentHostActions: Sendable {
    public var save: @MainActor @Sendable () throws -> String
    public var runPreview: @MainActor @Sendable () throws -> String
    public var play: @MainActor @Sendable () throws -> String
    public var stop: @MainActor @Sendable () throws -> String

    public init(
        save: @escaping @MainActor @Sendable () throws -> String,
        runPreview: @escaping @MainActor @Sendable () throws -> String,
        play: @escaping @MainActor @Sendable () throws -> String,
        stop: @escaping @MainActor @Sendable () throws -> String
    ) {
        self.save = save
        self.runPreview = runPreview
        self.play = play
        self.stop = stop
    }

    public static let unavailable = ScriptGraphAgentHostActions(
        save: { throw ScriptGraphAgentError.invalidArguments("Save is unavailable in this host.") },
        runPreview: { throw ScriptGraphAgentError.invalidArguments("Run Preview is unavailable in this host.") },
        play: { throw ScriptGraphAgentError.invalidArguments("Play is unavailable in this host.") },
        stop: { throw ScriptGraphAgentError.invalidArguments("Stop is unavailable in this host.") }
    )
}

/// Executes agent commands against the live, unsaved canvas model.
@MainActor
public final class ScriptGraphAgentExecutor: Sendable {
    public let model: ScriptGraphEditorModel
    private let hostActions: ScriptGraphAgentHostActions

    public init(
        model: ScriptGraphEditorModel,
        hostActions: ScriptGraphAgentHostActions = .unavailable
    ) {
        self.model = model
        self.hostActions = hostActions
    }

    public func execute(
        _ command: ScriptGraphAgentCommand,
        permitsMutation: Bool = true
    ) throws -> ScriptGraphAgentExecutionResult {
        if Self.isMutating(command), !permitsMutation {
            throw ScriptGraphAgentError.mutationNotPermitted
        }

        switch command {
        case .overview:
            let graph = model.graphSnapshot()
            return .init(
                summary: "Graph overview",
                detail: "id=\(graph.id ?? "unsaved") nodes=\(graph.nodes.count) connections=\(graph.wires.count) literals=\(graph.data.count) variables=\(graph.variables.count) dirty=\(model.isDirty)"
            )

        case .listNodes:
            let rows = model.nodes.map { node in
                let inputs = node.payload.inputPins.map(\.id).joined(separator: ",")
                let outputs = node.payload.outputPins.map(\.id).joined(separator: ",")
                return "\(node.id) | \(node.payload.type) | \(node.payload.title) | in=[\(inputs)] out=[\(outputs)]"
            }
            return .init(summary: "\(rows.count) nodes", detail: rows.joined(separator: "\n"))

        case let .inspectNode(id):
            let node = try requireNode(id)
            let pins = node.payload.pins.map {
                "\($0.id) | \($0.isInput ? "input" : "output") | \($0.isExec ? "exec" : "data") | \($0.label)\($0.valueLabel.map { " = \($0)" } ?? "")"
            }
            let touching = model.connections.filter { $0.from.nodeID == id || $0.to.nodeID == id }
            return .init(
                summary: "\(node.payload.title) (\(node.payload.type))",
                detail: "id=\(id) position=(\(node.position.x),\(node.position.y)) connections=\(touching.count)\n" + pins.joined(separator: "\n")
            )

        case let .searchCatalog(query, limit):
            let items = model.nodeRegistry.paletteSections(matching: query)
                .flatMap(\.items)
                .prefix(max(1, min(limit, 100)))
            let rows = items.map { "\($0.type) | \($0.displayName) | \($0.category.rawValue)" }
            return .init(summary: "\(rows.count) matching node types", detail: rows.joined(separator: "\n"))

        case let .inspectNodeType(type):
            guard let spec = model.nodeRegistry.spec(for: type) else {
                throw ScriptGraphAgentError.invalidArguments("Unknown RCP3 node type: \(type). Search the catalog first.")
            }
            let inputs = spec.inputs.map { "input \($0.connectorName) | \($0.displayName) | \($0.isExec ? "exec" : "data")" }
            let outputs = spec.outputs.map { "output \($0.connectorName) | \($0.displayName) | \($0.isExec ? "exec" : "data")" }
            let recipe = ScriptGraphAuthoringRecipes.recipe(for: type)
            return .init(
                summary: "\(type) — \(spec.category.rawValue)",
                detail: "authorable=\(recipe != nil) topology=\(recipe.map { String(describing: $0.topology) } ?? "unresolved")\n" + (inputs + outputs).joined(separator: "\n")
            )

        case .validate:
            return validate()

        case .compile:
            let source = CanonicalScriptGraphCompiler().compile(model.graphSnapshot())
            let unsupported = source.split(separator: "\n").filter { $0.contains("unsupported") }
            return .init(
                summary: unsupported.isEmpty
                    ? "Canonical compilation completed without unsupported markers."
                    : "Canonical compilation completed with \(unsupported.count) unsupported marker(s).",
                detail: source
            )

        case let .addNode(type, label, x, y):
            guard model.nodeRegistry.spec(for: type) != nil else {
                throw ScriptGraphAgentError.invalidArguments("Unknown RCP3 node type: \(type). Search the catalog first.")
            }
            guard ScriptGraphAuthoringRecipes.recipe(for: type) != nil else {
                throw ScriptGraphAgentError.invalidArguments("Node type \(type) has no certified authoring recipe.")
            }
            let id = model.addNode(type: type, label: label, at: CGPoint(x: x, y: y))
            return .init(summary: "Added \(type).", detail: "node_id=\(id)", mutated: true)

        case let .removeNode(id):
            _ = try requireNode(id)
            model.removeNode(id)
            return .init(summary: "Removed node.", detail: "node_id=\(id)", mutated: true)

        case let .connect(fromNode, fromPin, toNode, toPin):
            let source = try port(nodeID: fromNode, nameOrID: fromPin, expectsInput: false)
            let target = try port(nodeID: toNode, nameOrID: toPin, expectsInput: true)
            guard let id = model.connect(source, target) else {
                throw ScriptGraphAgentError.invalidArguments("The requested pins are not a valid output-to-input connection of the same kind.")
            }
            return .init(summary: "Connected nodes.", detail: "connection_id=\(id)", mutated: true)

        case let .removeConnection(id):
            guard model.connections.contains(where: { $0.id == id }) else {
                throw ScriptGraphAgentError.connectionNotFound(id)
            }
            model.removeConnection(id)
            return .init(summary: "Removed connection.", detail: "connection_id=\(id)", mutated: true)

        case let .setLiteral(nodeID, pin, value):
            let ref = try port(nodeID: nodeID, nameOrID: pin, expectsInput: true)
            guard !model.pin(ref)!.isExec, let hash = connectorHash(from: ref.pinID) else {
                throw ScriptGraphAgentError.invalidArguments("Only data input pins can hold literals.")
            }
            model.setValue(nodeID: nodeID, pinConnectorHash: hash, value: value?.graphValue)
            return .init(
                summary: value == nil ? "Cleared literal." : "Set literal.",
                detail: "node_id=\(nodeID) pin_id=\(ref.pinID)",
                mutated: true
            )

        case let .setVariable(nodeID, name):
            _ = try requireNode(nodeID)
            guard model.isVariableNode(nodeID) else {
                throw ScriptGraphAgentError.invalidArguments("Node \(nodeID) is not a variable operation.")
            }
            model.setVariableName(nodeID: nodeID, name: name)
            return .init(summary: "Updated variable reference.", detail: "node_id=\(nodeID) name=\(name ?? "none")", mutated: true)

        case let .setLabel(nodeID, label):
            _ = try requireNode(nodeID)
            model.setNodeLabel(nodeID: nodeID, label: label)
            return .init(summary: "Updated node label.", detail: "node_id=\(nodeID)", mutated: true)

        case let .moveNode(id, x, y):
            _ = try requireNode(id)
            model.moveNode(id, to: CGPoint(x: x, y: y))
            return .init(summary: "Moved node.", detail: "node_id=\(id) position=(\(x),\(y))", mutated: true)

        case let .selectNode(id):
            if let id { _ = try requireNode(id) }
            model.selectNode(id)
            return .init(summary: id == nil ? "Cleared selection." : "Selected node.", detail: id.map { "node_id=\($0)" } ?? "", mutated: true)

        case .save:
            return .init(summary: try hostActions.save(), detail: "", mutated: true)
        case .runPreview:
            return .init(summary: try hostActions.runPreview(), detail: "", mutated: true)
        case .play:
            return .init(summary: try hostActions.play(), detail: "", mutated: true)
        case .stop:
            return .init(summary: try hostActions.stop(), detail: "", mutated: true)
        }
    }

    private func validate() -> ScriptGraphAgentExecutionResult {
        let graph = model.graphSnapshot()
        let nodeIDs = Set(graph.nodes.map(\.id))
        var issues: [String] = []
        for node in graph.nodes {
            if model.nodeRegistry.spec(for: node.type) == nil {
                issues.append("unknown node type \(node.type) (\(node.id))")
            } else if ScriptGraphAuthoringRecipes.recipe(for: node.type) == nil {
                issues.append("missing authoring recipe for \(node.type) (\(node.id))")
            }
        }
        for wire in graph.wires {
            if !nodeIDs.contains(wire.from) || !nodeIDs.contains(wire.to) {
                issues.append("connection \(wire.id) references a missing node")
            }
        }
        let compiled = CanonicalScriptGraphCompiler().compile(graph)
        let unsupported = compiled.split(separator: "\n").filter { $0.contains("unsupported") }
        if !unsupported.isEmpty {
            issues.append("canonical compiler emitted \(unsupported.count) unsupported marker(s)")
        }
        return .init(
            summary: issues.isEmpty ? "Graph validation passed." : "Graph validation found \(issues.count) issue(s).",
            detail: issues.isEmpty ? "No structural or compiler coverage issues found." : issues.joined(separator: "\n")
        )
    }

    private func requireNode(_ id: String) throws -> GraphNodeBox {
        guard let node = model.node(id) else { throw ScriptGraphAgentError.nodeNotFound(id) }
        return node
    }

    private func port(nodeID: String, nameOrID: String, expectsInput: Bool) throws -> GraphPortRef {
        let node = try requireNode(nodeID)
        let normalized = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = node.payload.pins.first {
            $0.isInput == expectsInput && (
                $0.id.caseInsensitiveCompare(normalized) == .orderedSame
                    || $0.label.caseInsensitiveCompare(normalized) == .orderedSame
            )
        }
        guard let pin else { throw ScriptGraphAgentError.pinNotFound(nodeID: nodeID, pin: nameOrID) }
        return GraphPortRef(nodeID: nodeID, pinID: pin.id)
    }

    private func connectorHash(from pinID: String) -> UInt64? {
        for prefix in ["in.", "out."] where pinID.hasPrefix(prefix) {
            return UInt64(pinID.dropFirst(prefix.count), radix: 16)
        }
        return nil
    }

    private static func isMutating(_ command: ScriptGraphAgentCommand) -> Bool {
        switch command {
        case .overview, .listNodes, .inspectNode, .searchCatalog, .inspectNodeType, .validate, .compile:
            false
        case .addNode, .removeNode, .connect, .removeConnection, .setLiteral, .setVariable,
             .setLabel, .moveNode, .selectNode, .save, .runPreview, .play, .stop:
            true
        }
    }
}
