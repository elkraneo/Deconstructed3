import Foundation
import RCP3Document
import TMFormat

/// The **write-back** half of the script-graph editor: it takes the editor's live
/// `ScriptGraphEditorModel` and folds its edits (node moves, inserts, deletes, and
/// rewired connections) back into the original `.tm_script_graph` asset object —
/// then persists that to disk.
///
/// The editor models only *part* of the asset: nodes (id, position, type, label)
/// and connections (exec / data wires). It does **not** model data literals, the
/// `interface`, `validation_settings`, the many `__uuid`s, or `__asset_uuid`. So
/// write-back is deliberately **surgical**: it starts from the *parsed original
/// object* and updates only `graph.nodes` and `graph.connections` in place,
/// preserving every other member byte-for-byte (semantically). That is the
/// data-preservation guarantee — opening a real RCP graph, moving one node, and
/// saving must not drop the `component_type` literal, the bound `interface`, or the
/// validation path.
///
/// This type is renderer-agnostic and UI-free: it is the testable serialization
/// core. `patched(asset:with:)` is the pure transform (parse-in → object-out);
/// `write(model:toAssetWithRootUUID:in:)` resolves the file by root uuid and
/// commits the patch.
public enum ScriptGraphWriteBack {
    // MARK: - Pure transform (the testable core)

    /// Returns a **copy** of `asset` (a parsed `re_scripting_source_graph` root
    /// object) with `graph.nodes` and `graph.connections` rebuilt from `model`,
    /// while preserving everything the editor does not model: `graph.data`,
    /// `graph.interface`, `validation_settings`, all `__uuid`s, and `__asset_uuid`.
    ///
    /// **Nodes.** For each model node, the matching node object (`__uuid == id`) is
    /// updated in place — its `position.x` / `position.y` follow `box.position`, its
    /// `label` follows the payload (added/removed/changed), and any other members it
    /// carries (`settings`, the position's own `__uuid`, …) are left untouched. A
    /// model node with no matching object is an *insert*: a fresh node object
    /// `{ __uuid, type, label?, position: { x, y } }` is appended in model order.
    /// Node objects whose `__uuid` is absent from the model are *deletes* and are
    /// dropped.
    ///
    /// **Connections.** `graph.connections` is rebuilt wholesale from
    /// `model.connections`: each becomes `{ __uuid, from_node, to_node }`, plus
    /// `from_connector_hash` / `to_connector_hash` for a data wire (the hex after the
    /// dot of `out.<hex>` / `in.<hex>`). Exec wires omit the hashes.
    ///
    /// **Data.** `graph.data` is preserved as-is, except: literals bound to a deleted
    /// node (`to_node` no longer present) are dropped, since they can no longer apply;
    /// and the model's authored **scalar** literals (``ScriptGraphEditorModel/scalarLiterals``)
    /// are folded in — an existing scalar literal on a `(to_node, to_connector_hash)`
    /// is updated in place (its value object's `value` member rewritten, identity +
    /// other members preserved), one with no authored value is dropped, and a newly
    /// authored pin is appended as a fresh `{ to_node, to_connector_hash, data: { value } }`.
    /// Non-scalar literals (e.g. the `component_type`) are untouched.
    @MainActor
    public static func patched(asset: TMObject, with model: ScriptGraphEditorModel) -> TMObject {
        guard var graph = asset["graph"]?.objectValue else { return asset }

        // INSTANCE-OVERRIDE shape (the `source.graph` embedded on an entity's
        // `re_scripting_component`): it splits its node list into `nodes` (ADDED on the
        // instance, each with its own `type`) and `nodes__instantiated` (instances of
        // PROTOTYPE nodes, each carrying a `__prototype_uuid` + position override and NO
        // `type`). The parser MERGES both arrays into the model's flat node list and tags
        // each box with its provenance (``GraphNodeBox/instanceOf`` = the prototype uuid,
        // `nil` for an authored node). Write-back must restore that split — never flatten
        // the instances into `nodes` (that duplicates uuids across both arrays into a graph
        // RCP3 won't reopen, the corruption the old GAP-2 guard refused to risk). Routed to
        // a dedicated path that re-emits the two arrays faithfully.
        if graph["nodes__instantiated"] != nil {
            return patchedEntityOverride(asset: asset, graph: graph, with: model)
        }

        let existingNodes = graph["nodes"]?.arrayValue ?? []
        let liveIDs = Set(model.nodes.map(\.id))

        // Index the original node objects by __uuid so inserts/moves can find them.
        var objectByID: [String: TMObject] = [:]
        for value in existingNodes {
            guard let object = value.objectValue, let id = object.uuid else { continue }
            objectByID[id] = object
        }

        // Rebuild `nodes` in model order (so inserts land at the end, deletes drop).
        var newNodes: [TMValue] = []
        for box in model.nodes {
            let updated = patchedNode(existing: objectByID[box.id], box: box)
            newNodes.append(.object(updated))
        }
        graph.set(.array(newNodes), forKey: "nodes")

        // Rebuild `connections` wholesale from the model.
        let newConnections = model.connections.map { TMValue.object(connectionObject(for: $0)) }
        graph.set(.array(newConnections), forKey: "connections")

        // Preserve `data`, dropping literals whose target node was deleted, then fold
        // in the model's authored scalar literals + variable references (update/drop/append).
        let existingData = graph["data"]?.arrayValue ?? []
        graph.set(.array(patchedData(existingData, model: model, liveIDs: liveIDs)), forKey: "data")

        // Rebuild the `variables:` table from the model — preserving each declared
        // variable's `__uuid`. A graph that never had variables (empty table) writes no
        // `variables:` member (don't regress existing fixtures).
        let existingVariables = graph["variables"]?.arrayValue ?? []
        if let variablesArray = patchedVariables(existingVariables, model: model) {
            graph.set(.array(variablesArray), forKey: "variables")
        } else {
            graph.remove(key: "variables")
        }

        return asset.setting(.object(graph), forKey: "graph")
    }

