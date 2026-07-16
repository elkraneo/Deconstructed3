import Testing

@testable import RCP3GraphEditor
import RCP3Document
import TMFormat

@Suite("ScriptGraphValidator")
struct ScriptGraphValidatorTests {
    @Test("Structural identity and endpoint failures are deterministic")
    func structuralFailures() {
        let graph = RCP3ScriptGraph(
            nodes: [
                .init(id: "duplicate", type: "tm_update"),
                .init(id: "duplicate", type: "tm_update"),
            ],
            wires: [
                .init(id: "wire", from: "missing-source", to: "duplicate", fromPin: 1),
                .init(id: "wire", from: "duplicate", to: "missing-target"),
            ],
            data: [.init(id: "literal", toNode: "missing-literal-target", toPin: 1)],
            variables: [
                .init(uuid: "variable", name: "Score"),
                .init(uuid: "variable", name: "score"),
            ]
        )

        let first = ScriptGraphValidator.validate(graph)
        let second = ScriptGraphValidator.validate(graph)
        #expect(first == second)
        #expect(Set(first.errors.map(\.code)).isSuperset(of: [
            .duplicateNodeID, .duplicateWireID, .duplicateVariableID, .duplicateVariableName,
            .missingWireSource, .missingWireTarget, .incompleteWirePins, .missingLiteralTarget,
        ]))
        #expect(!first.isStructurallyValid)
        #expect(!first.isFullyValidated)
    }

    @Test("Variable references and type coverage are checked independently")
    func variableReferencesAndCoverage() {
        let typed = RCP3ScriptGraph.Variable(
            uuid: "typed", name: "Score", typeHash: 1, editHash: 2, dataType: "tm_double"
        )
        let untyped = RCP3ScriptGraph.Variable(uuid: "untyped", name: "Label")
        let partial = RCP3ScriptGraph.Variable(
            uuid: "partial", name: "Rotation", typeHash: 3, editHash: nil, dataType: "tm_rotation"
        )
        let graph = RCP3ScriptGraph(
            nodes: [
                .init(id: "valid", type: "tm_get_variable_node", variableName: "Score", variableRefUUID: "typed"),
                .init(id: "mismatch", type: "tm_get_variable_node", variableName: "Other", variableRefUUID: "typed"),
                .init(id: "dangling", type: "tm_get_variable_node", variableName: "Ghost", variableRefUUID: "ghost"),
                .init(id: "missing-id", type: "tm_get_variable_node", variableName: "Label"),
            ],
            wires: [], data: [], variables: [typed, untyped, partial]
        )

        let report = ScriptGraphValidator.validate(graph)
        #expect(report.errors.contains { $0.code == .mismatchedVariableReference && $0.subject == "mismatch" })
        #expect(report.errors.contains { $0.code == .danglingVariableReference && $0.subject == "dangling" })
        #expect(report.errors.contains { $0.code == .incompleteVariableReference && $0.subject == "missing-id" })
        #expect(report.errors.contains { $0.code == .incompleteVariableType && $0.subject == "partial" })
        #expect(report.coverage.contains {
            $0.subject == .variable(id: "typed", name: "Score") && $0.status == .exact
        })
        #expect(report.coverage.contains {
            guard $0.subject == .variable(id: "untyped", name: "Label") else { return false }
            if case .unknown = $0.status { return true }
            return false
        })
        #expect(!report.hasCompleteCoverage)
    }

    @Test("Supported settings families receive exact coverage")
    func validSettingsFamilies() throws {
        let materialProperty = RCP3ScriptGraph.Node.MaterialSettings.Property(
            name: "roughness", typeHash: 10, editTypeHash: 11, isOptional: false
        )
        let enumSelection = try #require(ScriptGraphNodeLibrary.enumSelection(
            for: "tm_make_anchoring_component_target", caseName: "plane"
        ))
        let dynamic = try #require(
            ScriptGraphNodeLibrary.defaultDynamicConnectorSettings(for: "tm_string_merge")
        )
        let array = try #require(
            ScriptGraphNodeLibrary.defaultDynamicConnectorSettings(for: "tm_array_create")
        )
        let graph = RCP3ScriptGraph(nodes: [
            .init(id: "enum", type: "tm_make_anchoring_component_target", enumSelection: enumSelection),
            .init(id: "dynamic", type: "tm_string_merge", dynamicConnectorSettings: dynamic),
            .init(id: "array", type: "tm_array_create", dynamicConnectorSettings: array),
            .init(
                id: "material", type: "tm_modify_any_material",
                materialSettings: .init(
                    typeHash: 12,
                    objectIdentifier: "RealityKit.PhysicallyBasedMaterial",
                    inputs: [materialProperty], outputs: [materialProperty]
                )
            ),
            .init(
                id: "entity-parameter", type: "tm_get_entity_parameter",
                entityParameterSettings: .init(typeHash: 13)
            ),
        ], wires: [], data: [])

        let report = ScriptGraphValidator.validate(graph)
        #expect(report.errors.isEmpty)
        #expect(report.coverage.allSatisfy { $0.status == .exact })
        #expect(report.isFullyValidated)
    }

    @Test("Enum settings must exactly match the selected public schema case")
    func invalidEnumSettings() throws {
        let valid = try #require(ScriptGraphNodeLibrary.enumSelection(
            for: "tm_make_anchoring_component_target", caseName: "plane"
        ))
        let invalid = RCP3ScriptGraph.Node.EnumSelection(
            typeHash: valid.typeHash,
            caseName: valid.caseName,
            associatedValues: valid.associatedValues.dropLast()
        )
        let graph = RCP3ScriptGraph(nodes: [
            .init(id: "missing", type: "tm_make_anchoring_component_target"),
            .init(id: "invalid", type: "tm_make_anchoring_component_target", enumSelection: invalid),
            .init(id: "unexpected", type: "tm_update", enumSelection: valid),
        ], wires: [], data: [])

        let report = ScriptGraphValidator.validate(graph)
        #expect(report.errors.contains { $0.code == .missingEnumSettings && $0.subject == "missing" })
        #expect(report.errors.contains { $0.code == .invalidEnumSettings && $0.subject == "invalid" })
        #expect(report.errors.contains { $0.code == .unexpectedEnumSettings && $0.subject == "unexpected" })
    }

    @Test("Dynamic settings enforce container, limits, names, orders, and types")
    func invalidDynamicSettings() {
        let duplicate = RCP3ScriptGraph.Node.DynamicConnector(
            name: "Value", typeHash: 1, order: 0
        )
        let invalidMerge = RCP3ScriptGraph.Node.DynamicConnectorSettings(
            container: .direct,
            inputs: [duplicate, duplicate],
            outputs: []
        )
        let invalidArray = RCP3ScriptGraph.Node.DynamicConnectorSettings(
            container: .array(arrayType: 2, elementType: 1),
            inputs: [.init(name: "value", typeHash: 2, order: 0)],
            outputs: [.init(name: "array", typeHash: 1, order: 0)]
        )
        let graph = RCP3ScriptGraph(nodes: [
            .init(id: "missing", type: "tm_string_merge"),
            .init(id: "merge", type: "tm_string_merge", dynamicConnectorSettings: invalidMerge),
            .init(id: "array", type: "tm_array_create", dynamicConnectorSettings: invalidArray),
            .init(id: "unexpected", type: "tm_update", dynamicConnectorSettings: invalidMerge),
        ], wires: [], data: [])

        let report = ScriptGraphValidator.validate(graph)
        #expect(report.errors.contains { $0.code == .missingDynamicSettings && $0.subject == "missing" })
        #expect(report.errors.contains { $0.code == .invalidDynamicSettings && $0.subject == "merge" })
        #expect(report.errors.contains { $0.code == .invalidDynamicSettings && $0.subject == "array" })
        #expect(report.errors.contains { $0.code == .unexpectedDynamicSettings && $0.subject == "unexpected" })
    }

    @Test("Material and entity-parameter settings reject missing and foreign schemas")
    func invalidDedicatedSettings() {
        let invalidMaterial = RCP3ScriptGraph.Node.MaterialSettings(
            typeHash: 0, objectIdentifier: "", inputs: [], outputs: []
        )
        let graph = RCP3ScriptGraph(nodes: [
            .init(id: "missing-material", type: "tm_get_material_parameter"),
            .init(id: "invalid-material", type: "tm_modify_any_material", materialSettings: invalidMaterial),
            .init(id: "foreign-material", type: "tm_update", materialSettings: invalidMaterial),
            .init(id: "missing-entity", type: "tm_set_entity_parameter"),
            .init(
                id: "invalid-entity", type: "tm_get_entity_parameter",
                entityParameterSettings: .init(typeHash: 0)
            ),
            .init(
                id: "foreign-entity", type: "tm_update",
                entityParameterSettings: .init(typeHash: 1)
            ),
        ], wires: [], data: [])

        let report = ScriptGraphValidator.validate(graph)
        #expect(Set(report.errors.map(\.code)).isSuperset(of: [
            .missingMaterialSettings, .invalidMaterialSettings, .unexpectedMaterialSettings,
            .missingEntityParameterSettings, .invalidEntityParameterSettings,
            .unexpectedEntityParameterSettings,
        ]))
    }

    @Test("Unknown node interfaces are explicit coverage gaps")
    func unknownNodeCoverage() {
        let graph = RCP3ScriptGraph(
            nodes: [.init(id: "unknown", type: "tm_future_node")],
            wires: [], data: []
        )
        let report = ScriptGraphValidator.validate(graph)

        #expect(report.errors.isEmpty)
        #expect(report.warnings.contains { $0.code == .unknownNodeInterface })
        #expect(report.isStructurallyValid)
        #expect(!report.hasCompleteCoverage)
        #expect(!report.isFullyValidated)
        let nodeCoverage = try! #require(report.coverage.first)
        if case let .unknown(reason) = nodeCoverage.status {
            #expect(reason.contains("tm_future_node"))
        } else {
            Issue.record("Unknown node was incorrectly reported as exact coverage")
        }
    }

    @Test("A named execution output may target an unnamed execution input")
    func partiallyNamedExecutionWire() {
        let graph = RCP3ScriptGraph(
            nodes: [
                .init(id: "delay", type: "tm_delay"),
                .init(id: "set", type: "tm_set_component"),
            ],
            wires: [.init(
                id: "once",
                from: "delay",
                to: "set",
                fromPin: TMHash.murmur64a("once"),
                toPin: nil
            )],
            data: []
        )

        let report = ScriptGraphValidator.validate(graph)
        #expect(!report.errors.contains { $0.code == .incompleteWirePins })
    }
}
