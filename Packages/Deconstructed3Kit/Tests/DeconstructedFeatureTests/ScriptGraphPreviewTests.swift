import Foundation
import RCP3Document
import RCP3Runtime
import TMFormat
import Testing

@testable import DeconstructedFeature

/// Exercises the RUN / PREVIEW path: the exact compile → run → dispatch pipeline
/// `ScriptGraphPreviewView` drives on appear, plus a build check on the view itself.
@MainActor
@Suite struct ScriptGraphPreviewTests {
    /// The workspace-local `Random` capture, if present. Captures live outside the
    /// OSS package, so capture-backed assertions no-op when it's absent.
    static var randomBundleURL: URL? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let bundle = dir.appending(path: "references/Random.realitycomposerpro")
            if FileManager.default.fileExists(atPath: bundle.appending(path: "world.tm_entity").path) {
                return bundle
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The canonical gesture → set-translation graph, built in-memory (drag exec→set,
    /// drag data→set.`translation`). Independent of the on-disk capture.
    static func dragToSetTranslationGraph() -> RCP3ScriptGraph {
        let drag = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let set = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component", label: "Set Transform")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let data = RCP3ScriptGraph.Wire(
            id: "c2",
            from: "n1",
            to: "n2",
            fromPin: 0x4f98_0d17_0a59_f903,
            toPin: TMHash.murmur64a("translation")
        )
        return RCP3ScriptGraph(nodes: [drag, set], wires: [exec, data], data: [])
    }

    // MARK: The path the preview runs

    @Test func previewPipelineRunsGraphAndMovesOnDrag() {
        // This is exactly what ScriptGraphPreviewView.start() does.
        let graph = Self.dragToSetTranslationGraph()
        let state = RuntimeEntityState()
        let host = ScriptGraphRunner.run(graph, into: state)

        #expect(host.hasHandler(for: "drag"))

        // ...and what a drag on the pad / +X button dispatches.
        host.dispatch(event: "drag", payload: ["delta": [2.0, 1.0, 0.0]])

        #expect(state.translation == SIMD3(2, 1, 0))
        #expect(host.lastException == nil)
    }

    @Test func previewViewBuildsForRunnableGraph() {
        // The SwiftUI view itself need only build (per the brief).
        let view = ScriptGraphPreviewView(graph: Self.dragToSetTranslationGraph())
        _ = view.body
    }

    @Test func previewViewBuildsForUnsupportedGraph() {
        // Honest empty state: a graph that compiles to no handlers still builds.
        let mystery = RCP3ScriptGraph.Node(id: "x1", type: "tm_some_future_node")
        let graph = RCP3ScriptGraph(nodes: [mystery], wires: [], data: [])
        let view = ScriptGraphPreviewView(graph: graph)
        _ = view.body

        // And the runtime path reports no handler for it (drives the empty state).
        let host = ScriptGraphRunner.run(graph, into: RuntimeEntityState())
        #expect(!host.hasHandler(for: "drag"))
        #expect(!host.hasHandler(for: "tap"))
    }

    // MARK: Capture-backed (no-ops cleanly when the capture is absent)

    @Test func previewPipelineRunsRandomCapture() throws {
        guard let url = Self.randomBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)
        let box = try #require(
            bundle.root["children"]?.arrayValue?
                .compactMap(\.objectValue)
                .first { $0.name == "box" }
        )
        let graph = try #require(bundle.scriptGraph(forEntity: box))

        let state = RuntimeEntityState()
        let host = ScriptGraphRunner.run(graph, into: state)
        host.dispatch(event: "drag", payload: ["delta": [2.0, 0.0, 1.0]])

        #expect(state.translation == SIMD3(2, 0, 1))
        #expect(host.lastException == nil)
    }
}
