import Testing
import RCP3Document
import TMFormat
@testable import RCP3GraphEditor

@Suite struct ScriptGraphAuthoringRecipeTests {
    private let verifiedTypes = [
        "tm_set_component", "tm_get_component", "tm_collision_event_began", "tm_add_child",
        "tm_get_material_parameter", "tm_set_material_parameter_v2",
        "tm_modify_any_material", "tm_break_anchoring_component_target",
        "tm_if", "tm_array_for_each", "tm_variable_add", "tm_variable_subtract",
        "tm_variable_multiply", "tm_variable_divide", "tm_variable_multiply_by_scalar",
        "tm_clear_variable_node", "tm_make_bool", "tm_get_variable_node",
    ]

    @Test func allRCPVerifiedRepresentativesHaveRecipes() {
        for type in verifiedTypes {
            #expect(ScriptGraphAuthoringRecipes.recipe(for: type) != nil, "Missing recipe for \(type)")
        }
    }

    @Test func setComponentStartsWithAConcreteComponentSelection() throws {
        let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
            requestedType: "tm_set_component", label: "Set Transform", graphID: "set-component"
        ))
        let set = try #require(graph.nodes.first { $0.type == "tm_set_component" })
        let selector = try #require(graph.data.first {
            $0.toNode == set.id && $0.toPin == TMHash.murmur64a("component_type")
        })
        #expect(selector.valueType == "re_scripting_graph_component_type")
        #expect(selector.valueHash == TMHash.murmur64a("Transform"))
        #expect(ScriptGraphPinResolver.pins(for: set, in: graph).contains {
            $0.isInput && $0.label == "Translation"
        })
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

    @Test func sourceBackedDynamicFamiliesHaveOneUniformAuthoringPath() throws {
        let authorable = [
            "tm_clone", "tm_to_string", "tm_string_merge",
            "tm_array_add", "tm_array_count", "tm_array_create", "tm_array_find",
            "tm_array_for_each", "tm_array_get", "tm_array_remove", "tm_array_set",
            "tm_custom_event", "tm_is_valid", "tm_is_valid_branch",
            "tm_on_entity_event", "tm_on_scene_event", "tm_send_entity_event",
            "tm_send_scene_event", "tm_trigger_event",
            "tm_break_material", "tm_break_physically_based_material_types",
        ]
        let palette = Set(ScriptGraphNodeLibrary.paletteItems.map(\.type))
        for type in authorable {
            #expect(ScriptGraphAuthoringRecipes.recipe(for: type) != nil, "Missing recipe for \(type)")
            #expect(palette.contains(type), "Missing palette item for \(type)")
            let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
                requestedType: type, label: type, graphID: type
            ))
            #expect(graph.nodes.last?.dynamicConnectorSettings != nil)
            #expect(ScriptGraphNodeLibrary.spec(for: type) != nil)
        }
    }

    @Test func cloneRecipeAuthorsTheRecoveredEntityDynamicContract() throws {
        let recipe = try #require(ScriptGraphAuthoringRecipes.recipe(for: "tm_clone"))
        #expect(recipe.topology == .action)

        let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
            requestedType: "tm_clone", label: "Clone", graphID: "clone"
        ))
        let clone = try #require(graph.nodes.first { $0.type == "tm_clone" })
        let settings = try #require(clone.dynamicConnectorSettings)
        #expect(settings.container == .direct)
        #expect(settings.inputs.map(\.name) == ["source"])
        #expect(settings.outputs.map(\.name) == ["source"])
        #expect(settings.inputs.map(\.typeHash) == [ScriptGraphTypeRegistry.entity.typeHash])
        #expect(settings.outputs.map(\.typeHash) == [ScriptGraphTypeRegistry.entity.typeHash])
        #expect(graph.wires.count == 1)
    }

    @Test func entityParameterUsesItsDedicatedSettingsRatherThanGenericDynamicSettings() throws {
        #expect(ScriptGraphNodeLibrary.defaultDynamicConnectorSettings(for: "tm_set_entity_parameter") == nil)
        let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
            requestedType: "tm_set_entity_parameter", label: "Set Parameter", graphID: "entity-parameter"
        ))
        let node = try #require(graph.nodes.last)
        #expect(node.dynamicConnectorSettings == nil)
        #expect(node.entityParameterSettings?.typeHash == 0xaed3caa5c516d191)
    }

    @Test func materialFamilyUsesInspectableSettingsForEveryOperation() throws {
        for type in [
            "tm_get_material_parameter", "tm_set_material_parameter_v2",
            "tm_modify_any_material",
        ] {
            let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
                requestedType: type, label: type, graphID: type
            ))
            let node = try #require(graph.nodes.last)
            let settings = try #require(node.materialSettings, "\(type) lost material settings")
            #expect(settings.objectIdentifier == "RealityKit.PhysicallyBasedMaterial")
            #expect(settings.inputs.map(\.name) == ["roughness"])
            #expect(settings.outputs.map(\.name) == ["roughness"])
            let needsRoot = type != "tm_get_material_parameter"
            #expect(graph.wires.count == (needsRoot ? 1 : 0))
        }
    }

    @Test func numberVariableFamilyIsFullyTypedAndBound() throws {
        for type in [
            "tm_variable_add", "tm_variable_subtract", "tm_variable_multiply",
            "tm_variable_divide", "tm_variable_multiply_by_scalar", "tm_clear_variable_node",
        ] {
            let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
                requestedType: type, label: "variable", graphID: type
            ))
            let variable = try #require(graph.variables.first)
            #expect(variable.typeHash == 0x3c2f3d0fe92dd9a0)
            #expect(variable.editHash == 0x0ef2dd9a55accbe4)
            #expect(variable.dataType == "tm_double")
            #expect(graph.nodes.last?.variableRefUUID == variable.uuid)
        }
    }

    @Test func quaternionAndMatrixVariablesUseTruthIdentityDefaults() throws {
        let cases: [(String, UInt64, UInt64, String)] = [
            ("tm_variable_multiply_by_quaternion", 0xc0151474cbd67fcc, 0xa4d2f46b41c9d717, "tm_rotation"),
            ("tm_variable_multiply_by_matrix", 0x32e0e9614b5964e2, 0x571323c7ad582d5f, "tm_mat44_t"),
        ]
        for (type, typeHash, editHash, dataType) in cases {
            let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
                requestedType: type, label: "variable", graphID: type
            ))
            let variable = try #require(graph.variables.first)
            #expect(variable.typeHash == typeHash)
            #expect(variable.editHash == editHash)
            #expect(variable.dataType == dataType)
            #expect(graph.nodes.last?.variableRefUUID == variable.uuid)
        }
    }

    @Test func fixedSpecsDeriveTopologyButUnknownNodesDoNot() throws {
        let action = try #require(ScriptGraphAuthoringRecipes.recipe(for: "tm_remove_from_parent"))
        #expect(action.topology == .action)
        let pure = try #require(ScriptGraphAuthoringRecipes.recipe(for: "tm_self"))
        #expect(pure.topology == .pure)
        #expect(ScriptGraphAuthoringRecipes.recipe(for: "not_a_real_node") == nil)
    }

    @Test func everyAuthorablePaletteTypeUsesTheSameFragmentAsFullGraphGeneration() throws {
        func generator() -> () -> String {
            var index = 0
            return {
                defer { index += 1 }
                return "id-\(index)"
            }
        }

        for item in ScriptGraphNodeLibrary.paletteItems where
            ScriptGraphAuthoringRecipes.recipe(for: item.type) != nil {
            let fragment = try #require(ScriptGraphAuthoringRecipes.makeFragment(
                requestedType: item.type,
                label: item.displayName,
                makeUUID: generator()
            ))
            let graph = try #require(ScriptGraphAuthoringRecipes.makeGraph(
                requestedType: item.type,
                label: item.displayName,
                graphID: item.type,
                makeUUID: generator()
            ))

            #expect(graph.nodes.contains(fragment.node), "Node fragment drifted for \(item.type)")
            #expect(graph.data == fragment.data, "Literal fragment drifted for \(item.type)")
            #expect(graph.variables == fragment.variables, "Variable fragment drifted for \(item.type)")
        }
    }

    @Test func everySchemaEnumFragmentStartsWithAValidCase() throws {
        for item in ScriptGraphNodeLibrary.paletteItems where
            ScriptGraphNodeLibrary.enumPinPolicy(for: item.type) != nil {
            let fragment = try #require(ScriptGraphAuthoringRecipes.makeFragment(
                requestedType: item.type,
                label: item.displayName
            ))
            let selection = try #require(fragment.node.enumSelection, "Missing enum selection for \(item.type)")
            #expect(ScriptGraphNodeLibrary.enumPinPolicy(for: item.type)?.schema.cases.contains {
                $0.name == selection.caseName
            } == true)
        }
    }
}
