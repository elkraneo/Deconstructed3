import Foundation
import TMFormat

public extension RCP3Editor {
    /// Adds a built-in primitive under `parentID` (or the root entity when `nil`),
    /// using this bundle's `core.lib/geometry` prototype as the source of truth.
    @discardableResult
    mutating func addPrimitive(
        _ kind: RCP3PrimitiveKind,
        parentID: RCP3Entity.ID? = nil,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> RCP3Entity.ID? {
        guard let child = RCP3EntityTreeWriteBack.primitiveInstance(
            kind,
            in: bundle.url,
            makeUUID: makeUUID
        ) else { return nil }

        let targetID = parentID ?? entity.id
        let (updated, addedID) = RCP3EntityTreeWriteBack.adding(
            child,
            toParent: targetID,
            in: root,
            makeUUID: makeUUID
        )
        guard let addedID, apply({ $0 = updated }) else { return nil }
        return addedID
    }

    /// Removes a non-root entity from the live root tree.
    @discardableResult
    mutating func deleteEntity(
        id: RCP3Entity.ID,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> Bool {
        let (updated, deleted) = RCP3EntityTreeWriteBack.deleting(id: id, in: root, makeUUID: makeUUID)
        guard deleted else { return false }
        return apply { $0 = updated }
    }

    /// Duplicates a non-root entity beside the original, preserving the copied
    /// subtree's unknown fields and prototype links while reminting copied identities.
    @discardableResult
    mutating func duplicateEntity(
        id: RCP3Entity.ID,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> RCP3Entity.ID? {
        let (updated, duplicatedID) = RCP3EntityTreeWriteBack.duplicating(id: id, in: root, makeUUID: makeUUID)
        guard let duplicatedID, apply({ $0 = updated }) else { return nil }
        return duplicatedID
    }

    /// Adds an (unassigned) `re_scripting_component` to the entity with `id` — the RCP
    /// "Add Component → Scripting" action. The component is the type index's DEFAULT
    /// shape (a `source` with an empty `graph`/`interface` and `validation_settings`,
    /// no prototype link yet); assigning a script-graph asset to it is a separate step.
    /// Returns `false` if the entity isn't found or already has one.
    @discardableResult
    mutating func addScriptingComponent(
        toEntityID id: RCP3Entity.ID,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> Bool {
        let component = RCP3EntityTreeWriteBack.scriptingComponentDefault(makeUUID: makeUUID)
        let (updated, added) = RCP3EntityTreeWriteBack.addingComponent(component, toEntityID: id, in: root)
        guard added else { return false }
        return apply { $0 = updated }
    }

    /// Assigns a script-graph asset to the entity's `re_scripting_component` — the RCP
    /// "Script → Prototype" dropdown. Points the component's `source` at the asset
    /// (`source.__prototype_uuid` = `assetRootUUID`, `source.graph.__prototype_uuid` =
    /// the asset's `tm_graph` uuid). `nil` clears it back to `(none)`. Returns `false`
    /// when the entity has no scripting component.
    @discardableResult
    mutating func assignScriptGraph(
        toEntityID id: RCP3Entity.ID,
        assetRootUUID: String?
    ) -> Bool {
        // The asset's inner `tm_graph` __uuid, for the graph-level prototype link.
        let graphUUID = assetRootUUID.flatMap { bundle.scriptGraph(assetID: $0)?.id }
        let (updated, ok) = RCP3EntityTreeWriteBack.assigningScriptGraph(
            toEntityID: id,
            assetRootUUID: assetRootUUID,
            graphUUID: graphUUID,
            in: root
        )
        guard ok else { return false }
        return apply { $0 = updated }
    }

    /// Removes the entity's `re_scripting_component` entirely — the RCP "Remove
    /// Component" action. Scans both `components` and `components__instantiated`.
    /// Returns `false` when the entity has no scripting component.
    @discardableResult
    mutating func removeScriptingComponent(
        fromEntityID id: RCP3Entity.ID
    ) -> Bool {
        let (updated, removed) = RCP3EntityTreeWriteBack.removingComponent(
            ofType: "re_scripting_component",
            fromEntityID: id,
            in: root
        )
        guard removed else { return false }
        return apply { $0 = updated }
    }

    /// Whether the entity with `id` carries a `re_scripting_component`.
    func hasScriptingComponent(entityID id: RCP3Entity.ID) -> Bool {
        scriptingComponent(entityID: id) != nil
    }

    /// The asset root `__uuid` currently assigned to the entity's scripting component
    /// (`source.__prototype_uuid`), or `nil` when there's no component or it is `(none)`.
    func assignedScriptGraphAssetID(entityID id: RCP3Entity.ID) -> String? {
        scriptingComponent(entityID: id)?["source"]?.objectValue?["__prototype_uuid"]?.stringValue
    }

    /// Every entity (depth-first) that carries a `re_scripting_component` with a
    /// resolvable graph, paired with that graph — the scripts a Play/Simulate run
    /// executes (each on its own entity), mirroring RCP. Unassigned components
    /// ("(none)") resolve to no graph and are skipped.
    public func scriptedEntities() -> [EntityScriptBinding] {
        var bindings: [EntityScriptBinding] = []
        func visit(_ node: RCP3Entity) {
            // Include any entity whose resolved graph has nodes — i.e. actually does
            // something. Covers inline-override graphs AND asset-referenced ones, and in
            // either `components` or `components__instantiated`. An unassigned/empty
            // component resolves to a no-op (0 nodes) and is skipped.
            if let graph = scriptGraph(forEntityID: node.id), !graph.nodes.isEmpty {
                bindings.append(EntityScriptBinding(entityID: node.id, graph: graph))
            }
            for child in node.children { visit(child) }
        }
        visit(entity)
        return bindings
    }

    private func scriptingComponent(entityID id: RCP3Entity.ID) -> TMObject? {
        guard let entity = RCP3Bundle.findEntity(id: id, in: root) else { return nil }
        for key in ["components", "components__instantiated"] {
            for value in entity[key]?.arrayValue ?? [] {
                if let component = value.objectValue, component.type == "re_scripting_component" {
                    return component
                }
            }
        }
        return nil
    }
}

enum RCP3EntityTreeWriteBack {
    /// The DEFAULT-shaped `re_scripting_component` (from `__type_index.tm_meta`'s
    /// `default`): a `source` (`re_scripting_source_graph`) holding an empty `graph`
    /// (with an `interface`) and `validation_settings { path: "" }`. No prototype link
    /// — that's added when a script-graph asset is assigned.
    static func scriptingComponentDefault(makeUUID: () -> String) -> TMObject {
        var interface = TMObject()
        interface.set(.string(makeUUID()), forKey: "__uuid")

        var graph = TMObject()
        graph.set(.string(makeUUID()), forKey: "__uuid")
        graph.set(.object(interface), forKey: "interface")

        var validation = TMObject()
        validation.set(.string(makeUUID()), forKey: "__uuid")
        validation.set(.string(""), forKey: "path")

        var source = TMObject()
        source.set(.string(makeUUID()), forKey: "__uuid")
        source.set(.object(graph), forKey: "graph")
        source.set(.object(validation), forKey: "validation_settings")

        var component = TMObject()
        component.set(.string("re_scripting_component"), forKey: "__type")
        component.set(.string(makeUUID()), forKey: "__uuid")
        component.set(.object(source), forKey: "source")
        return component
    }

    /// Appends `component` to the `components` array of the entity with `id` (creating
    /// the array if absent), searching the tree recursively. No-op when the entity
    /// already carries a component of the same `__type`. Returns `(updated, didAdd)`.
    static func addingComponent(
        _ component: TMObject,
        toEntityID id: RCP3Entity.ID,
        in object: TMObject
    ) -> (TMObject, Bool) {
        if matches(object, id: id) {
            let existing = object["components"]?.arrayValue ?? []
            let newType = component.type
            let alreadyPresent = existing.contains { $0.objectValue?.type == newType }
            guard !alreadyPresent else { return (object, false) }
            var updated = object
            updated.set(.array(existing + [.object(component)]), forKey: "components")
            return (updated, true)
        }
        guard let children = object["children"]?.arrayValue else { return (object, false) }
        var updatedChildren = children
        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            let (updatedChild, added) = addingComponent(component, toEntityID: id, in: child)
            if added {
                updatedChildren[index] = .object(updatedChild)
                var updated = object
                updated.set(.array(updatedChildren), forKey: "children")
                return (updated, true)
            }
        }
        return (object, false)
    }

    /// Removes the first component of `__type` from the entity with `id`, searching the
    /// tree recursively and both `components` and `components__instantiated`. No-op when
    /// the entity has no such component. Returns `(updated, didRemove)`.
    static func removingComponent(
        ofType type: String,
        fromEntityID id: RCP3Entity.ID,
        in object: TMObject
    ) -> (TMObject, Bool) {
        if matches(object, id: id) {
            for key in ["components", "components__instantiated"] {
                guard let existing = object[key]?.arrayValue,
                      existing.contains(where: { $0.objectValue?.type == type })
                else { continue }
                let filtered = existing.filter { $0.objectValue?.type != type }
                var updated = object
                updated.set(.array(filtered), forKey: key)
                return (updated, true)
            }
            return (object, false)
        }
        guard let children = object["children"]?.arrayValue else { return (object, false) }
        var updatedChildren = children
        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            let (updatedChild, removed) = removingComponent(ofType: type, fromEntityID: id, in: child)
            if removed {
                updatedChildren[index] = .object(updatedChild)
                var updated = object
                updated.set(.array(updatedChildren), forKey: "children")
                return (updated, true)
            }
        }
        return (object, false)
    }

    /// Points the entity's `re_scripting_component.source` at a script-graph asset
    /// (or clears it when `assetRootUUID == nil`), searching the tree recursively.
    /// Sets `source.__prototype_{type,uuid}` (= `re_scripting_source_graph` / asset
    /// root) and `source.graph.__prototype_{type,uuid}` (= `tm_graph` / asset graph),
    /// mirroring the observed assigned shape. Returns `(updated, didAssign)`.
    static func assigningScriptGraph(
        toEntityID id: RCP3Entity.ID,
        assetRootUUID: String?,
        graphUUID: String?,
        in object: TMObject
    ) -> (TMObject, Bool) {
        if matches(object, id: id) {
            var components = object["components"]?.arrayValue ?? []
            guard let index = components.firstIndex(where: {
                $0.objectValue?.type == "re_scripting_component"
            }), var component = components[index].objectValue,
                var source = component["source"]?.objectValue else {
                return (object, false)
            }

            if let assetRootUUID {
                source.set(.string("re_scripting_source_graph"), forKey: "__prototype_type")
                source.set(.string(assetRootUUID), forKey: "__prototype_uuid")
                if var graph = source["graph"]?.objectValue {
                    graph.set(.string("tm_graph"), forKey: "__prototype_type")
                    if let graphUUID { graph.set(.string(graphUUID), forKey: "__prototype_uuid") }
                    source.set(.object(graph), forKey: "graph")
                }
            } else {
                source.remove(key: "__prototype_type")
                source.remove(key: "__prototype_uuid")
                if var graph = source["graph"]?.objectValue {
                    graph.remove(key: "__prototype_type")
                    graph.remove(key: "__prototype_uuid")
                    source.set(.object(graph), forKey: "graph")
                }
            }

            component.set(.object(source), forKey: "source")
            components[index] = .object(component)
            var updated = object
            updated.set(.array(components), forKey: "components")
            return (updated, true)
        }

        guard let children = object["children"]?.arrayValue else { return (object, false) }
        var updatedChildren = children
        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            let (updatedChild, ok) = assigningScriptGraph(
                toEntityID: id, assetRootUUID: assetRootUUID, graphUUID: graphUUID, in: child
            )
            if ok {
                updatedChildren[index] = .object(updatedChild)
                var updated = object
                updated.set(.array(updatedChildren), forKey: "children")
                return (updated, true)
            }
        }
        return (object, false)
    }

    static func primitiveInstance(
        _ kind: RCP3PrimitiveKind,
        in bundleURL: URL,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> TMObject? {
        guard kind != .none,
              let prototype = geometryPrototype(kind, in: bundleURL),
              let prototypeUUID = prototype.uuid
        else { return nil }

        var entity = TMObject()
        entity.set(.string(makeUUID()), forKey: "__uuid")
        entity.set(.string("tm_entity"), forKey: "__prototype_type")
        entity.set(.string(prototypeUUID), forKey: "__prototype_uuid")
        entity.set(.string(kind.rawValue), forKey: "name")

        if let transform = transformComponent(in: prototype) {
            entity.set(.array([.object(instantiatedTransformComponent(from: transform, makeUUID: makeUUID))]), forKey: "components__instantiated")
        }
        return entity
    }

    static func adding(
        _ child: TMObject,
        toParent parentID: RCP3Entity.ID,
        in root: TMObject,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> (TMObject, RCP3Entity.ID?) {
        add(child, toParent: parentID, in: root, makeUUID: makeUUID)
    }

    static func deleting(
        id: RCP3Entity.ID,
        in root: TMObject,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> (TMObject, Bool) {
        guard !matches(root, id: id) else { return (root, false) }
        return delete(id: id, in: root, makeUUID: makeUUID)
    }

    static func duplicating(
        id: RCP3Entity.ID,
        in root: TMObject,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> (TMObject, RCP3Entity.ID?) {
        guard !matches(root, id: id) else { return (root, nil) }
        return duplicate(id: id, in: root, makeUUID: makeUUID)
    }

    static func duplicated(
        _ object: TMObject,
        siblingNames: [String] = [],
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> TMObject {
        let replacements = uuidReplacements(in: object, makeUUID: makeUUID)
        var duplicate = remintUUIDs(in: object, replacements: replacements)
        if let name = duplicate.name {
            duplicate.set(.string(uniqueName(base: duplicateBaseName(for: name), existing: siblingNames)), forKey: "name")
        }
        return duplicate
    }

    // MARK: - Recursive tree mutations

    private static func add(
        _ child: TMObject,
        toParent parentID: RCP3Entity.ID,
        in object: TMObject,
        makeUUID: () -> String
    ) -> (TMObject, RCP3Entity.ID?) {
        if matches(object, id: parentID) {
            let existingChildren = object["children"]?.arrayValue ?? []
            let existingNames = existingChildren.compactMap { $0.objectValue?.name }
            var child = child
            if let name = child.name {
                child.set(.string(uniqueName(base: name, existing: existingNames)), forKey: "name")
            }
            let childID = RCP3Entity(child).id
            return (object.settingChildren(existingChildren + [.object(child)], makeUUID: makeUUID), childID)
        }

        guard let children = object["children"]?.arrayValue else { return (object, nil) }
        var updatedChildren = children
        for (index, value) in children.enumerated() {
            guard let childObject = value.objectValue else { continue }
            let (updatedChild, addedID) = add(child, toParent: parentID, in: childObject, makeUUID: makeUUID)
            if let addedID {
                updatedChildren[index] = .object(updatedChild)
                var updated = object
                updated.set(.array(updatedChildren), forKey: "children")
                return (updated, addedID)
            }
        }
        return (object, nil)
    }

    private static func delete(
        id: RCP3Entity.ID,
        in object: TMObject,
        makeUUID: () -> String
    ) -> (TMObject, Bool) {
        guard let children = object["children"]?.arrayValue else { return (object, false) }
        var updatedChildren = children

        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            if matches(child, id: id) {
                updatedChildren.remove(at: index)
                return (object.settingChildren(updatedChildren, makeUUID: makeUUID), true)
            }

            let (updatedChild, deleted) = delete(id: id, in: child, makeUUID: makeUUID)
            if deleted {
                updatedChildren[index] = .object(updatedChild)
                var updated = object
                updated.set(.array(updatedChildren), forKey: "children")
                return (updated, true)
            }
        }
        return (object, false)
    }

    private static func duplicate(
        id: RCP3Entity.ID,
        in object: TMObject,
        makeUUID: () -> String
    ) -> (TMObject, RCP3Entity.ID?) {
        guard let children = object["children"]?.arrayValue else { return (object, nil) }
        var updatedChildren = children

        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            if matches(child, id: id) {
                let siblingNames = children.compactMap { $0.objectValue?.name }
                let duplicate = duplicated(child, siblingNames: siblingNames, makeUUID: makeUUID)
                updatedChildren.insert(.object(duplicate), at: index + 1)
                return (object.settingChildren(updatedChildren, makeUUID: makeUUID), RCP3Entity(duplicate).id)
            }

            let (updatedChild, duplicatedID) = duplicate(id: id, in: child, makeUUID: makeUUID)
            if let duplicatedID {
                updatedChildren[index] = .object(updatedChild)
                var updated = object
                updated.set(.array(updatedChildren), forKey: "children")
                return (updated, duplicatedID)
            }
        }
        return (object, nil)
    }

    // MARK: - Primitive instance construction

    private static func geometryPrototype(_ kind: RCP3PrimitiveKind, in bundleURL: URL) -> TMObject? {
        let url = bundleURL.appending(path: "core.lib/geometry/\(kind.rawValue).tm_entity")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? TM.parse(text).objectValue
    }

    private static func transformComponent(in entity: TMObject) -> TMObject? {
        guard let components = entity["components"]?.arrayValue else { return nil }
        return components.compactMap(\.objectValue).first {
            $0.type == "tm_transform_component"
        }
    }

    private static func instantiatedTransformComponent(
        from prototype: TMObject,
        makeUUID: () -> String
    ) -> TMObject {
        var component = TMObject()
        component.set(.string("tm_transform_component"), forKey: "__type")
        component.set(.string(makeUUID()), forKey: "__uuid")
        component.set(.string("tm_transform_component"), forKey: "__prototype_type")
        if let uuid = prototype.uuid {
            component.set(.string(uuid), forKey: "__prototype_uuid")
        }

        for key in ["local_position_double", "local_rotation", "local_scale"] {
            guard let subobject = prototype[key]?.objectValue else { continue }
            component.set(.object(instantiatedSubobject(key: key, from: subobject, makeUUID: makeUUID)), forKey: key)
        }
        return component
    }

    private static func instantiatedSubobject(
        key: String,
        from prototype: TMObject,
        makeUUID: () -> String
    ) -> TMObject {
        var object = TMObject()
        object.set(.string(makeUUID()), forKey: "__uuid")
        if let type = prototype.type {
            object.set(.string(type), forKey: "__prototype_type")
        } else if let type = prototype.prototypeType {
            object.set(.string(type), forKey: "__prototype_type")
        } else {
            object.set(.string(subobjectPrototypeType(for: key)), forKey: "__prototype_type")
        }
        if let uuid = prototype.uuid {
            object.set(.string(uuid), forKey: "__prototype_uuid")
        }
        return object
    }

    private static func subobjectPrototypeType(for key: String) -> String {
        switch key {
        case "local_rotation": return "tm_rotation"
        case "local_scale": return "tm_scale"
        default: return "tm_position_double"
        }
    }

    // MARK: - UUID remapping

    private static func uuidReplacements(in object: TMObject, makeUUID: () -> String) -> [String: String] {
        var replacements: [String: String] = [:]
        collectUUIDs(in: .object(object), into: &replacements, makeUUID: makeUUID)
        return replacements
    }

    private static func collectUUIDs(
        in value: TMValue,
        into replacements: inout [String: String],
        makeUUID: () -> String
    ) {
        switch value {
        case let .object(object):
            if let uuid = object.uuid {
                replacements[uuid] = makeUUID()
            }
            for member in object.members {
                collectUUIDs(in: member.value, into: &replacements, makeUUID: makeUUID)
            }
        case let .array(values):
            for value in values {
                collectUUIDs(in: value, into: &replacements, makeUUID: makeUUID)
            }
        case .string, .number, .bool, .symbol:
            return
        }
    }

    private static func remintUUIDs(in object: TMObject, replacements: [String: String]) -> TMObject {
        TMObject(members: object.members.map { member in
            if member.key == "__uuid" {
                let uuid = member.value.stringValue.flatMap { replacements[$0] } ?? member.value.stringValue
                return .init(key: member.key, value: uuid.map(TMValue.string) ?? member.value)
            }
            return .init(key: member.key, value: remintUUIDs(in: member.value, replacements: replacements))
        })
    }

    private static func remintUUIDs(in value: TMValue, replacements: [String: String]) -> TMValue {
        switch value {
        case let .object(object):
            return .object(remintUUIDs(in: object, replacements: replacements))
        case let .array(values):
            return .array(values.map { remintUUIDs(in: $0, replacements: replacements) })
        case let .string(string):
            return replacements[string].map(TMValue.string) ?? value
        case .number, .bool, .symbol:
            return value
        }
    }

    // MARK: - Names and child order

    private static func matches(_ object: TMObject, id: RCP3Entity.ID) -> Bool {
        RCP3Entity(object).id == id || object.name == id
    }

    private static func duplicateBaseName(for name: String) -> String {
        guard name.hasSuffix(")") else { return name }
        guard let open = name.lastIndex(of: "("),
              open > name.startIndex,
              name[name.index(before: open)] == " "
        else { return name }
        let numberStart = name.index(after: open)
        let numberEnd = name.index(before: name.endIndex)
        guard Int(name[numberStart..<numberEnd]) != nil else { return name }
        return String(name[..<name.index(before: open)])
    }

    private static func uniqueName(base: String, existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var index = 1
        while existing.contains("\(base) (\(index))") {
            index += 1
        }
        return "\(base) (\(index))"
    }
}

private extension TMObject {
    func settingChildren(
        _ children: [TMValue],
        makeUUID: () -> String
    ) -> TMObject {
        var updated = self
        updated.set(.array(children), forKey: "children")
        updated.set(.array(Self.childSortValues(for: children, makeUUID: makeUUID)), forKey: "child_sort_values")
        return updated
    }

    static func childSortValues(
        for children: [TMValue],
        makeUUID: () -> String
    ) -> [TMValue] {
        children.enumerated().compactMap { index, value in
            guard let child = value.objectValue, let uuid = child.uuid else { return nil }
            var sort = TMObject()
            sort.set(.string(makeUUID()), forKey: "__uuid")
            sort.set(.string(uuid), forKey: "child")
            if index > 0 {
                sort.set(.number(String(index)), forKey: "value")
            }
            return .object(sort)
        }
    }
}
