import TMFormat

/// Editing an entity's `name` by its display identity — the rename half of the
/// open → edit → save loop, addressed the way the UI selects (`RCP3Entity.id`).
///
/// Selection in the tree/viewport is keyed on `RCP3Entity.id` (the `__uuid`, with
/// a `type#name` fallback). Renaming therefore means: walk the `children[]` tree,
/// find the object whose projected id matches, build the `TMPath` to its `name`,
/// and write through with `setting(_:at:)` — leaving every sibling untouched.
public extension RCP3Editor {
    /// Renames the entity whose `RCP3Entity.id` is `id` to `newName`, in place on
    /// the live `root`. Returns `true` if a matching entity was found and changed.
    ///
    /// No-op (returns `false`) when no entity matches or the name already equals
    /// `newName`. Marks the session dirty (`hasUnsavedChanges`) on a real change.
    @discardableResult
    mutating func renameEntity(id: RCP3Entity.ID, to newName: String) -> Bool {
        guard let path = Self.pathToEntity(id: id, in: root) else { return false }
        let namePath = TMPath(path.steps + [.member("name")])
        guard let updated = try? root.setting(.string(newName), at: namePath) else { return false }
        return apply { $0 = updated }
    }

    /// The `TMPath` from `container` to the entity whose `RCP3Entity.id == id`, or
    /// `nil`. An empty path means `container` itself is the match (the root).
    private static func pathToEntity(
        id: RCP3Entity.ID,
        in container: TMObject,
        prefix: [TMPath.Step] = []
    ) -> TMPath? {
        if RCP3Entity(container).id == id { return TMPath(prefix) }
        guard let children = container["children"]?.arrayValue else { return nil }
        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            let childPrefix = prefix + [.member("children"), .index(index)]
            if let found = pathToEntity(id: id, in: child, prefix: childPrefix) {
                return found
            }
        }
        return nil
    }
}