    // MARK: - Instance-override (entity-attached) write-back

    /// Write-back for the PROTOTYPE-INSTANCE shape — the `source.graph` embedded on an
    /// entity's `re_scripting_component`. It splits the model's flat node list back into
    /// the on-disk `nodes` / `nodes__instantiated` arrays by per-node provenance
    /// (``GraphNodeBox/instanceOf``), then rebuilds `connections` + `data` + `variables`
    /// exactly as the standalone path does — preserving every `__uuid` and the parts the
    /// editor doesn't model (`interface`, the graph's own `__prototype_*`, …) in place.
    ///
    /// The two node arrays:
    /// - **`nodes`** — boxes with `instanceOf == nil`: nodes ADDED on the instance (and any
    ///   freshly authored in the editor). Emitted as a full node object — `type`, `label?`,
    ///   `position { x, y }` — reusing/updating the original object when one matches the
    ///   uuid (so unmodeled members + the position's own `__uuid` survive). This is the
    ///   ``patchedNode(existing:box:)`` the standalone path uses.
    /// - **`nodes__instantiated`** — boxes with `instanceOf != nil`: instances of prototype
    ///   nodes. Emitted preserving ONLY what the fixture shows: the entry `__uuid`,
    ///   `__prototype_type: tm_graph_node`, `__prototype_uuid` (the prototype node), and a
    ///   `position` OVERRIDE (with its own `__uuid`/`__prototype_*`). NO `type` is written
    ///   (it's recovered from the prototype on read). When the original entry exists it is
    ///   updated in place (position-only, identity preserved); an instantiated box with no
    ///   original is reconstructed minimally from its `instanceOf` prototype uuid.
    ///
    /// DELTA SEMANTICS — DEFERRED (needs a before/after RCP3 capture). This faithfully
    /// ROUND-TRIPS + edits the EXISTING instance structure (the oracle fixture). What is
    /// NOT directly observable from a single static fixture is exactly where RCP3 places a
    /// BRAND-NEW node the user adds to an instance (`nodes` vs `nodes__instantiated`), and
    /// what `components__instantiated`/override bookkeeping it writes when an instance is
    /// FIRST overridden. We apply the reasonable rule — a newly authored node (`instanceOf
    /// == nil`) lands in `nodes` — and never fabricate an instantiation. Confirming RCP3's
    /// exact add-a-node-to-an-instance write needs that capture.
    @MainActor
    private static func patchedEntityOverride(
        asset: TMObject,
        graph: TMObject,
        with model: ScriptGraphEditorModel
    ) -> TMObject {
        var graph = graph
        let liveIDs = Set(model.nodes.map(\.id))

        // Index the original entries of BOTH arrays by `__uuid`, so a moved/edited node
        // reuses its original object (preserving identity + unmodeled members).
        var authoredByID: [String: TMObject] = [:]
        for value in graph["nodes"]?.arrayValue ?? [] {
            guard let object = value.objectValue, let id = object.uuid else { continue }
            authoredByID[id] = object
        }
        var instantiatedByID: [String: TMObject] = [:]
        for value in graph["nodes__instantiated"]?.arrayValue ?? [] {
            guard let object = value.objectValue, let id = object.uuid else { continue }
            instantiatedByID[id] = object
        }

        // Split the model's flat node list back into the two on-disk arrays by provenance,
        // preserving model order within each. A box with `instanceOf != nil` is a prototype
        // instance → `nodes__instantiated`; otherwise it's authored/added → `nodes`.
        var newAuthored: [TMValue] = []
        var newInstantiated: [TMValue] = []
        for box in model.nodes {
            if let prototypeUUID = box.instanceOf {
                let entry = patchedInstantiatedNode(
                    existing: instantiatedByID[box.id],
                    box: box,
                    prototypeUUID: prototypeUUID
                )
                newInstantiated.append(.object(entry))
            } else {
                let entry = patchedNode(existing: authoredByID[box.id], box: box)
                newAuthored.append(.object(entry))
            }
        }
        graph.set(.array(newAuthored), forKey: "nodes")
        graph.set(.array(newInstantiated), forKey: "nodes__instantiated")

        // Connections + data + variables: identical treatment to the standalone path
        // (the instance graph fully re-states its own wires/literals — they aren't deltas).
        let newConnections = model.connections.map { TMValue.object(connectionObject(for: $0)) }
        graph.set(.array(newConnections), forKey: "connections")

        let existingData = graph["data"]?.arrayValue ?? []
        graph.set(.array(patchedData(existingData, model: model, liveIDs: liveIDs)), forKey: "data")

        let existingVariables = graph["variables"]?.arrayValue ?? []
        if let variablesArray = patchedVariables(existingVariables, model: model) {
            graph.set(.array(variablesArray), forKey: "variables")
        } else {
            graph.remove(key: "variables")
        }

        return asset.setting(.object(graph), forKey: "graph")
    }

