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

    /// The single transform round-trips at every zoom and pan we support: the same
    /// `canvasPoint`/`graphPoint` pair drives node placement, edge routing, and
    /// hit-testing, so if it is an exact inverse the wires can never desync from the
    /// ports. Exercises the documented convention
    /// `screen = graph * zoom + pan + center` across the full zoom range and a
    /// non-zero pan.
    @Test func coordinateRoundTripAtZoomAndPan() {
        let view = ScriptGraphCanvasView(model: ScriptGraphEditorModel(graph: Self.sampleGraph()))
        view.configureViewportForTesting(
            size: CGSize(width: 1280, height: 800),
            zoom: 1,
            pan: .zero
        )
        let zooms: [CGFloat] = [0.25, 1.0, 2.5]
        let pans: [CGSize] = [.zero, CGSize(width: -137.5, height: 412.25)]
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 240, y: 78),       // a node's output-port column
            CGPoint(x: -320, y: 260),
            CGPoint(x: 9.5, y: 1024.25),
        ]
        for zoom in zooms {
            for pan in pans {
                view.configureViewportForTesting(
                    size: CGSize(width: 1280, height: 800),
                    zoom: zoom,
                    pan: pan
                )
                for p in points {
                    let screen = view.canvasPoint(fromGraph: p)
                    let back = view.graphPoint(fromCanvas: screen)
                    #expect(abs(back.x - p.x) < 0.0001)
                    #expect(abs(back.y - p.y) < 0.0001)
                }
            }
        }
    }

    /// A port's graph-space connection point round-trips through the view transform:
    /// the screen point an edge is drawn to is exactly the screen point the node's
    /// port dot is placed at, at any zoom — the core of Bug 1's fix.
    @Test func portPointStaysAttachedUnderZoom() {
        let model = ScriptGraphEditorModel(graph: Self.sampleGraph())
        let view = ScriptGraphCanvasView(model: model)
        view.configureViewportForTesting(
            size: CGSize(width: 1280, height: 800),
            zoom: 2.5,
            pan: CGSize(width: 64, height: -32)
        )
        let port = GraphPortRef(nodeID: "n2", pinID: "exec.in")
        guard let graphPoint = model.canvasPortPoint(port) else {
            Issue.record("expected a resolvable port point")
            return
        }
        // The hit-test (graph space) and the routed endpoint (screen space, via the
        // single transform) describe the same physical location.
        let screen = view.canvasPoint(fromGraph: graphPoint)
        let recoveredGraph = view.graphPoint(fromCanvas: screen)
        #expect(model.canvasPort(near: recoveredGraph) == port)
    }

    /// During a live node drag the model is NOT mutated; the renderer offsets the
    /// dragged node's edge endpoints locally. An endpoint on the dragged node must move
    /// by EXACTLY the screen-space drag translation (so the wire stays attached to the
    /// port as the card follows the cursor), while an endpoint on a node that isn't
    /// being dragged must not move at all. Verified at a non-unit zoom, where the
    /// graph→screen scaling makes an incorrect offset obvious.
    @Test func edgeEndpointsFollowLiveNodeDrag() {
        let model = ScriptGraphEditorModel(graph: Self.sampleGraph())
        // Wire n1.exec.out → n2.exec.in so we have one edge with an endpoint on each.
        let from = GraphPortRef(nodeID: "n1", pinID: "exec.out")
        let to = GraphPortRef(nodeID: "n2", pinID: "exec.in")
        #expect(model.connect(from, to) != nil)

        let view = ScriptGraphCanvasView(model: model)
        let zoom: CGFloat = 2.5
        view.configureViewportForTesting(
            size: CGSize(width: 1280, height: 800), zoom: zoom, pan: .zero
        )

        // Baseline screen positions of both endpoints, with no active drag.
        guard
            let n1ScreenBefore = view.screenPortPointForTesting(from, draggingNodeID: nil, dragTranslation: .zero),
            let n2ScreenBefore = view.screenPortPointForTesting(to, draggingNodeID: nil, dragTranslation: .zero)
        else { Issue.record("expected resolvable port points"); return }

        // Simulate dragging n2 by a screen-space translation.
        let translation = CGSize(width: 120, height: -80)
        guard
            let n1ScreenAfter = view.screenPortPointForTesting(from, draggingNodeID: "n2", dragTranslation: translation),
            let n2ScreenAfter = view.screenPortPointForTesting(to, draggingNodeID: "n2", dragTranslation: translation)
        else { Issue.record("expected resolvable port points"); return }

        // n1 (not dragged) stays put; n2 (dragged) moves by exactly the screen drag.
        #expect(abs(n1ScreenAfter.x - n1ScreenBefore.x) < 0.0001)
        #expect(abs(n1ScreenAfter.y - n1ScreenBefore.y) < 0.0001)
        #expect(abs(n2ScreenAfter.x - (n2ScreenBefore.x + translation.width)) < 0.0001)
        #expect(abs(n2ScreenAfter.y - (n2ScreenBefore.y + translation.height)) < 0.0001)

        // The model itself was never mutated during the drag.
        #expect(model.node("n2")?.position == ScriptGraphEditorModel(graph: Self.sampleGraph()).node("n2")?.position)
    }

    /// After a live drag is cleared and the move is committed to the model, the routed
    /// endpoint lands exactly where the live drag had it — no jump on commit.
    @Test func committedMoveMatchesLiveDragEndpoint() {
        let model = ScriptGraphEditorModel(graph: Self.sampleGraph())
        let to = GraphPortRef(nodeID: "n2", pinID: "exec.in")
        let from = GraphPortRef(nodeID: "n1", pinID: "exec.out")
        #expect(model.connect(from, to) != nil)

        let view = ScriptGraphCanvasView(model: model)
        let zoom: CGFloat = 1.75
        view.configureViewportForTesting(
            size: CGSize(width: 1280, height: 800), zoom: zoom, pan: CGSize(width: 40, height: -20)
        )

        let translation = CGSize(width: 90, height: 140)
        guard let liveScreen = view.screenPortPointForTesting(to, draggingNodeID: "n2", dragTranslation: translation) else {
            Issue.record("expected a resolvable port point"); return
        }

        // Commit the move the way `handleDragEnded` does (same graph delta the live drag
        // previewed), then read with no active drag.
        let origin = model.node("n2")!.position
        let graphOffset = view.graphDragOffsetForTesting(translation: translation)
        model.moveNode("n2", to: CGPoint(x: origin.x + graphOffset.x, y: origin.y + graphOffset.y))

        guard let committedScreen = view.screenPortPointForTesting(to, draggingNodeID: nil, dragTranslation: .zero) else {
            Issue.record("expected a resolvable port point"); return
        }
        #expect(abs(committedScreen.x - liveScreen.x) < 0.0001)
        #expect(abs(committedScreen.y - liveScreen.y) < 0.0001)
    }

    /// The public entry builds a model-backed canvas without touching SwiftFlow.
    @Test func publicCanvasBuilds() {
        let canvas = ScriptGraphCanvas(graph: Self.sampleGraph())
        _ = canvas.body
    }
}
