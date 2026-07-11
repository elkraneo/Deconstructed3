import Foundation
import RCP3Document
import TMFormat

/// RCP-authoring metadata that cannot be inferred from a node's fixed pin list.
///
/// The node catalog describes the interface RCP displays. A recipe describes the
/// additional choices RCP persists when an author inserts/configures that node.
/// Keeping these separate prevents parser support from being mistaken for authoring
/// parity and gives generators one uniform path for every node family.
public struct ScriptGraphAuthoringRecipe: Sendable, Hashable {
    public enum Topology: Sendable, Hashable { case pure, event, action, scoped }
    public enum Settings: Sendable, Hashable {
        case none
        case enumCase(String)
        case stringArrayIteration
        case physicallyBasedMaterial
    }
    public enum Variable: Sendable, Hashable {
        case none
        case numberDouble(name: String)
    }
    public enum Literal: Sendable, Hashable {
        case bool(pin: String, value: Bool)
        case componentType(pin: String, name: String)
    }

    public let requestedType: String
    public let authoredType: String
    public let topology: Topology
    public let settings: Settings
    public let variable: Variable
    public let literals: [Literal]
    /// Explains why `authoredType` replaces `requestedType`, when applicable.
    public let replacementReason: String?

    public init(
        requestedType: String,
        authoredType: String? = nil,
        topology: Topology,
        settings: Settings = .none,
        variable: Variable = .none,
        literals: [Literal] = [],
        replacementReason: String? = nil
    ) {
        self.requestedType = requestedType
        self.authoredType = authoredType ?? requestedType
        self.topology = topology
        self.settings = settings
        self.variable = variable
        self.literals = literals
        self.replacementReason = replacementReason
    }
}

/// Source/RCP-verified recipes used by authoring generators.
public enum ScriptGraphAuthoringRecipes {
    private static let numberVariable = ScriptGraphAuthoringRecipe.Variable.numberDouble(
        name: "Certification Value"
    )

    /// The representative mechanisms manually accepted by RCP 3.
    public static let verified: [String: ScriptGraphAuthoringRecipe] = [
        "tm_get_component": .init(
            requestedType: "tm_get_component", topology: .pure,
            literals: [.componentType(pin: "component_type", name: "Transform")]
        ),
        "tm_collision_event_began": .init(requestedType: "tm_collision_event_began", topology: .event),
        "tm_add_child": .init(requestedType: "tm_add_child", topology: .action),
        "tm_get_material_parameter": .init(
            requestedType: "tm_get_material_parameter", topology: .pure,
            settings: .physicallyBasedMaterial
        ),
        "tm_break_anchoring_component_target": .init(
            requestedType: "tm_break_anchoring_component_target", topology: .pure,
            settings: .enumCase("plane")
        ),
        "tm_if": .init(requestedType: "tm_if", topology: .scoped),
        "tm_array_for_each": .init(
            requestedType: "tm_array_for_each", topology: .scoped,
            settings: .stringArrayIteration
        ),
        "tm_variable_add": .init(
            requestedType: "tm_variable_add", topology: .action, variable: numberVariable
        ),
        "tm_constant": .init(
            requestedType: "tm_constant", authoredType: "tm_make_bool", topology: .pure,
            literals: [.bool(pin: "initial_value", value: true)],
            replacementReason: "RCP 3 deprecates the generic Constant node; use a typed constructor."
        ),
        "tm_make_bool": .init(
            requestedType: "tm_make_bool", topology: .pure,
            literals: [.bool(pin: "initial_value", value: true)]
        ),
        "tm_get_variable_node": .init(
            requestedType: "tm_get_variable_node", topology: .pure, variable: numberVariable
        ),
    ]