    /// The `nodes__instantiated` entry for a prototype-instance `box`: the `existing`
    /// entry updated IN PLACE (position override only, identity + `__prototype_*` members
    /// preserved) when there is one, else a minimal reconstruction.
    ///
    /// What it writes (and ONLY this — matching the oracle fixture):
    /// - `__uuid` — the instance's own identity (`box.id`).
    /// - `__prototype_type: tm_graph_node` — the kind being instanced.
    /// - `__prototype_uuid` — the prototype node this instances (`box.instanceOf`).
    /// - `position` — the OVERRIDE: its `x`/`y` follow `box.position` (with the same
    ///   compare-and-skip precision preservation as authored nodes, so an unmoved instance
    ///   keeps its exact original lexeme), preserving the position object's own `__uuid`
    ///   and `__prototype_*`. The fixture shows a position override may carry ONLY a
    ///   `__uuid`/`__prototype_*` and no coordinates (an inherited position); to honor that
    ///   we only WRITE `x`/`y` when the box was actually moved off such an entry, leaving a
    ///   coordinate-less inherited position untouched.
    /// Notably it writes NO `type` (recovered from the prototype on read) and NO `label`.
    @MainActor
    private static func patchedInstantiatedNode(
        existing: TMObject?,
        box: GraphNodeBox,
        prototypeUUID: String
    ) -> TMObject {
        var node = existing ?? TMObject()
        node.set(.string(box.id), forKey: "__uuid")
        // Preserve an existing `__prototype_type`; default to the observed `tm_graph_node`.
        if node.prototypeType == nil {
            node.set(.string("tm_graph_node"), forKey: "__prototype_type")
        }
        node.set(.string(prototypeUUID), forKey: "__prototype_uuid")

        // Position OVERRIDE. Reuse the original position object (its `__uuid`/`__prototype_*`
        // survive). A coordinate is emitted ONLY when it was AUTHORED on disk or the node was
        // moved (`box.authoredX/Y` — flipped true by `moveNode`); an inherited, coordinate-less
        // position that the user never moved stays coordinate-less (we don't materialize the
        // model's fallback-lane seed into a fabricated override). An authored/moved coordinate
        // re-emits only on a real change (compare-and-skip preserves the byte-exact lexeme).
        if var position = node["position"]?.objectValue {
            setInstantiatedPositionComponent(&position, key: "x", value: box.position.x, authored: box.authoredX)
            setInstantiatedPositionComponent(&position, key: "y", value: box.position.y, authored: box.authoredY)
            node.set(.object(position), forKey: "position")
        } else {
            // No original position object: write a fresh override only for authored/moved coords.
            var position = TMObject()
            if box.authoredX { position.set(.number(numberLexeme(box.position.x)), forKey: "x") }
            if box.authoredY { position.set(.number(numberLexeme(box.position.y)), forKey: "y") }
            node.set(.object(position), forKey: "position")
        }
        return node
    }

