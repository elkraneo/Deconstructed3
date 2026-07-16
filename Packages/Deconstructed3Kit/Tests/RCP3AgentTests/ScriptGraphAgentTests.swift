import Foundation
import RCP3Document
import RCP3GraphEditor
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
