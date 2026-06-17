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

    // MARK: - Scalar pin literals (author an unwired numeric input)

    /// A lone `make_vector3` exposes its x/y/z as editable, unwired numeric pins;
    /// `setLiteral` authors a value, which the editable-pin query then reflects, and a
    /// `nil` clears it.
    @Test func setLiteralAuthorsAndClearsAScalarPin() {
        let vec = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector3")
        let model = ScriptGraphEditorModel(graph: RCP3ScriptGraph(nodes: [vec], wires: [], data: []))

        // x/y/z are offered as editable numeric pins, all defaulting to 0.
        let editable = model.editableLiterals(forNode: "v")
        #expect(editable.map(\.displayName).sorted() == ["X", "Y", "Z"])
        #expect(editable.allSatisfy { $0.value == 0 })

        // Author the x literal.
        let x = TMHash.murmur64a("x")
        model.setLiteral(nodeID: "v", pinConnectorHash: x, value: 2.5)
        #expect(model.literal(nodeID: "v", pinConnectorHash: x) == 2.5)
        #expect(model.editableLiterals(forNode: "v").first { $0.displayName == "X" }?.value == 2.5)

        // Clearing it removes the authored value (pin reverts to default 0).
        model.setLiteral(nodeID: "v", pinConnectorHash: x, value: nil)
        #expect(model.literal(nodeID: "v", pinConnectorHash: x) == nil)
        #expect(model.editableLiterals(forNode: "v").first { $0.displayName == "X" }?.value == 0)
    }

    /// A wired input pin is NOT offered as a literal (the wire feeds it); only the
    /// remaining unwired numeric pins are editable.
    @Test func wiredPinIsNotLiteralEditable() {
        let drag = RCP3ScriptGraph.Node(id: "d", type: "tm_gesture_event_drag")
        let vec = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector3")
        // Wire the drag's sceneTranslation → the vector's x input.
        let wire = RCP3ScriptGraph.Wire(
            id: "w", from: "d", to: "v",
            fromPin: TMHash.murmur64a("sceneTranslation"),
            toPin: TMHash.murmur64a("x")
        )
        let model = ScriptGraphEditorModel(graph: RCP3ScriptGraph(nodes: [drag, vec], wires: [wire], data: []))

        let editable = model.editableLiterals(forNode: "v")
        // x is wired → not editable; y and z remain.
        #expect(editable.map(\.displayName).sorted() == ["Y", "Z"])
    }

    /// A scalar `data[]` literal in the source graph seeds the model's editable value.
    @Test func scalarLiteralFromGraphSeedsEditableValue() {
        let vec = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector3")
        let z = TMHash.murmur64a("z")
        let literal = RCP3ScriptGraph.DataLiteral(
            id: "lit", toNode: "v", toPin: z, scalarValue: -3
        )
        let model = ScriptGraphEditorModel(
            graph: RCP3ScriptGraph(nodes: [vec], wires: [], data: [literal])
        )
        #expect(model.literal(nodeID: "v", pinConnectorHash: z) == -3)
        #expect(model.editableLiterals(forNode: "v").first { $0.displayName == "Z" }?.value == -3)
    }

    /// Deleting a node drops the scalar literals bound to it.
    @Test func deletingNodeDropsItsLiterals() {
        let vec = RCP3ScriptGraph.Node(id: "v", type: "tm_make_vector3")
        let model = ScriptGraphEditorModel(graph: RCP3ScriptGraph(nodes: [vec], wires: [], data: []))
        model.setLiteral(nodeID: "v", pinConnectorHash: TMHash.murmur64a("x"), value: 9)
        #expect(!model.scalarLiterals.isEmpty)

        model.selectNode("v")
        model.deleteSelection()
        #expect(model.scalarLiterals.isEmpty)
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
