import Foundation
import TMFormat

/// A browsable `*.tm_script_graph` asset in a bundle — a script graph as a
/// top-level thing the user can open directly, rather than one reached through the
/// entity that happens to reference it.
///
/// `id` is the asset file's root `__uuid` (the same identity an entity's
/// `re_scripting_component` points at), and `name` is the file's name without its
/// `.tm_script_graph` extension (e.g. `"Script Graph"`).
public struct RCP3ScriptGraphAsset: Identifiable, Equatable, Sendable {
    /// The asset root `__uuid` — load the graph with `scriptGraph(assetID:)`.
    public let id: String
    /// The asset's display name: its filename without the `.tm_script_graph` extension.
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension RCP3Bundle {
    /// Every `*.tm_script_graph` asset in this bundle, as browsable assets sorted by
    /// name. Scans `url` non-recursively, parsing each file's root and pairing its
    /// `__uuid` with the filename (sans extension). Unparseable or anonymous files
    /// (no root `__uuid`) are skipped.
    public func scriptGraphAssets() -> [RCP3ScriptGraphAsset] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var assets: [RCP3ScriptGraphAsset] = []
        for fileURL in entries where fileURL.pathExtension == "tm_script_graph" {
            guard
                let text = try? String(contentsOf: fileURL, encoding: .utf8),
                let object = try? TM.parse(text).objectValue,
                let id = object.uuid
            else { continue }
            let name = fileURL.deletingPathExtension().lastPathComponent
            assets.append(RCP3ScriptGraphAsset(id: id, name: name))
        }
        return assets.sorted { $0.name < $1.name }
    }

    /// Loads and parses the `*.tm_script_graph` asset with this id. The asset id IS
    /// the graph's root `__uuid`, so this is the prototype-uuid path under another
    /// name.
    public func scriptGraph(assetID: String) -> RCP3ScriptGraph? {
        scriptGraph(prototypeUUID: assetID)
    }
    /// The parsed script graph attached to `entity` through a
    /// `re_scripting_component`, or `nil` when the entity has none (or the asset
    /// can't be resolved).
    ///
    /// Two cases:
    /// - **Instance override** — the component carries an INLINE `source.graph`
    ///   (the user edited the graph on this entity in RCP). That embedded graph is
    ///   a prototype-instance: its `nodes` are instance additions and its
    ///   `nodes__instantiated` are instances of the prototype's nodes (carrying a
    ///   `__prototype_uuid` but no `type`). We load the prototype graph (via
    ///   `source.__prototype_uuid`) only to recover a `[nodeUUID: type]` lookup,
    ///   then parse the INLINE graph — merging instance `nodes` with the resolved
    ///   instantiated nodes, and using the inline `connections` + `data`. This is
    ///   the edited graph the user actually sees, not the stale prototype.
    /// - **Pure reference** — the component has NO inline `source.graph`. We fall
    ///   back to loading the standalone `*.tm_script_graph` prototype asset as-is
    ///   (via `source.__prototype_uuid`), scanning the bundle directory for the
    ///   file whose root `__uuid` matches and parsing its `graph` member.
    public func scriptGraph(forEntity entity: TMObject) -> RCP3ScriptGraph? {
        // Prefer an inline instance graph (the entity's own edited override).
        if let component = Self.scriptingComponent(in: entity),
           let source = component["source"]?.objectValue,
           let instanceGraph = source["graph"]?.objectValue {
            // Recover the prototype graph's node types so `nodes__instantiated`
            // entries (which carry no `type`) can resolve theirs.
            let prototypeNodeTypes: [String: String]
            if let prototypeUUID = source.prototypeUUID,
               let prototype = scriptGraphPrototypeGraph(prototypeUUID: prototypeUUID) {
                prototypeNodeTypes = Self.nodeTypes(in: prototype)
            } else {
                prototypeNodeTypes = [:]
            }
            return RCP3ScriptGraph(tmGraph: instanceGraph, prototypeNodeTypes: prototypeNodeTypes)
        }

        // Pure reference: load the standalone prototype asset as-is.
        guard let prototypeUUID = Self.scriptGraphPrototypeUUID(in: entity) else { return nil }
        return scriptGraph(prototypeUUID: prototypeUUID)
    }

