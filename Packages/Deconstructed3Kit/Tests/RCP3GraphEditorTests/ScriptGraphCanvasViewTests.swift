import Testing
import CoreGraphics
import RCP3Document
@testable import RCP3GraphEditor

/// Light tests for the interactive Canvas renderer. The interaction logic lives in
/// `ScriptGraphEditorModel` (tested separately); here we verify the renderer-owned
/// coordinate transform is a clean round-trip and that the public entry builds.
@MainActor
@Suite struct ScriptGraphCanvasViewTests {
    static func sampleGraph() -> RCP3ScriptGraph {
        let n1 = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let n2 = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set Transform")
        return RCP3ScriptGraph(nodes: [n1, n2], wires: [], data: [])
    }

    /// `graphPoint(fromCanvas:) ∘ canvasPoint(fromGraph:)` is the identity, for
    /// representative graph points. (Default transform: zoom 1, pan zero.)
    @Test func coordinateRoundTripIsIdentity() {
        let view = ScriptGraphCanvasView(model: ScriptGraphEditorModel(graph: Self.sampleGraph()))
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 120, y: -40),
            CGPoint(x: -320, y: 260),
            CGPoint(x: 9.5, y: 1024.25),
        ]
        for p in points {
            let back = view.graphPoint(fromCanvas: view.canvasPoint(fromGraph: p))
            #expect(abs(back.x - p.x) < 0.0001)
            #expect(abs(back.y - p.y) < 0.0001)
        }
    }

    /// The public entry builds a model-backed canvas without touching SwiftFlow.
    @Test func publicCanvasBuilds() {
        let canvas = ScriptGraphCanvas(graph: Self.sampleGraph())
        _ = canvas.body
    }
}
