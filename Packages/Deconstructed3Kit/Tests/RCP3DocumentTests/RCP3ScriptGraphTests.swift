import Testing
import Foundation
import TMFormat
import RCP3Document

@Suite struct RCP3ScriptGraphTests {
    /// The workspace-local `Random` capture (a box with a `re_scripting_component`),
    /// if present. Captures live outside the OSS package (`../../references/`), so
    /// these tests no-op cleanly when the capture is absent.
    static var randomBundleURL: URL? { bundleURL(named: "Random.realitycomposerpro") }

    /// The workspace-local `Random2` capture (a standalone `My Script Graph` asset
    /// — the non-instance reference path), if present.
    static var random2BundleURL: URL? { bundleURL(named: "Random2.realitycomposerpro") }

    /// Walk-up resolver for a workspace-local `references/<name>` capture.
    static func bundleURL(named name: String) -> URL? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let bundle = dir.appending(path: "references/\(name)")
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

        // The `box` entity carries an EDITED instance-override graph inline in its
        // `re_scripting_component.source.graph` — NOT the 2-node prototype. The
        // loader must merge the instance's own `nodes` with the prototype nodes its
        // `nodes__instantiated` entries reference, and use the instance's
        // connections + data.
        let graph = try #require(bundle.scriptGraph(forEntity: box))

        // 6 nodes total = 4 instance additions + 2 resolved instantiated prototype
        // nodes (NOT the stale 2-node prototype).
        #expect(graph.nodes.count == 6)

        // The 4 instance additions, each with its own `type` + label.
        let setAccessibility = try #require(graph.nodes.first { $0.label == "Set Accessibility" })
        #expect(setAccessibility.type == "tm_set_component")
        #expect(graph.nodes.contains { $0.type == "tm_get_component" })
        #expect(graph.nodes.contains { $0.type == "tm_entity_look_at" })
        #expect(graph.nodes.contains { $0.type == "tm_did_add" })

        // The 2 instantiated prototype nodes: their `type` is recovered from the
        // prototype graph by `__prototype_uuid` (they carry none themselves).
        #expect(graph.nodes.contains { $0.type == "tm_gesture_event_drag" })
        // Two `tm_set_component` exist now: "Set Accessibility" (instance) + the
        // resolved instantiated one (was the prototype's "Set Transform").
        #expect(graph.nodes.filter { $0.type == "tm_set_component" }.count == 2)
        // The instantiated drag node carries its instance `__uuid`, not the
        // prototype's — the type is resolved, the identity is the instance's.
        let drag = try #require(graph.nodes.first { $0.type == "tm_gesture_event_drag" })
        #expect(drag.id == "ba3614d0-9e16-c46a-d324-a8284e2026d7")

        // The instance's 2 connections are present (both exec edges).
        #expect(graph.wires.count == 2)
        let didAdd = try #require(graph.nodes.first { $0.type == "tm_did_add" })
        let lookAt = try #require(graph.nodes.first { $0.type == "tm_entity_look_at" })
        #expect(graph.wires.contains { $0.from == didAdd.id && $0.to == setAccessibility.id })
        #expect(graph.wires.contains { $0.to == lookAt.id })

