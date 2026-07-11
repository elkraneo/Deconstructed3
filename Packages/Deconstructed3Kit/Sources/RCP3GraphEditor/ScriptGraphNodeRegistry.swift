import RCP3NodeLib

/// A merged authoring catalogue for built-in and imported NodeLib nodes.
///
/// The static `ScriptGraphNodeLibrary` remains the observed RCP3 built-in source;
/// this value layer makes custom libraries injectable and keeps the editor,
/// agent planner, and future web bridge on the same resolved interfaces.
public struct ScriptGraphNodeRegistry: Sendable {
    public static let builtins = ScriptGraphNodeRegistry()

    private let nodeLibSpecs: [String: ScriptGraphNodeLibrary.NodeSpec]
    public let nodeLibPaletteItems: [ScriptGraphNodeLibrary.PaletteItem]

    public init(nodeLibraries: [NodeLibLibrary] = []) {
        var specs: [String: ScriptGraphNodeLibrary.NodeSpec] = [:]
        var palette: [ScriptGraphNodeLibrary.PaletteItem] = []

        for declaration in nodeLibraries.flatMap(\.methodDeclarations) {
            let node = declaration.node
            var inputs: [ScriptGraphNodeLibrary.PinSpec] = []
            var outputs: [ScriptGraphNodeLibrary.PinSpec] = []
            if declaration.hasExecutionFlow {
                inputs.append(.init(connectorName: "exec", displayName: "", isExec: true))
                outputs.append(.init(connectorName: "exec", displayName: "", isExec: true))
            }
            if node.method?.type == "instance", node.object != nil {
                inputs.append(.data("source", "Source"))
            }
            inputs += declaration.inputs.map {
                .data($0.name, Self.displayName(for: $0))
            }
            outputs += declaration.outputs.map {
                .data($0.name, Self.displayName(for: $0))
            }
            let category = Self.category(for: node.category)
            specs[declaration.identity] = .init(
                inputs: inputs,
                outputs: outputs,
                category: category
            )
            palette.append(.init(
                id: declaration.identity,
                type: declaration.identity,
                displayName: node.displayName ?? node.name,
                category: category
            ))
        }

        nodeLibSpecs = specs
        nodeLibPaletteItems = palette.sorted { $0.displayName < $1.displayName }
    }

    public func spec(for type: String) -> ScriptGraphNodeLibrary.NodeSpec? {
        nodeLibSpecs[type] ?? ScriptGraphNodeLibrary.spec(for: type)
    }

    private static func displayName(for property: NodeLibLibrary.Property) -> String {
        property.displayName ?? property.name
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func category(for value: String?) -> ScriptGraphNodeLibrary.Category {
        switch value?.lowercased() {
        case "events": .events
        case "control flow": .controlFlow
        case "logic": .logic
        case "entity", "gameplay": .entity
        case "math": .math
        case "make": .make
        case "string": .string
        case "variables": .variables
        case "components": .components
        default: .utility
        }
    }
}