    /// Sets a `position` override component for an instantiated node. When `authored` is
    /// false (an inherited, coordinate-less position the user never moved) the component is
    /// LEFT ABSENT — writing the model's fallback-lane seed would fabricate an override the
    /// fixture doesn't show. When authored/moved, the component is written, but only when it
    /// genuinely differs from what's stored (compare-and-skip preserves the original lexeme
    /// byte-exact for an unchanged value, same precision guard as authored nodes).
    private static func setInstantiatedPositionComponent(_ position: inout TMObject, key: String, value: Double, authored: Bool) {
        guard authored else {
            position.remove(key: key) // never had a coordinate; keep it inherited
            return
        }
        if let existing = position[key]?.doubleValue, existing == value { return }
        position.set(.number(numberLexeme(value)), forKey: key)
    }

    // MARK: - Variable table

    /// Rebuilds the `variables:` array from `model.variables`, preserving each entry's
    /// `__uuid` (reusing the original object when one matches the uuid, so any unmodeled
    /// members — a future `type`/`default` — survive). Returns `nil` when the model has
    /// no variables, so the caller drops the member entirely.
    @MainActor
    private static func patchedVariables(_ existing: [TMValue], model: ScriptGraphEditorModel) -> [TMValue]? {
        guard !model.variables.isEmpty else { return nil }
        var objectByUUID: [String: TMObject] = [:]
        for value in existing {
            if let object = value.objectValue, let uuid = object.uuid { objectByUUID[uuid] = object }
        }
        return model.variables.map { variable in
            var object = objectByUUID[variable.uuid] ?? TMObject()
            object.set(.string(variable.uuid), forKey: "__uuid")
            object.set(.string(variable.name), forKey: "name")
            return .object(object)
        }
    }

    // MARK: - Data literal patch (authored scalars)

