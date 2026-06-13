import Foundation
import TMFormat

extension RCP3Bundle {
    /// The parsed script graph attached to `entity` through a
    /// `re_scripting_component`, or `nil` when the entity has none (or the asset
    /// can't be resolved).
    ///
    /// Resolution path: find the entity's `re_scripting_component`, read its
    /// `source.__prototype_uuid` (the graph asset's identity), then scan the
    /// bundle directory for the `*.tm_script_graph` whose root `__uuid` matches and
    /// parse its `graph` member.
    public func scriptGraph(forEntity entity: TMObject) -> RCP3ScriptGraph? {
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
        guard
            let asset = Self.scriptGraphAsset(uuid: prototypeUUID, in: url),
            let tmGraph = asset["graph"]?.objectValue
        else { return nil }
        return RCP3ScriptGraph(tmGraph: tmGraph)
    }

    // MARK: Resolution helpers

    /// The `source.__prototype_uuid` of the entity's first `re_scripting_component`.
    static func scriptGraphPrototypeUUID(in entity: TMObject) -> String? {
        for key in ["components", "components__instantiated"] {
            guard let array = entity[key]?.arrayValue else { continue }
            for value in array {
                guard
                    let component = value.objectValue,
                    (component.type ?? component.prototypeType) == "re_scripting_component",
                    let source = component["source"]?.objectValue
                else { continue }
                // The graph asset is referenced by the source's prototype identity.
                if let prototype = source.prototypeUUID { return prototype }
                // Fall back to the source's own uuid for an inlined source.
                if let uuid = source.uuid { return uuid }
            }
        }
        return nil
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
    static func findEntity(id: RCP3Entity.ID, in object: TMObject) -> TMObject? {
        if RCP3Entity(object).id == id { return object }
        for value in object["children"]?.arrayValue ?? [] {
            guard let child = value.objectValue else { continue }
            if let found = findEntity(id: id, in: child) { return found }
        }
        return nil
    }
}
