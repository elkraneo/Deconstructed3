import Foundation
import TMFormat

/// An entity's local transform, as the inspector edits it and as it persists into a
/// `tm_transform_component` — the write half of open → edit → save for scene/entity
/// editing.
///
/// Components are plain `Double`s in the format's stored representation: translation
/// `(x, y, z)`, rotation as a **quaternion** `(x, y, z, w)` (note the field order —
/// `x` first, `w` last, as RCP3 writes `local_rotation`), and scale `(x, y, z)`.
/// The identity transform mirrors the schema defaults (`RCP3TransformDefaults`):
/// translation `(0, 0, 0)`, rotation `(0, 0, 0, 1)`, scale `(1, 1, 1)`.
public struct RCP3Transform: Equatable, Sendable {
    public var translation: (x: Double, y: Double, z: Double)
    public var rotation: (x: Double, y: Double, z: Double, w: Double)
    public var scale: (x: Double, y: Double, z: Double)

    public init(
        translation: (x: Double, y: Double, z: Double),
        rotation: (x: Double, y: Double, z: Double, w: Double),
        scale: (x: Double, y: Double, z: Double)
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    /// The identity transform (matches `RCP3TransformDefaults`).
    public static let identity = RCP3Transform(
        translation: RCP3TransformDefaults.translation,
        rotation: RCP3TransformDefaults.rotation,
        scale: RCP3TransformDefaults.scale
    )

    // Tuples aren't auto-`Equatable`; compare component-wise.
    public static func == (lhs: RCP3Transform, rhs: RCP3Transform) -> Bool {
        lhs.translation == rhs.translation
            && lhs.rotation == rhs.rotation
            && lhs.scale == rhs.scale
    }
}

// MARK: - Euler ⇆ quaternion (inspector convenience)

/// Euler-angle conversions for the stored rotation quaternion, so the inspector can
/// present a human-readable rotation (degrees) while persisting the quaternion RCP3
/// stores. Convention: intrinsic **XYZ** — the rotation matrix is `R = Rx·Ry·Rz`, and
/// the two methods are exact inverses (see ``eulerDegrees`` / ``settingEulerDegrees(_:)``).
///
/// As with any Euler-over-quaternion editing, the displayed angles are the *principal*
/// decomposition (X via `atan2`, Y via `asin` clamped to ±90°, Z via `atan2`): entering
/// an out-of-range angle stores the correct orientation but the field re-displays its
/// equivalent principal value (e.g. Y 120° → 60° with X/Z flipped). The stored
/// quaternion is always a faithful representation of the requested rotation.
public extension RCP3Transform {
    /// The rotation expressed as Euler angles in **degrees** `(x, y, z)`, derived from
    /// the stored quaternion. The exact inverse of ``settingEulerDegrees(_:)``:
    /// extracted from the quaternion's rotation matrix to match the `R = Rx·Ry·Rz`
    /// (intrinsic XYZ) composition that builds it.
    var eulerDegrees: (x: Double, y: Double, z: Double) {
        let (x, y, z, w) = (rotation.x, rotation.y, rotation.z, rotation.w)
        // Relevant rotation-matrix entries from the (assumed unit) quaternion.
        let r00 = 1 - 2 * (y * y + z * z)
        let r01 = 2 * (x * y - z * w)
        let r02 = 2 * (x * z + y * w)
        let r12 = 2 * (y * z - x * w)
        let r22 = 1 - 2 * (x * x + y * y)
        // For R = Rx·Ry·Rz: sin(ay) = r02; ax = atan2(-r12, r22); az = atan2(-r01, r00).
        let ay = asin(max(-1, min(1, r02)))
        let ax = atan2(-r12, r22)
        let az = atan2(-r01, r00)
        let toDegrees = 180.0 / Double.pi
        return (x: ax * toDegrees, y: ay * toDegrees, z: az * toDegrees)
    }