    /// Rebuilds the `data[]` array: keeps every literal bound to a live node, updating
    /// or dropping the **scalar** ones to match the model's authored values, then
    /// appends a fresh literal for each newly-authored pin not already present.
    @MainActor
    private static func patchedData(
        _ existing: [TMValue],
        model: ScriptGraphEditorModel,
        liveIDs: Set<String>
    ) -> [TMValue] {
        var remaining = model.scalarLiterals // authored pins not yet matched to an existing literal
        // Variable references the model still wants, keyed by node — consumed as we
        // rewrite existing `tm_graph_variable_ref` entries; the rest are appended fresh.
        var remainingVariableNodes = Set(model.variableNames.keys)
        var kept: [TMValue] = []

        for value in existing {
            guard let object = value.objectValue,
                  let toNode = object["to_node"]?.stringValue else {
                kept.append(value)
                continue
            }
            // Drop literals targeting a deleted node.
            guard liveIDs.contains(toNode) else { continue }

            let valueObject = object["data"]?.objectValue

            // A variable reference (`tm_graph_variable_ref`): reconcile it with the
            // model's per-node variable name. Rewrite `ref`/`name` in place (preserving
            // the entry's + inner value's `__uuid`); drop it when the node no longer
            // names a variable.
            if valueObject?.type == "tm_graph_variable_ref" {
                remainingVariableNodes.remove(toNode)
                if let name = model.variableNames[toNode] {
                    kept.append(.object(updatedVariableRef(object, name: name, model: model)))
                }
                // else: the node's variable reference was cleared; drop the entry.
                continue
            }

            // A scalar literal: its value object carries a `value` number (and no
            // named `type` hash — that marks a component-type literal). Reconcile it
            // with the model's authored value for this pin.
            let isScalarLiteral = valueObject?["value"]?.doubleValue != nil
                && valueObject?["type"] == nil
            if isScalarLiteral,
               let pinHex = object["to_connector_hash"]?.stringValue,
               let pinHash = UInt64(pinHex, radix: 16) {
                let key = LiteralKey(nodeID: toNode, pinConnectorHash: pinHash)
                if let authored = remaining.removeValue(forKey: key) {
                    // Rewrite the value in place, preserving identity + other members.
                    kept.append(.object(updatedScalarLiteral(object, value: authored)))
                }
                // else: no authored value for this pin → the literal was cleared; drop it.
                continue
            }

            // Non-scalar literal (e.g. component_type) — preserved untouched.
            kept.append(value)
        }

        // Append a fresh literal for each newly-authored pin (bound to a live node).
        for (key, scalar) in remaining where liveIDs.contains(key.nodeID) {
            kept.append(.object(newScalarLiteral(key: key, value: scalar)))
        }

        // Append a fresh `tm_graph_variable_ref` for each newly-named variable node.
        for nodeID in remainingVariableNodes where liveIDs.contains(nodeID) {
            if let name = model.variableNames[nodeID] {
                kept.append(.object(newVariableRef(nodeID: nodeID, name: name, model: model)))
            }
        }
        return kept
    }

    // MARK: - Variable reference (`tm_graph_variable_ref`) literals

    /// The variable table entry's `__uuid` for `name` (case-insensitive — the compile
    /// slot lowercases), or `nil` when the name isn't declared (a defensive fallback;
    /// the model declares any named variable, so this normally resolves).
    @MainActor
    private static func variableUUID(forName name: String, model: ScriptGraphEditorModel) -> String? {
        model.variables.first { $0.name.lowercased() == name.lowercased() }?.uuid
    }

    /// `object` with its `tm_graph_variable_ref` value rewritten to point at `name`:
    /// `name` denormalized, `ref` updated to the table entry's uuid. The entry's
    /// `__uuid` and the value object's `__uuid` are preserved (rewrite in place).
    @MainActor
    private static func updatedVariableRef(_ object: TMObject, name: String, model: ScriptGraphEditorModel) -> TMObject {
        var object = object
        var valueObject = object["data"]?.objectValue ?? TMObject()
        if valueObject.uuid == nil { valueObject.set(.string(UUID().uuidString), forKey: "__uuid") }
        valueObject.set(.string("tm_graph_variable_ref"), forKey: "__type")
        if let ref = variableUUID(forName: name, model: model) {
            valueObject.set(.string(ref), forKey: "ref")
        }
        valueObject.set(.string(name), forKey: "name")
        object.set(.object(valueObject), forKey: "data")
        return object
    }

    /// A fresh variable-reference data literal for `nodeID` naming `name`, bound to the
    /// `name` connector (`murmur64a("name")`):
    /// `{ __uuid, to_node, to_connector_hash, data: { __type: "tm_graph_variable_ref", __uuid, ref, name } }`.
    @MainActor
    private static func newVariableRef(nodeID: String, name: String, model: ScriptGraphEditorModel) -> TMObject {
        var object = TMObject()
        object.set(.string(UUID().uuidString), forKey: "__uuid")
        object.set(.string(nodeID), forKey: "to_node")
        object.set(.string(TMHash.hex(RCP3ScriptGraph.variableNameConnectorHash)), forKey: "to_connector_hash")
        var valueObject = TMObject()
        valueObject.set(.string("tm_graph_variable_ref"), forKey: "__type")
        valueObject.set(.string(UUID().uuidString), forKey: "__uuid")
        if let ref = variableUUID(forName: name, model: model) {
            valueObject.set(.string(ref), forKey: "ref")
        }
        valueObject.set(.string(name), forKey: "name")
        object.set(.object(valueObject), forKey: "data")
        return object
    }

