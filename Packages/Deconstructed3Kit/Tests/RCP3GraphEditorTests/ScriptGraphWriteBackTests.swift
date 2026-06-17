import Testing
import Foundation
import TMFormat
import RCP3Document
@testable import RCP3GraphEditor

/// The write-back serialization core: folding model edits back into the parsed
/// `.tm_script_graph` object while preserving the parts the editor doesn't model.
@MainActor
@Suite struct ScriptGraphWriteBackTests {
    // MARK: - Hand-built asset (deterministic, no capture needed)

    /// A minimal `re_scripting_source_graph` root object built from text, mirroring
    /// the real format: two nodes, an exec + a data connection, a `component_type`
    /// data literal, an `interface`, and `validation_settings`. Used to assert
    /// determinism and the data-preservation guarantee without any capture.
    static func handBuiltAsset() throws -> TMObject {
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
        \t\t\t\tx: 10
        \t\t\t\ty: 20
        \t\t\t}
        \t\t}
        \t\t{
        \t\t\t__uuid: "n2"
        \t\t\ttype: "tm_set_component"
        \t\t\tlabel: "Set Transform"
        \t\t\tsettings: {
        \t\t\t\t__uuid: "s2"
        \t\t\t\tfoo: "bar"
        \t\t\t}
        \t\t\tposition: {
        \t\t\t\t__uuid: "p2"
        \t\t\t\tx: 300
        \t\t\t\ty: 40
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
        \t\t\t\ttype: "8c878bd87b046f80"
        \t\t\t}
        \t\t}
        \t]
        \tinterface: {
        \t\t__uuid: "iface-uuid"
        \t}
        }
        validation_settings: {
        \t__uuid: "vs-uuid"
        \tpath: "Some/Validation/Path"
        }
        __asset_uuid: "asset-uuid"
        """
        return try #require(try TM.parse(text).objectValue)
    }

    static func model(for asset: TMObject) throws -> ScriptGraphEditorModel {
        let tmGraph = try #require(asset["graph"]?.objectValue)
        return ScriptGraphEditorModel(graph: RCP3ScriptGraph(tmGraph: tmGraph))
    }

    // MARK: - Node move + label preserved members

    @Test func movingANodeUpdatesPositionAndPreservesOtherMembers() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)

        model.moveNode("n2", to: CGPoint(x: 999, y: 111))
        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)

        // Re-parse the patched object and read n2 back.
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graph = try #require(reparsed["graph"]?.objectValue)
        let n2 = try #require(
            graph["nodes"]?.arrayValue?.compactMap(\.objectValue).first { $0.uuid == "n2" }
        )
        let position = try #require(n2["position"]?.objectValue)
        #expect(position["x"]?.doubleValue == 999)
        #expect(position["y"]?.doubleValue == 111)
        // The position object's own __uuid is preserved (not regenerated).
        #expect(position.uuid == "p2")
        // The node's unmodeled `settings` member survives untouched.
        let settings = try #require(n2["settings"]?.objectValue)
        #expect(settings.uuid == "s2")
        #expect(settings["foo"]?.stringValue == "bar")
        #expect(n2["label"]?.stringValue == "Set Transform")
    }

    // MARK: - Add a connection (data wire) round-trips with hashes

    @Test func addingADataConnectionRoundTripsWithHashes() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)

        // Wire n1's "rotation" output → n2's "scale" input as a NEW data connection.
        let rotation = TMHash.murmur64a("rotation")
        let scale = TMHash.murmur64a("scale")
        let from = GraphPortRef(nodeID: "n1", pinID: "out." + TMHash.hex(rotation))
        let to = GraphPortRef(nodeID: "n2", pinID: "in." + TMHash.hex(scale))
        let newID = "new-conn"
        model.insert(
            connection: GraphConnection(id: newID, from: from, to: to, isExec: false, label: "scale")
        )

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graph = try #require(reparsed["graph"]?.objectValue)
        let connections = try #require(graph["connections"]?.arrayValue)

        let added = try #require(connections.compactMap(\.objectValue).first { $0.uuid == newID })
        #expect(added["from_node"]?.stringValue == "n1")
        #expect(added["to_node"]?.stringValue == "n2")
        #expect(added["from_connector_hash"]?.stringValue == TMHash.hex(rotation))
        #expect(added["to_connector_hash"]?.stringValue == TMHash.hex(scale))
    }

    // MARK: - Exec connection omits hashes

    @Test func execConnectionOmitsHashes() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graph = try #require(reparsed["graph"]?.objectValue)
        let connections = try #require(graph["connections"]?.arrayValue)

        let exec = try #require(connections.compactMap(\.objectValue).first { $0.uuid == "c1" })
        #expect(exec["from_node"]?.stringValue == "n1")
        #expect(exec["to_node"]?.stringValue == "n2")
        #expect(exec["from_connector_hash"] == nil)
        #expect(exec["to_connector_hash"] == nil)
    }

    // MARK: - Data-preservation guarantee (the key invariant)

    @Test func preservesUnmodeledMembers() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)

        // A representative edit: move a node and add an exec wire's worth of change.
        model.moveNode("n1", to: CGPoint(x: 1, y: 2))
        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)

        // Root identity preserved.
        #expect(reparsed.uuid == "root-uuid")
        #expect(reparsed.type == "re_scripting_source_graph")
        #expect(reparsed["__asset_uuid"]?.stringValue == "asset-uuid")

        let graph = try #require(reparsed["graph"]?.objectValue)
        #expect(graph.uuid == "graph-uuid")

        // The `component_type` data literal is STILL present and intact.
        let data = try #require(graph["data"]?.arrayValue)
        #expect(data.count == 1)
        let literal = try #require(data.first?.objectValue)
        #expect(literal.uuid == "d1")
        #expect(literal["to_node"]?.stringValue == "n2")
        #expect(literal["to_connector_hash"]?.stringValue == "772749b3cbf24a8f")
        let value = try #require(literal["data"]?.objectValue)
        #expect(value.type == "re_scripting_graph_component_type")
        #expect(value["type"]?.stringValue == "8c878bd87b046f80")

        // interface preserved.
        let interface = try #require(graph["interface"]?.objectValue)
        #expect(interface.uuid == "iface-uuid")

        // validation_settings preserved.
        let vs = try #require(reparsed["validation_settings"]?.objectValue)
        #expect(vs.uuid == "vs-uuid")
        #expect(vs["path"]?.stringValue == "Some/Validation/Path")
    }

    // MARK: - Insert + delete

    @Test func insertedNodeIsSerializedAndDeletedNodeIsDropped() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)

        // Insert a new node.
        let newID = model.addNode(type: "tm_get_component", label: "Reader", at: CGPoint(x: 50, y: 60))

        // Delete n1 (selecting it removes the node + its touching wires).
        model.selectNode("n1")
        model.deleteSelection()

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graph = try #require(reparsed["graph"]?.objectValue)
        let nodes = try #require(graph["nodes"]?.arrayValue).compactMap(\.objectValue)

        // n1 dropped; n2 + the inserted node remain.
        #expect(nodes.contains { $0.uuid == "n2" })
        #expect(!nodes.contains { $0.uuid == "n1" })

        let inserted = try #require(nodes.first { $0.uuid == newID })
        #expect(inserted["type"]?.stringValue == "tm_get_component")
        #expect(inserted["label"]?.stringValue == "Reader")
        let position = try #require(inserted["position"]?.objectValue)
        #expect(position["x"]?.doubleValue == 50)
        #expect(position["y"]?.doubleValue == 60)

        // Connections touching n1 are gone (both c1 + c2 referenced n1).
        let connections = (graph["connections"]?.arrayValue ?? []).compactMap(\.objectValue)
        #expect(!connections.contains { $0["from_node"]?.stringValue == "n1" || $0["to_node"]?.stringValue == "n1" })

        // The data literal still targets n2 (a live node), so it is kept.
        let data = try #require(graph["data"]?.arrayValue)
        #expect(data.count == 1)
    }

    @Test func deletingTargetNodeDropsItsDataLiteral() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)

        // The lone data literal targets n2; deleting n2 should drop it.
        model.selectNode("n2")
        model.deleteSelection()

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graph = try #require(reparsed["graph"]?.objectValue)
        #expect((graph["data"]?.arrayValue ?? []).isEmpty)
    }

    // MARK: - Scalar literal authoring round-trips through data[]

    /// A minimal asset with a single `tm_make_vector3` node and NO data literals — a
    /// clean canvas for authoring scalar pin literals.
    static func vectorAsset() throws -> TMObject {
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "root-uuid"
        graph: {
        \t__uuid: "graph-uuid"
        \tnodes: [
        \t\t{
        \t\t\t__uuid: "v1"
        \t\t\ttype: "tm_make_vector3"
        \t\t\tposition: {
        \t\t\t\t__uuid: "pv"
        \t\t\t\tx: 0
        \t\t\t\ty: 0
        \t\t\t}
        \t\t}
        \t]
        \tconnections: [
        \t]
        \tdata: [
        \t]
        }
        __asset_uuid: "asset-uuid"
        """
        return try #require(try TM.parse(text).objectValue)
    }

    /// Authoring a scalar literal on an unwired numeric pin survives a write → parse
    /// round-trip: the value lands in `data[]` and re-parses back to the same number
    /// (read by `RCP3ScriptGraph.scalarLiteral`).
    @Test func authoredScalarLiteralRoundTrips() throws {
        let asset = try Self.vectorAsset()
        let model = try Self.model(for: asset)

        let x = TMHash.murmur64a("x")
        let z = TMHash.murmur64a("z")
        model.setLiteral(nodeID: "v1", pinConnectorHash: x, value: 2.5)
        model.setLiteral(nodeID: "v1", pinConnectorHash: z, value: -4)

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let tmGraph = try #require(reparsed["graph"]?.objectValue)

        // Two scalar literals were written into data[].
        let data = try #require(tmGraph["data"]?.arrayValue)
        #expect(data.count == 2)

        // Re-parse to a display graph and read the scalars back.
        let graph = RCP3ScriptGraph(tmGraph: tmGraph)
        #expect(graph.scalarLiteral(node: "v1", pin: x) == 2.5)
        #expect(graph.scalarLiteral(node: "v1", pin: z) == -4)

        // And a fresh editor model re-seeds those authored values.
        let reloaded = ScriptGraphEditorModel(graph: graph)
        #expect(reloaded.literal(nodeID: "v1", pinConnectorHash: x) == 2.5)
        #expect(reloaded.literal(nodeID: "v1", pinConnectorHash: z) == -4)
    }

    /// Editing an existing scalar literal rewrites its value in place (preserving the
    /// literal's identity); clearing it drops the literal from data[].
    @Test func editingAndClearingScalarLiteral() throws {
        let asset = try Self.vectorAsset()
        let x = TMHash.murmur64a("x")

        // Start with an authored literal, write it, then re-open from the written form.
        let model = try Self.model(for: asset)
        model.setLiteral(nodeID: "v1", pinConnectorHash: x, value: 1)
        let firstWrite = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let firstReparsed = try #require(try TM.parse(firstWrite.tmText()).objectValue)
        let literalUUID = try #require(
            firstReparsed["graph"]?.objectValue?["data"]?.arrayValue?.first?.objectValue?.uuid
        )

        // EDIT: change the value; the literal keeps its __uuid (updated in place).
        let edited = ScriptGraphEditorModel(graph: RCP3ScriptGraph(tmGraph: try #require(firstReparsed["graph"]?.objectValue)))
        edited.setLiteral(nodeID: "v1", pinConnectorHash: x, value: 7.5)
        let editWrite = ScriptGraphWriteBack.patched(asset: firstReparsed, with: edited)
        let editReparsed = try #require(try TM.parse(editWrite.tmText()).objectValue)
        let editData = try #require(editReparsed["graph"]?.objectValue?["data"]?.arrayValue)
        #expect(editData.count == 1)
        #expect(editData.first?.objectValue?.uuid == literalUUID) // identity preserved
        #expect(RCP3ScriptGraph(tmGraph: try #require(editReparsed["graph"]?.objectValue))
            .scalarLiteral(node: "v1", pin: x) == 7.5)

        // CLEAR: removing the authored value drops the literal entirely.
        let cleared = ScriptGraphEditorModel(graph: RCP3ScriptGraph(tmGraph: try #require(editReparsed["graph"]?.objectValue)))
        cleared.setLiteral(nodeID: "v1", pinConnectorHash: x, value: nil)
        let clearWrite = ScriptGraphWriteBack.patched(asset: editReparsed, with: cleared)
        let clearReparsed = try #require(try TM.parse(clearWrite.tmText()).objectValue)
        #expect((clearReparsed["graph"]?.objectValue?["data"]?.arrayValue ?? []).isEmpty)
    }

    /// Authoring a scalar literal does NOT disturb a non-scalar (`component_type`)
    /// literal already in the graph — both survive the round-trip.
    @Test func authoredScalarLiteralPreservesComponentTypeLiteral() throws {
        let asset = try Self.handBuiltAsset() // has the component_type literal on n2
        let model = try Self.model(for: asset)

        // Author a numeric literal on n2's `scale` input (unwired numeric-ish pin).
        let scale = TMHash.murmur64a("scale")
        model.setLiteral(nodeID: "n2", pinConnectorHash: scale, value: 3)

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let tmGraph = try #require(reparsed["graph"]?.objectValue)
        let data = try #require(tmGraph["data"]?.arrayValue).compactMap(\.objectValue)

        // The component_type literal is intact.
        let componentType = try #require(
            data.first { $0["data"]?.objectValue?.type == "re_scripting_graph_component_type" }
        )
        #expect(componentType.uuid == "d1")
        #expect(componentType["data"]?.objectValue?["type"]?.stringValue == "8c878bd87b046f80")

        // The authored scalar literal is present and reads back.
        #expect(RCP3ScriptGraph(tmGraph: tmGraph).scalarLiteral(node: "n2", pin: scale) == 3)
    }

    // MARK: - Round trip against the Random capture (skips when absent)

    /// The workspace-local `Random` capture (a box with a `re_scripting_component`),
    /// if present. Captures live outside the OSS package (`../../references/`), so
    /// this no-ops cleanly when the capture is absent.
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

    @Test func roundTripsRealCapturePreservingData() throws {
        guard let url = Self.randomBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)

        // Find the "Script Graph" asset and load both its parsed asset object + graph.
        let asset = try #require(bundle.scriptGraphAssets().first { $0.name.contains("Script Graph") })
        let (assetObject, _) = try #require(
            ScriptGraphWriteBack.resolveAsset(rootUUID: asset.id, in: url)
        )
        let graph = try #require(bundle.scriptGraph(assetID: asset.id))
        let model = ScriptGraphEditorModel(graph: graph)

        // The original graph data literals (the `component_type`) for later comparison.
        let originalDataCount = (assetObject["graph"]?.objectValue?["data"]?.arrayValue ?? []).count
        #expect(originalDataCount >= 1)

        // MOVE the first node.
        let firstNodeID = try #require(model.nodes.first?.id)
        model.moveNode(firstNodeID, to: CGPoint(x: 1234, y: 5678))

        // ADD a data connection between two distinct nodes (if there are ≥2).
        var expectedNewConnection: GraphConnection?
        if model.nodes.count >= 2 {
            let a = model.nodes[0].id
            let b = model.nodes[1].id
            let rotation = TMHash.murmur64a("rotation")
            let scale = TMHash.murmur64a("scale")
            let conn = GraphConnection(
                id: "wb-test-conn",
                from: GraphPortRef(nodeID: a, pinID: "out." + TMHash.hex(rotation)),
                to: GraphPortRef(nodeID: b, pinID: "in." + TMHash.hex(scale)),
                isExec: false,
                label: "scale"
            )
            model.insert(connection: conn)
            expectedNewConnection = conn
        }

        let patched = ScriptGraphWriteBack.patched(asset: assetObject, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let reparsedGraph = try #require(reparsed["graph"]?.objectValue)

        // The moved node's position changed.
        let movedNode = try #require(
            reparsedGraph["nodes"]?.arrayValue?.compactMap(\.objectValue).first { $0.uuid == firstNodeID }
        )
        let position = try #require(movedNode["position"]?.objectValue)
        #expect(position["x"]?.doubleValue == 1234)
        #expect(position["y"]?.doubleValue == 5678)

        // The new connection is present with correct from/to + hashes.
        if let expected = expectedNewConnection {
            let connections = (reparsedGraph["connections"]?.arrayValue ?? []).compactMap(\.objectValue)
            let added = try #require(connections.first { $0.uuid == expected.id })
            #expect(added["from_node"]?.stringValue == expected.from.nodeID)
            #expect(added["to_node"]?.stringValue == expected.to.nodeID)
            #expect(added["from_connector_hash"]?.stringValue == String(expected.from.pinID.dropFirst(4)))
            #expect(added["to_connector_hash"]?.stringValue == String(expected.to.pinID.dropFirst(3)))
        }

        // The original `component_type` data literal is STILL present (not lost).
        let reparsedDataCount = (reparsedGraph["data"]?.arrayValue ?? []).count
        #expect(reparsedDataCount == originalDataCount)
        let hasComponentType = (reparsedGraph["data"]?.arrayValue ?? [])
            .compactMap(\.objectValue)
            .contains { $0["data"]?.objectValue?.type == "re_scripting_graph_component_type" }
        #expect(hasComponentType)

        // Root uuid + validation_settings preserved.
        #expect(reparsed.uuid == assetObject.uuid)
        if let originalVS = assetObject["validation_settings"]?.objectValue {
            let vs = try #require(reparsed["validation_settings"]?.objectValue)
            #expect(vs.uuid == originalVS.uuid)
        }
    }

    // MARK: - File write resolves by root uuid

    @Test func writeResolvesByRootUUIDAndPersists() throws {
        // Build a temp bundle dir with a single .tm_script_graph file.
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "wb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset = try Self.handBuiltAsset()
        let fileURL = tmp.appending(path: "Script Graph.tm_script_graph")
        try asset.tmText().write(to: fileURL, atomically: true, encoding: .utf8)

        let model = try Self.model(for: asset)
        model.moveNode("n1", to: CGPoint(x: 777, y: 888))

        try ScriptGraphWriteBack.write(model: model, toAssetWithRootUUID: "root-uuid", in: tmp)

        // Re-read the file and confirm the move landed + data preserved.
        let written = try String(contentsOf: fileURL, encoding: .utf8)
        let reparsed = try #require(try TM.parse(written).objectValue)
        let graph = try #require(reparsed["graph"]?.objectValue)
        let n1 = try #require(
            graph["nodes"]?.arrayValue?.compactMap(\.objectValue).first { $0.uuid == "n1" }
        )
        #expect(n1["position"]?.objectValue?["x"]?.doubleValue == 777)
        #expect((graph["data"]?.arrayValue ?? []).count == 1)
    }

    @Test func writeThrowsWhenAssetNotFound() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "wb-test-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)
        #expect(throws: ScriptGraphWriteBack.WriteError.assetNotFound(rootUUID: "nope")) {
            try ScriptGraphWriteBack.write(model: model, toAssetWithRootUUID: "nope", in: tmp)
        }
    }

    // MARK: - Variable round-trip + authoring

    /// Walk-up resolver for the `Random2` capture's standalone `My Script Graph`
    /// (a graph that uses variables). No-ops cleanly when the capture is absent.
    /// Note the SPACE in the file name.
    static func myScriptGraphAsset() throws -> (asset: TMObject, graph: RCP3ScriptGraph)? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let file = dir.appending(path: "references/Random2.realitycomposerpro/My Script Graph.tm_script_graph")
            if FileManager.default.fileExists(atPath: file.path) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let asset = try #require(try TM.parse(text).objectValue)
                let tmGraph = try #require(asset["graph"]?.objectValue)
                return (asset, RCP3ScriptGraph(tmGraph: tmGraph))
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Parse → write-back → re-parse of the real variable-using graph reproduces the
    /// variable table (stable uuids) + each variable node's `variableName`, and the
    /// `tm_graph_variable_ref` entries land on the `murmur64a("name")` connector.
    @Test func variableGraphRoundTrips() throws {
        guard let (asset, graph) = try Self.myScriptGraphAsset() else { return } // capture absent
        let model = ScriptGraphEditorModel(graph: graph)

        // Sanity: the model seeded the table + per-node names from disk.
        #expect(model.variables.map(\.name) == ["Name1"])
        #expect(model.variableNames.values.allSatisfy { $0 == "Name1" })
        let originalVariableUUID = try #require(model.variables.first?.uuid)

        // Write back WITHOUT changing anything → re-parse.
        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let tmGraph = try #require(reparsed["graph"]?.objectValue)
        let graph2 = RCP3ScriptGraph(tmGraph: tmGraph)

        // The variable table survived with its name + uuid (stable).
        #expect(graph2.variables.map(\.name) == ["Name1"])
        #expect(graph2.variables.first?.uuid == originalVariableUUID)

        // Each variable node still references "Name1".
        let varNodes2 = graph2.nodes.filter {
            $0.type == "tm_get_variable_node" || $0.type == "tm_set_variable_node"
        }
        #expect(varNodes2.count == 3)
        #expect(varNodes2.allSatisfy { $0.variableName == "Name1" })
        #expect(varNodes2.allSatisfy { $0.variableRefUUID == originalVariableUUID })

        // The `tm_graph_variable_ref` entries are on the murmur64a("name") connector,
        // and point at the table entry by `ref`.
        let nameHash = RCP3ScriptGraph.variableNameConnectorHash
        let refEntries = (tmGraph["data"]?.arrayValue ?? []).compactMap(\.objectValue)
            .filter { $0["data"]?.objectValue?.type == "tm_graph_variable_ref" }
        #expect(refEntries.count == 3)
        for entry in refEntries {
            let connectorHex = try #require(entry["to_connector_hash"]?.stringValue)
            #expect(UInt64(connectorHex, radix: 16) == nameHash)
            #expect(entry["data"]?.objectValue?["ref"]?.stringValue == originalVariableUUID)
            #expect(entry["data"]?.objectValue?["name"]?.stringValue == "Name1")
        }

        // The per-node ref entry uuids are preserved across the in-place rewrite.
        let originalRefUUIDs = Set(
            (asset["graph"]?.objectValue?["data"]?.arrayValue ?? []).compactMap(\.objectValue)
                .filter { $0["data"]?.objectValue?.type == "tm_graph_variable_ref" }
                .compactMap(\.uuid)
        )
        #expect(Set(refEntries.compactMap(\.uuid)) == originalRefUUIDs)
    }

    /// A hand-built graph with NO variables writes NO `variables:` member and NO
    /// `tm_graph_variable_ref` entries (don't regress existing fixtures).
    @Test func graphWithoutVariablesWritesNoVariableTable() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)
        #expect(model.variables.isEmpty)

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let tmGraph = try #require(reparsed["graph"]?.objectValue)
        #expect(tmGraph["variables"] == nil)
        #expect(!(tmGraph["data"]?.arrayValue ?? []).contains {
            $0.objectValue?["data"]?.objectValue?.type == "tm_graph_variable_ref"
        })
    }

    /// A hand-built deterministic graph with two variable nodes, exercising authoring
    /// from scratch: naming a variable on a node declares it in the table and emits a
    /// `tm_graph_variable_ref` on the `name` connector; both Get + Set sharing a name
    /// reuse the single table entry.
    static func variableNodesAsset() throws -> TMObject {
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "root-uuid"
        graph: {
        \t__uuid: "graph-uuid"
        \tnodes: [
        \t\t{
        \t\t\t__uuid: "get1"
        \t\t\ttype: "tm_get_variable_node"
        \t\t\tposition: { __uuid: "pg" x: 0 y: 0 }
        \t\t}
        \t\t{
        \t\t\t__uuid: "set1"
        \t\t\ttype: "tm_set_variable_node"
        \t\t\tposition: { __uuid: "ps" x: 100 y: 0 }
        \t\t}
        \t]
        \tconnections: []
        \tdata: []
        }
        __asset_uuid: "asset-uuid"
        """
        return try #require(try TM.parse(text).objectValue)
    }

    /// Setting a variable name via the inspector verb updates the node and (when new)
    /// declares it in the table; write-back emits the ref + the `variables:` table; a
    /// fresh model re-seeds the same name. Two nodes sharing a name reuse one entry.
    @Test func authoringVariableNameDeclaresAndRoundTrips() throws {
        let asset = try Self.variableNodesAsset()
        let model = try Self.model(for: asset)
        #expect(model.isVariableNode("get1"))
        #expect(model.isVariableNode("set1"))

        // Author the SAME variable on both nodes — declared once in the table.
        model.setVariableName(nodeID: "get1", name: "Score")
        model.setVariableName(nodeID: "set1", name: "Score")
        #expect(model.variables.map(\.name) == ["Score"])
        #expect(model.variableName(nodeID: "get1") == "Score")

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let tmGraph = try #require(reparsed["graph"]?.objectValue)
        let graph2 = RCP3ScriptGraph(tmGraph: tmGraph)

        // One table entry, two ref entries (one per node), both pointing at it.
        #expect(graph2.variables.map(\.name) == ["Score"])
        let varUUID = try #require(graph2.variables.first?.uuid)
        let varNodes = graph2.nodes.filter { $0.variableName != nil }
        #expect(varNodes.count == 2)
        #expect(varNodes.allSatisfy { $0.variableName == "Score" })
        #expect(varNodes.allSatisfy { $0.variableRefUUID == varUUID })

        // The refs are on the murmur64a("name") connector.
        let nameHash = RCP3ScriptGraph.variableNameConnectorHash
        let refEntries = (tmGraph["data"]?.arrayValue ?? []).compactMap(\.objectValue)
            .filter { $0["data"]?.objectValue?.type == "tm_graph_variable_ref" }
        #expect(refEntries.count == 2)
        #expect(refEntries.allSatisfy { UInt64($0["to_connector_hash"]?.stringValue ?? "", radix: 16) == nameHash })

        // A fresh model re-seeds the authored name.
        let reloaded = ScriptGraphEditorModel(graph: graph2)
        #expect(reloaded.variableName(nodeID: "get1") == "Score")
        #expect(reloaded.variableName(nodeID: "set1") == "Score")

        // CLEARING one node's name drops only its ref; the table entry survives.
        reloaded.setVariableName(nodeID: "get1", name: nil)
        let clearWrite = ScriptGraphWriteBack.patched(asset: reparsed, with: reloaded)
        let clearRoot = try #require(try TM.parse(clearWrite.tmText()).objectValue)
        let clearGraph = RCP3ScriptGraph(tmGraph: try #require(clearRoot["graph"]?.objectValue))
        #expect(clearGraph.nodes.first { $0.id == "get1" }?.variableName == nil)
        #expect(clearGraph.nodes.first { $0.id == "set1" }?.variableName == "Score")
        #expect(clearGraph.variables.map(\.name) == ["Score"]) // table entry retained
    }
}