    public static func recipe(for type: String) -> ScriptGraphAuthoringRecipe? {
        if let verified = verified[type] { return verified }
        // Fixed-interface nodes need no authored settings beyond their catalog spec.
        // Typed-dynamic specs appear here only when the library has a concrete,
        // serializable default settings selection; policy-only nodes remain absent.
        guard let spec = ScriptGraphNodeLibrary.spec(for: type) else { return nil }
        let hasExecInput = spec.inputs.contains(where: \.isExec)
        let execOutputCount = spec.outputs.count(where: \.isExec)
        let topology: ScriptGraphAuthoringRecipe.Topology
        if hasExecInput {
            topology = execOutputCount > 1 ? .scoped : .action
        } else if execOutputCount > 0 {
            topology = .event
        } else {
            topology = .pure
        }
        return .init(requestedType: type, topology: topology)
    }

    /// Creates a minimal graph through the same recipe interpreter for every family.
    public static func makeGraph(
        requestedType: String,
        label: String,
        graphID: String,
        makeUUID: () -> String = { UUID().uuidString }
    ) -> RCP3ScriptGraph? {
        guard let recipe = recipe(for: requestedType) else { return nil }
        let subjectID = makeUUID()
        var node = RCP3ScriptGraph.Node(id: subjectID, type: recipe.authoredType, label: label)
        var data: [RCP3ScriptGraph.DataLiteral] = []
        var variables: [RCP3ScriptGraph.Variable] = []

        switch recipe.settings {
        case .none: break
        case let .enumCase(name):
            node.enumSelection = ScriptGraphNodeLibrary.enumSelection(for: recipe.authoredType, caseName: name)
        case .stringArrayIteration:
            node.dynamicConnectorSettings = .init(
                container: .direct,
                inputs: [.init(name: "array", displayName: "Array", typeHash: 0xa147db4e70aa455c, order: 0)],
                outputs: [.init(name: "element", displayName: "Element", typeHash: TMHash.murmur64a("String"), order: 0)]
            )
        case .physicallyBasedMaterial:
            let float = TMHash.murmur64a("Float")
            node.materialSettings = .init(
                typeHash: TMHash.murmur64a("PhysicallyBasedMaterial"),
                objectIdentifier: "RealityKit.PhysicallyBasedMaterial",
                inputs: [.init(name: "roughness", typeHash: float, editTypeHash: float, isOptional: false)],
                outputs: [.init(name: "roughness", typeHash: float, editTypeHash: float, isOptional: false)]
            )
        }
        if node.dynamicConnectorSettings == nil {
            node.dynamicConnectorSettings = ScriptGraphNodeLibrary.defaultDynamicConnectorSettings(
                for: recipe.authoredType
            )
        }

        switch recipe.variable {
        case .none: break
        case let .numberDouble(name):
            let variable = RCP3ScriptGraph.Variable(
                uuid: makeUUID(), name: name,
                typeHash: 0x3c2f3d0fe92dd9a0, editHash: 0x0ef2dd9a55accbe4,
                dataType: "tm_double"
            )
            variables = [variable]
            node.variableName = variable.name
            node.variableRefUUID = variable.uuid
        }

        for literal in recipe.literals {
            switch literal {
            case let .bool(pin, value):
                data.append(.init(id: makeUUID(), toNode: subjectID, toPin: TMHash.murmur64a(pin), value: .bool(value)))
            case let .componentType(pin, name):
                data.append(.init(
                    id: makeUUID(), toNode: subjectID, toPin: TMHash.murmur64a(pin),
                    valueType: "re_scripting_graph_component_type", valueHash: TMHash.murmur64a(name)
                ))
            }
        }

        let needsRoot = recipe.topology == .action || recipe.topology == .scoped
        let root = RCP3ScriptGraph.Node(id: makeUUID(), type: "tm_update", label: "Certification Start")
        return .init(
            id: graphID,
            nodes: needsRoot ? [root, node] : [node],
            wires: needsRoot ? [.init(id: makeUUID(), from: root.id, to: node.id)] : [],
            data: data,
            variables: variables
        )
    }
}