    /// `object` with its value object's `value` member rewritten to `value`,
    /// preserving the literal's `__uuid` and the value object's `__type`/`__uuid`.
    private static func updatedScalarLiteral(_ object: TMObject, value: Double) -> TMObject {
        var object = object
        var valueObject = object["data"]?.objectValue ?? TMObject()
        valueObject.set(.number(numberLexeme(value)), forKey: "value")
        object.set(.object(valueObject), forKey: "data")
        return object
    }

    /// A fresh scalar data literal `{ __uuid, to_node, to_connector_hash, data: { value } }`
    /// for a newly-authored pin.
    private static func newScalarLiteral(key: LiteralKey, value: Double) -> TMObject {
        var object = TMObject()
        object.set(.string(UUID().uuidString), forKey: "__uuid")
        object.set(.string(key.nodeID), forKey: "to_node")
        object.set(.string(TMHash.hex(key.pinConnectorHash)), forKey: "to_connector_hash")
        var valueObject = TMObject()
        valueObject.set(.number(numberLexeme(value)), forKey: "value")
        object.set(.object(valueObject), forKey: "data")
        return object
    }

    // MARK: - Node patch

    /// The node object for `box`: the `existing` object updated in place (position,
    /// label) when there is one, else a fresh inserted node object.
    @MainActor
    private static func patchedNode(existing: TMObject?, box: GraphNodeBox) -> TMObject {
        if var node = existing {
            // Update position.x / position.y, preserving the position object's __uuid
            // and any other members.
            //
            // Precision-preservation (byte-exact interchange): the model's
            // `box.position` is `Double(originalLexeme)` — the SAME parse that produced
            // the original `position.x`/`.y` `.number` lexemes. RCP writes 17-sig-fig
            // floats; Swift's `String(Double)` emits the 16-sig-fig shortest form, so
            // unconditionally re-emitting drifts every node ~1 ULP on EVERY save even
            // with no edits (e.g. `-84.444442749023438` → `-84.44444274902344`). So we
            // only rewrite a component when its parsed-Double genuinely DIFFERS from the
            // model's (a node that was actually moved); an unchanged component keeps its
            // original lexeme untouched. The compare is exact (same parse, no epsilon).
            var position = node["position"]?.objectValue ?? TMObject()
            setPositionComponent(&position, key: "x", value: box.position.x)
            setPositionComponent(&position, key: "y", value: box.position.y)
            node.set(.object(position), forKey: "position")

            // Mirror the label: set it when present, drop it when the payload has none.
            if let label = box.payload.label {
                node.set(.string(label), forKey: "label")
            } else {
                node.remove(key: "label")
            }
            return node
        }

        // Inserted node: a minimal, well-formed node object.
        var node = TMObject()
        node.set(.string(box.id), forKey: "__uuid")
        node.set(.string(box.payload.type), forKey: "type")
        if let label = box.payload.label {
            node.set(.string(label), forKey: "label")
        }
        var position = TMObject()
        position.set(.number(numberLexeme(box.position.x)), forKey: "x")
        position.set(.number(numberLexeme(box.position.y)), forKey: "y")
        node.set(.object(position), forKey: "position")
        return node
    }

    /// Sets `position[key]` to `value` ONLY when it genuinely differs from the
    /// component already stored — preserving the original `.number` lexeme (byte-exact)
    /// when the node wasn't moved.
    ///
    /// The stored component's `doubleValue` (`Double(lexeme)`) is the very Double the
    /// model carries for an unmoved node, so the equality test is exact, not
    /// epsilon-fragile. Only when they differ (a real move) do we re-emit, accepting the
    /// shortest-form lexeme for the new value. A component that was previously absent
    /// (or non-numeric) is always written.
    private static func setPositionComponent(_ position: inout TMObject, key: String, value: Double) {
        if let existing = position[key]?.doubleValue, existing == value { return }
        position.set(.number(numberLexeme(value)), forKey: key)
    }

    // MARK: - Connection serialization

    /// A `{ __uuid, from_node, to_node [, from_connector_hash, to_connector_hash] }`
    /// object for `connection`. Legacy unnamed exec wires omit hashes; named exec and
    /// data wires carry the hash suffix parsed from their pin ids.
    private static func connectionObject(for connection: GraphConnection) -> TMObject {
        var object = TMObject()
        object.set(.string(connection.id), forKey: "__uuid")
        object.set(.string(connection.from.nodeID), forKey: "from_node")
        object.set(.string(connection.to.nodeID), forKey: "to_node")
        if let fromHex = hashHexComponent(of: connection.from.pinID) {
            object.set(.string(fromHex), forKey: "from_connector_hash")
        }
        if let toHex = hashHexComponent(of: connection.to.pinID) {
            object.set(.string(toHex), forKey: "to_connector_hash")
        }
        return object
    }