    /// A copy with the rotation set from Euler angles in **degrees** `(x, y, z)`,
    /// converting to the stored quaternion. Intrinsic **XYZ** composition
    /// (`q = qx ⊗ qy ⊗ qz`), the inverse of ``eulerDegrees``.
    func settingEulerDegrees(_ degrees: (x: Double, y: Double, z: Double)) -> RCP3Transform {
        let half = Double.pi / 180.0 / 2
        let (cx, sx) = (cos(degrees.x * half), sin(degrees.x * half))
        let (cy, sy) = (cos(degrees.y * half), sin(degrees.y * half))
        let (cz, sz) = (cos(degrees.z * half), sin(degrees.z * half))
        // q = qx ⊗ qy ⊗ qz (intrinsic XYZ): standard expansion.
        let w = cx * cy * cz - sx * sy * sz
        let x = sx * cy * cz + cx * sy * sz
        let y = cx * sy * cz - sx * cy * sz
        let z = cx * cy * sz + sx * sy * cz
        var copy = self
        copy.rotation = (x: x, y: y, z: z, w: w)
        return copy
    }
}

public extension RCP3Editor {
    /// The current local transform of the entity whose `RCP3Entity.id` is `id`, read
    /// from its `tm_transform_component` (inherited/omitted components fall back to the
    /// schema identity defaults). `nil` when no entity matches.
    func transform(forEntityID id: RCP3Entity.ID) -> RCP3Transform? {
        guard let object = RCP3Bundle.findEntity(id: id, in: root) else { return nil }
        let resolved = object.resolvedLocalTransform()
        return RCP3Transform(
            translation: resolved.translation,
            rotation: resolved.rotation,
            scale: resolved.scale
        )
    }

    /// Writes `transform` into the `tm_transform_component` of the entity whose
    /// `RCP3Entity.id` is `id`, in place on the live `root`. Returns `true` if a
    /// matching entity was found and its serialized transform changed.
    ///
    /// Faithful to how RCP3 saves a transform edit (observed in the `Random3` capture,
    /// see `Docs/CleanRoom-Spec.md` — "Entity transform editing — write-back"):
    ///
    /// - The component's `local_position_double` / `local_rotation` / `local_scale`
    ///   subobjects are rewritten **in place** — each keeps its `__uuid` and any
    ///   `__prototype_type` / `__prototype_uuid`, and the component keeps its slot in
    ///   `components` / `components__instantiated`. Only the value fields move.
    /// - A field whose value equals the inherited prototype default is **omitted**
    ///   (left to inherit), exactly as RCP3 left the unchanged position/scale empty.
    ///   A non-default value is written as an explicit `x` / `y` / `z` (and `w` for
    ///   rotation) field, appended after the subobject's identity members in the
    ///   canonical order `x, y, z[, w]`.
    /// - Float lexemes are preserved: a field already at the target value keeps its
    ///   original lexeme byte-for-byte (no re-emit/drift); only a genuinely changed
    ///   field is re-written. This mirrors the script-graph position write-back.
    ///
    /// Marks the session dirty (`hasUnsavedChanges`) on a real change.
    @discardableResult
    mutating func setTransform(_ transform: RCP3Transform, forEntityID id: RCP3Entity.ID) -> Bool {
        guard let entityPath = Self.pathToEntityObject(id: id, in: root) else { return false }
        guard let entity = try? root.object(at: entityPath) else { return false }
        guard let (arrayKey, index) = Self.transformComponentSlot(in: entity) else { return false }

        // The component lives at `entity[arrayKey][index]`. We can't write through a
        // path ending in an array index (the path-set API writes through object
        // *members*), so update the array element and write the array back through its
        // member key.
        guard var array = entity[arrayKey]?.arrayValue,
              array.indices.contains(index),
              let component = array[index].objectValue else { return false }

        let updatedComponent = RCP3TransformWriteBack.applied(transform, to: component)
        guard updatedComponent != component else { return false }
        array[index] = .object(updatedComponent)

        let arrayPath = TMPath(entityPath.steps + [.member(arrayKey)])
        guard let updated = try? root.setting(.array(array), at: arrayPath) else { return false }
        return apply { $0 = updated }
    }

    /// The `(arrayKey, index)` of the first `tm_transform_component` on `entity`,
    /// searched across `components` then `components__instantiated`. `nil` when the
    /// entity has no transform component.
    private static func transformComponentSlot(in entity: TMObject) -> (key: String, index: Int)? {
        for key in ["components", "components__instantiated"] {
            guard let array = entity[key]?.arrayValue else { continue }
            for (index, value) in array.enumerated() {
                guard let component = value.objectValue else { continue }
                if (component.type ?? component.prototypeType) == "tm_transform_component" {
                    return (key, index)
                }
            }
        }
        return nil
    }

