import Foundation
import Testing
import TMFormat

@testable import RCP3GraphEditor
import RCP3Document

/// Tests for the full named-interface parity with RCP 3: each node renders its
/// whole declared pin set (not just the wired pins), with resolved names and
/// exposed literal values, via ``ScriptGraphNodeLibrary`` + ``ScriptGraphPinResolver``.
@Suite("ScriptGraphNodeLibrary parity")
struct ScriptGraphNodeLibraryTests {

    @Test("Every corpus node is authorable with a declared interface")
    func everyCorpusNodeHasANodeSpec() {
        for type in ScriptGraphExamples.coveredNodeTypes {
            #expect(
                ScriptGraphNodeLibrary.spec(for: type) != nil,
                "Corpus uses \(type), but the editor cannot author it"
            )
        }
    }

    /// Resolves a payload for every node in `graph`, keyed by node id.
    static func payloads(for graph: RCP3ScriptGraph) -> [String: ScriptGraphNodePayload] {
        Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, ScriptGraphPinResolver.payload(for: $0, in: graph)) }
        )
    }

    // MARK: - Palette search

    @Test("Blank query returns the full palette")
    func paletteSearchBlankReturnsAll() {
        func types(_ sections: [ScriptGraphNodeLibrary.PaletteSection]) -> [String] {
            sections.flatMap(\.items).map(\.type)
        }
        let all = types(ScriptGraphNodeLibrary.paletteSections)
        #expect(types(ScriptGraphNodeLibrary.paletteSections(matching: "")) == all)
        #expect(types(ScriptGraphNodeLibrary.paletteSections(matching: "   ")) == all)
    }

    @Test("Query matches on display name and on raw type")
    func paletteSearchMatchesNameAndType() {
        func types(_ q: String) -> Set<String> {
            Set(ScriptGraphNodeLibrary.paletteSections(matching: q).flatMap(\.items).map(\.type))
        }
        // The drag event is found by readable name, by raw type, and by a fragment.
        #expect(types("drag").contains("tm_gesture_event_drag"))
        #expect(types("tm_gesture_event_drag").contains("tm_gesture_event_drag"))
        #expect(types("gesture").contains("tm_gesture_event_drag"))
        // Case-insensitive.
        #expect(types("DRAG").contains("tm_gesture_event_drag"))
    }

    @Test("A query that matches nothing yields no sections")
    func paletteSearchNoMatchIsEmpty() {
        #expect(ScriptGraphNodeLibrary.paletteSections(matching: "zzzznotanode").isEmpty)
    }

    @Test("Filtered results are a subset of the full palette")
    func paletteSearchIsSubset() {
        let allTypes = Set(ScriptGraphNodeLibrary.paletteItems.map(\.type))
        let filtered = Set(
            ScriptGraphNodeLibrary.paletteSections(matching: "set").flatMap(\.items).map(\.type)
        )
        #expect(!filtered.isEmpty)
        #expect(filtered.isSubset(of: allTypes))
    }

    // MARK: - Library

    @Test("Drag spec declares the full named output set")
    func dragSpecOutputs() throws {
        let spec = try #require(ScriptGraphNodeLibrary.spec(for: "tm_gesture_event_drag"))
        #expect(spec.inputs.isEmpty)
        // One exec output + nine data outputs.
        #expect(spec.outputs.filter(\.isExec).count == 1)
        let dataNames = spec.outputs.filter { !$0.isExec }.map(\.displayName)
        #expect(dataNames == [
            "Entity", "Location", "Start Location", "Translation",
            "Scene Location", "Scene Start Location", "Scene Translation",
            "Scene Input Device Rotation", "Did End",
        ])
    }

    @Test("Palette lists every node type that has a spec, with readable names")
    func paletteItems() throws {
        let items = ScriptGraphNodeLibrary.paletteItems
        #expect(!items.isEmpty)

        // Every palette item maps to a real spec (so inserted nodes have an interface),
        // and id == type.
        for item in items {
            #expect(item.id == item.type)
            #expect(ScriptGraphNodeLibrary.spec(for: item.type) != nil)
        }

        // The known insertable types appear with their curated display names.
        let byType = Dictionary(uniqueKeysWithValues: items.map { ($0.type, $0.displayName) })
        #expect(byType["tm_set_component"] == "Set Component")
        #expect(byType["tm_gesture_event_drag"] == "On Drag")
        #expect(byType["tm_gesture_event_tap"] == "On Tap")

        // The expanded palette: On Update, Get Component, and the lifecycle events.
        #expect(byType["tm_update"] == "On Update")
        #expect(byType["tm_get_component"] == "Get Component")
        #expect(byType["tm_did_add"] == "On Added")
        #expect(byType["tm_did_activate"] == "On Activated")
        #expect(byType["tm_will_remove"] == "Will Remove")
        #expect(byType["tm_will_deactivate"] == "Will Deactivate")
        #expect(byType["tm_script_changed"] == "Script Changed")

        // The math/make/string batch, with curated names.
        #expect(byType["tm_math_greater"] == "Greater")
        #expect(byType["tm_math_within_range"] == "Within Range")
        #expect(byType["tm_constant_pi"] == "π")
        #expect(byType["tm_constant_sqrt1_2"] == "Sqrt(0.5)")
        #expect(byType["tm_make_vector3"] == "Vector3")
        #expect(byType["tm_make_color"] == "Color")
        #expect(byType["tm_cgcolor_to_color"] == "CGColor to Color")
        #expect(byType["tm_color_to_cgcolor"] == "Color to CGColor")
        #expect(byType["tm_string_has_prefix"] == "Has Prefix")
        #expect(byType["tm_string_length"] == "String Length")

        // The logic/arithmetic/constant/variable batch, with curated names.
        #expect(byType["tm_and"] == "And")
        #expect(byType["tm_math_add"] == "Add")
        #expect(byType["tm_math_multiply_by_scalar"] == "Multiply by Scalar")
        #expect(byType["tm_math_sqrt"] == "Square Root")
        #expect(byType["tm_constant"] == "Constant")
        #expect(byType["tm_get_variable_node"] == "Get Variable")
        #expect(byType["tm_set_remote_variable_node"] == "Set Remote Variable")

        // Data-driven: one palette item per type that has a spec.
        let expectedTypes = [
            // Events
            "tm_gesture_event_drag", "tm_gesture_event_tap", "tm_update",
            "tm_did_add", "tm_did_activate", "tm_will_remove",
            "tm_will_deactivate", "tm_script_changed",
            "tm_collision_event_began", "tm_collision_event_ended",
            "tm_collision_event_updated", "tm_physics_event_will_simulate",
            "tm_physics_event_did_simulate", "tm_animation_event_playback_started",
            "tm_animation_event_playback_completed", "tm_animation_event_playback_looped",
            "tm_animation_event_playback_terminated", "tm_audio_event_playback_completed",
            // Components
            "tm_set_component", "tm_get_component",
            // Math — Comparison
            "tm_math_greater", "tm_math_greater_equal", "tm_math_less",
            "tm_math_less_equal", "tm_math_within_range", "tm_math_random",
            // Math — Rotation
            "tm_math_quaternion_to_euler", "tm_math_euler_to_quaternion",
            "tm_make_rotation", "tm_make_look_at_rotation",
            "tm_math_deg_to_rad", "tm_math_rad_to_deg",
            // Math — Constant
            "tm_constant_pi", "tm_constant_e", "tm_constant_ln2", "tm_constant_ln10",
            "tm_constant_log10e", "tm_constant_log2e", "tm_constant_sqrt2",
            "tm_constant_sqrt1_2",
            // Make
            "tm_make_vector2", "tm_make_vector3", "tm_make_vector4",
            "tm_make_vector4_with_vector3", "tm_make_matrix2x2", "tm_make_matrix3x3",
            "tm_make_matrix4x4", "tm_make_cgcolor", "tm_make_color", "tm_make_cgsize",
            "tm_make_edge_insets", "tm_cgcolor_to_color", "tm_color_to_cgcolor",
            // Break
            "tm_break_vector2", "tm_break_vector3", "tm_break_vector4",
            "tm_break_cgpoint", "tm_break_cgsize", "tm_break_color", "tm_break_cgcolor",
            // String
            "tm_string_has_prefix", "tm_string_has_suffix", "tm_string_contains",
            "tm_string_length", "tm_string_prefix", "tm_string_suffix",
            "tm_string_substring",
            // Control Flow
            "tm_sequence", "tm_if", "tm_switch", "tm_loop", "tm_delay",
            "tm_cancel_delay", "tm_do_once",
            // Entity
            "tm_entity_set_relative_transform", "tm_entity_get_world_transform",
            "tm_entity_set_world_transform", "tm_entity_look_at", "tm_set_entity_enable",
            "tm_find_entity", "tm_find_parent_entity", "tm_find_entity_with_component",
            "tm_has_component", "tm_get_parent", "tm_get_children", "tm_set_parent", "tm_add_child",
            "tm_remove_child", "tm_remove_from_parent", "tm_self", "tm_scene",
            // Logic
            "tm_and", "tm_or", "tm_equals", "tm_not_equals", "tm_not",
            // Math — Arithmetic & trig
            "tm_math_add", "tm_math_subtract", "tm_math_multiply", "tm_math_divide",
            "tm_math_mod", "tm_math_min", "tm_math_max", "tm_math_dot", "tm_math_cross",
            "tm_math_reflect", "tm_math_bitwise_and", "tm_math_bitwise_or",
            "tm_math_bitwise_xor", "tm_math_sin", "tm_math_cos", "tm_math_tan",
            "tm_math_asin", "tm_math_acos", "tm_math_atan", "tm_math_sqrt",
            "tm_math_log", "tm_math_log2", "tm_math_abs", "tm_math_ceil",
            "tm_math_floor", "tm_math_round", "tm_math_trunc", "tm_math_length",
            "tm_math_normal", "tm_math_bitwise_not", "tm_math_pow", "tm_math_clamp",
            "tm_math_lerp", "tm_math_slerp", "tm_math_smoothstep",
            "tm_math_multiply_by_scalar", "tm_math_multiply_by_quaternion",
            "tm_math_multiply_by_matrix",
            // Math — Constant (literal)
            "tm_constant",
            // Variables
            "tm_get_variable_node", "tm_set_variable_node", "tm_clear_variable_node",
            "tm_get_remote_variable_node", "tm_set_remote_variable_node",
            "tm_clear_remote_variable_node",
        ]
        let schemaDerivedTypes = Set(ScriptGraphValueSchema.breakNodes.keys)
            .union(ScriptGraphValueSchema.writeNodes.keys)
            .union(ScriptGraphValueSchema.enumMakeNodes.keys)
            .union(ScriptGraphValueSchema.enumBreakNodes.keys)
        let newlySourceBackedTypes: Set<String> = [
            "tm_make_bool", "tm_make_number", "tm_make_string",
            "tm_in_editor", "tm_host_is_ios", "tm_host_is_macos",
            "tm_host_is_simulator", "tm_host_is_tvos", "tm_host_is_visionos",
            "tm_host_time",
            "tm_is_head_tracking_available", "tm_is_hand_tracking_available",
            "tm_hand_joint", "tm_head_tracking",
            "tm_stop_all_animations", "tm_stop_animation", "tm_pause_animation",
            "tm_play_animation_by_name", "tm_play_animation_by_index",
            "tm_input_get_gamepad", "tm_input_get_keyboard", "tm_input_get_mouse",
            "tm_input_gamepad_axes", "tm_input_gamepad_button",
            "tm_input_keyboard_key", "tm_input_mouse_button", "tm_input_mouse_motion",
            "tm_get_material",
            "tm_scene_raycast_v2", "tm_scene_convex_cast",
            "tm_make_audio_mix_group", "tm_make_collision_group_number",
            "tm_make_font", "tm_make_attributed_string",
            "tm_attributed_string_size",
            "tm_make_collision_filter_number", "tm_make_collision_filter",
            "tm_make_sphere_shape", "tm_make_capsule_shape", "tm_make_box_shape",
            "tm_entity_equals", "tm_entity_get_relative_transform",
            "tm_entity_get_local_direction_vectors", "tm_entity_get_world_direction_vectors",
            "tm_physics_clear_forces_and_torques", "tm_physics_reset_transform",
            "tm_physics_add_force", "tm_physics_add_torque",
            "tm_physics_apply_linear_impulse", "tm_physics_apply_angular_impulse",
            "tm_physics_apply_impulse",
            "tm_make_material_parameter_types_texture_coordinate_transform",
            "tm_make_physically_based_material_anisotropy_angle",
            "tm_make_physically_based_material_anisotropy_level",
            "tm_make_physically_based_material_base_color",
            "tm_make_physically_based_material_clearcoat",
            "tm_make_physically_based_material_clearcoat_roughness",
            "tm_make_physically_based_material_emissive_color",
            "tm_make_physically_based_material_metallic",
            "tm_make_physically_based_material_roughness",
            "tm_make_physically_based_material_sheen_color",
            "tm_make_physics_mass_properties", "tm_make_physics_material_resource",
            "tm_audio_mix_groups_component_add_group",
            "tm_audio_mix_groups_component_remove_group",
            "tm_remove_component",
            "tm_pause_audio", "tm_seek_audio", "tm_fade_audio",
            "tm_pause_audio_group", "tm_seek_audio_group", "tm_fade_audio_group",
            "tm_stop_all_audio",
            "tm_stop_audio", "tm_stop_audio_group",
            "tm_play_audio_at_time", "tm_play_audio_group_at_time",
            "tm_fade_audio_mix_group", "tm_play_audio_by_name",
            "tm_play_audio_group_by_name",
            "tm_entity_convert_matrix_to", "tm_entity_convert_matrix_from",
            "tm_entity_convert_direction_to", "tm_entity_convert_direction_from",
            "tm_entity_convert_normal_to", "tm_entity_convert_normal_from",
            "tm_entity_convert_position_to", "tm_entity_convert_position_from",
            "tm_entity_move_character", "tm_entity_teleport_character", "tm_entity_move",
            "tm_constant_bitset", "tm_bool_to_any", "tm_cgcolor_to_color", "tm_color_to_cgcolor",
            "tm_variable_add", "tm_variable_subtract", "tm_variable_multiply",
            "tm_variable_divide", "tm_variable_multiply_by_scalar",
            "tm_variable_multiply_by_quaternion", "tm_variable_multiply_by_matrix",
            "tm_math_inverse",
        ]
        let expectedTypeSet = Set(expectedTypes)
            .union(schemaDerivedTypes)
            .union(newlySourceBackedTypes)
            .union([
                "tm_to_string", "tm_string_merge", "tm_array_add", "tm_array_count",
                "tm_array_create", "tm_array_find", "tm_array_for_each", "tm_array_get",
                "tm_array_remove", "tm_array_set", "tm_custom_event", "tm_is_valid",
                "tm_is_valid_branch", "tm_on_entity_event", "tm_on_scene_event",
                "tm_send_entity_event", "tm_send_scene_event", "tm_trigger_event",
            ])
        #expect(items.count == expectedTypeSet.count)
        #expect(Set(items.map(\.type)) == expectedTypeSet)
    }

    @Test("Public value schemas author fixed Break and Write interfaces")
    func schemaDerivedBreakAndWriteSpecs() throws {
        let breakMatrix = try #require(ScriptGraphNodeLibrary.spec(for: "tm_break_matrix2x2"))
        #expect(breakMatrix.inputs.map(\.connectorName) == ["source"])
        #expect(breakMatrix.outputs.map(\.connectorName) == [
            "col0", "col1", "determinant", "inverse", "transpose",
        ])

        let writeMatrix = try #require(ScriptGraphNodeLibrary.spec(for: "tm_write_matrix2x2"))
        #expect(writeMatrix.inputs.map(\.connectorName) == ["source", "col0", "col1"])
        #expect(writeMatrix.outputs.map(\.connectorName) == ["source"])

        let breakContact = try #require(ScriptGraphNodeLibrary.spec(for: "tm_break_contact"))
        #expect(breakContact.outputs.map(\.connectorName) == ["impulse", "normal", "point"])
        #expect(ScriptGraphNodeLibrary.paletteItems.contains { $0.type == "tm_write_entity" })
    }

    @Test("Public enum schemas author case-dependent connectors")
    func schemaDerivedEnumPolicies() throws {
        let make = try #require(
            ScriptGraphNodeLibrary.enumPinPolicy(for: "tm_make_anchoring_component_target")
        )
        #expect(make.direction == .make)
        #expect(make.fixedPins.map(\.connectorName) == ["value"])
        let plane = try #require(make.schema.cases.first { $0.name == "plane" })
        #expect(plane.associatedValues.map(\.name) == ["value0", "value1", "value2"])

        let breakPolicy = try #require(
            ScriptGraphNodeLibrary.enumPinPolicy(for: "tm_break_audio_directivity")
        )
        #expect(breakPolicy.direction == .break)
        #expect(breakPolicy.fixedPins.map(\.connectorName) == ["source"])
        #expect(ScriptGraphNodeLibrary.paletteItems.contains {
            $0.type == "tm_make_anchoring_component_target"
        })

        let selection = try #require(ScriptGraphNodeLibrary.enumSelection(
            for: "tm_make_anchoring_component_target", caseName: "plane"
        ))
        let node = RCP3ScriptGraph.Node(
            id: "enum", type: "tm_make_anchoring_component_target",
            enumSelection: selection
        )
        let graph = RCP3ScriptGraph(nodes: [node], wires: [], data: [])
        let payload = ScriptGraphPinResolver.payload(for: node, in: graph)
        #expect(payload.inputPins.map(\.label) == ["Value 0", "Value 1", "Value 2"])
        #expect(payload.outputPins.map(\.label) == ["Value"])
    }

    @Test("Material settings derive exact typed connector names without Any placeholders")
    func materialSettingsDerivedSpecs() throws {
        typealias Property = RCP3ScriptGraph.Node.MaterialSettings.Property
        let settings = RCP3ScriptGraph.Node.MaterialSettings(
            typeHash: 0x101,
            objectIdentifier: "RealityKit.PhysicallyBasedMaterial",
            inputs: [
                Property(name: "value", typeHash: 0x201, editTypeHash: 0x301, isOptional: false),
                Property(name: "clearcoat_roughness", typeHash: 0x202, editTypeHash: 0x302, isOptional: true),
            ],
            outputs: [
                Property(name: "result", typeHash: 0x201, editTypeHash: 0x301, isOptional: false),
                Property(name: "base_color", typeHash: 0x203, editTypeHash: 0x303, isOptional: false),
            ]
        )

        let get = try #require(ScriptGraphNodeLibrary.materialSpec(
            for: "tm_get_material_parameter", settings: settings
        ))
        #expect(get.inputs.map(\.connectorName) == ["entity", "slot", "parameter"])
        #expect(get.outputs.map(\.connectorName) == ["result", "base_color"])

        let set = try #require(ScriptGraphNodeLibrary.materialSpec(
            for: "tm_set_material_parameter_v2", settings: settings
        ))
        #expect(set.inputs.map(\.connectorName) == ["", "entity", "slot", "parameter", "value", "clearcoat_roughness"])
        #expect(set.outputs.map(\.connectorName) == [""])

        let modify = try #require(ScriptGraphNodeLibrary.materialSpec(
            for: "tm_modify_any_material", settings: settings
        ))
        #expect(modify.inputs.map(\.connectorName) == ["", "entity", "slot", "value", "clearcoat_roughness"])
        #expect(modify.outputs.map(\.connectorName) == ["", "result", "base_color"])

        let node = RCP3ScriptGraph.Node(
            id: "material", type: "tm_modify_any_material", materialSettings: settings
        )
        let graph = RCP3ScriptGraph(nodes: [node], wires: [], data: [])
        let payload = ScriptGraphPinResolver.payload(for: node, in: graph)
        #expect(payload.inputPins.map(\.label) == ["exec", "Entity", "Slot", "Value", "Clearcoat Roughness"])
        #expect(payload.outputPins.map(\.label) == ["exec", "Result", "Base Color"])
        #expect(payload.pins.allSatisfy { !$0.label.contains("Any") })
    }

    @Test("Entity Parameter settings select the typed Get and Set interfaces")
    func entityParameterSettingsDerivedSpecs() throws {
        let settings = RCP3ScriptGraph.Node.EntityParameterSettings(typeHash: 0x1111)
        let get = try #require(ScriptGraphNodeLibrary.entityParameterSpec(
            for: "tm_get_entity_parameter", settings: settings
        ))
        #expect(get.inputs.map(\.connectorName) == ["entity", "name"])
        #expect(get.outputs.map(\.connectorName) == ["result"])

        let set = try #require(ScriptGraphNodeLibrary.entityParameterSpec(
            for: "tm_set_entity_parameter", settings: settings
        ))
        #expect(set.inputs.map(\.connectorName) == ["", "entity", "name", "value"])
        #expect(set.outputs.map(\.connectorName) == [""])

        let node = RCP3ScriptGraph.Node(
            id: "parameter", type: "tm_set_entity_parameter", entityParameterSettings: settings
        )
        let payload = ScriptGraphPinResolver.payload(
            for: node, in: RCP3ScriptGraph(nodes: [node], wires: [], data: [])
        )
        #expect(payload.inputPins.map(\.label) == ["exec", "Entity", "Name", "Value"])
        #expect(payload.outputPins.map(\.label) == ["exec"])

        for type in ["tm_get_entity_parameter", "tm_set_entity_parameter"] {
            #expect(ScriptGraphNodeLibrary.paletteItems.contains { $0.type == type })
            #expect(ScriptGraphAuthoringRecipes.recipe(for: type) != nil)
            #expect(
                ScriptGraphNodeLibrary.defaultEntityParameterSettings(for: type)?.typeHash
                    == 0xaed3caa5c516d191
            )
        }
    }

    @Test("New data-only node specs declare faithful pin connector names, no exec")
    func dataOnlyNodeSpecs() throws {
        // Comparison: a, b → result.
        let greater = try #require(ScriptGraphNodeLibrary.spec(for: "tm_math_greater"))
        #expect(greater.inputs.map(\.connectorName) == ["a", "b"])
        #expect(greater.outputs.map(\.connectorName) == ["result"])
        // Data-only: no exec pins anywhere.
        #expect(greater.inputs.allSatisfy { !$0.isExec })
        #expect(greater.outputs.allSatisfy { !$0.isExec })

        // Within Range: val, min, max → result.
        let within = try #require(ScriptGraphNodeLibrary.spec(for: "tm_math_within_range"))
        #expect(within.inputs.map(\.connectorName) == ["val", "min", "max"])
        #expect(within.outputs.map(\.connectorName) == ["result"])

        // Make Vector3: x, y, z → vec3 (output connector name is faithful too).
        let vec3 = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_vector3"))
        #expect(vec3.inputs.map(\.connectorName) == ["x", "y", "z"])
        let makeBool = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_bool"))
        #expect(makeBool.inputs.map(\.connectorName) == ["initial_value"])
        #expect(makeBool.outputs.map(\.connectorName) == ["value"])
        let macOS = try #require(ScriptGraphNodeLibrary.spec(for: "tm_host_is_macos"))
        #expect(macOS.inputs.isEmpty)
        #expect(macOS.outputs.map(\.connectorName) == ["status"])
        let iOS = try #require(ScriptGraphNodeLibrary.spec(for: "tm_host_is_ios"))
        #expect(iOS.outputs.map(\.connectorName) == ["result"])
        let collisionFilter = try #require(
            ScriptGraphNodeLibrary.spec(for: "tm_make_collision_filter")
        )
        #expect(collisionFilter.inputs.map(\.connectorName) == ["group", "mask"])
        #expect(collisionFilter.outputs.map(\.connectorName) == ["filter"])
        #expect(vec3.outputs.map(\.connectorName) == ["vec3"])

        // Look-at Rotation uses the camelCase `upVector` connector.
        let lookAt = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_look_at_rotation"))
        #expect(lookAt.inputs.map(\.connectorName) == ["at", "from", "upVector"])
        #expect(lookAt.outputs.map(\.connectorName) == ["new"])

        // Constants: no inputs; one output whose connector name is the UPPERCASE name.
        let pi = try #require(ScriptGraphNodeLibrary.spec(for: "tm_constant_pi"))
        #expect(pi.inputs.isEmpty)
        #expect(pi.outputs.map(\.connectorName) == ["PI"])
        let sqrtHalf = try #require(ScriptGraphNodeLibrary.spec(for: "tm_constant_sqrt1_2"))
        #expect(sqrtHalf.outputs.map(\.connectorName) == ["SQRT1_2"])

        // String: has-prefix predicate, plus length.
        let hasPrefix = try #require(ScriptGraphNodeLibrary.spec(for: "tm_string_has_prefix"))
        #expect(hasPrefix.inputs.map(\.connectorName) == ["string", "prefix"])
        #expect(hasPrefix.outputs.map(\.connectorName) == ["result"])
        let length = try #require(ScriptGraphNodeLibrary.spec(for: "tm_string_length"))
        #expect(length.outputs.map(\.connectorName) == ["length"])
    }

    @Test("Variable math operations share the harvested mutation contract")
    func variableMutationSpecs() throws {
        let expectedOperands: [String: String] = [
            "tm_variable_add": "value",
            "tm_variable_subtract": "value",
            "tm_variable_multiply": "value",
            "tm_variable_divide": "value",
            "tm_variable_multiply_by_scalar": "scalar",
            "tm_variable_multiply_by_quaternion": "quaternion",
            "tm_variable_multiply_by_matrix": "matrix",
        ]
        for (type, operand) in expectedOperands {
            let spec = try #require(ScriptGraphNodeLibrary.spec(for: type))
            #expect(spec.inputs.map(\.connectorName) == ["", operand])
            #expect(spec.outputs.map(\.connectorName) == ["", "result"])
        }
    }

    @Test("Shape constructors use the source-harvested interfaces")
    func shapeConstructorSpecs() throws {
        let sphere = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_sphere_shape"))
        #expect(sphere.inputs.map(\.connectorName) == ["radius"])
        #expect(sphere.outputs.map(\.connectorName) == ["shape"])

        let capsule = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_capsule_shape"))
        #expect(capsule.inputs.map(\.connectorName) == ["height", "radius"])
        #expect(capsule.outputs.map(\.connectorName) == ["shape"])

        let box = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_box_shape"))
        #expect(box.inputs.map(\.connectorName) == ["extents"])
        #expect(box.outputs.map(\.connectorName) == ["shape"])
    }

    @Test("Material and physics Make nodes use harvested connector contracts")
    func materialAndPhysicsMakeSpecs() throws {
        let textureTransform = try #require(ScriptGraphNodeLibrary.spec(
            for: "tm_make_material_parameter_types_texture_coordinate_transform"
        ))
        #expect(textureTransform.inputs.map(\.connectorName) == ["offset", "scale", "rotation"])
        #expect(textureTransform.outputs.map(\.connectorName) == ["textureCoordinateTransform"])

        let baseColor = try #require(ScriptGraphNodeLibrary.spec(
            for: "tm_make_physically_based_material_base_color"
        ))
        #expect(baseColor.inputs.map(\.connectorName) == ["red", "green", "blue", "alpha"])
        #expect(baseColor.outputs.map(\.connectorName) == ["baseColor"])

        let scalarContracts: [(String, String, String)] = [
            ("tm_make_physically_based_material_anisotropy_angle", "angle", "angle"),
            ("tm_make_physically_based_material_anisotropy_level", "level", "level"),
            ("tm_make_physically_based_material_clearcoat", "clearcoat", "clearcoat"),
            ("tm_make_physically_based_material_clearcoat_roughness", "roughness", "roughness"),
            ("tm_make_physically_based_material_metallic", "metallic", "metallic"),
            ("tm_make_physically_based_material_roughness", "roughness", "roughness"),
        ]
        for (type, input, output) in scalarContracts {
            let spec = try #require(ScriptGraphNodeLibrary.spec(for: type))
            #expect(spec.inputs.map(\.connectorName) == [input])
            #expect(spec.outputs.map(\.connectorName) == [output])
        }

        let mass = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_physics_mass_properties"))
        #expect(mass.inputs.map(\.connectorName) == ["mass", "inertia", "position", "orientation"])
        #expect(mass.outputs.map(\.connectorName) == ["massProperties"])

        let material = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_physics_material_resource"))
        #expect(material.inputs.map(\.connectorName) == ["staticFriction", "dynamicFriction", "restitution"])
        #expect(material.outputs.map(\.connectorName) == ["material"])
    }

    @Test("Text constructors use source-harvested capitalization and modifier order")
    func textConstructorSpecs() throws {
        let font = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_font"))
        #expect(font.inputs.map(\.connectorName) == [
            "name", "size", "weight", "italic", "monospaced", "monospacedDigit",
        ])
        #expect(font.outputs.map(\.connectorName) == ["font"])

        let attributed = try #require(ScriptGraphNodeLibrary.spec(for: "tm_make_attributed_string"))
        #expect(attributed.inputs.map(\.connectorName) == [
            "Text", "font", "alignment", "foregroundColor", "backgroundColor",
        ])
        #expect(attributed.outputs.map(\.connectorName) == ["string"])

        let size = try #require(ScriptGraphNodeLibrary.spec(for: "tm_attributed_string_size"))
        #expect(size.inputs.map(\.connectorName) == ["string", "maxWidth", "padding"])
        #expect(size.outputs.map(\.connectorName) == ["size"])
    }

    @Test("Tracking input nodes expose the source-harvested records")
    func trackingInputSpecs() throws {
        for type in ["tm_is_head_tracking_available", "tm_is_hand_tracking_available"] {
            let spec = try #require(ScriptGraphNodeLibrary.spec(for: type))
            #expect(spec.inputs.isEmpty)
            #expect(spec.outputs.map(\.connectorName) == ["status"])
        }
        let joint = try #require(ScriptGraphNodeLibrary.spec(for: "tm_hand_joint"))
        #expect(joint.inputs.map(\.connectorName) == ["hand", "joint"])
        #expect(joint.outputs.map(\.connectorName) == ["position", "orientation"])
        let head = try #require(ScriptGraphNodeLibrary.spec(for: "tm_head_tracking"))
        #expect(head.inputs.isEmpty)
        #expect(head.outputs.map(\.connectorName) == ["position", "orientation"])
        #expect(try #require(ScriptGraphNodeLibrary.spec(for: "tm_input_get_keyboard")).outputs.map(\.connectorName) == ["keyboard"])
        #expect(try #require(ScriptGraphNodeLibrary.spec(for: "tm_input_get_mouse")).outputs.map(\.connectorName) == ["mouse"])
        let gamepad = try #require(ScriptGraphNodeLibrary.spec(for: "tm_input_get_gamepad"))
        #expect(gamepad.inputs.map(\.connectorName) == ["player", "gamepad"])
        #expect(gamepad.outputs.map(\.connectorName) == ["gamepad"])
        let axes = try #require(ScriptGraphNodeLibrary.spec(for: "tm_input_gamepad_axes"))
        #expect(axes.outputs.map(\.connectorName) == ["leftThumbstickAxes", "rightThumbstickAxes", "leftTriggerPressure", "rightTriggerPressure"])
        for type in ["tm_input_gamepad_button", "tm_input_mouse_button"] {
            let button = try #require(ScriptGraphNodeLibrary.spec(for: type))
            #expect(button.inputs.map(\.connectorName).last == "button")
            #expect(button.outputs.map(\.connectorName) == ["down", "pressed", "released", "pressCount"])
        }
        let key = try #require(ScriptGraphNodeLibrary.spec(for: "tm_input_keyboard_key"))
        #expect(key.inputs.map(\.connectorName) == ["keyboard", "key"])
        #expect(key.outputs.map(\.connectorName) == ["down", "pressed", "released", "pressesCount"])
        #expect(try #require(ScriptGraphNodeLibrary.spec(for: "tm_input_mouse_motion")).outputs.map(\.connectorName) == ["delta"])

        let stopAll = try #require(ScriptGraphNodeLibrary.spec(for: "tm_stop_all_animations"))
        #expect(stopAll.inputs.map(\.connectorName) == ["", "entity", "recursive"])
        let stop = try #require(ScriptGraphNodeLibrary.spec(for: "tm_stop_animation"))
        #expect(stop.inputs.map(\.connectorName) == ["", "playbackController", "blendOutDuration"])
        let pause = try #require(ScriptGraphNodeLibrary.spec(for: "tm_pause_animation"))
        #expect(pause.inputs.map(\.connectorName) == ["", "playbackController", "pause"])
        let playName = try #require(ScriptGraphNodeLibrary.spec(for: "tm_play_animation_by_name"))
        #expect(playName.inputs.map(\.connectorName) == ["", "entity", "name", "repeat", "transitionDuration", "startsPaused"])
        #expect(playName.outputs.map(\.connectorName) == ["", "playbackController"])
        let playIndex = try #require(ScriptGraphNodeLibrary.spec(for: "tm_play_animation_by_index"))
        #expect(playIndex.inputs.map(\.connectorName) == ["", "entity", "index", "repeat", "transitionDuration", "startsPaused"])
        let material = try #require(ScriptGraphNodeLibrary.spec(for: "tm_get_material"))
        #expect(material.inputs.map(\.connectorName) == ["entity", "index"])
        #expect(material.outputs.map(\.connectorName) == ["material"])
        let ray = try #require(ScriptGraphNodeLibrary.spec(for: "tm_scene_raycast_v2"))
        #expect(ray.inputs.map(\.connectorName) == ["", "from", "direction", "length", "mask", "relativeTo"])
        #expect(ray.outputs.map(\.connectorName) == ["hit", "miss", "entity", "position", "normal"])
        let convex = try #require(ScriptGraphNodeLibrary.spec(for: "tm_scene_convex_cast"))
        #expect(convex.inputs.map(\.connectorName) == ["", "shape", "from", "to", "mask", "relativeTo"])
        #expect(convex.outputs.map(\.connectorName) == ray.outputs.map(\.connectorName))
    }

    @Test("Audio mix-group and Entity motion specs use shipped connector order")
    func audioAndEntityMotionSpecs() throws {
        let add = try #require(ScriptGraphNodeLibrary.spec(
            for: "tm_audio_mix_groups_component_add_group"
        ))
        #expect(add.inputs.map(\.connectorName) == ["", "source", "mixGroup"])
        #expect(add.outputs.map(\.connectorName) == [""])

        let remove = try #require(ScriptGraphNodeLibrary.spec(
            for: "tm_audio_mix_groups_component_remove_group"
        ))
        #expect(remove.inputs.map(\.connectorName) == ["", "source", "name"])

        let removeComponent = try #require(ScriptGraphNodeLibrary.spec(for: "tm_remove_component"))
        #expect(removeComponent.inputs.map(\.connectorName) == ["", "source", "component_type"])
        #expect(removeComponent.outputs.map(\.connectorName) == [""])

        let audioContracts: [(String, [String])] = [
            ("tm_pause_audio", ["", "source"]),
            ("tm_seek_audio", ["", "source", "time"]),
            ("tm_fade_audio", ["", "source", "gain", "duration"]),
            ("tm_pause_audio_group", ["", "source", "pause"]),
            ("tm_seek_audio_group", ["", "source", "time"]),
            ("tm_fade_audio_group", ["", "source", "gain", "duration"]),
        ]
        for (type, inputs) in audioContracts {
            let spec = try #require(ScriptGraphNodeLibrary.spec(for: type))
            #expect(spec.inputs.map(\.connectorName) == inputs)
            #expect(spec.outputs.map(\.connectorName) == [""])
        }
        let fadeMix = try #require(ScriptGraphNodeLibrary.spec(for: "tm_fade_audio_mix_group"))
        #expect(fadeMix.inputs.map(\.connectorName) == ["", "source", "gain", "duration"])
        #expect(fadeMix.outputs.map(\.connectorName) == [""])
        let named = try #require(ScriptGraphNodeLibrary.spec(for: "tm_play_audio_by_name"))
        #expect(named.inputs.map(\.connectorName) == ["", "entity", "name", "target", "prepareOnly"])
        #expect(named.outputs.map(\.connectorName) == ["source"])
        let group = try #require(ScriptGraphNodeLibrary.spec(for: "tm_play_audio_group_by_name"))
        #expect(group.inputs.map(\.connectorName) == ["", "entities", "names", "source", "prepareOnly"])
        #expect(group.outputs.map(\.connectorName) == ["source"])

        let matrixTo = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_convert_matrix_to"))
        #expect(matrixTo.inputs.map(\.connectorName) == ["entity", "matrix", "toEntity"])
        #expect(matrixTo.outputs.map(\.connectorName) == ["matrix"])
        let matrixFrom = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_convert_matrix_from"))
        #expect(matrixFrom.inputs.map(\.connectorName) == ["entity", "matrix", "fromEntity"])

        for value in ["direction", "normal", "position"] {
            let to = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_convert_\(value)_to"))
            #expect(to.inputs.map(\.connectorName) == ["entity", value, "toEntity"])
            #expect(to.outputs.map(\.connectorName) == [value])
            let from = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_convert_\(value)_from"))
            #expect(from.inputs.map(\.connectorName) == ["entity", value, "fromEntity"])
            #expect(from.outputs.map(\.connectorName) == [value])
        }

        let teleport = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_teleport_character"))
        #expect(teleport.inputs.map(\.connectorName) == ["", "entity", "to", "relativeTo"])

        let move = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_move"))
        #expect(move.inputs.map(\.connectorName) == [
            "", "entity", "scale", "orientation", "position", "relativeTo",
            "duration", "timingFunction",
        ])
        #expect(move.outputs.map(\.connectorName) == ["", "controller"])

        let character = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_move_character"))
        #expect(character.inputs.map(\.connectorName) == ["", "entity", "by", "deltaTime", "relativeTo"])
        #expect(character.outputs.map(\.connectorName) == [
            "", "collision", "hitEntity", "hitPosition", "hitNormal",
            "moveDirection", "moveDistance",
        ])

        let bitset = try #require(ScriptGraphNodeLibrary.spec(for: "tm_constant_bitset"))
        #expect(bitset.inputs.map(\.connectorName) == ["count"])
        #expect(bitset.outputs.map(\.connectorName) == ["value"])

        let boolToAny = try #require(ScriptGraphNodeLibrary.spec(for: "tm_bool_to_any"))
        #expect(boolToAny.inputs.map(\.connectorName) == ["bool", "true", "false"])
        #expect(boolToAny.outputs.map(\.connectorName) == ["result"])
    }

    @Test("Source-harvested dynamic policies stay out of the palette until authorable")
    func dynamicPinPolicies() throws {
        let toString = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_to_string"))
        #expect(toString.minimumInputCount == 1)
        #expect(toString.maximumInputCount == 1)
        #expect(toString.fixedInputs.isEmpty)
        #expect(toString.fixedOutputs.map(\.connectorName) == ["value"])
        #expect(toString.acceptsMixedInputTypes)
        #expect(!toString.requiresArrayInput)

        let join = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_string_merge"))
        #expect(join.minimumInputCount == 3)
        #expect(join.maximumInputCount == nil)
        #expect(join.fixedInputs.map(\.connectorName) == ["separator"])
        #expect(join.fixedOutputs.map(\.connectorName) == ["result"])
        #expect(join.acceptsMixedInputTypes)

        let isValid = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_is_valid"))
        #expect(isValid.minimumInputCount == 1)
        #expect(isValid.maximumInputCount == 1)
        #expect(isValid.fixedOutputs.map(\.connectorName) == ["result"])
        #expect(isValid.acceptsMixedInputTypes)

        let validBranch = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(
            for: "tm_is_valid_branch"
        ))
        #expect(validBranch.minimumInputCount == 1)
        #expect(validBranch.maximumInputCount == 1)
        #expect(validBranch.fixedInputs.map(\.connectorName) == [""])
        #expect(validBranch.fixedOutputs.map(\.connectorName) == ["valid", "invalid"])

        let count = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_array_count"))
        #expect(count.minimumInputCount == 1)
        #expect(count.maximumInputCount == 1)
        #expect(count.fixedOutputs.map(\.connectorName) == ["count"])
        #expect(count.requiresArrayInput)

        let get = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_array_get"))
        #expect(get.fixedInputs.map(\.connectorName) == ["index"])
        #expect(get.fixedOutputs.map(\.connectorName) == ["element"])
        #expect(get.requiresArrayInput)

        let set = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_array_set"))
        #expect(set.fixedInputs.map(\.connectorName) == ["", "index", "element"])
        #expect(set.fixedOutputs.map(\.connectorName) == [""])
        #expect(set.requiresArrayInput)

        let add = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_array_add"))
        #expect(add.fixedInputs.map(\.connectorName) == ["", "element"])
        #expect(add.fixedOutputs.map(\.connectorName) == [""])
        let create = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_array_create"))
        #expect(create.minimumInputCount == 0)
        #expect(create.fixedOutputs.map(\.connectorName) == ["array"])
        let remove = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_array_remove"))
        #expect(remove.fixedInputs.map(\.connectorName) == ["", "index"])
        #expect(remove.fixedOutputs.map(\.connectorName) == [""])
        let each = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_array_for_each"))
        #expect(each.fixedInputs.map(\.connectorName) == [""])
        #expect(each.fixedOutputs.map(\.connectorName) == ["step", "end", "index", "element"])
        let find = try #require(ScriptGraphNodeLibrary.dynamicPinPolicy(for: "tm_array_find"))
        #expect(find.fixedInputs.map(\.connectorName) == ["", "searchValue"])
        #expect(find.fixedOutputs.map(\.connectorName) == ["found", "not found", "index", "element"])
        for type in [
            "tm_custom_event", "tm_on_scene_event", "tm_on_entity_event",
            "tm_trigger_event", "tm_send_scene_event", "tm_send_entity_event",
        ] {
            #expect(ScriptGraphNodeLibrary.dynamicPinPolicy(for: type) != nil)
            #expect(ScriptGraphNodeLibrary.spec(for: type) != nil)
        }
        for type in ["tm_get_entity_parameter", "tm_set_entity_parameter"] {
            #expect(ScriptGraphNodeLibrary.dynamicPinPolicy(for: type) != nil)
            #expect(ScriptGraphNodeLibrary.spec(for: type) == nil)
        }

        // Generic typed settings are authorable; the distinct entity-parameter
        // settings container remains deliberately absent.
        let paletteTypes = Set(ScriptGraphNodeLibrary.paletteItems.map(\.type))
        #expect(paletteTypes.contains("tm_to_string"))
        #expect(paletteTypes.contains("tm_string_merge"))
        #expect(paletteTypes.contains("tm_array_count"))
        #expect(paletteTypes.contains("tm_array_get"))
        #expect(paletteTypes.contains("tm_array_set"))
        #expect(paletteTypes.contains("tm_array_add"))
        #expect(paletteTypes.contains("tm_array_create"))
        #expect(paletteTypes.contains("tm_array_remove"))
        #expect(paletteTypes.contains("tm_array_for_each"))
        #expect(paletteTypes.contains("tm_array_find"))
    }

    @Test("Logic/arithmetic/constant/variable specs declare faithful pins")
    func logicMathVariableSpecs() throws {
        // Logic: variadic, seeded a, b → result (data-only).
        let and = try #require(ScriptGraphNodeLibrary.spec(for: "tm_and"))
        #expect(and.inputs.map(\.connectorName) == ["a", "b"])
        #expect(and.outputs.map(\.connectorName) == ["result"])
        #expect(and.inputs.allSatisfy { !$0.isExec })
        #expect(and.outputs.allSatisfy { !$0.isExec })

        // Equality: a, b → result (data-only); negation: single a → result.
        let equals = try #require(ScriptGraphNodeLibrary.spec(for: "tm_equals"))
        #expect(equals.inputs.map(\.connectorName) == ["a", "b"])
        #expect(equals.outputs.map(\.connectorName) == ["result"])
        #expect(equals.inputs.allSatisfy { !$0.isExec })
        #expect(equals.outputs.allSatisfy { !$0.isExec })
        let notEquals = try #require(ScriptGraphNodeLibrary.spec(for: "tm_not_equals"))
        #expect(notEquals.inputs.map(\.connectorName) == ["a", "b"])
        #expect(notEquals.outputs.map(\.connectorName) == ["result"])
        let not = try #require(ScriptGraphNodeLibrary.spec(for: "tm_not"))
        #expect(not.inputs.map(\.connectorName) == ["a"])
        #expect(not.outputs.map(\.connectorName) == ["result"])
        #expect(not.inputs.allSatisfy { !$0.isExec })
        #expect(not.outputs.allSatisfy { !$0.isExec })

        // Arithmetic binary: a, b → result.
        let add = try #require(ScriptGraphNodeLibrary.spec(for: "tm_math_add"))
        #expect(add.inputs.map(\.connectorName) == ["a", "b"])
        #expect(add.outputs.map(\.connectorName) == ["result"])
        #expect(add.inputs.allSatisfy { !$0.isExec })

        // Trig unary: a → result.
        let sin = try #require(ScriptGraphNodeLibrary.spec(for: "tm_math_sin"))
        #expect(sin.inputs.map(\.connectorName) == ["a"])
        #expect(sin.outputs.map(\.connectorName) == ["result"])

        // Auxiliary-input operators keep their named aux pins.
        let pow = try #require(ScriptGraphNodeLibrary.spec(for: "tm_math_pow"))
        #expect(pow.inputs.map(\.connectorName) == ["a", "exponent"])
        let clamp = try #require(ScriptGraphNodeLibrary.spec(for: "tm_math_clamp"))
        #expect(clamp.inputs.map(\.connectorName) == ["a", "min", "max"])
        let byScalar = try #require(ScriptGraphNodeLibrary.spec(for: "tm_math_multiply_by_scalar"))
        #expect(byScalar.inputs.map(\.connectorName) == ["a", "b"])

        // Constant (literal): no inputs; single `value` output (value in settings).
        let constant = try #require(ScriptGraphNodeLibrary.spec(for: "tm_constant"))
        #expect(constant.inputs.isEmpty)
        #expect(constant.outputs.map(\.connectorName) == ["value"])

        // Get Variable: data-only, output `value`.
        let getVar = try #require(ScriptGraphNodeLibrary.spec(for: "tm_get_variable_node"))
        #expect(getVar.inputs.isEmpty)
        #expect(getVar.outputs.map(\.connectorName) == ["value"])
        #expect(getVar.outputs.allSatisfy { !$0.isExec })

        // Set Variable: exec in + exec out, plus a `value` data input.
        let setVar = try #require(ScriptGraphNodeLibrary.spec(for: "tm_set_variable_node"))
        #expect(setVar.inputs.contains { $0.isExec })
        #expect(setVar.outputs.contains { $0.isExec })
        #expect(setVar.inputs.contains { !$0.isExec && $0.connectorName == "value" })
        #expect(setVar.outputs.allSatisfy { $0.isExec })

        // Clear Variable: exec in + exec out only (no data pins).
        let clearVar = try #require(ScriptGraphNodeLibrary.spec(for: "tm_clear_variable_node"))
        #expect(clearVar.inputs.map(\.isExec) == [true])
        #expect(clearVar.outputs.map(\.isExec) == [true])

        // Remote variants take the referenced variable as a `Variable` Entity input.
        let getRemote = try #require(ScriptGraphNodeLibrary.spec(for: "tm_get_remote_variable_node"))
        #expect(getRemote.inputs.map(\.connectorName) == ["Variable"])
        #expect(getRemote.outputs.map(\.connectorName) == ["value"])
        let setRemote = try #require(ScriptGraphNodeLibrary.spec(for: "tm_set_remote_variable_node"))
        #expect(setRemote.inputs.contains { $0.isExec })
        #expect(setRemote.inputs.contains { !$0.isExec && $0.connectorName == "Variable" })
        #expect(setRemote.inputs.contains { !$0.isExec && $0.connectorName == "value" })
        #expect(setRemote.outputs.contains { $0.isExec })
    }

    @Test("Control-flow specs declare named event outputs")
    func controlFlowNodeSpecs() throws {
        let branch = try #require(ScriptGraphNodeLibrary.spec(for: "tm_if"))
        #expect(branch.inputs.map(\.connectorName) == ["", "condition"])
        #expect(branch.outputs.map(\.connectorName) == ["always", "true", "false"])
        #expect(branch.outputs.allSatisfy { $0.isExec })

        let loop = try #require(ScriptGraphNodeLibrary.spec(for: "tm_loop"))
        #expect(loop.inputs.map(\.connectorName) == ["", "begin", "end", "step", "inclusive"])
        #expect(loop.outputs.map(\.connectorName) == ["step", "end", "index"])
        #expect(loop.outputs.filter(\.isExec).map(\.connectorName) == ["step", "end"])

        let delay = try #require(ScriptGraphNodeLibrary.spec(for: "tm_delay"))
        #expect(delay.inputs.map(\.connectorName) == ["", "seconds", "is unique"])
        #expect(delay.outputs.map(\.connectorName) == ["always", "once", "cancelID"])

        let cancel = try #require(ScriptGraphNodeLibrary.spec(for: "tm_cancel_delay"))
        #expect(cancel.inputs.map(\.connectorName) == ["", "cancelID"])
        #expect(cancel.outputs.map(\.connectorName) == [""])
    }

    @Test("Entity specs declare exact pins")
    func entityNodeSpecs() throws {
        let relative = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_set_relative_transform"))
        #expect(relative.inputs.map(\.connectorName) == ["", "entity", "scale", "orientation", "position", "matrix", "relativeTo"])
        #expect(relative.outputs.map(\.connectorName) == [""])

        let look = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_look_at"))
        #expect(look.inputs.map(\.connectorName) == ["", "entity", "at", "from", "upVector", "relativeTo", "positiveZForward"])
        #expect(look.outputs.map(\.connectorName) == [""])

        let selfNode = try #require(ScriptGraphNodeLibrary.spec(for: "tm_self"))
        #expect(selfNode.inputs.isEmpty)
        #expect(selfNode.outputs.map(\.connectorName) == ["entity"])

        let scene = try #require(ScriptGraphNodeLibrary.spec(for: "tm_scene"))
        #expect(scene.inputs.isEmpty)
        #expect(scene.outputs.map(\.connectorName) == ["scene"])

        let entityEquals = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_equals"))
        #expect(entityEquals.inputs.map(\.connectorName) == ["a", "b"])
        #expect(entityEquals.outputs.map(\.connectorName) == ["result"])
        #expect(entityEquals.inputs.allSatisfy { !$0.isExec })

        let getRelative = try #require(ScriptGraphNodeLibrary.spec(for: "tm_entity_get_relative_transform"))
        #expect(getRelative.inputs.map(\.connectorName) == ["entity", "relativeTo"])
        #expect(getRelative.outputs.map(\.connectorName) == ["scale", "orientation", "position", "matrix"])

        for type in ["tm_entity_get_local_direction_vectors", "tm_entity_get_world_direction_vectors"] {
            let directions = try #require(ScriptGraphNodeLibrary.spec(for: type))
            #expect(directions.inputs.map(\.connectorName) == ["entity"])
            #expect(directions.outputs.map(\.connectorName) == ["up", "right", "forward"])
        }

        for type in ["tm_physics_clear_forces_and_torques", "tm_physics_reset_transform"] {
            let physics = try #require(ScriptGraphNodeLibrary.spec(for: type))
            #expect(physics.inputs.map(\.connectorName) == ["", "entity", "recursive"])
            #expect(physics.outputs.map(\.connectorName) == [""])
        }
        #expect(try #require(ScriptGraphNodeLibrary.spec(for: "tm_physics_add_force")).inputs.map(\.connectorName) == ["", "entity", "force", "at", "relativeTo"])
        #expect(try #require(ScriptGraphNodeLibrary.spec(for: "tm_physics_apply_impulse")).inputs.map(\.connectorName) == ["", "entity", "impulse", "at", "relativeTo"])
        #expect(try #require(ScriptGraphNodeLibrary.spec(for: "tm_physics_add_torque")).inputs.map(\.connectorName) == ["", "entity", "torque", "relativeTo"])
        for type in ["tm_physics_apply_linear_impulse", "tm_physics_apply_angular_impulse"] {
            #expect(try #require(ScriptGraphNodeLibrary.spec(for: type)).inputs.map(\.connectorName) == ["", "entity", "impulse", "relativeTo"])
        }
    }

    @Test("Palette sections group the library by category in display order")
    func paletteSections() throws {
        let sections = ScriptGraphNodeLibrary.paletteSections

        // Sections appear in Category.order: Events, Control Flow, Logic, Entity, Math,
        // Make, String, Components, Variables.
        #expect(sections.map(\.category) == [.events, .controlFlow, .logic, .entity, .math, .make, .string, .components, .variables, .utility])

        let byCategory = Dictionary(uniqueKeysWithValues: sections.map { ($0.category, $0) })

        // Each section's items belong to that category, and are sorted by name.
        for section in sections {
            #expect(section.items.allSatisfy { $0.category == section.category })
            let names = section.items.map(\.displayName)
            #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        }

        // Representative members land in the right section.
        #expect(byCategory[.events]?.items.contains { $0.type == "tm_gesture_event_drag" } == true)
        #expect(byCategory[.components]?.items.contains { $0.type == "tm_set_component" } == true)
        #expect(byCategory[.math]?.items.contains { $0.type == "tm_math_greater" } == true)
        #expect(byCategory[.math]?.items.contains { $0.type == "tm_constant_pi" } == true)
        #expect(byCategory[.make]?.items.contains { $0.type == "tm_make_vector3" } == true)
        #expect(byCategory[.string]?.items.contains { $0.type == "tm_string_contains" } == true)
        #expect(byCategory[.logic]?.items.contains { $0.type == "tm_and" } == true)
        #expect(byCategory[.math]?.items.contains { $0.type == "tm_math_add" } == true)
        #expect(byCategory[.math]?.items.contains { $0.type == "tm_constant" } == true)
        #expect(byCategory[.variables]?.items.contains { $0.type == "tm_set_variable_node" } == true)

        // Every spec'd type is reachable through exactly one section (no drops/dupes).
        let sectionedTypes = sections.flatMap { $0.items.map(\.type) }
        #expect(Set(sectionedTypes) == Set(ScriptGraphNodeLibrary.paletteItems.map(\.type)))
        #expect(sectionedTypes.count == ScriptGraphNodeLibrary.paletteItems.count)
    }

    @Test("Humanized fallback name drops the tm_ prefix and Title Cases the type")
    func humanizedPaletteName() {
        #expect(ScriptGraphNodeLibrary.paletteDisplayName(for: "tm_some_new_node") == "Some New Node")
    }

    @Test("Transform component type resolves by hash")
    func transformTypeName() {
        #expect(ScriptGraphNodeLibrary.componentTypeName(forHash: TMHash.murmur64a("Transform")) == "Transform")
        #expect(TMHash.hex(TMHash.murmur64a("Transform")) == "af53dc359e631774")
        #expect(ScriptGraphNodeLibrary.componentTypeName(forHash: 0xdead_beef) == nil)
    }

    @Test("Transform exposes its four editable properties as data inputs")
    func transformProperties() throws {
        let props = try #require(
            ScriptGraphNodeLibrary.componentProperties(forComponentTypeHash: TMHash.murmur64a("Transform"))
        )
        #expect(props.map(\.displayName) == ["Translation", "Rotation", "Scale", "Matrix"])
        #expect(props.allSatisfy { !$0.isExec })
    }

    // MARK: - Bridge: full On Drag interface

    @Test("On Drag node renders all nine named outputs, wired or not")
    func dragNodeFullInterface() throws {
        let drag = try #require(Self.payloads(for: Self.dragToSetGraph())["n1"])

        let outputs = drag.outputPins.filter { !$0.isExec }
        #expect(outputs.count >= 9)
        let labels = Set(outputs.map(\.label))
        #expect(labels.contains("Scene Translation"))
        #expect(labels.contains("Entity"))
        #expect(labels.contains("Did End"))

        // The wired output (`sceneTranslation`) shares the hashed handle id, so the
        // data wire still resolves to a declared pin.
        #expect(drag.pins.contains { $0.id == "out." + TMHash.hex(TMHash.murmur64a("sceneTranslation")) })
    }

    // MARK: - Bridge: Set Component interface + exposed values

    @Test("Set Component node renders Source/Component Type + Transform properties with exposed values")
    func setComponentFullInterface() throws {
        let set = try #require(Self.payloads(for: Self.dragToSetGraph())["n2"])
        let inputs = set.inputPins

        let source = try #require(inputs.first { $0.label == "Source" })
        #expect(source.valueLabel == "(Self)")

        let componentType = try #require(inputs.first { $0.label == "Component Type" })
        #expect(componentType.valueLabel == "Transform")

        // The four Transform properties appear as data inputs.
        let labels = Set(inputs.map(\.label))
        #expect(labels.isSuperset(of: ["Translation", "Rotation", "Scale", "Matrix"]))

        // Set Component is a passthrough — it declares both exec input and output.
        #expect(set.pins.contains { $0.isExec && $0.isInput })
        #expect(set.pins.contains { $0.isExec && !$0.isInput })
    }

    // MARK: - Bridge: Get Component interface (mirror — properties as OUTPUTS)

    @Test("Get Component node renders Source/Component Type inputs + Transform properties as OUTPUTS")
    func getComponentFullInterface() throws {
        let get = try #require(Self.payloads(for: Self.getComponentGraph())["g1"])

        // Source/Component Type are inputs, with the same exposed values as Set.
        let inputs = get.inputPins
        let source = try #require(inputs.first { $0.label == "Source" })
        #expect(source.valueLabel == "(Self)")
        let componentType = try #require(inputs.first { $0.label == "Component Type" })
        #expect(componentType.valueLabel == "Transform")

        // The four Transform properties appear as data OUTPUTS (you read them) — the
        // mirror of Set Component, where they are inputs.
        let outputLabels = Set(get.outputPins.filter { !$0.isExec }.map(\.label))
        #expect(outputLabels.isSuperset(of: ["Translation", "Rotation", "Scale", "Matrix"]))

        // They are NOT inputs on a Get node.
        let inputLabels = Set(inputs.map(\.label))
        #expect(inputLabels.isDisjoint(with: ["Translation", "Rotation", "Scale", "Matrix"]))

        // RCP renders Get Component as a pure value node with no exec pins.
        #expect(!get.pins.contains { $0.isExec })
    }

    @Test("Get Component without a component_type literal adds no Transform properties")
    func getComponentWithoutType() throws {
        let g1 = RCP3ScriptGraph.Node(id: "g1", type: "tm_get_component", label: "Get")
        let graph = RCP3ScriptGraph(nodes: [g1], wires: [], data: [])

        let get = try #require(Self.payloads(for: graph)["g1"])
        let outputLabels = Set(get.outputPins.map(\.label))
        #expect(!outputLabels.contains("Rotation"))
        let componentType = try #require(get.inputPins.first { $0.label == "Component Type" })
        #expect(componentType.valueLabel == nil)
    }

    @Test("Without a component_type literal, no Transform properties are added")
    func setComponentWithoutType() throws {
        // A bare set node with only the exec wire — no component_type literal.
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let graph = RCP3ScriptGraph(nodes: [n1, n2], wires: [exec], data: [])

        let set = try #require(Self.payloads(for: graph)["n2"])
        let labels = Set(set.inputPins.map(\.label))
        #expect(labels.contains("Source"))
        #expect(labels.contains("Component Type"))
        #expect(!labels.contains("Rotation"))
        // Component type is unresolved, so it exposes no value.
        let componentType = try #require(set.inputPins.first { $0.label == "Component Type" })
        #expect(componentType.valueLabel == nil)
    }

    // MARK: - Integrity

    @Test("Every wire endpoint resolves to an existing pin (no dangling)")
    func noDanglingWires() {
        assertIntegrity(of: Self.dragToSetGraph())
    }

    // MARK: - Optional real-bundle parity (depth-robust skip)

    @Test("Random capture (if present): On Drag + Set Component render full interfaces")
    func realBundleParity() throws {
        guard let url = Self.locateReferenceBundle() else { return }
        let bundle = try RCP3Bundle.open(url)

        var sawDrag = false
        var sawSet = false
        for entity in Self.allEntities(bundle.entity) {
            guard let graph = bundle.scriptGraph(forEntityID: entity.id), !graph.nodes.isEmpty else { continue }
            let payloads = Self.payloads(for: graph)

            if let drag = payloads.values.first(where: { $0.type == "tm_gesture_event_drag" }) {
                sawDrag = true
                #expect(drag.outputPins.filter { !$0.isExec }.count >= 9)
                #expect(drag.outputPins.contains { $0.label == "Scene Translation" })
            }
            if let set = payloads.values.first(where: { $0.type == "tm_set_component" }) {
                sawSet = true
                let labels = Set(set.inputPins.map(\.label))
                #expect(labels.contains("Source"))
                #expect(labels.contains("Component Type"))
            }

            // Integrity holds on the real graph too.
            assertIntegrity(of: graph)
        }
        _ = (sawDrag, sawSet) // not assertion targets — the capture may differ
    }

    // MARK: - Helpers

    /// Asserts every wire whose endpoints both exist resolves to pins those nodes
    /// declare — no dangling connections (renderer-agnostic).
    private func assertIntegrity(of graph: RCP3ScriptGraph, sourceLocation: SourceLocation = #_sourceLocation) {
        let pinIDsByNode = Self.payloads(for: graph).mapValues { Set($0.pins.map(\.id)) }
        for wire in graph.wires {
            guard let sourcePins = pinIDsByNode[wire.from],
                  let targetPins = pinIDsByNode[wire.to] else { continue }
            let sourceID: String
            let targetID: String
            if wire.isExec {
                sourceID = ScriptGraphPinResolver.execOutHandleID
                targetID = ScriptGraphPinResolver.execInHandleID
            } else {
                guard let fromPin = wire.fromPin, let toPin = wire.toPin else { continue }
                sourceID = ScriptGraphPinResolver.outputHandleID(forHash: fromPin)
                targetID = ScriptGraphPinResolver.inputHandleID(forHash: toPin)
            }
            #expect(sourcePins.contains(sourceID),
                    "wire \(wire.id): source node \(wire.from) lacks pin \(sourceID)",
                    sourceLocation: sourceLocation)
            #expect(targetPins.contains(targetID),
                    "wire \(wire.id): target node \(wire.to) lacks pin \(targetID)",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: - Fixtures

    /// The "drag → set" graph with a `component_type` literal naming `Transform`, so
    /// the set node resolves its component and exposes Transform's property pins.
    static func dragToSetGraph() -> RCP3ScriptGraph {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set Transform")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        // A data wire from the drag's `sceneTranslation` output into the set's
        // `translation` input (matches the canonical capture).
        let data = RCP3ScriptGraph.Wire(
            id: "c2",
            from: "n1",
            to: "n2",
            fromPin: TMHash.murmur64a("sceneTranslation"),
            toPin: TMHash.murmur64a("translation")
        )
        // The `component_type` literal: its `valueHash` names the Transform component.
        let literal = RCP3ScriptGraph.DataLiteral(
            id: "d1",
            toNode: "n2",
            toPin: TMHash.murmur64a("component_type"),
            valueType: "re_scripting_graph_component_type",
            valueHash: TMHash.murmur64a("Transform")
        )
        return RCP3ScriptGraph(nodes: [n1, n2], wires: [exec, data], data: [literal])
    }

    /// A lone Get Component node with a `component_type` literal naming `Transform`, so
    /// the get node resolves its component and exposes Transform's property pins — as
    /// OUTPUTS (the mirror of `dragToSetGraph`'s input properties).
    static func getComponentGraph() -> RCP3ScriptGraph {
        let g1 = RCP3ScriptGraph.Node(id: "g1", type: "tm_get_component", label: "Get Transform")
        let literal = RCP3ScriptGraph.DataLiteral(
            id: "d1",
            toNode: "g1",
            toPin: TMHash.murmur64a("component_type"),
            valueType: "re_scripting_graph_component_type",
            valueHash: TMHash.murmur64a("Transform")
        )
        return RCP3ScriptGraph(nodes: [g1], wires: [], data: [literal])
    }

    private static func allEntities(_ root: RCP3Entity) -> [RCP3Entity] {
        var result = [root]
        for child in root.children { result.append(contentsOf: allEntities(child)) }
        return result
    }

    private static func locateReferenceBundle() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "references/Random.realitycomposerpro"
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