    /// The final `<hex>` component of a data or named-exec pin id.
    private static func hashHexComponent(of pinID: String) -> String? {
        guard let component = pinID.split(separator: ".").last, UInt64(component, radix: 16) != nil else {
            return nil
        }
        return String(component)
    }

    /// A numeric lexeme for `value`, written to match how RCP stores positions.
    /// Whole values stay integers (`3` not `3.0`); fractional values use the default
    /// `Double` description.
    private static func numberLexeme(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - Persist

    /// A failure resolving or writing a script-graph asset.
    public enum WriteError: Error, Equatable, Sendable, CustomStringConvertible {
        /// No `*.tm_script_graph` file in `bundleURL` has root `__uuid == rootUUID`.
        case assetNotFound(rootUUID: String)
        /// No entity in the bundle root tree matched `entityID` (or it carried no
        /// `re_scripting_component` with an embedded `source.graph` to write back into).
        case entityGraphNotFound(entityID: String)

        public var description: String {
            switch self {
            case let .assetNotFound(rootUUID):
                return "No .tm_script_graph asset with root __uuid '\(rootUUID)' in the bundle."
            case let .entityGraphNotFound(entityID):
                return "No entity '\(entityID)' with an embedded re_scripting_component.source.graph in the bundle."
            }
        }
    }

    /// Patches the `.tm_script_graph` whose root `__uuid` is `rootUUID` with `model`
    /// and writes it back to its file in `bundleURL`.
    ///
    /// Resolution: scan `bundleURL` for the `*.tm_script_graph` file whose parsed
    /// root `__uuid` matches `rootUUID`, parse it, apply ``patched(asset:with:)``,
    /// and write the result (`tmText()`) back to that same file. Throws
    /// ``WriteError/assetNotFound(rootUUID:)`` when no file matches.
    @MainActor
    public static func write(
        model: ScriptGraphEditorModel,
        toAssetWithRootUUID rootUUID: String,
        in bundleURL: URL
    ) throws {
        guard let (asset, fileURL) = resolveAsset(rootUUID: rootUUID, in: bundleURL) else {
            throw WriteError.assetNotFound(rootUUID: rootUUID)
        }
        let patched = patched(asset: asset, with: model)
        try patched.tmText().write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Scans `bundleURL` (non-recursively) for the `*.tm_script_graph` whose root
    /// `__uuid` equals `rootUUID`, returning its parsed root object and file URL.
    static func resolveAsset(rootUUID: String, in bundleURL: URL) -> (asset: TMObject, url: URL)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: nil
        ) else { return nil }

        for fileURL in entries where fileURL.pathExtension == "tm_script_graph" {
            guard
                let text = try? String(contentsOf: fileURL, encoding: .utf8),
                let object = try? TM.parse(text).objectValue
            else { continue }
            if object.uuid == rootUUID { return (object, fileURL) }
        }
        return nil
    }

    // MARK: - Persist (entity-attached / instance-override graph)

    /// Patches the script graph embedded on the entity `entityID` (its
    /// `re_scripting_component.source.graph`) with `model` and writes the whole root
    /// entity file (`world.tm_entity`) back to disk.
    ///
    /// This is the entity-override counterpart to ``write(model:toAssetWithRootUUID:in:)``:
    /// rather than resolving a standalone `*.tm_script_graph`, it parses the bundle root,
    /// patches the embedded graph IN PLACE (preserving the component's slot in
    /// `components`/`components__instantiated`, the `source` identity + `validation_settings`,
    /// and the graph's own `__prototype_*`), and rewrites the root file. Throws
    /// ``WriteError/entityGraphNotFound(entityID:)`` when no such entity/component exists.
    ///
    /// `rootURL` is the bundle's root entity file (`RCP3Bundle.rootURL`); `entityID`
    /// matches the entity's `__uuid` and, as a fallback, its `name` (the same matching the
    /// loader uses for `scriptGraph(forEntityID:)`).
    @MainActor
    public static func write(
        model: ScriptGraphEditorModel,
        toEntityWithID entityID: String,
        rootFileURL rootURL: URL
    ) throws {
        let text = try String(contentsOf: rootURL, encoding: .utf8)
        guard let root = try TM.parse(text).objectValue else {
            throw WriteError.entityGraphNotFound(entityID: entityID)
        }
        guard let patchedRoot = patchedRoot(root, entityID: entityID, with: model) else {
            throw WriteError.entityGraphNotFound(entityID: entityID)
        }
        try patchedRoot.tmText().write(to: rootURL, atomically: true, encoding: .utf8)
    }

