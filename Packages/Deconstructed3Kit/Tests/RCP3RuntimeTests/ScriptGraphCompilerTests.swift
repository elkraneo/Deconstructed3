import Testing
import Foundation
import TMFormat
import RCP3Document
import RCP3Runtime

@Suite struct ScriptGraphCompilerTests {
    /// The workspace-local `Random` capture, if present. Captures live outside the
    /// OSS package (`../../references/`), so these tests no-op when it is absent.
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

    /// Builds the canonical gesture→set-translation graph in-memory (drag exec→set,
    /// drag data→set.`translation`), independent of the on-disk capture.
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

    @Test func compilesDragToSetTranslation() {
        let js = ScriptGraphCompiler().compile(Self.dragToSetTranslationGraph())

        #expect(js.contains("entity.on(\"drag\""))
        #expect(js.contains("entity.transform.translation"))
        #expect(js.contains("e.delta[0]"))
        #expect(!js.contains("unsupported node"))
    }

    @Test func unrecognizedNodeEmitsHonestNoOp() {
        let mystery = RCP3ScriptGraph.Node(id: "x1", type: "tm_some_future_node")
        let graph = RCP3ScriptGraph(nodes: [mystery], wires: [], data: [])

        let js = ScriptGraphCompiler().compile(graph)

        #expect(js.contains("// unsupported node: tm_some_future_node"))
        #expect(!js.contains("entity.on"))
    }

    @Test func setComponentWithoutTranslationWireIsUnsupportedAction() {
        // Drag exec→set, but no data wire into `translation`: the action is not the
        // recognized move pattern, so it falls back to an honest no-op inside the
        // handler.
        let drag = RCP3ScriptGraph.Node(id: "n1", type: "tm_gesture_event_drag")
        let set = RCP3ScriptGraph.Node(id: "n2", type: "tm_set_component")
        let exec = RCP3ScriptGraph.Wire(id: "c1", from: "n1", to: "n2")
        let graph = RCP3ScriptGraph(nodes: [drag, set], wires: [exec], data: [])

        let js = ScriptGraphCompiler().compile(graph)

        #expect(js.contains("entity.on(\"drag\""))
        #expect(js.contains("// unsupported node: tm_set_component"))
    }

    @Test func compilesRandomFixtureToDragHandler() throws {
        guard let url = Self.randomBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)
        let box = try #require(
            bundle.root["children"]?.arrayValue?
                .compactMap(\.objectValue)
                .first { $0.name == "box" }
        )
        let graph = try #require(bundle.scriptGraph(forEntity: box))

        let js = ScriptGraphCompiler().compile(graph)

        // The fixture decodes as "on drag, move the box": a drag handler that
        // updates translation.
        #expect(js.contains("entity.on(\"drag\""))
        #expect(js.contains("entity.transform.translation"))
        #expect(js.contains("e.delta"))
    }
}
