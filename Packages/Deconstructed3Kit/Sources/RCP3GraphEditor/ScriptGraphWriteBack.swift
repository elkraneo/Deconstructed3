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
    /// **Data.** `graph.data` is preserved as-is, except literals bound to a deleted
    /// node (`to_node` no longer present) are dropped, since they can no longer apply.
    @MainActor
    public static func patched(asset: TMObject, with model: ScriptGraphEditorModel) -> TMObject {
        guard var graph = asset["graph"]?.objectValue else { return asset }

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

        // Preserve `data`, dropping literals whose target node was deleted.
        if let data = graph["data"]?.arrayValue {
            let kept = data.filter { value in
                guard let toNode = value.objectValue?["to_node"]?.stringValue else { return true }
                return liveIDs.contains(toNode)
            }
            graph.set(.array(kept), forKey: "data")
        }

        return asset.setting(.object(graph), forKey: "graph")
    }

    // MARK: - Node patch

    /// The node object for `box`: the `existing` object updated in place (position,
    /// label) when there is one, else a fresh inserted node object.
    @MainActor
    private static func patchedNode(existing: TMObject?, box: GraphNodeBox) -> TMObject {
        if var node = existing {
            // Update position.x / position.y, preserving the position object's __uuid
            // and any other members.
            var position = node["position"]?.objectValue ?? TMObject()
            position.set(.number(numberLexeme(box.position.x)), forKey: "x")
            position.set(.number(numberLexeme(box.position.y)), forKey: "y")
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

    // MARK: - Connection serialization

    /// A `{ __uuid, from_node, to_node [, from_connector_hash, to_connector_hash] }`
    /// object for `connection`. Exec wires omit the hashes; data wires carry the hex
    /// parsed from the pin ids (`out.<hex>` / `in.<hex>`).
    private static func connectionObject(for connection: GraphConnection) -> TMObject {
        var object = TMObject()
        object.set(.string(connection.id), forKey: "__uuid")
        object.set(.string(connection.from.nodeID), forKey: "from_node")
        object.set(.string(connection.to.nodeID), forKey: "to_node")
        if !connection.isExec {
            if let fromHex = hexComponent(of: connection.from.pinID) {
                object.set(.string(fromHex), forKey: "from_connector_hash")
            }
            if let toHex = hexComponent(of: connection.to.pinID) {
                object.set(.string(toHex), forKey: "to_connector_hash")
            }
        }
        return object
    }

    /// The `<hex>` part of a data pin id (`out.<hex>` / `in.<hex>`): the substring
    /// after the first dot, or `nil` when the pin id has no hex component.
    private static func hexComponent(of pinID: String) -> String? {
        guard let dot = pinID.firstIndex(of: ".") else { return nil }
        let hex = pinID[pinID.index(after: dot)...]
        return hex.isEmpty ? nil : String(hex)
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

        public var description: String {
            switch self {
            case let .assetNotFound(rootUUID):
                return "No .tm_script_graph asset with root __uuid '\(rootUUID)' in the bundle."
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
}