    /// Returns a copy of the root entity tree with the graph embedded on entity `entityID`
    /// patched by `model`, or `nil` when the entity (or its embedded source graph) can't be
    /// found. Pure transform (parse-in → object-out) — the testable core of the entity path.
    ///
    /// It descends `children` to the matching entity, locates its `re_scripting_component`
    /// (across `components` + `components__instantiated`), runs ``patched(asset:with:)`` on
    /// the component's `source` (a `re_scripting_source_graph`, the same shape that holds
    /// `graph` + `validation_settings`), and rebuilds the tree around the patched source —
    /// every sibling member, the component slot, and unrelated entities untouched.
    @MainActor
    public static func patchedRoot(
        _ root: TMObject,
        entityID: String,
        with model: ScriptGraphEditorModel
    ) -> TMObject? {
        guard let entity = findEntity(id: entityID, in: root) else { return nil }
        guard let patchedEntity = patchedEntity(entity, with: model) else { return nil }
        return replaceEntity(id: entityID, with: patchedEntity, in: root)
    }

    /// Returns a copy of `entity` whose first `re_scripting_component`'s embedded
    /// `source.graph` is patched by `model`, or `nil` when the entity has no such
    /// component with an embedded source. The component keeps its position in whichever
    /// array (`components`/`components__instantiated`) it lives in; only its `source`
    /// member is rewritten.
    @MainActor
    static func patchedEntity(_ entity: TMObject, with model: ScriptGraphEditorModel) -> TMObject? {
        for arrayKey in ["components", "components__instantiated"] {
            guard let array = entity[arrayKey]?.arrayValue else { continue }
            for (index, value) in array.enumerated() {
                guard
                    var component = value.objectValue,
                    (component.type ?? component.prototypeType) == "re_scripting_component",
                    let source = component["source"]?.objectValue,
                    source["graph"] != nil
                else { continue }
                // `source` is a `re_scripting_source_graph` (graph + validation_settings) —
                // the exact shape `patched(asset:with:)` consumes.
                let patchedSource = patched(asset: source, with: model)
                component.set(.object(patchedSource), forKey: "source")
                var newArray = array
                newArray[index] = .object(component)
                return entity.setting(.array(newArray), forKey: arrayKey)
            }
        }
        return nil
    }

    /// Finds the `tm_entity` whose `__uuid` (or, as a fallback, `name`) is `id` in
    /// `object`'s `children` tree. Clean-room mirror of the loader's matching, kept local
    /// so the editor module needn't widen `RCP3Document`'s internal API.
    static func findEntity(id: String, in object: TMObject) -> TMObject? {
        if object.uuid == id { return object }
        if let name = object.name, !name.isEmpty, name == id { return object }
        for value in object["children"]?.arrayValue ?? [] {
            guard let child = value.objectValue else { continue }
            if let found = findEntity(id: id, in: child) { return found }
        }
        return nil
    }

    /// Returns a copy of `object`'s tree with the entity matching `id` (by `__uuid`, else
    /// `name`) replaced by `replacement`. Rebuilds only the path to the matched entity;
    /// every other member/child is preserved in place and order.
    static func replaceEntity(id: String, with replacement: TMObject, in object: TMObject) -> TMObject {
        if object.uuid == id || (object.name.map { !$0.isEmpty && $0 == id } ?? false) {
            return replacement
        }
        guard let children = object["children"]?.arrayValue else { return object }
        var newChildren = children
        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            newChildren[index] = .object(replaceEntity(id: id, with: replacement, in: child))
        }
        return object.setting(.array(newChildren), forKey: "children")
    }
}
