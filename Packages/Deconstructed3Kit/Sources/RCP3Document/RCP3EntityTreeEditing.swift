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
}

enum RCP3EntityTreeWriteBack {
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
