import Testing
import Foundation
import TMFormat
import RCP3Document
import RCP3Runtime

/// The canonical compiler emits the **public RealityKit Script Graph runtime**
/// surface (the `ScriptingComponent(source:)` form), distinct from the in-house
/// preview dialect of `ScriptGraphCompiler`.
@Suite struct CanonicalScriptGraphCompilerTests {
    /// The canonical gesture→set-translation graph (drag exec→set, drag data→
    /// set.`translation`), built in-memory — the `Random` capture's shape.
    static func dragToSetTranslationGraph() -> RCP3ScriptGraph {
        let drag = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let set = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set Transform")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let data = RCP3ScriptGraph.Wire(
            id: "c2",
            from: "n1",
            to: "n2",
            fromPin: 0x4f980d170a59f903,
            toPin: TMHash.murmur64a("translation")
        )
        return RCP3ScriptGraph(nodes: [drag, set], wires: [exec, data], data: [])
    }

    @Test func compilesDragToCanonicalDidAddHandler() {
        let js = CanonicalScriptGraphCompiler().compile(Self.dragToSetTranslationGraph())

        // Built-in modules must be require()'d before use, else the runtime throws
        // "Can't find variable: RealityKit".
        #expect(js.contains("const RealityKit = require(\"RealityKit\")"))
        #expect(js.contains("const Math3D = require(\"Math3D\")"))
        // The public-package surface: lifecycle assigned on `this`, gesture against
        // RealityKit.DragGestureEvent.name, entity.position moved via Math3D.
        #expect(js.contains("this.didAdd = function()"))
        #expect(js.contains("this.entity.on(RealityKit.DragGestureEvent.name"))
        #expect(js.contains("Math3D.add(dragStart, event.sceneTranslation)"))
        #expect(js.contains("event.entity.position"))
        // And it does NOT fall back to our in-house preview dialect.
        #expect(!js.contains("entity.transform.translation"))
        #expect(!js.contains("e.delta"))
        #expect(!js.contains("unsupported node"))
    }

    @Test func unrecognizedNodeEmitsHonestNoOp() {
        let mystery = RCP3ScriptGraph.Node(id: "x1", type: "tm_some_future_node")
        let graph = RCP3ScriptGraph(nodes: [mystery], wires: [], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(js.contains("// unsupported node: tm_some_future_node"))
        #expect(!js.contains("this.didAdd"))
    }

    @Test func dragWithoutTranslationWireEmitsNoHandler() {
        // Drag exec→set but no data wire into `translation`: not the recognized move
        // pattern, so no canonical handler is emitted (honest).
        let drag = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let set = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let graph = RCP3ScriptGraph(nodes: [drag, set], wires: [exec], data: [])

        let js = CanonicalScriptGraphCompiler().compile(graph)

        #expect(!js.contains("this.didAdd"))
        #expect(js.contains("// unsupported node:"))
    }
}
