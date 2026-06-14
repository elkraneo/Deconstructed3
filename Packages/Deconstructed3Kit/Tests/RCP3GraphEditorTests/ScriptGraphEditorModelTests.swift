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

    /// Reconnect (Bug 2): grabbing a wired INPUT detaches the wire and starts a new
    /// drag from its original OUTPUT source. Dropping on a NEW input rewires it;
    /// dropping on empty (cancel) leaves it detached. This mirrors what the canvas
    /// view does on a press near an already-wired input port.
    @Test func reconnectFromWiredInputRewires() {
        // Three nodes so we have a second valid exec target.
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "A")
        let n3 = RCP3ScriptGraph.Node(id: "n3", type: "tm_set_component", label: "B")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let model = ScriptGraphEditorModel(graph: RCP3ScriptGraph(nodes: [n1, n2, n3], wires: [exec], data: []))

        let n2ExecIn = GraphPortRef(nodeID: "n2", pinID: "exec.in")
        let n3ExecIn = GraphPortRef(nodeID: "n3", pinID: "exec.in")

        // Grab the wired input: detach + begin from the original source output.
        let existing = model.connections(touching: n2ExecIn).first { $0.to == n2ExecIn }
        #expect(existing != nil)
        let source = existing!.from
        model.removeConnection(existing!.id)
        model.beginConnection(from: source)
        #expect(model.connections.isEmpty)               // detached while dragging
        #expect(model.draftSource == source)

        // Drop on a different input → rewired to the new target.
        let newID = model.completeConnection(to: n3ExecIn)
        #expect(newID != nil)
        #expect(model.connections.count == 1)
        #expect(model.connections.first?.to == n3ExecIn)
        #expect(model.connections.first?.from == source)

        // Reconnect again, this time drop on empty (cancel) → stays detached.
        let again = model.connections.first!
        model.removeConnection(again.id)
        model.beginConnection(from: again.from)
        model.cancelConnection()
        #expect(model.connections.isEmpty)
        #expect(model.draftSource == nil)
    }

    /// Deleting via the connection-selection path (Bug 3): a tapped/selected wire is
    /// removed by `deleteSelection()` (the same call the canvas's delete key reaches).
    @Test func deleteSelectedConnection() {
        let model = ScriptGraphEditorModel(graph: Self.dragToSetGraph())
        let exec = model.connections.first { $0.isExec }
        #expect(exec != nil)
        model.selectConnection(exec!.id)
        model.deleteSelection()
        #expect(!model.connections.contains { $0.id == exec!.id })
        #expect(model.selectedConnectionID == nil)
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

    /// `addNode` inserts a node with the requested id/type, gives it the type's full
    /// named interface (non-empty pins — exec + data), and selects it.
    @Test func addNodeInsertsWithFullInterfaceAndSelects() {
        let model = ScriptGraphEditorModel(graph: Self.dragToSetGraph())
        let before = model.nodes.count

        let position = CGPoint(x: 42, y: 17)
        let id = model.addNode(type: "tm_set_component", at: position)

        // Appended and selected.
        #expect(model.nodes.count == before + 1)
        #expect(model.selectedNodeID == id)
        let box = model.node(id)
        #expect(box != nil)
        #expect(box?.position == position)
        #expect(box?.payload.type == "tm_set_component")

        // A lone Set Component yields its declared interface: an exec pair plus a
        // `component_type` data input — i.e. a non-empty named pin set.
        let pins = box?.payload.pins ?? []
        #expect(!pins.isEmpty)
        #expect(pins.contains { $0.isExec && $0.isInput })
        #expect(pins.contains { $0.isExec && !$0.isInput })
        let componentTypeID = "in." + TMHash.hex(TMHash.murmur64a("component_type"))
        #expect(pins.contains { $0.id == componentTypeID && $0.isInput && !$0.isExec })
    }

    /// An inserted node participates in the connection rules with an existing node:
    /// its exec output can wire into an existing node's exec input.
    @Test func addedNodeParticipatesInCanConnect() {
        let model = ScriptGraphEditorModel(graph: Self.dragToSetGraph())
        let newID = model.addNode(type: "tm_gesture_event_drag", at: .zero)

        let newExecOut = GraphPortRef(nodeID: newID, pinID: "exec.out")
        let existingExecIn = GraphPortRef(nodeID: "n2", pinID: "exec.in")
        #expect(model.canConnect(newExecOut, existingExecIn))

        // And the wire actually forms.
        let connID = model.connect(newExecOut, existingExecIn)
        #expect(connID != nil)
        #expect(model.connections.contains { $0.from == newExecOut && $0.to == existingExecIn })
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