    /// The `TMPath` from `root` to the entity whose `RCP3Entity.id == id`, walking the
    /// `children[]` tree. An empty path means `root` itself matches.
    private static func pathToEntityObject(
        id: RCP3Entity.ID,
        in container: TMObject,
        prefix: [TMPath.Step] = []
    ) -> TMPath? {
        if RCP3Entity(container).id == id { return TMPath(prefix) }
        if let name = container.name, !name.isEmpty, name == id { return TMPath(prefix) }
        guard let children = container["children"]?.arrayValue else { return nil }
        for (index, value) in children.enumerated() {
            guard let child = value.objectValue else { continue }
            let childPrefix = prefix + [.member("children"), .index(index)]
            if let found = pathToEntityObject(id: id, in: child, prefix: childPrefix) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Transform write-back (the testable, UI-free core)

/// Folds an edited ``RCP3Transform`` back into a `tm_transform_component` object,
/// preserving the subobjects' identity and lexemes and omitting inherited defaults —
/// the pure transform behind ``RCP3Editor/setTransform(_:forEntityID:)``.
public enum RCP3TransformWriteBack {
    /// Returns a copy of `component` with its `local_position_double` /
    /// `local_rotation` / `local_scale` subobjects updated to carry `transform`.
    public static func applied(_ transform: RCP3Transform, to component: TMObject) -> TMObject {
        var component = component

        applySubobject(
            &component,
            key: "local_position_double",
            values: [
                ("x", transform.translation.x, RCP3TransformDefaults.translation.x),
                ("y", transform.translation.y, RCP3TransformDefaults.translation.y),
                ("z", transform.translation.z, RCP3TransformDefaults.translation.z),
            ]
        )
        applySubobject(
            &component,
            key: "local_rotation",
            values: [
                ("x", transform.rotation.x, RCP3TransformDefaults.rotation.x),
                ("y", transform.rotation.y, RCP3TransformDefaults.rotation.y),
                ("z", transform.rotation.z, RCP3TransformDefaults.rotation.z),
                ("w", transform.rotation.w, RCP3TransformDefaults.rotation.w),
            ]
        )
        applySubobject(
            &component,
            key: "local_scale",
            values: [
                ("x", transform.scale.x, RCP3TransformDefaults.scale.x),
                ("y", transform.scale.y, RCP3TransformDefaults.scale.y),
                ("z", transform.scale.z, RCP3TransformDefaults.scale.z),
            ]
        )

        return component
    }

    /// Updates `component[key]` from `values`, in place. A subobject already present is
    /// rewritten through ``updatedSubobject(_:values:)`` (identity + lexemes preserved).
    /// A subobject that is *absent* is only added when at least one value is non-default
    /// — an all-default edit on an absent subobject writes nothing (no spurious empty
    /// `{}` member that RCP3 wouldn't emit).
    private static func applySubobject(
        _ component: inout TMObject,
        key: String,
        values: [(key: String, value: Double, default: Double)]
    ) {
        if let existing = component[key]?.objectValue {
            component.set(.object(updatedSubobject(existing, values: values)), forKey: key)
        } else if values.contains(where: { $0.value != $0.default }) {
            component.set(.object(updatedSubobject(TMObject(), values: values)), forKey: key)
        }
        // else: absent subobject + all-default values → leave it absent.
    }

    /// `subobject` with each `(key, value, default)` reconciled:
    ///
    /// - value **equals the inherited default** → the field is dropped (omitted), so
    ///   the component inherits the prototype, as RCP3 does for an unchanged axis;
    /// - value **differs from default** → the field is written, but only re-emitted
    ///   when its stored lexeme's `Double` genuinely differs from `value` (so an
    ///   unchanged-but-explicit field keeps its original lexeme byte-for-byte).
    ///
    /// Identity members (`__uuid`, `__prototype_type`, `__prototype_uuid`) and any
    /// other unmodeled members are preserved in place; newly-written value fields are
    /// appended after them in the canonical `x, y, z[, w]` order.
    private static func updatedSubobject(
        _ subobject: TMObject,
        values: [(key: String, value: Double, default: Double)]
    ) -> TMObject {
        var subobject = subobject
        for entry in values {
            if entry.value == entry.default {
                subobject.remove(key: entry.key)
            } else if subobject[entry.key]?.doubleValue != entry.value {
                subobject.set(.number(numberLexeme(entry.value)), forKey: entry.key)
            }
            // else: already present at exactly this value — keep its original lexeme.
        }
        return subobject
    }

    /// A numeric lexeme for `value`, matching how RCP3 serializes transform-component
    /// floats: `%.17g` (the C `printf` round-trip form, observed in the `Random3`
    /// capture — e.g. `0.94134980440139771`). `%g` also drops the radix point for whole
    /// values (`2`, not `2.0`), matching RCP3's integer-valued components.
    private static func numberLexeme(_ value: Double) -> String {
        String(format: "%.17g", value)
    }
}
