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

    /// Covers both settings layouts observed in the RKS schemas: String and typed
    /// Array operators keep dynamic connectors directly; Array Create nests them in
    /// `tm_array_create_node_settings` with the selected type hashes.
    static func dynamicConnectorAsset() throws -> TMObject {
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "dynamic-root"
        graph: {
        \t__uuid: "dynamic-graph"
        \tnodes: [
        \t\t{
        \t\t\t__uuid: "string-node"
        \t\t\ttype: "tm_to_string"
        \t\t\tposition: { __uuid: "string-position" x: 10 y: 20 }
        \t\t\tsettings: {
        \t\t\t\t__type: "tm_graph_node_dynamic_connectors_settings"
        \t\t\t\t__uuid: "string-settings"
        \t\t\t\tinputs: [{
        \t\t\t\t\t__type: "tm_graph_node_dynamic_connector"
        \t\t\t\t\t__uuid: "string-input"
        \t\t\t\t\tname: "source_value"
        \t\t\t\t\tdisplay_name: "Source Value"
        \t\t\t\t\ttype_hash: "1111111111111111"
        \t\t\t\t\tedit_hash: "2222222222222222"
        \t\t\t\t\torder: 3.5
        \t\t\t\t\toptionality: 1
        \t\t\t\t}]
        \t\t\t\toutputs: []
        \t\t\t}
        \t\t}
        \t\t{
        \t\t\t__uuid: "array-node"
        \t\t\ttype: "tm_array_get"
        \t\t\tposition: { __uuid: "array-position" x: 30 y: 40 }
        \t\t\tsettings: {
        \t\t\t\t__type: "tm_graph_node_dynamic_connectors_settings"
        \t\t\t\t__uuid: "array-settings"
        \t\t\t\tinputs: [{
        \t\t\t\t\t__type: "tm_graph_node_dynamic_connector"
        \t\t\t\t\t__uuid: "array-input"
        \t\t\t\t\tname: "array"
        \t\t\t\t\ttype_hash: "aaaaaaaaaaaaaaaa"
        \t\t\t\t\tedit_hash: "3333333333333333"
        \t\t\t\t\torder: 0
        \t\t\t\t\toptionality: 0
        \t\t\t\t}]
        \t\t\t\toutputs: []
        \t\t\t}
        \t\t}
        \t\t{
        \t\t\t__uuid: "create-node"
        \t\t\ttype: "tm_array_create"
        \t\t\tposition: { __uuid: "create-position" x: 50 y: 60 }
        \t\t\tsettings: {
        \t\t\t\t__type: "tm_array_create_node_settings"
        \t\t\t\t__uuid: "create-settings"
        \t\t\t\tarray_type: "aaaaaaaaaaaaaaaa"
        \t\t\t\telement_type: "bbbbbbbbbbbbbbbb"
        \t\t\t\tdynamic_connectors: {
        \t\t\t\t\t__type: "tm_graph_node_dynamic_connectors_settings"
        \t\t\t\t\t__uuid: "create-connectors"
        \t\t\t\t\tinputs: []
        \t\t\t\t\toutputs: []
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t]
        \tconnections: []
        \tdata: []
        }
        """
        return try #require(try TM.parse(text).objectValue)
    }

    static func materialSettingsAsset() throws -> TMObject {
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "material-root"
        graph: {
        \t__uuid: "material-graph"
        \tnodes: [{
        \t\t__uuid: "material-node"
        \t\ttype: "tm_modify_any_material_123"
        \t\tposition: { __uuid: "material-position" x: 10 y: 20 }
        \t\tsettings: {
        \t\t\t__type: "tm_material_node_settings"
        \t\t\t__uuid: "material-settings"
        \t\t\ttype: "1111111111111111"
        \t\t\tobject_identifier: "RealityKit.PhysicallyBasedMaterial"
        \t\t\tinputs: [{
        \t\t\t\t__type: "tm_material_node_settings_property"
        \t\t\t\t__uuid: "base-color-property"
        \t\t\t\tname: "baseColor"
        \t\t\t\ttype: "2222222222222222"
        \t\t\t\tedit_type: "3333333333333333"
        \t\t\t\toptional: false
        \t\t\t\tvendor_extension: "preserve-me"
        \t\t\t}]
        \t\t\toutputs: [{
        \t\t\t\t__type: "tm_material_node_settings_property"
        \t\t\t\t__uuid: "roughness-property"
        \t\t\t\tname: "roughness"
        \t\t\t\ttype: "4444444444444444"
        \t\t\t\tedit_type: "5555555555555555"
        \t\t\t\toptional: true
        \t\t\t}]
        \t\t}
        \t}]
        \tconnections: []
        \tdata: []
        }
        """
        return try #require(try TM.parse(text).objectValue)
    }

    static func entityParameterSettingsAsset() throws -> TMObject {
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "parameter-root"
        graph: {
        \t__uuid: "parameter-graph"
        \tnodes: [{
        \t\t__uuid: "parameter-node"
        \t\ttype: "tm_get_entity_parameter"
        \t\tposition: { __uuid: "parameter-position" x: 10 y: 20 }
        \t\tsettings: {
        \t\t\t__type: "tm_entity_parameter_node_settings"
        \t\t\t__uuid: "parameter-settings"
        \t\t\ttype: "1111111111111111"
        \t\t\tvendor_extension: "preserve-me"
        \t\t}
        \t}]
        \tconnections: []
        \tdata: []
        }
        """
        return try #require(try TM.parse(text).objectValue)
    }

    @Test("Entity Parameter settings parse and identity-preservingly round trip")
    func entityParameterSettingsRoundTrip() throws {
        let asset = try Self.entityParameterSettingsAsset()
        let model = try Self.model(for: asset)
        let box = try #require(model.node("parameter-node"))
        #expect(box.entityParameterSettings?.typeHash == 0x1111_1111_1111_1111)
        #expect(box.dynamicConnectorSettings == nil)

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let node = try #require(reparsed["graph"]?.objectValue?["nodes"]?.arrayValue?.first?.objectValue)
        let settings = try #require(node["settings"]?.objectValue)
        #expect(settings.type == "tm_entity_parameter_node_settings")
        #expect(settings.uuid == "parameter-settings")
        #expect(settings["type"]?.stringValue == "1111111111111111")
        #expect(settings["vendor_extension"]?.stringValue == "preserve-me")

        let projected = RCP3ScriptGraph(tmGraph: try #require(reparsed["graph"]?.objectValue))
        #expect(projected.node(id: "parameter-node")?.entityParameterSettings ==
            RCP3ScriptGraph.Node.EntityParameterSettings(typeHash: 0x1111_1111_1111_1111))
    }

    @Test("Material settings parse the exact Inspectable property schema")
    func materialSettingsParse() throws {
        let model = try Self.model(for: Self.materialSettingsAsset())
        let node = try #require(model.node("material-node"))
        let settings = try #require(node.materialSettings)
        #expect(settings.typeHash == 0x1111_1111_1111_1111)
        #expect(settings.objectIdentifier == "RealityKit.PhysicallyBasedMaterial")
        #expect(settings.inputs == [.init(
            name: "baseColor",
            typeHash: 0x2222_2222_2222_2222,
            editTypeHash: 0x3333_3333_3333_3333,
            isOptional: false
        )])
        #expect(settings.outputs == [.init(
            name: "roughness",
            typeHash: 0x4444_4444_4444_4444,
            editTypeHash: 0x5555_5555_5555_5555,
            isOptional: true
        )])
        #expect(node.dynamicConnectorSettings == nil)
    }

    @Test("Material settings write-back preserves identities and unknown members")
    func materialSettingsRoundTrip() throws {
        let asset = try Self.materialSettingsAsset()
        let model = try Self.model(for: asset)
        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graph = try #require(reparsed["graph"]?.objectValue)
        let node = try #require(graph["nodes"]?.arrayValue?.first?.objectValue)
        let settings = try #require(node["settings"]?.objectValue)
        #expect(settings.type == "tm_material_node_settings")
        #expect(settings.uuid == "material-settings")
        #expect(settings["type"]?.stringValue == "1111111111111111")
        #expect(settings["object_identifier"]?.stringValue == "RealityKit.PhysicallyBasedMaterial")
        let input = try #require(settings["inputs"]?.arrayValue?.first?.objectValue)
        #expect(input.type == "tm_material_node_settings_property")
        #expect(input.uuid == "base-color-property")
        #expect(input["vendor_extension"]?.stringValue == "preserve-me")
        #expect(input["optional"]?.boolValue == false)

        let projected = RCP3ScriptGraph(tmGraph: graph)
        #expect(projected.node(id: "material-node")?.materialSettings ==
            model.node("material-node")?.materialSettings)
    }

    @Test("Dynamic connector settings resolve exact pins from direct and nested schemas")
    func dynamicConnectorSettingsResolvePins() throws {
        let model = try Self.model(for: Self.dynamicConnectorAsset())

        let string = try #require(model.node("string-node"))
        #expect(string.dynamicConnectorSettings?.inputs.map(\.name) == ["source_value"])
        #expect(string.payload.inputPins.map(\.label) == ["Source Value"])
        #expect(string.payload.outputPins.map(\.label) == ["Value"])

        let array = try #require(model.node("array-node"))
        #expect(array.dynamicConnectorSettings?.container == .direct)
        #expect(array.payload.inputPins.map(\.label) == ["Index", "Array"])
        #expect(array.payload.outputPins.map(\.label) == ["Element"])

        let create = try #require(model.node("create-node"))
        #expect(create.dynamicConnectorSettings?.container == .array(
            arrayType: 0xaaaa_aaaa_aaaa_aaaa,
            elementType: 0xbbbb_bbbb_bbbb_bbbb
        ))
    }

    @Test("Dynamic connector write-back preserves settings and connector identities")
    func dynamicConnectorSettingsRoundTrip() throws {
        let asset = try Self.dynamicConnectorAsset()
        let model = try Self.model(for: asset)
        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graphObject = try #require(reparsed["graph"]?.objectValue)
        let nodes = try #require(graphObject["nodes"]?.arrayValue).compactMap(\.objectValue)

        let stringSettings = try #require(
            nodes.first { $0.uuid == "string-node" }?["settings"]?.objectValue
        )
        #expect(stringSettings.uuid == "string-settings")
        let stringInput = try #require(stringSettings["inputs"]?.arrayValue?.first?.objectValue)
        #expect(stringInput.uuid == "string-input")
        #expect(stringInput["type_hash"]?.stringValue == "1111111111111111")
        #expect(stringInput["edit_hash"]?.stringValue == "2222222222222222")

        let arraySettings = try #require(
            nodes.first { $0.uuid == "array-node" }?["settings"]?.objectValue
        )
        #expect(arraySettings.uuid == "array-settings")
        let arrayInput = try #require(arraySettings["inputs"]?.arrayValue?.first?.objectValue)
        #expect(arrayInput.uuid == "array-input")

        let createSettings = try #require(
            nodes.first { $0.uuid == "create-node" }?["settings"]?.objectValue
        )
        #expect(createSettings.uuid == "create-settings")
        #expect(createSettings["array_type"]?.stringValue == "aaaaaaaaaaaaaaaa")
        #expect(createSettings["element_type"]?.stringValue == "bbbbbbbbbbbbbbbb")
        let nested = try #require(createSettings["dynamic_connectors"]?.objectValue)
        #expect(nested.uuid == "create-connectors")

        let projected = RCP3ScriptGraph(tmGraph: graphObject)
        #expect(projected.node(id: "string-node")?.dynamicConnectorSettings ==
            model.node("string-node")?.dynamicConnectorSettings)
        #expect(projected.node(id: "array-node")?.dynamicConnectorSettings ==
            model.node("array-node")?.dynamicConnectorSettings)
        #expect(projected.node(id: "create-node")?.dynamicConnectorSettings ==
            model.node("create-node")?.dynamicConnectorSettings)
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
        #expect(position.uuid != nil)
        #expect(position["x"]?.doubleValue == 50)
        #expect(position["y"]?.doubleValue == 60)

        // Connections touching n1 are gone (both c1 + c2 referenced n1).
        let connections = (graph["connections"]?.arrayValue ?? []).compactMap(\.objectValue)
        #expect(!connections.contains { $0["from_node"]?.stringValue == "n1" || $0["to_node"]?.stringValue == "n1" })

        // The data literal still targets n2 (a live node), so it is kept.
        let data = try #require(graph["data"]?.arrayValue)
        #expect(data.count == 1)
    }

    @Test func insertedEnumNodeSettingsRoundTripAndDrivePins() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)
        let id = model.addNode(
            type: "tm_make_anchoring_component_target", at: CGPoint(x: 80, y: 90)
        )
        model.setEnumCase(nodeID: id, caseName: "plane")

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graphObject = try #require(reparsed["graph"]?.objectValue)
        let object = try #require(
            graphObject["nodes"]?.arrayValue?.compactMap(\.objectValue).first { $0.uuid == id }
        )
        let settings = try #require(object["settings"]?.objectValue)
        #expect(settings.type == "script_graph_enum")
        #expect(settings["case"]?.stringValue == "plane")
        #expect(settings["type"]?.stringValue == TMHash.murmur64aHex("AnchoringComponent.Target"))
        #expect(settings["associated_values"]?.arrayValue?.count == 3)

        let reopened = RCP3ScriptGraph(tmGraph: graphObject)
        let node = try #require(reopened.node(id: id))
        #expect(node.enumSelection?.caseName == "plane")
        #expect(node.enumSelection?.associatedValues.map(\.index) == [0, 1, 2])
        let payload = ScriptGraphPinResolver.payload(for: node, in: reopened)
        #expect(payload.inputPins.map(\.label) == ["Value 0", "Value 1", "Value 2"])
        #expect(payload.outputPins.map(\.label) == ["Value"])
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

    /// Authoring a boolean and a string literal survives write → parse: each lands in
    /// `data[]` with its observed value object (`tm_bool { bool }` / `tm_string
    /// { string }`) and re-seeds a fresh model as the same `TMGraphValue`.
    @Test func authoredBoolAndStringLiteralsRoundTrip() throws {
        let asset = try Self.vectorAsset()
        let model = try Self.model(for: asset)

        let flag = TMHash.murmur64a("flag")
        let label = TMHash.murmur64a("label")
        model.setValue(nodeID: "v1", pinConnectorHash: flag, value: .bool(true))
        model.setValue(nodeID: "v1", pinConnectorHash: label, value: .string("hi"))

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let tmGraph = try #require(reparsed["graph"]?.objectValue)

        // The written value objects carry the observed encodings.
        let data = try #require(tmGraph["data"]?.arrayValue)
        let valueObjects = data.compactMap { $0.objectValue?["data"]?.objectValue }
        #expect(valueObjects.contains { $0.type == "tm_bool" && $0["bool"]?.boolValue == true })
        #expect(valueObjects.contains { $0.type == "tm_string" && $0["string"]?.stringValue == "hi" })

        // A fresh model re-seeds them as the canonical values.
        let reloaded = ScriptGraphEditorModel(graph: RCP3ScriptGraph(tmGraph: tmGraph))
        #expect(reloaded.value(nodeID: "v1", pinConnectorHash: flag) == .bool(true))
        #expect(reloaded.value(nodeID: "v1", pinConnectorHash: label) == .string("hi"))
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

    @Test func typedNumberVariableWritesAndReparsesCanonicalRCPMetadata() throws {
        let asset = try Self.variableNodesAsset()
        let variable = RCP3ScriptGraph.Variable(
            uuid: "typed-variable",
            name: "Score",
            typeHash: 0x3c2f3d0fe92dd9a0,
            editHash: 0x0ef2dd9a55accbe4,
            dataType: "tm_double"
        )
        let node = RCP3ScriptGraph.Node(
            id: "get1",
            type: "tm_get_variable_node",
            variableName: variable.name,
            variableRefUUID: variable.uuid
        )
        let model = ScriptGraphEditorModel(graph: .init(
            nodes: [node], wires: [], data: [], variables: [variable]
        ))

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let root = try #require(try TM.parse(patched.tmText()).objectValue)
        let tmGraph = try #require(root["graph"]?.objectValue)
        let stored = try #require(tmGraph["variables"]?.arrayValue?.first?.objectValue)
        #expect(stored["type_hash"]?.stringValue == "3c2f3d0fe92dd9a0")
        #expect(stored["edit_hash"]?.stringValue == "0ef2dd9a55accbe4")
        #expect(stored["data"]?.objectValue?.type == "tm_double")
        #expect(stored["data"]?.objectValue?.uuid != nil)

        let reparsed = RCP3ScriptGraph(tmGraph: tmGraph)
        #expect(reparsed.variables == [variable])
        #expect(reparsed.nodes.first?.variableName == "Score")
        #expect(reparsed.nodes.first?.variableRefUUID == "typed-variable")
    }

    @Test func quaternionAndMatrixVariablesWriteCanonicalTruthDefaultObjects() throws {
        let cases: [(UInt64, UInt64, String)] = [
            (0xc0151474cbd67fcc, 0xa4d2f46b41c9d717, "tm_rotation"),
            (0x32e0e9614b5964e2, 0x571323c7ad582d5f, "tm_mat44_t"),
        ]
        for (index, item) in cases.enumerated() {
            let asset = try Self.variableNodesAsset()
            let variable = RCP3ScriptGraph.Variable(
                uuid: "typed-spatial-\(index)", name: "Spatial \(index)",
                typeHash: item.0, editHash: item.1, dataType: item.2
            )
            let node = RCP3ScriptGraph.Node(
                id: "get1", type: "tm_get_variable_node",
                variableName: variable.name, variableRefUUID: variable.uuid
            )
            let model = ScriptGraphEditorModel(graph: .init(
                nodes: [node], wires: [], data: [], variables: [variable]
            ))

            let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
            let root = try #require(try TM.parse(patched.tmText()).objectValue)
            let stored = try #require(
                root["graph"]?.objectValue?["variables"]?.arrayValue?.first?.objectValue
            )
            #expect(stored["type_hash"]?.stringValue == TMHash.hex(item.0))
            #expect(stored["edit_hash"]?.stringValue == TMHash.hex(item.1))
            #expect(stored["data"]?.objectValue?.type == item.2)
            #expect(stored["data"]?.objectValue?.uuid != nil)

            let reparsed = RCP3ScriptGraph(tmGraph: try #require(root["graph"]?.objectValue))
            #expect(reparsed.variables == [variable])
        }
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

    // MARK: - GAP 1: position float-precision no-drift round-trip

    /// Walk-up resolver for a standalone `.tm_script_graph` fixture by file name under
    /// `references/<bundle>/`. No-ops cleanly when the capture is absent. Note the SPACE
    /// in the `Random2` file name.
    static func standaloneGraphAsset(bundle: String, file: String) throws -> TMObject? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let path = dir.appending(path: "references/\(bundle)/\(file)")
            if FileManager.default.fileExists(atPath: path.path) {
                let text = try String(contentsOf: path, encoding: .utf8)
                return try #require(try TM.parse(text).objectValue)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Every node's `position.x`/`.y` `.number` lexeme of `graph`, keyed by node uuid —
    /// the EXACT on-disk text, not a re-parsed Double (the precision drift we guard).
    static func positionLexemes(of graph: TMObject) -> [String: (x: String?, y: String?)] {
        var out: [String: (x: String?, y: String?)] = [:]
        for value in graph["nodes"]?.arrayValue ?? [] {
            guard let node = value.objectValue, let id = node.uuid else { continue }
            let position = node["position"]?.objectValue
            out[id] = (position?["x"]?.numberLexeme, position?["y"]?.numberLexeme)
        }
        return out
    }

    /// Opening a real graph and writing it back with NO edits must NOT drift any node's
    /// position lexeme. RCP writes 17-sig-fig floats; the previous unconditional re-emit
    /// turned `-84.444442749023438` into the 16-sig-fig `-84.44444274902344` on every
    /// save. The compare-and-skip in `patchedNode` now preserves the original lexeme for
    /// every unmoved node, so a no-edit round-trip is byte-identical for positions.
    @Test func noEditRoundTripPreservesPositionLexemesRandom() throws {
        guard let asset = try Self.standaloneGraphAsset(
            bundle: "Random.realitycomposerpro", file: "Script Graph.tm_script_graph"
        ) else { return } // capture absent
        try assertNoEditRoundTripPreservesPositions(asset: asset)
    }

    @Test func noEditRoundTripPreservesPositionLexemesRandom2() throws {
        guard let asset = try Self.standaloneGraphAsset(
            bundle: "Random2.realitycomposerpro", file: "My Script Graph.tm_script_graph"
        ) else { return } // capture absent
        try assertNoEditRoundTripPreservesPositions(asset: asset)
    }

    /// Shared assertion: parse → build model (no edits) → write-back → re-parse, and the
    /// per-node `position.x`/`.y` lexemes are IDENTICAL to the original.
    private func assertNoEditRoundTripPreservesPositions(asset: TMObject) throws {
        let tmGraph = try #require(asset["graph"]?.objectValue)
        let original = Self.positionLexemes(of: tmGraph)
        #expect(!original.isEmpty)

        // No edits: the model is built straight from the parsed graph.
        let model = ScriptGraphEditorModel(graph: RCP3ScriptGraph(tmGraph: tmGraph))
        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let after = Self.positionLexemes(of: try #require(reparsed["graph"]?.objectValue))

        #expect(after.count == original.count)
        for (id, lexemes) in original {
            #expect(after[id]?.x == lexemes.x, "x lexeme drifted for node \(id)")
            #expect(after[id]?.y == lexemes.y, "y lexeme drifted for node \(id)")
        }
    }

    /// Sanity: the unconditional re-emit WOULD have drifted — proving the fixture
    /// actually exercises the precision gap (and isn't trivially clean). The original
    /// `Random` x lexeme `-84.444442749023438` is 17 sig-figs; `String(Double(...))`
    /// emits the shorter form, so they must differ (else the test would pass vacuously).
    @Test func positionLexemeDriftIsRealForFixture() throws {
        guard let asset = try Self.standaloneGraphAsset(
            bundle: "Random.realitycomposerpro", file: "Script Graph.tm_script_graph"
        ) else { return } // capture absent
        let tmGraph = try #require(asset["graph"]?.objectValue)
        let lexemes = Self.positionLexemes(of: tmGraph)
        // At least one node's x or y lexeme must NOT survive a Double round-trip,
        // otherwise the no-drift test would be vacuous.
        let drifts = lexemes.values.contains { entry in
            (entry.x.map { $0 != String(Double($0) ?? .nan) } ?? false)
                || (entry.y.map { $0 != String(Double($0) ?? .nan) } ?? false)
        }
        #expect(drifts, "fixture has no 17-sig-fig float — no-drift test would be vacuous")
    }

    /// A node that was actually MOVED still gets its new position written (the
    /// compare-and-skip only preserves UNCHANGED components). Built on the hand asset
    /// (whole-number positions) so the expectation is exact.
    @Test func movedNodeStillRewritesPosition() throws {
        let asset = try Self.handBuiltAsset()
        let model = try Self.model(for: asset)

        // Move n1 to a fractional position whose shortest-form lexeme is deterministic.
        model.moveNode("n1", to: CGPoint(x: 12.5, y: -7.25))
        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let graph = try #require(reparsed["graph"]?.objectValue)

        let n1 = try #require(
            graph["nodes"]?.arrayValue?.compactMap(\.objectValue).first { $0.uuid == "n1" }
        )
        let position = try #require(n1["position"]?.objectValue)
        #expect(position["x"]?.doubleValue == 12.5)
        #expect(position["y"]?.doubleValue == -7.25)
        #expect(position["x"]?.numberLexeme == "12.5")
        #expect(position["y"]?.numberLexeme == "-7.25")

        // n2 was NOT moved — its original integer lexemes survive untouched.
        let n2 = try #require(
            graph["nodes"]?.arrayValue?.compactMap(\.objectValue).first { $0.uuid == "n2" }
        )
        let n2pos = try #require(n2["position"]?.objectValue)
        #expect(n2pos["x"]?.numberLexeme == "300")
        #expect(n2pos["y"]?.numberLexeme == "40")
    }

    // MARK: - Instance-override graphs: faithful nodes/nodes__instantiated split

    /// A minimal instance-override graph root mirroring the `source.graph` embedded on
    /// an entity's `re_scripting_component`: a `nodes` array (instance-added nodes, each
    /// with a `type`) PLUS a `nodes__instantiated` array (prototype-node instances, each
    /// with a `__prototype_uuid` and NO `type`). This is the shape `patched()` must split
    /// back faithfully (never flatten).
    static func instanceOverrideAsset() throws -> TMObject {
        let text = """
        __type: "re_scripting_source_graph"
        __uuid: "root-uuid"
        graph: {
        \t__uuid: "graph-uuid"
        \tnodes: [
        \t\t{
        \t\t\t__uuid: "added1"
        \t\t\ttype: "tm_set_component"
        \t\t\tposition: { __uuid: "pa1" x: 5 y: 10 }
        \t\t}
        \t]
        \tnodes__instantiated: [
        \t\t{
        \t\t\t__uuid: "inst1"
        \t\t\t__prototype_type: "tm_graph_node"
        \t\t\t__prototype_uuid: "proto1"
        \t\t\tposition: { __uuid: "pi1" __prototype_uuid: "pproto1" x: -246.33290100097656 y: -190.22328186035156 }
        \t\t}
        \t\t{
        \t\t\t__uuid: "inst2"
        \t\t\t__prototype_type: "tm_graph_node"
        \t\t\t__prototype_uuid: "proto2"
        \t\t\tposition: { __uuid: "pi2" __prototype_uuid: "pproto2" }
        \t\t}
        \t]
        \tconnections: []
        \tdata: []
        }
        __asset_uuid: "asset-uuid"
        """
        return try #require(try TM.parse(text).objectValue)
    }

    /// Patching an instance-override graph (one with `nodes__instantiated`) splits the
    /// flat model node list back into the two on-disk arrays by provenance — never
    /// flattening: no uuid appears in BOTH arrays, the instances keep their
    /// `__prototype_uuid` (no synthesized `type`), and a MOVED instance's new position
    /// actually persists into its `nodes__instantiated` entry.
    @Test func patchingInstanceOverrideGraphSplitsByProvenance() throws {
        let asset = try Self.instanceOverrideAsset()
        let tmGraph = try #require(asset["graph"]?.objectValue)

        // The parser merges nodes + nodes__instantiated into the model's flat list and
        // tags each box's provenance.
        let graph = RCP3ScriptGraph(tmGraph: tmGraph)
        let model = ScriptGraphEditorModel(graph: graph)
        #expect(Set(model.nodes.map(\.id)) == ["added1", "inst1", "inst2"])
        // Provenance is carried: the two instances point at their prototype nodes.
        #expect(graph.nodes.first { $0.id == "inst1" }?.instanceOf == "proto1")
        #expect(graph.nodes.first { $0.id == "inst2" }?.instanceOf == "proto2")
        #expect(graph.nodes.first { $0.id == "added1" }?.instanceOf == nil)

        // Move an instance — its new position must land in `nodes__instantiated`.
        model.moveNode("inst1", to: CGPoint(x: 999, y: 888))

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let patchedGraph = try #require(reparsed["graph"]?.objectValue)

        let nodes = (patchedGraph["nodes"]?.arrayValue ?? []).compactMap(\.objectValue)
        let instantiated = (patchedGraph["nodes__instantiated"]?.arrayValue ?? []).compactMap(\.objectValue)

        // The arrays are split by provenance: authored node in `nodes`, instances in
        // `nodes__instantiated` — not flattened together.
        #expect(Set(nodes.compactMap(\.uuid)) == ["added1"])
        #expect(Set(instantiated.compactMap(\.uuid)) == ["inst1", "inst2"])
        // Each instantiated node keeps its `__prototype_uuid` (not flattened away) + no type.
        #expect(instantiated.allSatisfy { $0.prototypeUUID != nil })
        #expect(instantiated.allSatisfy { $0["type"] == nil })
        // No cross-array duplication; every uuid unique across both arrays.
        let allUUIDs = nodes.compactMap(\.uuid) + instantiated.compactMap(\.uuid)
        #expect(allUUIDs.count == Set(allUUIDs).count, "duplicate node uuid across arrays")

        // The MOVE persisted into inst1's instantiated entry (identity preserved).
        let inst1 = try #require(instantiated.first { $0.uuid == "inst1" })
        #expect(inst1.prototypeUUID == "proto1")
        let inst1pos = try #require(inst1["position"]?.objectValue)
        #expect(inst1pos["x"]?.doubleValue == 999)
        #expect(inst1pos["y"]?.doubleValue == 888)
        #expect(inst1pos.uuid == "pi1") // position object identity preserved

        // inst2 (an inherited, coordinate-less position) was NOT moved → it stays
        // coordinate-less (we don't fabricate a 0/0 override the fixture never showed).
        let inst2 = try #require(instantiated.first { $0.uuid == "inst2" })
        let inst2pos = try #require(inst2["position"]?.objectValue)
        #expect(inst2pos["x"] == nil)
        #expect(inst2pos["y"] == nil)
        #expect(inst2pos.prototypeUUID == "pproto2") // inherited identity preserved
    }

    /// A NO-EDIT round-trip of the hand-built instance-override graph reproduces both
    /// arrays structurally (uuids, prototype refs, the authored node's type) and keeps
    /// the high-precision instance position lexeme byte-identical.
    @Test func noEditRoundTripOfInstanceOverrideReproducesBothArrays() throws {
        let asset = try Self.instanceOverrideAsset()
        let tmGraph = try #require(asset["graph"]?.objectValue)
        let model = ScriptGraphEditorModel(graph: RCP3ScriptGraph(tmGraph: tmGraph))

        let patched = ScriptGraphWriteBack.patched(asset: asset, with: model)
        let reparsed = try #require(try TM.parse(patched.tmText()).objectValue)
        let patchedGraph = try #require(reparsed["graph"]?.objectValue)

        let nodes = (patchedGraph["nodes"]?.arrayValue ?? []).compactMap(\.objectValue)
        let instantiated = (patchedGraph["nodes__instantiated"]?.arrayValue ?? []).compactMap(\.objectValue)

        // Authored node reproduced with its type + label-less shape.
        let added1 = try #require(nodes.first { $0.uuid == "added1" })
        #expect(added1["type"]?.stringValue == "tm_set_component")
        // Instances reproduced with prototype refs, no type.
        #expect(Set(instantiated.compactMap(\.uuid)) == ["inst1", "inst2"])
        #expect(instantiated.first { $0.uuid == "inst1" }?.prototypeUUID == "proto1")
        #expect(instantiated.first { $0.uuid == "inst1" }?.prototypeType == "tm_graph_node")

        // The 17-sig-fig instance position lexeme survives byte-identical (no drift).
        let inst1pos = try #require(instantiated.first { $0.uuid == "inst1" }?["position"]?.objectValue)
        #expect(inst1pos["x"]?.numberLexeme == "-246.33290100097656")
        #expect(inst1pos["y"]?.numberLexeme == "-190.22328186035156")
    }

    // MARK: - THE PROOF: round-trip the real entity-attached graph (Random capture)

    /// The parsed root `world.tm_entity` of the `Random` capture, if present. Captures
    /// live outside the OSS package (`../../references/`), so these tests no-op cleanly
    /// when the capture is absent.
    static func randomRoot() throws -> TMObject? {
        guard let url = randomBundleURL else { return nil }
        let text = try String(contentsOf: url.appending(path: "world.tm_entity"), encoding: .utf8)
        return try #require(try TM.parse(text).objectValue)
    }

    /// The box entity's `re_scripting_component.source.graph` object inside `root`.
    static func boxSourceGraph(in root: TMObject) throws -> TMObject {
        let box = try #require(ScriptGraphWriteBack.findEntity(id: "box", in: root))
        let component = try #require(
            (box["components"]?.arrayValue ?? []).compactMap(\.objectValue)
                .first { ($0.type ?? $0.prototypeType) == "re_scripting_component" }
        )
        let source = try #require(component["source"]?.objectValue)
        return try #require(source["graph"]?.objectValue)
    }

    /// A `[nodeUUID: __prototype_uuid]` map over a `nodes__instantiated` array.
    static func instantiatedPrototypeRefs(_ graph: TMObject) -> [String: String?] {
        var out: [String: String?] = [:]
        for value in graph["nodes__instantiated"]?.arrayValue ?? [] {
            guard let node = value.objectValue, let id = node.uuid else { continue }
            out[id] = node.prototypeUUID
        }
        return out
    }

    /// THE PROOF — resolve the box entity's instance-override graph, write it back with
    /// NO semantic edits, and assert the re-serialized `world.tm_entity` reproduces the
    /// original's `re_scripting_component.source.graph` STRUCTURALLY: the same `nodes` +
    /// `nodes__instantiated` uuids/types/prototype-refs (no duplication/flattening), and
    /// the connections + data intact.
    @Test func entityOverrideNoEditRoundTripReproducesSourceGraphStructurally() throws {
        guard let root = try Self.randomRoot() else { return } // capture absent
        let original = try Self.boxSourceGraph(in: root)

        // Resolve the box's MERGED instance-override graph the way the loader does, so the
        // model carries the nodes/nodes__instantiated provenance.
        guard let url = Self.randomBundleURL else { return }
        let bundle = try RCP3Bundle.open(url)
        let graph = try #require(bundle.scriptGraph(forEntityID: "box"))
        #expect(graph.nodes.count == 6) // 4 authored + 2 instantiated
        let model = ScriptGraphEditorModel(graph: graph)

        // Write back with NO edits, targeting the box entity in the tree.
        let patchedRoot = try #require(
            ScriptGraphWriteBack.patchedRoot(root, entityID: "box", with: model)
        )
        // Re-serialize + re-parse the whole entity file, then read the box's source graph.
        let reparsedRoot = try #require(try TM.parse(patchedRoot.tmText()).objectValue)
        let after = try Self.boxSourceGraph(in: reparsedRoot)

        // `nodes`: same set of uuids + types (4 authored nodes, none flattened).
        let originalAuthored = (original["nodes"]?.arrayValue ?? []).compactMap(\.objectValue)
        let afterAuthored = (after["nodes"]?.arrayValue ?? []).compactMap(\.objectValue)
        #expect(Set(afterAuthored.compactMap(\.uuid)) == Set(originalAuthored.compactMap(\.uuid)))
        func typesByID(_ objects: [TMObject]) -> [String: String?] {
            Dictionary(uniqueKeysWithValues: objects.compactMap { o in o.uuid.map { ($0, o["type"]?.stringValue) } })
        }
        #expect(typesByID(afterAuthored) == typesByID(originalAuthored))
        // The 4 authored uuids are exactly the fixture's instance additions.
        #expect(Set(afterAuthored.compactMap(\.uuid)) == [
            "fc35fd00-122d-1f7e-b99f-5c56bb4ca58e", // tm_set_component "Set Accessibility"
            "506454b0-3315-e6c2-4864-3c67a0769062", // tm_get_component
            "4fa769df-e410-ad6f-3308-779bbbcae264", // tm_entity_look_at
            "74f66281-a4ab-7b14-fe9c-3f643ced6ff1", // tm_did_add
        ])

        // `nodes__instantiated`: same uuids + same `__prototype_uuid` refs, NO `type`.
        #expect(Self.instantiatedPrototypeRefs(after) == Self.instantiatedPrototypeRefs(original))
        let afterInstantiated = (after["nodes__instantiated"]?.arrayValue ?? []).compactMap(\.objectValue)
        #expect(afterInstantiated.allSatisfy { $0["type"] == nil })
        #expect(afterInstantiated.allSatisfy { $0.prototypeType == "tm_graph_node" })
        #expect(Set(afterInstantiated.compactMap(\.prototypeUUID)) == [
            "9a09b843-d3dd-8754-4167-4ed28d962bd4",
            "ab95034e-fc77-a6c1-d60a-a7184c7e90d4",
        ])

        // No duplication/flattening: no uuid in both arrays; all node uuids unique.
        let allNodeUUIDs = afterAuthored.compactMap(\.uuid) + afterInstantiated.compactMap(\.uuid)
        #expect(allNodeUUIDs.count == Set(allNodeUUIDs).count)
        #expect(Set(afterAuthored.compactMap(\.uuid)).isDisjoint(with: Set(afterInstantiated.compactMap(\.uuid))))

        // Connections intact: same set of `__uuid`s + from/to endpoints.
        func conns(_ g: TMObject) -> Set<String> {
            Set((g["connections"]?.arrayValue ?? []).compactMap(\.objectValue).compactMap { c in
                guard let id = c.uuid, let from = c["from_node"]?.stringValue, let to = c["to_node"]?.stringValue
                else { return nil }
                return "\(id)|\(from)->\(to)"
            })
        }
        #expect(conns(after) == conns(original))

        // Data intact: the `component_type` literal survives (uuid + bound pin + value hash).
        let originalData = (original["data"]?.arrayValue ?? []).compactMap(\.objectValue)
        let afterData = (after["data"]?.arrayValue ?? []).compactMap(\.objectValue)
        #expect(afterData.count == originalData.count)
        let originalLiteral = try #require(originalData.first)
        let afterLiteral = try #require(afterData.first { $0.uuid == originalLiteral.uuid })
        #expect(afterLiteral["to_node"]?.stringValue == originalLiteral["to_node"]?.stringValue)
        #expect(afterLiteral["to_connector_hash"]?.stringValue == originalLiteral["to_connector_hash"]?.stringValue)
        #expect(afterLiteral["data"]?.objectValue?.type == "re_scripting_graph_component_type")
        #expect(afterLiteral["data"]?.objectValue?["type"]?.stringValue
            == originalLiteral["data"]?.objectValue?["type"]?.stringValue)

        // The source identity + sibling `interface` / `validation_settings` are preserved.
        #expect(after.uuid == original.uuid)
        #expect(after.prototypeUUID == original.prototypeUUID) // graph's own __prototype_uuid
        #expect(after["interface"]?.objectValue?.uuid == original["interface"]?.objectValue?.uuid)

        // Position lexemes of every node (both arrays) are byte-identical (no drift).
        func positionLexemes(_ g: TMObject) -> [String: (x: String?, y: String?)] {
            var out: [String: (String?, String?)] = [:]
            for key in ["nodes", "nodes__instantiated"] {
                for value in g[key]?.arrayValue ?? [] {
                    guard let node = value.objectValue, let id = node.uuid else { continue }
                    let p = node["position"]?.objectValue
                    out[id] = (p?["x"]?.numberLexeme, p?["y"]?.numberLexeme)
                }
            }
            return out
        }
        let beforePos = positionLexemes(original)
        let afterPos = positionLexemes(after)
        for (id, lex) in beforePos {
            #expect(afterPos[id]?.x == lex.x, "x lexeme drifted for node \(id)")
            #expect(afterPos[id]?.y == lex.y, "y lexeme drifted for node \(id)")
        }
    }

    /// An ACTUAL edit to the entity-attached graph persists and re-reads: move an
    /// authored node + an instantiated node, set a scalar literal — write back into the
    /// entity tree — and a fresh load of the patched root reflects all three.
    @Test func entityOverrideEditPersistsAndReReads() throws {
        guard let root = try Self.randomRoot() else { return } // capture absent
        guard let url = Self.randomBundleURL else { return }
        let bundle = try RCP3Bundle.open(url)
        let graph = try #require(bundle.scriptGraph(forEntityID: "box"))
        let model = ScriptGraphEditorModel(graph: graph)

        // Move an AUTHORED node (tm_did_add) and an INSTANTIATED node (the drag node).
        let authoredID = "74f66281-a4ab-7b14-fe9c-3f643ced6ff1"   // tm_did_add (in `nodes`)
        let instantiatedID = "ba3614d0-9e16-c46a-d324-a8284e2026d7" // drag (in `nodes__instantiated`)
        model.moveNode(authoredID, to: CGPoint(x: 111, y: 222))
        model.moveNode(instantiatedID, to: CGPoint(x: 333, y: 444))

        // Author a scalar literal on the look_at node's `x` pin (an unwired numeric pin).
        let lookAtID = "4fa769df-e410-ad6f-3308-779bbbcae264"
        let xPin = TMHash.murmur64a("x")
        model.setLiteral(nodeID: lookAtID, pinConnectorHash: xPin, value: 9.5)

        // Write back into the box entity in the tree, re-serialize, re-parse, re-load.
        let patchedRoot = try #require(
            ScriptGraphWriteBack.patchedRoot(root, entityID: "box", with: model)
        )
        let reparsedRoot = try #require(try TM.parse(patchedRoot.tmText()).objectValue)
        let after = try Self.boxSourceGraph(in: reparsedRoot)

        // Authored move persisted in `nodes`.
        let authoredNode = try #require(
            (after["nodes"]?.arrayValue ?? []).compactMap(\.objectValue).first { $0.uuid == authoredID }
        )
        #expect(authoredNode["position"]?.objectValue?["x"]?.doubleValue == 111)
        #expect(authoredNode["position"]?.objectValue?["y"]?.doubleValue == 222)

        // Instantiated move persisted in `nodes__instantiated` (prototype ref intact).
        let instNode = try #require(
            (after["nodes__instantiated"]?.arrayValue ?? []).compactMap(\.objectValue).first { $0.uuid == instantiatedID }
        )
        #expect(instNode["position"]?.objectValue?["x"]?.doubleValue == 333)
        #expect(instNode["position"]?.objectValue?["y"]?.doubleValue == 444)
        #expect(instNode.prototypeUUID == "9a09b843-d3dd-8754-4167-4ed28d962bd4")
        #expect(instNode["type"] == nil)

        // The scalar literal persisted into data[] and re-reads (a fresh display parse).
        let afterGraph = RCP3ScriptGraph(tmGraph: after)
        #expect(afterGraph.scalarLiteral(node: lookAtID, pin: xPin) == 9.5)

        // The structure is still intact: 4 authored + 2 instantiated, no flattening.
        #expect((after["nodes"]?.arrayValue ?? []).count == 4)
        #expect((after["nodes__instantiated"]?.arrayValue ?? []).count == 2)

        // The full editor reload sees the moved authored node at its new position.
        let reloaded = ScriptGraphEditorModel(graph: afterGraph)
        #expect(reloaded.node(authoredID)?.position == CGPoint(x: 111, y: 222))
        #expect(reloaded.node(instantiatedID)?.position == CGPoint(x: 333, y: 444))
        #expect(reloaded.node(instantiatedID)?.instanceOf == "9a09b843-d3dd-8754-4167-4ed28d962bd4")
    }

    /// The full file-write entry point round-trips: `write(model:toEntityWithID:rootFileURL:)`
    /// writes into a COPY of the capture's `world.tm_entity` and a re-open reflects the edit
    /// (the source capture is never mutated). No-ops when the capture is absent.
    @Test func entityOverrideFileWriteRoundTrips() throws {
        guard let url = Self.randomBundleURL else { return } // capture absent

        // Copy the whole bundle to a temp dir so we never mutate the reference capture.
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "wb-entity-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.copyItem(at: url, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let bundle = try RCP3Bundle.open(tmp)
        let graph = try #require(bundle.scriptGraph(forEntityID: "box"))
        let model = ScriptGraphEditorModel(graph: graph)
        let authoredID = "74f66281-a4ab-7b14-fe9c-3f643ced6ff1"
        model.moveNode(authoredID, to: CGPoint(x: 1357, y: 2468))

        try ScriptGraphWriteBack.write(model: model, toEntityWithID: "box", rootFileURL: bundle.rootURL)

        // Re-open the (now-edited) copy and confirm the move landed + structure intact.
        let reopened = try RCP3Bundle.open(tmp)
        let reloaded = try #require(reopened.scriptGraph(forEntityID: "box"))
        #expect(reloaded.nodes.count == 6)
        let moved = try #require(reloaded.nodes.first { $0.id == authoredID })
        #expect(moved.x == 1357)
        #expect(moved.y == 2468)
    }

    /// Writing to a non-existent entity throws `entityGraphNotFound`.
    @Test func entityWriteThrowsWhenEntityAbsent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "wb-entity-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A root entity file with no scripting component anywhere.
        let rootURL = tmp.appending(path: "world.tm_entity")
        try """
        __type: "tm_entity"
        __uuid: "world-uuid"
        name: "world"
        """.write(to: rootURL, atomically: true, encoding: .utf8)

        let model = try Self.model(for: Self.handBuiltAsset())
        #expect(throws: ScriptGraphWriteBack.WriteError.entityGraphNotFound(entityID: "nope")) {
            try ScriptGraphWriteBack.write(model: model, toEntityWithID: "nope", rootFileURL: rootURL)
        }
    }

    // MARK: Materialize a sample into a real asset

    /// Creating an empty Script Graph asset and writing a sample graph's nodes into it
    /// yields a real, reopenable `.tm_script_graph` document carrying those nodes — the
    /// "+ → sample" Project Browser action (so a scripting component can point at it).
    @Test func materializeSampleGraphCreatesReopenableAsset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-sample-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appending(path: "project.rcp").path, contents: Data())
        try "__type: \"tm_entity\"\n__uuid: \"w\"\nname: \"world\""
            .write(to: dir.appending(path: "world.tm_entity"), atomically: true, encoding: .utf8)
        let bundle = try RCP3Bundle.open(dir)

        // 1. Create the empty asset, 2. write a sample graph's nodes into it.
        let asset = try bundle.createScriptGraphAsset(named: "Spin")
        let update = RCP3ScriptGraph.Node(id: "a", type: "tm_update")
        let set = RCP3ScriptGraph.Node(id: "b", type: "tm_set_component", label: "Set")
        let exec = RCP3ScriptGraph.Wire(id: "w", from: "a", to: "b")
        let model = ScriptGraphEditorModel(graph: RCP3ScriptGraph(nodes: [update, set], wires: [exec], data: []))
        try ScriptGraphWriteBack.write(model: model, toAssetWithRootUUID: asset.id, in: bundle.url)

        // Reopen: the document is enumerable and carries the sample's nodes.
        let reopened = try RCP3Bundle.open(dir)
        #expect(reopened.scriptGraphAssets().contains { $0.id == asset.id && $0.name == "Spin" })
        let loaded = try #require(reopened.scriptGraph(assetID: asset.id))
        #expect(loaded.nodes.count == 2)
        #expect(loaded.nodes.contains { $0.type == "tm_update" })
    }

    @Test func completeExampleCorpusMaterializesAndReopens() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-corpus-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appending(path: "project.rcp").path, contents: Data())
        try "__type: \"tm_entity\"\n__uuid: \"w\"\nname: \"world\""
            .write(to: dir.appending(path: "world.tm_entity"), atomically: true, encoding: .utf8)
        let bundle = try RCP3Bundle.open(dir)

        var expectedByAssetID: [String: ScriptGraphExample] = [:]
        for example in ScriptGraphExamples.all {
            let asset = try bundle.createScriptGraphAsset(named: example.name)
            try ScriptGraphWriteBack.write(
                model: ScriptGraphEditorModel(graph: example.graph),
                toAssetWithRootUUID: asset.id,
                in: bundle.url
            )
            expectedByAssetID[asset.id] = example
        }

        let reopened = try RCP3Bundle.open(dir)
        let assets = reopened.scriptGraphAssets()
        #expect(assets.count == ScriptGraphExamples.all.count)
        for asset in assets {
            let example = try #require(expectedByAssetID[asset.id])
            let graph = try #require(reopened.scriptGraph(assetID: asset.id))
            assertStructurallyEqual(graph, to: example.graph, corpus: example.name)
        }
    }

    /// Headless certification of the serialization templates which interaction
    /// examples do not cover. Each graph completes two parse/write cycles; this
    /// catches settings that survive insertion but disappear when a node is patched.
    @Test func representativeAuthoringFamiliesSurviveTwoStructuralCycles() throws {
        let stringType = TMHash.murmur64a("String")
        let floatType = TMHash.murmur64a("Float")
        let dynamic = RCP3ScriptGraph.Node.DynamicConnectorSettings(
            container: .direct,
            inputs: [
                .init(name: "first", displayName: "First", typeHash: stringType, order: 0),
                .init(name: "second", displayName: "Second", typeHash: stringType, order: 1, optionality: 2),
            ],
            outputs: [.init(name: "result", displayName: "Result", typeHash: stringType, order: 0)]
        )
        let material = RCP3ScriptGraph.Node.MaterialSettings(
            typeHash: TMHash.murmur64a("PhysicallyBasedMaterial"),
            objectIdentifier: "RealityKit.PhysicallyBasedMaterial",
            inputs: [.init(name: "roughness", typeHash: floatType, editTypeHash: floatType, isOptional: false)],
            outputs: [.init(name: "baseColor", typeHash: TMHash.murmur64a("MaterialColorParameter"), editTypeHash: 0, isOptional: true)]
        )
        let families: [(String, RCP3ScriptGraph)] = [
            ("Fixed", .init(nodes: [.init(id: "update", type: "tm_update"), .init(id: "delay", type: "tm_delay", label: "Wait")], wires: [.init(id: "flow", from: "update", to: "delay")], data: [])),
            ("Dynamic", .init(nodes: [.init(id: "concat", type: "tm_string_concatenate", dynamicConnectorSettings: dynamic)], wires: [], data: [])),
            ("EnumSchema", .init(nodes: [.init(id: "enum", type: "tm_make_triangle_fill_mode", enumSelection: .init(typeHash: TMHash.murmur64a("TriangleFillMode"), caseName: "lines", associatedValues: [.init(index: 0, typeHash: floatType)]))], wires: [], data: [])),
            ("ScopedControlFlow", .init(nodes: [.init(id: "start", type: "tm_update"), .init(id: "loop", type: "tm_for_loop"), .init(id: "body", type: "tm_set_component")], wires: [.init(id: "to-loop", from: "start", to: "loop"), .init(id: "loop-body", from: "loop", to: "body")], data: [])),
            ("InspectableMaterial", .init(nodes: [.init(id: "material", type: "tm_modify_any_material", materialSettings: material)], wires: [], data: [])),
            // NodeLib registration supplies a static interface. The serialized
            // graph stores only the derived node identity, never fabricated
            // dynamic-connector settings.
            ("ImportedNodeLib", .init(nodes: [.init(id: "custom", type: "node_17854906811712824314", label: "NodeLib fixture")], wires: [], data: [])),
        ]

        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-template-corpus-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appending(path: "project.rcp").path, contents: Data())
        try "__type: \"tm_entity\"\n__uuid: \"w\"\nname: \"world\""
            .write(to: dir.appending(path: "world.tm_entity"), atomically: true, encoding: .utf8)
        let bundle = try RCP3Bundle.open(dir)

        for (name, source) in families {
            // Fresh inserted nodes are assigned the writer's canonical origin.
            let canonicalSource = RCP3ScriptGraph(
                id: source.id,
                nodes: source.nodes.map { node in
                    .init(
                        id: node.id, type: node.type, label: node.label,
                        x: node.x ?? 0, y: node.y ?? 0,
                        variableName: node.variableName, variableRefUUID: node.variableRefUUID,
                        instanceOf: node.instanceOf, enumSelection: node.enumSelection,
                        dynamicConnectorSettings: node.dynamicConnectorSettings,
                        materialSettings: node.materialSettings
                    )
                },
                wires: source.wires, data: source.data, variables: source.variables
            )
            let asset = try bundle.createScriptGraphAsset(named: name)
            try ScriptGraphWriteBack.write(model: ScriptGraphEditorModel(graph: source), toAssetWithRootUUID: asset.id, in: bundle.url)
            let firstBundle = try RCP3Bundle.open(dir)
            let first = try #require(firstBundle.scriptGraph(assetID: asset.id))
            assertStructurallyEqual(first, to: canonicalSource, corpus: "\(name)/materialize", comparePositions: false)

            try ScriptGraphWriteBack.write(model: ScriptGraphEditorModel(graph: first), toAssetWithRootUUID: asset.id, in: firstBundle.url)
            let second = try #require(RCP3Bundle.open(dir).scriptGraph(assetID: asset.id))
            assertStructurallyEqual(second, to: first, corpus: "\(name)/rewrite")
        }
    }

    /// The automated half of the certification procedure's "reopen intact" gate:
    /// a reopened materialized graph must carry the SAME structure as its source —
    /// every node (type, label, position), every wire's connectivity including pin
    /// hashes, every authored data literal's value, and the variable table.
    private func assertStructurallyEqual(
        _ reopened: RCP3ScriptGraph,
        to source: RCP3ScriptGraph,
        corpus name: String,
        comparePositions: Bool = true
    ) {
        let sourceNodes = Dictionary(uniqueKeysWithValues: source.nodes.map { ($0.id, $0) })
        let reopenedNodes = Dictionary(uniqueKeysWithValues: reopened.nodes.map { ($0.id, $0) })
        #expect(Set(reopenedNodes.keys) == Set(sourceNodes.keys), "\(name): node identities")
        for (id, expected) in sourceNodes {
            guard let actual = reopenedNodes[id] else { continue }
            #expect(actual.type == expected.type, "\(name)/\(id): type")
            #expect(actual.label == expected.label, "\(name)/\(id): label")
            if comparePositions {
                #expect(actual.x == expected.x && actual.y == expected.y, "\(name)/\(id): position")
            }
            #expect(actual.variableName == expected.variableName, "\(name)/\(id): variableName")
            #expect(
                actual.variableRefUUID == expected.variableRefUUID,
                "\(name)/\(id): variableRefUUID"
            )
            #expect(actual.enumSelection == expected.enumSelection, "\(name)/\(id): enum settings")
            #expect(actual.dynamicConnectorSettings == expected.dynamicConnectorSettings, "\(name)/\(id): dynamic settings")
            #expect(actual.materialSettings == expected.materialSettings, "\(name)/\(id): material settings")
        }

        // Wire and literal identities are serialization details; connectivity and
        // authored values are the structure that must survive.
        struct Connection: Hashable {
            let from: String
            let to: String
            let fromPin: UInt64?
            let toPin: UInt64?
        }
        let sourceWires = Set(source.wires.map {
            Connection(from: $0.from, to: $0.to, fromPin: $0.fromPin, toPin: $0.toPin)
        })
        let reopenedWires = Set(reopened.wires.map {
            Connection(from: $0.from, to: $0.to, fromPin: $0.fromPin, toPin: $0.toPin)
        })
        #expect(reopenedWires == sourceWires, "\(name): wire connectivity")

        struct Literal: Hashable {
            let toNode: String
            let toPin: UInt64
            let valueType: String?
            let valueHash: UInt64?
            let value: TMGraphValue?
        }
        let sourceLiterals = Set(source.data.map {
            Literal(toNode: $0.toNode, toPin: $0.toPin, valueType: $0.valueType, valueHash: $0.valueHash, value: $0.value)
        })
        let reopenedLiterals = Set(reopened.data.map {
            Literal(toNode: $0.toNode, toPin: $0.toPin, valueType: $0.valueType, valueHash: $0.valueHash, value: $0.value)
        })
        #expect(reopenedLiterals == sourceLiterals, "\(name): data literals")

        let sourceVariables = Set(source.variables.map { "\($0.uuid)|\($0.name)" })
        let reopenedVariables = Set(reopened.variables.map { "\($0.uuid)|\($0.name)" })
        #expect(reopenedVariables == sourceVariables, "\(name): variable table")
    }
}
