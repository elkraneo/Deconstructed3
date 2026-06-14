import Testing
import Foundation
import TMFormat
import RCP3Document
@testable import RCP3GraphEditor

/// The renderer-agnostic core: building the model from a graph, the connection
/// rules, mutation verbs, and the Canvas geometry helpers.
@MainActor
@Suite struct ScriptGraphEditorModelTests {
    /// The canonical drag → set graph (exec wire + a Scene Translation → translation data wire).
    static func dragToSetGraph() -> RCP3ScriptGraph {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set Transform")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let data = RCP3ScriptGraph.Wire(
            id: "c2", from: "n1", to: "n2",
            fromPin: 0x4f980d170a59f903,
            toPin: TMHash.murmur64a("translation")
        )
        return RCP3ScriptGraph(nodes: [n1, n2], wires: [exec, data], data: [])
    }

    @Test func buildsNodesAndConnections() {
        let model = ScriptGraphEditorModel(graph: Self.dragToSetGraph())
        #expect(model.nodes.count == 2)
        #expect(model.connections.count == 2)
        #expect(model.connections.contains { $0.isExec })
        #expect(model.connections.contains { !$0.isExec && $0.label == "translation" })
    }

    @Test func connectionRules() {
        let model = ScriptGraphEditorModel(graph: Self.dragToSetGraph())
        let dragExecOut = GraphPortRef(nodeID: "n1", pinID: "exec.out")
        let setExecIn = GraphPortRef(nodeID: "n2", pinID: "exec.in")
        let dragSceneTranslation = GraphPortRef(nodeID: "n1", pinID: "out." + TMHash.hex(0x4f980d170a59f903))
        let setTranslation = GraphPortRef(nodeID: "n2", pinID: "in." + TMHash.hex(TMHash.murmur64a("translation")))

        // output → input, matching kind: OK (order-independent).
        #expect(model.canConnect(dragExecOut, setExecIn))
        #expect(model.canConnect(setTranslation, dragSceneTranslation))
        // exec ↔ data mismatch: rejected.
        #expect(!model.canConnect(dragExecOut, setTranslation))
        // input → input: rejected.
        #expect(!model.canConnect(setExecIn, setTranslation))
        // same node: rejected.
        #expect(!model.canConnect(dragExecOut, dragSceneTranslation))
    }

    @Test func beginAndCompleteConnectionReplacesInput() {
        let model = ScriptGraphEditorModel(graph: Self.dragToSetGraph())
        let before = model.connections.count
        let dragSceneTranslation = GraphPortRef(nodeID: "n1", pinID: "out." + TMHash.hex(0x4f980d170a59f903))
        let setTranslation = GraphPortRef(nodeID: "n2", pinID: "in." + TMHash.hex(TMHash.murmur64a("translation")))

        model.beginConnection(from: dragSceneTranslation)
        let id = model.completeConnection(to: setTranslation)
        #expect(id != nil)
        #expect(model.draftSource == nil)
        // The target input already had a wire; it is replaced, not duplicated.
        #expect(model.connections.count == before)
        #expect(model.connections.filter { $0.to == setTranslation }.count == 1)
    }

    @Test func moveAndDelete() {
        let model = ScriptGraphEditorModel(graph: Self.dragToSetGraph())
        model.moveNode("n1", to: CGPoint(x: 100, y: 50))
        #expect(model.node("n1")?.position == CGPoint(x: 100, y: 50))

        model.selectNode("n2")
        model.deleteSelection()
        #expect(model.node("n2") == nil)
        // Connections touching the deleted node are gone too.
        #expect(model.connections.allSatisfy { $0.from.nodeID != "n2" && $0.to.nodeID != "n2" })
    }

    @Test func canvasGeometryResolvesPorts() {
        let model = ScriptGraphEditorModel(graph: Self.dragToSetGraph())
        let setTranslation = GraphPortRef(nodeID: "n2", pinID: "in." + TMHash.hex(TMHash.murmur64a("translation")))
        let point = model.canvasPortPoint(setTranslation)
        #expect(point != nil)
        // The nearest port to its own connection point is itself.
        if let point { #expect(model.canvasPort(near: point) == setTranslation) }
    }
}
