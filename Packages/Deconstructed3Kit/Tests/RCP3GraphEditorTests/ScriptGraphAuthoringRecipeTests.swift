import Testing
import RCP3Document
@testable import RCP3GraphEditor

@Suite struct ScriptGraphAuthoringRecipeTests {
    private let verifiedTypes = [
        "tm_get_component", "tm_collision_event_began", "tm_add_child",
        "tm_get_material_parameter", "tm_break_anchoring_component_target",
        "tm_if", "tm_array_for_each", "tm_variable_add", "tm_make_bool",
        "tm_get_variable_node",
    ]

    @Test func allRCPVerifiedRepresentativesHaveRecipes() {
        for type in verifiedTypes {
            #expect(ScriptGraphAuthoringRecipes.recipe(for: type) != nil, "Missing recipe for \(type)")
        }
    }

    @Test func topologyCreatesOnlyValidExecRoots() throws {
        for type in verifiedTypes {
            let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
                requestedType: type, label: type, graphID: type
            ))
            let topology = try #require(ScriptGraphAuthoringRecipes.recipe(for: type)).topology
            let needsRoot = topology == .action || topology == .scoped
            #expect(graph.nodes.contains(where: { $0.type == "tm_update" }) == needsRoot)
            #expect(graph.wires.count == (needsRoot ? 1 : 0))
        }
    }

    @Test func deprecatedConstantUsesTypedConstructor() throws {
        let recipe = try #require(ScriptGraphAuthoringRecipes.recipe(for: "tm_constant"))
        #expect(recipe.authoredType == "tm_make_bool")
        #expect(recipe.replacementReason != nil)
        let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
            requestedType: "tm_constant", label: "constant", graphID: "constant"
        ))
        #expect(graph.nodes.map(\.type) == ["tm_make_bool"])
        #expect(graph.data.first?.value == .bool(true))
    }

    @Test func dynamicArrayUsesDirectConcreteTypes() throws {
        let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
            requestedType: "tm_array_for_each", label: "array", graphID: "array"
        ))
        let settings = try #require(graph.nodes.last?.dynamicConnectorSettings)
        #expect(settings.container == .direct)
        #expect(settings.inputs.first?.typeHash == 0xa147db4e70aa455c)
        #expect(settings.outputs.first?.name == "element")
    }

    @Test func numberVariableIsFullyTypedAndBound() throws {
        let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
            requestedType: "tm_variable_add", label: "variable", graphID: "variable"
        ))
        let variable = try #require(graph.variables.first)
        #expect(variable.typeHash == 0x3c2f3d0fe92dd9a0)
        #expect(variable.editHash == 0x0ef2dd9a55accbe4)
        #expect(variable.dataType == "tm_double")
        #expect(graph.nodes.last?.variableRefUUID == variable.uuid)
    }

    @Test func fixedSpecsDeriveTopologyButUnknownNodesDoNot() throws {
        let action = try #require(ScriptGraphAuthoringRecipes.recipe(for: "tm_remove_from_parent"))
        #expect(action.topology == .action)
        let pure = try #require(ScriptGraphAuthoringRecipes.recipe(for: "tm_self"))
        #expect(pure.topology == .pure)
        #expect(ScriptGraphAuthoringRecipes.recipe(for: "not_a_real_node") == nil)
    }
}
