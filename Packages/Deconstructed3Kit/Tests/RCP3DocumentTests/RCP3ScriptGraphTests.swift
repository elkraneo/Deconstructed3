import Testing
import Foundation
import TMFormat
import RCP3Document

@Suite struct RCP3ScriptGraphTests {
    /// The workspace-local `Random` capture (a box with a `re_scripting_component`),
    /// if present. Captures live outside the OSS package (`../../references/`), so
    /// these tests no-op cleanly when the capture is absent.
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

    // MARK: Parse from the bundle (entity → asset → graph)

    @Test func parsesRandomFixtureScriptGraph() throws {
        guard let url = Self.randomBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)

        let world = bundle.root
        let box = try #require(
            world["children"]?.arrayValue?
                .compactMap(\.objectValue)
                .first { $0.name == "box" }
        )

        let graph = try #require(bundle.scriptGraph(forEntity: box))

        // 2 nodes: the drag event and the "Set Transform" set_component.
        #expect(graph.nodes.count == 2)
        let drag = try #require(graph.nodes.first { $0.type == "tm_gesture_event_drag" })
        #expect(drag.label == nil)
        let setNode = try #require(graph.nodes.first { $0.type == "tm_set_component" })
        #expect(setNode.label == "Set Transform")

        // 2 wires: one exec (no hashes) + one data wire into `translation`.
        #expect(graph.wires.count == 2)
        let exec = try #require(graph.wires.first { $0.isExec })
        #expect(exec.from == drag.id)
        #expect(exec.to == setNode.id)

        let dataWire = try #require(graph.wires.first { !$0.isExec })
        #expect(dataWire.from == drag.id)
        #expect(dataWire.to == setNode.id)
        #expect(dataWire.toPin == TMHash.murmur64a("translation"))
        #expect(RCP3ScriptGraph.label(forHash: dataWire.toPin) == "translation")

        // 1 data literal bound to `component_type`.
        #expect(graph.data.count == 1)
        let literal = try #require(graph.data.first)
        #expect(literal.toNode == setNode.id)
        #expect(literal.toPin == TMHash.murmur64a("component_type"))
        #expect(RCP3ScriptGraph.label(forHash: literal.toPin) == "component_type")
        #expect(literal.valueType == "re_scripting_graph_component_type")
    }

    // MARK: Browse script graphs as assets (independent of any entity)

    @Test func enumeratesScriptGraphAssets() throws {
        guard let url = Self.randomBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)

        let assets = bundle.scriptGraphAssets()
        #expect(!assets.isEmpty)

        // At least one asset is a "Script Graph" (RCP's default name for a new graph).
        let scriptGraph = try #require(assets.first { $0.name.contains("Script Graph") })

        // Loading by the asset's id resolves a real graph with nodes.
        let graph = try #require(bundle.scriptGraph(assetID: scriptGraph.id))
        #expect(!graph.nodes.isEmpty)

        // The editor passthroughs see the same assets + graph.
        let editor = try RCP3Editor.open(url)
        #expect(editor.scriptGraphAssets() == assets)
        #expect(editor.scriptGraph(assetID: scriptGraph.id)?.nodes.count == graph.nodes.count)
    }

    @Test func resolvesGraphBySelectedEntityID() throws {
        guard let url = Self.randomBundleURL else { return }
        let editor = try RCP3Editor.open(url)

        let box = try #require(editor.entity.children.first { $0.name == "box" })
        let graph = try #require(editor.scriptGraph(forEntityID: box.id))
        #expect(graph.nodes.count == 2)

        // The world entity itself has no scripting component.
        #expect(editor.scriptGraph(forEntityID: editor.entity.id) == nil)
    }

    // MARK: Parse directly from a tm_graph object (no bundle needed)

    @Test func parsesGraphObjectDirectly() throws {
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "root-uuid"
        graph: {
        \t__uuid: "graph-uuid"
        \tnodes: [
        \t\t{
        \t\t\t__uuid: "n1"
        \t\t\ttype: "tm_gesture_event_drag"
        \t\t\tposition: {
        \t\t\t\t__uuid: "p1"
        \t\t\t\tx: 1
        \t\t\t\ty: 2
        \t\t\t}
        \t\t}
        \t\t{
        \t\t\t__uuid: "n2"
        \t\t\ttype: "tm_set_component"
        \t\t\tlabel: "Set Transform"
        \t\t\tposition: {
        \t\t\t\t__uuid: "p2"
        \t\t\t\tx: 3
        \t\t\t\ty: 4
        \t\t\t}
        \t\t}
        \t]
        \tconnections: [
        \t\t{
        \t\t\t__uuid: "c1"
        \t\t\tfrom_node: "n1"
        \t\t\tto_node: "n2"
        \t\t}
        \t\t{
        \t\t\t__uuid: "c2"
        \t\t\tfrom_node: "n1"
        \t\t\tto_node: "n2"
        \t\t\tfrom_connector_hash: "4f980d170a59f903"
        \t\t\tto_connector_hash: "3e132861ebce0169"
        \t\t}
        \t]
        \tdata: [
        \t\t{
        \t\t\t__uuid: "d1"
        \t\t\tto_node: "n2"
        \t\t\tto_connector_hash: "772749b3cbf24a8f"
        \t\t\tdata: {
        \t\t\t\t__type: "re_scripting_graph_component_type"
        \t\t\t\t__uuid: "v1"
        \t\t\t}
        \t\t}
        \t]
        }
        """
        let root = try #require(try TM.parse(text).objectValue)
        let tmGraph = try #require(root["graph"]?.objectValue)
        let graph = RCP3ScriptGraph(tmGraph: tmGraph)

        #expect(graph.nodes.count == 2)
        #expect(graph.nodes.first?.x == 1)
        #expect(graph.wires.count == 2)
        #expect(graph.wires.first { $0.isExec }?.id == "c1")
        let dataWire = try #require(graph.wires.first { !$0.isExec })
        #expect(dataWire.toPin == 0x3e132861ebce0169)
        #expect(graph.data.first?.toPin == 0x772749b3cbf24a8f)
    }

    @Test func unknownPinHashFallsBackToHex() {
        let unknown: UInt64 = 0x4f980d170a59f903
        #expect(RCP3ScriptGraph.pinName(forHash: unknown) == nil)
        #expect(RCP3ScriptGraph.label(forHash: unknown) == "4f980d170a59f903")
    }
}
