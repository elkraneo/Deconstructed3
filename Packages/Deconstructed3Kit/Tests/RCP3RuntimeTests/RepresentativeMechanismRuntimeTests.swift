import JavaScriptCore
import Testing
import TMFormat
import RCP3Document
import RCP3Runtime

/// Observable execution checks for the representative certification mechanisms
/// whose canonical output is independent of a live RealityKit entity/component
/// implementation. These tests intentionally execute the compiler result rather
/// than merely matching generated source text.
@MainActor
@Suite struct RepresentativeMechanismRuntimeTests {
    private func runUpdate(_ graph: RCP3ScriptGraph, setup: String = "") throws -> JSContext {
        let host = ScriptJSHost(state: RuntimeEntityState())
        // The canonical compiler always imports these public runtime modules. The
        // variable/control/value mechanisms below do not call into them, so empty
        // deterministic modules are the honest minimal host boundary.
        host.load("var require = function(_) { return {}; };")
        if !setup.isEmpty { host.load(setup) }
        host.load(CanonicalScriptGraphCompiler().compile(graph))
        try #require(host.lastException == nil)
        host.load("this.update(1.0);")
        try #require(host.lastException == nil)
        return host.context
    }

    private func number(_ name: String, in context: JSContext) -> Double? {
        context.objectForKeyedSubscript(name)?.toDouble()
    }

    private func bool(_ name: String, in context: JSContext) -> Bool? {
        context.objectForKeyedSubscript(name)?.toBool()
    }

    private func slot(_ name: String) -> String {
        "variable_\(TMHash.murmur64a(name))"
    }

    private func dynamicArraySettings(_ name: String) -> RCP3ScriptGraph.Node.DynamicConnectorSettings {
        .init(container: .direct, inputs: [
            .init(name: name, typeHash: 1, editHash: 1, order: 0, optionality: 0),
        ], outputs: [])
    }

    @Test func case6ScopedControlFlowExecutesOnlySelectedScope() throws {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let branch = RCP3ScriptGraph.Node(id: "branch", type: "tm_if")
        let onTrue = RCP3ScriptGraph.Node(id: "true", type: "tm_set_variable_node", variableName: "selected")
        let onFalse = RCP3ScriptGraph.Node(id: "false", type: "tm_set_variable_node", variableName: "rejected")
        let graph = RCP3ScriptGraph(nodes: [update, branch, onTrue, onFalse], wires: [
            .init(id: "start", from: "update", to: "branch"),
            .init(id: "true-flow", from: "branch", to: "true", fromPin: TMHash.murmur64a("true"), toPin: nil),
            .init(id: "false-flow", from: "branch", to: "false", fromPin: TMHash.murmur64a("false"), toPin: nil),
        ], data: [
            .init(id: "condition", toNode: "branch", toPin: TMHash.murmur64a("condition"), value: .bool(true)),
            .init(id: "true-value", toNode: "true", toPin: TMHash.murmur64a("value"), value: .number(41)),
            .init(id: "false-value", toNode: "false", toPin: TMHash.murmur64a("value"), value: .number(99)),
        ])

        let context = try runUpdate(graph)
        #expect(number(slot("selected"), in: context) == 41)
        #expect(context.objectForKeyedSubscript(slot("rejected"))?.isUndefined == true)
    }