        // The instance's data literal bound to `component_type` on "Set Accessibility".
        #expect(graph.data.count == 1)
        let literal = try #require(graph.data.first)
        #expect(literal.toNode == setAccessibility.id)
        #expect(literal.toPin == TMHash.murmur64a("component_type"))
        #expect(literal.valueType == "re_scripting_graph_component_type")
    }

    /// Regression guard for the pure-reference path: a `re_scripting_component`
    /// with NO inline `source.graph` still loads the standalone prototype asset.
    @Test func standaloneAssetReadsAsPrototype() throws {
        guard let url = Self.randomBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)

        // Loading the prototype asset directly (the pre-edit `Script Graph`) still
        // yields the 2-node drag graph — the instance-override path does not affect
        // direct asset reads.
        let asset = try #require(
            bundle.scriptGraphAssets().first { $0.name.contains("Script Graph") }
        )
        let graph = try #require(bundle.scriptGraph(assetID: asset.id))
        #expect(graph.nodes.count == 2)
        #expect(graph.nodes.contains { $0.type == "tm_gesture_event_drag" })
        let setNode = try #require(graph.nodes.first { $0.type == "tm_set_component" })
        #expect(setNode.label == "Set Transform")
    }

    /// Regression guard for the non-instance standalone path against the `Random2`
    /// capture: its `My Script Graph` is a plain `re_scripting_source_graph` (no
    /// instance override), so it parses straight from the asset's `nodes` — its
    /// node count is unaffected by the `nodes__instantiated` merge logic.
    @Test func random2StandaloneScriptGraphUnaffected() throws {
        guard let url = Self.random2BundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)

        let asset = try #require(
            bundle.scriptGraphAssets().first { $0.name.contains("My Script Graph") }
        )
        let graph = try #require(bundle.scriptGraph(assetID: asset.id))

        // The standalone graph reads its full node set straight from `nodes`.
        #expect(graph.nodes.count == 8)
        #expect(graph.nodes.contains { $0.type == "tm_gesture_event_drag" })
        #expect(graph.nodes.contains { $0.type == "tm_did_add" })
        // No "?" placeholders — every node has a real type (nothing was dropped to
        // or mis-resolved via the instantiated path).
        #expect(!graph.nodes.contains { $0.type == "?" })
    }

    /// The `Random2` standalone graph uses script-graph variables: its `variables:`
    /// table declares `Name1`, and its Get/Set variable nodes reference it via
    /// `tm_graph_variable_ref`. The parser surfaces the table on the graph and attaches
    /// `variableName` to each variable node — and does NOT leak the ref as a scalar/
    /// component data literal.
    @Test func random2VariableTableAndNodeReferencesParse() throws {
        guard let url = Self.random2BundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)

        let asset = try #require(
            bundle.scriptGraphAssets().first { $0.name.contains("My Script Graph") }
        )
        let graph = try #require(bundle.scriptGraph(assetID: asset.id))

        // The graph-level variable table declares one variable, "Name1".
        #expect(graph.variables.map(\.name) == ["Name1"])
        let variable = try #require(graph.variables.first)
        #expect(!variable.uuid.isEmpty)

        // The fixture has 3 variable nodes (2 Get + 1 Set), each referencing "Name1".
        let variableNodes = graph.nodes.filter {
            $0.type == "tm_get_variable_node" || $0.type == "tm_set_variable_node"
        }
        #expect(variableNodes.count == 3)
        #expect(variableNodes.allSatisfy { $0.variableName == "Name1" })
        // Each ref points back at the table entry's uuid.
        #expect(variableNodes.allSatisfy { $0.variableRefUUID == variable.uuid })

        // The `tm_graph_variable_ref` literals are NOT surfaced as scalar/component
        // data literals (they live on `variableName`, not in `data`).
        #expect(!graph.data.contains { $0.valueType == "tm_graph_variable_ref" })
        // No variable node carries a leaked scalar on its `name` connector.
        let nameHash = RCP3ScriptGraph.variableNameConnectorHash
        #expect(!graph.data.contains { $0.toPin == nameHash })
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
        // Resolving by the box's display id yields its EDITED instance-override
        // graph (the merged 6-node graph), not the stale 2-node prototype.
        let graph = try #require(editor.scriptGraph(forEntityID: box.id))
        #expect(graph.nodes.count == 6)

        // The lookup also succeeds by the entity's display name.
        let byName = try #require(editor.scriptGraph(forEntityID: "box"))
        #expect(byName.nodes.count == 6)

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

    // MARK: Stable graph identity (the canvas key the editor uses)

    /// The parsed graph carries its own STABLE identity — the `tm_graph`'s root
    /// `__uuid` — so the editor can key the canvas on the SHOWN graph (not a coupled
    /// selection). A synthetic graph built in memory with no assigned id keeps `nil`.
    @Test func carriesGraphRootUUIDAsStableID() throws {
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "root-uuid"
        graph: {
        \t__uuid: "graph-uuid"
        \tnodes: [
        \t\t{
        \t\t\t__uuid: "n1"
        \t\t\ttype: "tm_update"
        \t\t}
        \t]
        }
        """
        let root = try #require(try TM.parse(text).objectValue)
        let tmGraph = try #require(root["graph"]?.objectValue)
        // The id is the GRAPH member's `__uuid` (not the asset root's).
        #expect(RCP3ScriptGraph(tmGraph: tmGraph).id == "graph-uuid")

        // A memberwise (synthetic) graph defaults to no identity; an explicit id sticks.
        #expect(RCP3ScriptGraph(nodes: [], wires: [], data: []).id == nil)
        #expect(RCP3ScriptGraph(id: "synthetic", nodes: [], wires: [], data: []).id == "synthetic")
    }

    @Test func unknownPinHashFallsBackToHex() {
        let unknown: UInt64 = 0x4f980d170a59f903
        #expect(RCP3ScriptGraph.pinName(forHash: unknown) == nil)
        #expect(RCP3ScriptGraph.label(forHash: unknown) == "4f980d170a59f903")
    }
}
