import Foundation
import TMFormat

public extension RCP3Editor {
    /// Removes a non-root entity from the live root tree.
    @discardableResult
    mutating func deleteEntity(id: RCP3Entity.ID) -> Bool {
        guard let location = Self.childLocation(id: id, in: root) else { return false }
        guard var children = try? root.value(at: location.childrenPath).arrayValue else { return false }
        guard children.indices.contains(location.index) else { return false }

        children.remove(at: location.index)
        guard let updated = try? root.setting(.array(children), at: location.childrenPath) else { return false }
        return apply { $0 = updated }
    }

    /// Duplicates a non-root entity beside the original, preserving the copied
    /// subtree's unknown fields and prototype links while reminting copied identities.
    @discardableResult
    mutating func duplicateEntity(id: RCP3Entity.ID) -> RCP3Entity.ID? {
        guard let location = Self.childLocation(id: id, in: root) else { return nil }
        guard var children = try? root.value(at: location.childrenPath).arrayValue else { return nil }
        guard children.indices.contains(location.index),
              let source = children[location.index].objectValue else { return nil }

        let duplicate = RCP3EntityTreeWriteBack.duplicated(source)
        children.insert(.object(duplicate), at: location.index + 1)
        guard let updated = try? root.setting(.array(children), at: location.childrenPath) else { return nil }
        guard apply({ $0 = updated }) else { return nil }
        return RCP3Entity(duplicate).id
    }

    private struct ChildLocation {
        var childrenPath: TMPath
        var index: Int
    }

    /// Location of the array slot containing `id`. The root entity has no parent
    /// slot and is intentionally not removable/duplicable through this helper.
    private static func childLocation(
        id: RCP3Entity.ID,
        in parent: TMObject,
        parentPath: [TMPath.Step] = []
    ) -> ChildLocation? {
        guard let children = parent["children"]?.arrayValue else { return nil }
        let childrenPath = TMPath(parentPath + [.member("children")])
        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            if RCP3Entity(child).id == id || child.name == id {
                return ChildLocation(childrenPath: childrenPath, index: index)
            }
            let childPath = parentPath + [.member("children"), .index(index)]
            if let found = childLocation(id: id, in: child, parentPath: childPath) {
                return found
            }
        }
        return nil
    }
}

enum RCP3EntityTreeWriteBack {
    static func duplicated(
        _ object: TMObject,
        makeUUID: () -> String = { UUID().uuidString.lowercased() }
    ) -> TMObject {
        let replacements = uuidReplacements(in: object, makeUUID: makeUUID)
        var duplicate = remintUUIDs(in: object, replacements: replacements)
        if let name = duplicate.name {
            duplicate.set(.string(copyName(for: name)), forKey: "name")
        }
        return duplicate
    }

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

    private static func copyName(for name: String) -> String {
        if name.isEmpty { return name }
        return "\(name) Copy"
    }
}