    @Test func case8TypedVariableMutationChangesAndForwardsValue() throws {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let add = RCP3ScriptGraph.Node(id: "add", type: "tm_variable_add", variableName: "score")
        let capture = RCP3ScriptGraph.Node(id: "capture", type: "tm_set_variable_node", variableName: "result")
        let graph = RCP3ScriptGraph(nodes: [update, add, capture], wires: [
            .init(id: "start", from: "update", to: "add"),
            .init(id: "next", from: "add", to: "capture"),
            .init(id: "result", from: "add", to: "capture", fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")),
        ], data: [
            .init(id: "amount", toNode: "add", toPin: TMHash.murmur64a("value"), value: .number(7)),
        ])

        let context = try runUpdate(graph)
        #expect(number(slot("score"), in: context) == 7)
        #expect(number(slot("result"), in: context) == 7)
    }

    @Test func case7TypedDynamicCollectionVisitsEveryElement() throws {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let children = RCP3ScriptGraph.Node(id: "children", type: "tm_get_children")
        let each = RCP3ScriptGraph.Node(
            id: "each", type: "tm_array_for_each",
            dynamicConnectorSettings: dynamicArraySettings("entities")
        )
        let capture = RCP3ScriptGraph.Node(id: "capture", type: "tm_set_variable_node", variableName: "visited")
        let graph = RCP3ScriptGraph(nodes: [update, children, each, capture], wires: [
            .init(id: "start", from: "update", to: "each"),
            .init(id: "step", from: "each", to: "capture", fromPin: TMHash.murmur64a("step"), toPin: nil),
            .init(id: "array", from: "children", to: "each", fromPin: TMHash.murmur64a("children"), toPin: TMHash.murmur64a("entities")),
            .init(id: "element", from: "each", to: "capture", fromPin: TMHash.murmur64a("element"), toPin: TMHash.murmur64a("value")),
        ], data: [])

        let context = try runUpdate(graph, setup: "entity.children = [3, 5, 8];")
        #expect(number(slot("visited"), in: context) == 8)
    }

    @Test func case9TypedBoolConstructorProducesObservableValue() throws {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let make = RCP3ScriptGraph.Node(id: "make", type: "tm_make_bool")
        let capture = RCP3ScriptGraph.Node(id: "capture", type: "tm_set_variable_node", variableName: "flag")
        let graph = RCP3ScriptGraph(nodes: [update, make, capture], wires: [
            .init(id: "start", from: "update", to: "capture"),
            .init(id: "value", from: "make", to: "capture", fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("value")),
        ], data: [
            .init(id: "initial", toNode: "make", toPin: TMHash.murmur64a("initial_value"), value: .bool(true)),
        ])

        let context = try runUpdate(graph)
        #expect(bool(slot("flag"), in: context) == true)
    }

    @Test func case10VariableReadReturnsPreviouslyAuthoredValue() throws {
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let seed = RCP3ScriptGraph.Node(id: "seed", type: "tm_set_variable_node", variableName: "source")
        let read = RCP3ScriptGraph.Node(id: "read", type: "tm_get_variable_node", variableName: "source")
        let capture = RCP3ScriptGraph.Node(id: "capture", type: "tm_set_variable_node", variableName: "copy")
        let graph = RCP3ScriptGraph(nodes: [update, seed, read, capture], wires: [
            .init(id: "start", from: "update", to: "seed"),
            .init(id: "next", from: "seed", to: "capture"),
            .init(id: "read", from: "read", to: "capture", fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("value")),
        ], data: [
            .init(id: "seed-value", toNode: "seed", toPin: TMHash.murmur64a("value"), value: .number(12.5)),
        ])

        let context = try runUpdate(graph)
        #expect(number(slot("source"), in: context) == 12.5)
        #expect(number(slot("copy"), in: context) == 12.5)
    }

    @Test func entityParameterSetAndGetExecuteWithTheSelectedPrimitiveType() throws {
        let settings = RCP3ScriptGraph.Node.EntityParameterSettings(
            typeHash: TMHash.murmur64a("tm_double")
        )
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let set = RCP3ScriptGraph.Node(
            id: "set", type: "tm_set_entity_parameter", entityParameterSettings: settings
        )
        let get = RCP3ScriptGraph.Node(
            id: "get", type: "tm_get_entity_parameter", entityParameterSettings: settings
        )
        let capture = RCP3ScriptGraph.Node(
            id: "capture", type: "tm_set_variable_node", variableName: "parameter"
        )
        let graph = RCP3ScriptGraph(nodes: [update, set, get, capture], wires: [
            .init(id: "start", from: "update", to: "set"),
            .init(id: "next", from: "set", to: "capture"),
            .init(
                id: "result", from: "get", to: "capture",
                fromPin: TMHash.murmur64a("result"), toPin: TMHash.murmur64a("value")
            ),
        ], data: [
            .init(id: "set-name", toNode: "set", toPin: TMHash.murmur64a("name"), value: .string("speed")),
            .init(id: "set-value", toNode: "set", toPin: TMHash.murmur64a("value"), value: .number(4.5)),
            .init(id: "get-name", toNode: "get", toPin: TMHash.murmur64a("name"), value: .string("speed")),
        ])

        let context = try runUpdate(graph, setup: """
            entity.parameters = {};
            entity.setParameter = function(parameter) {
                this.lastParameterType = parameter.type;
                this.parameters[parameter.name] = parameter.value;
            };
            entity.getParameter = function(name, type) {
                this.lastGetType = type;
                return this.parameters[name];
            };
            """)
        #expect(number(slot("parameter"), in: context) == 4.5)
        #expect(context.evaluateScript("entity.lastParameterType")?.toString() == "double")
        #expect(context.evaluateScript("entity.lastGetType")?.toString() == "double")
    }

    @Test func case5SchemaValueAccessReadsSelectedEnumAssociatedValue() throws {
        let planeSelection = RCP3ScriptGraph.Node.EnumSelection(
            typeHash: 0xfbcb65d98823de74,
            caseName: "plane",
            associatedValues: [
                .init(index: 0, typeHash: 0x7c899dc3ffa1603b),
                .init(index: 1, typeHash: 0x6bb355a28ed0d03c),
                .init(index: 2, typeHash: 0xe21127b812fa38ef),
            ]
        )
        let update = RCP3ScriptGraph.Node(id: "update", type: "tm_update")
        let make = RCP3ScriptGraph.Node(
            id: "make", type: "tm_make_anchoring_component_target",
            enumSelection: planeSelection
        )
        let access = RCP3ScriptGraph.Node(
            id: "access", type: "tm_break_anchoring_component_target",
            enumSelection: planeSelection
        )
        let capture = RCP3ScriptGraph.Node(
            id: "capture", type: "tm_set_variable_node", variableName: "extent"
        )
        let graph = RCP3ScriptGraph(nodes: [update, make, access, capture], wires: [
            .init(id: "start", from: "update", to: "capture"),
            .init(
                id: "source", from: "make", to: "access",
                fromPin: TMHash.murmur64a("value"), toPin: TMHash.murmur64a("source")
            ),
            .init(
                id: "associated-value", from: "access", to: "capture",
                fromPin: TMHash.murmur64a("value2"), toPin: TMHash.murmur64a("value")
            ),
        ], data: [
            .init(id: "alignment", toNode: "make", toPin: TMHash.murmur64a("value0"), value: .string("horizontal")),
            .init(id: "classification", toNode: "make", toPin: TMHash.murmur64a("value1"), value: .string("wall")),
            .init(id: "extent", toNode: "make", toPin: TMHash.murmur64a("value2"), value: .number(2.5)),
        ])

        let context = try runUpdate(
            graph,
            setup: "require = function(_) { return { AnchoringComponent: { Target: { plane: function(a, c, e) { return [a, c, e]; } } } }; };"
        )
        #expect(number(slot("extent"), in: context) == 2.5)
    }
}