    /// Looks up a `tm_entity` by its display `RCP3Entity.id` in this bundle's root
    /// tree and returns its script graph, if any.
    public func scriptGraph(forEntityID id: RCP3Entity.ID) -> RCP3ScriptGraph? {
        guard let object = Self.findEntity(id: id, in: root) else { return nil }
        return scriptGraph(forEntity: object)
    }

    /// Loads and parses the `*.tm_script_graph` asset whose root `__uuid` is
    /// `prototypeUUID`.
    public func scriptGraph(prototypeUUID: String) -> RCP3ScriptGraph? {
        guard let tmGraph = scriptGraphPrototypeGraph(prototypeUUID: prototypeUUID) else { return nil }
        return RCP3ScriptGraph(tmGraph: tmGraph)
    }

    /// The raw `graph` member of the standalone `*.tm_script_graph` asset whose root
    /// `__uuid` is `prototypeUUID`, or `nil` when no such asset exists. Used both to
    /// parse the prototype directly and to recover a prototype node-type lookup for
    /// resolving an entity's instance-override graph.
    func scriptGraphPrototypeGraph(prototypeUUID: String) -> TMObject? {
        Self.scriptGraphAsset(uuid: prototypeUUID, in: url)?["graph"]?.objectValue
    }

    // MARK: Resolution helpers

    /// The entity's first `re_scripting_component` object, across both its `components`
    /// and `components__instantiated` arrays.
    static func scriptingComponent(in entity: TMObject) -> TMObject? {
        for key in ["components", "components__instantiated"] {
            guard let array = entity[key]?.arrayValue else { continue }
            for value in array {
                guard
                    let component = value.objectValue,
                    (component.type ?? component.prototypeType) == "re_scripting_component"
                else { continue }
                return component
            }
        }
        return nil
    }

    /// The `source.__prototype_uuid` of the entity's first `re_scripting_component`.
    static func scriptGraphPrototypeUUID(in entity: TMObject) -> String? {
        guard
            let component = scriptingComponent(in: entity),
            let source = component["source"]?.objectValue
        else { return nil }
        // The graph asset is referenced by the source's prototype identity.
        if let prototype = source.prototypeUUID { return prototype }
        // Fall back to the source's own uuid for an inlined source.
        if let uuid = source.uuid { return uuid }
        return nil
    }

    /// A `[nodeUUID: type]` lookup over a prototype `tm_graph` object's `nodes`,
    /// used to recover the `type` of an instance graph's `nodes__instantiated`
    /// entries (which point at these prototype nodes by `__prototype_uuid`).
    static func nodeTypes(in tmGraph: TMObject) -> [String: String] {
        var types: [String: String] = [:]
        for value in tmGraph["nodes"]?.arrayValue ?? [] {
            guard
                let object = value.objectValue,
                let id = object.uuid,
                let type = object["type"]?.stringValue ?? object.prototypeType
            else { continue }
            types[id] = type
        }
        return types
    }

    /// Scans `bundleURL` (non-recursively) for the `*.tm_script_graph` whose root
    /// `__uuid` equals `uuid`, returning its parsed root object.
    static func scriptGraphAsset(uuid: String, in bundleURL: URL) -> TMObject? {
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
            if object.uuid == uuid { return object }
        }
        return nil
    }

    /// Finds the `tm_entity` object whose `RCP3Entity.id` is `id` in `object`'s tree.
    ///
    /// Matches on the display `RCP3Entity.id` (the entity's `__uuid`, e.g. the
    /// `box` entity's `73fc9fd1-…`) and, as a fallback, on the entity's display
    /// `name` — so a lookup keyed by name (`"box"`) also resolves.
    static func findEntity(id: RCP3Entity.ID, in object: TMObject) -> TMObject? {
        if RCP3Entity(object).id == id { return object }
        if let name = object.name, !name.isEmpty, name == id { return object }
        for value in object["children"]?.arrayValue ?? [] {
            guard let child = value.objectValue else { continue }
            if let found = findEntity(id: id, in: child) { return found }
        }
        return nil
    }
}
