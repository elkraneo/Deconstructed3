import Foundation
import RCP3Document
import RCP3GraphEditor
import TMFormat
import Testing
@testable import RCP3Agent

@MainActor
@Suite struct ScriptGraphAgentTests {
    @Test func profilesGrantRealCapabilities() {
        #expect(ScriptGraphAgentProfile.review.toolIDs == [.inspect, .compile])
        #expect(!ScriptGraphAgentProfile.review.permitsMutation)
        #expect(ScriptGraphAgentProfile.build.permitsMutation)
        #expect(ScriptGraphAgentProfile.deepBuild.toolIDs == Set(ScriptGraphAgentToolID.allCases))
    }

    @Test func reviewProfileCannotMutateLiveGraph() throws {
        let model = ScriptGraphEditorModel(graph: .init(nodes: [], wires: [], data: []))
        let executor = ScriptGraphAgentExecutor(model: model)

        #expect(throws: ScriptGraphAgentError.mutationNotPermitted) {
            try executor.execute(
                .addNode(type: "tm_update", label: nil, x: 0, y: 0),
                permitsMutation: ScriptGraphAgentProfile.review.permitsMutation
            )
        }
        #expect(model.nodes.isEmpty)
    }

    @Test func buildProfileAuthorsTheLiveGraph() throws {
        let model = ScriptGraphEditorModel(graph: .init(nodes: [], wires: [], data: []))
        let executor = ScriptGraphAgentExecutor(model: model)

        let result = try executor.execute(
            .addNode(type: "tm_update", label: "Agent Update", x: 40, y: 80),
            permitsMutation: ScriptGraphAgentProfile.build.permitsMutation
        )

        #expect(result.mutated)
        #expect(model.nodes.count == 1)
        #expect(model.nodes.first?.payload.type == "tm_update")
        #expect(model.graphSnapshot().nodes.first?.label == "Agent Update")
    }

    @Test func addReportsTheActualReplacementType() throws {
        let model = ScriptGraphEditorModel(graph: .init(nodes: [], wires: [], data: []))
        let executor = ScriptGraphAgentExecutor(model: model)

        let result = try executor.execute(
            .addNode(type: "tm_constant", label: nil, x: 0, y: 0),
            permitsMutation: true
        )

        #expect(result.summary == "Added tm_make_bool instead of tm_constant.")
        #expect(result.detail.contains("deprecates"))
        #expect(model.nodes.first?.payload.type == "tm_make_bool")
    }

    @Test func agentCanFinishSettingsBackedNodes() throws {
        let model = ScriptGraphEditorModel(graph: .init(nodes: [], wires: [], data: []))
        let componentID = model.addNode(type: "tm_get_component", at: .zero)
        let dynamicID = model.addNode(type: "tm_to_string", at: .zero)
        let parameterID = model.addNode(type: "tm_get_entity_parameter", at: .zero)
        let executor = ScriptGraphAgentExecutor(model: model)

        _ = try executor.execute(.setComponentType(
            nodeID: componentID, componentName: "ModelComponent"
        ))
        _ = try executor.execute(.setDynamicConnectorType(
            nodeID: dynamicID, connectorName: "value", isInput: true, typeName: "Number"
        ))
        _ = try executor.execute(.setEntityParameterType(
            nodeID: parameterID, typeName: "Vector3"
        ))

        let snapshot = model.graphSnapshot()
        #expect(snapshot.data.contains { $0.valueHash == TMHash.murmur64a("ModelComponent") })
        #expect(snapshot.nodes.first(where: { $0.id == dynamicID })?
            .dynamicConnectorSettings?.inputs.first?.typeHash == ScriptGraphTypeRegistry.number.typeHash)
        #expect(snapshot.nodes.first(where: { $0.id == parameterID })?
            .entityParameterSettings?.typeHash == ScriptGraphTypeRegistry.vector3.editHash)
    }

    @Test func agentCanManageVariadicConnectors() throws {
        let model = ScriptGraphEditorModel(graph: .init(nodes: [], wires: [], data: []))
        let id = model.addNode(type: "tm_string_merge", at: .zero)
        let executor = ScriptGraphAgentExecutor(model: model)

        _ = try executor.execute(.addDynamicConnector(
            nodeID: id, connectorName: "value2", isInput: true, typeName: "String"
        ))
        _ = try executor.execute(.renameDynamicConnector(
            nodeID: id, connectorName: "value2", isInput: true, newName: "suffix"
        ))
        _ = try executor.execute(.removeDynamicConnector(
            nodeID: id, connectorName: "suffix", isInput: true
        ))

        #expect(model.node(id)?.dynamicConnectorSettings?.inputs.map(\.name) == ["value0", "value1"])
    }

    @Test func validationReadsUnsavedCanvasState() throws {
        let graph = RCP3ScriptGraph(
            nodes: [.init(id: "update", type: "tm_update")],
            wires: [],
            data: []
        )
        let model = ScriptGraphEditorModel(graph: graph)
        let executor = ScriptGraphAgentExecutor(model: model)
        _ = model.addNode(type: "tm_make_vector3", label: "Unsaved", at: .zero)

        let overview = try executor.execute(.overview)
        #expect(overview.detail.contains("nodes=2"))
        #expect(overview.detail.contains("dirty=true"))
    }
}
