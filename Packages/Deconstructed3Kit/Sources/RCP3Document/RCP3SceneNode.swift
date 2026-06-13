import Foundation
import TMFormat

/// The kind of built-in primitive an entity reconstructs to, resolved by matching
/// its `__prototype_uuid` against the bundle's `core.lib/geometry/*.tm_entity`
/// library. `.none` means the entity is structural (no geometry prototype).
public enum RCP3PrimitiveKind: String, Sendable, Equatable {
    case box
    case plane
    case sphere
    case none
}

/// A render-oriented projection of a `tm_entity`: its resolved local transform and
/// (if it instances a `core.lib` geometry prototype) its primitive kind, plus the
/// recursively-projected children.
///
/// This is a pure-data, `Sendable` tree — it imports no rendering framework. The
/// app target materializes public RealityKit entities from it. Transforms are
/// plain `Double` tuples (Foundation/stdlib only): translation `(x, y, z)`,
/// rotation as a quaternion `(x, y, z, w)`, and scale `(x, y, z)`.
public struct RCP3SceneNode: Sendable, Equatable, Identifiable {
    /// Stable identity (the entity `__uuid`, with a display fallback) — matches
    /// `RCP3Entity.id` so selection can cross between the tree and the viewport.
    public let id: String
    public let name: String
    /// Local translation `(x, y, z)`. Identity is `(0, 0, 0)`.
    public let translation: (x: Double, y: Double, z: Double)
    /// Local rotation as a quaternion `(x, y, z, w)`. Identity is `(0, 0, 0, 1)`.
    public let rotation: (x: Double, y: Double, z: Double, w: Double)
    /// Local scale `(x, y, z)`. Identity is `(1, 1, 1)`.
    public let scale: (x: Double, y: Double, z: Double)
    /// The primitive this entity reconstructs to, or `.none` for structural nodes.
    public let primitiveKind: RCP3PrimitiveKind
    public let children: [RCP3SceneNode]

    public init(
        id: String,
        name: String,
        translation: (x: Double, y: Double, z: Double),
        rotation: (x: Double, y: Double, z: Double, w: Double),
        scale: (x: Double, y: Double, z: Double),
        primitiveKind: RCP3PrimitiveKind,
        children: [RCP3SceneNode]
    ) {
        self.id = id
        self.name = name
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
        self.primitiveKind = primitiveKind
        self.children = children
    }

    // Tuples aren't auto-`Equatable`; compare component-wise.
    public static func == (lhs: RCP3SceneNode, rhs: RCP3SceneNode) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.translation == rhs.translation
            && lhs.rotation == rhs.rotation
            && lhs.scale == rhs.scale
            && lhs.primitiveKind == rhs.primitiveKind
            && lhs.children == rhs.children
    }
}

// MARK: - Transform resolution

/// Default (identity) transform values, mirroring the `__type_index.tm_meta`
/// schema defaults: position `tm_position_double` → 0; rotation `tm_rotation` →
/// `w: 1`; scale `tm_scale` → `1, 1, 1`.
enum RCP3TransformDefaults {
    static let translation = (x: 0.0, y: 0.0, z: 0.0)
    static let rotation = (x: 0.0, y: 0.0, z: 0.0, w: 1.0)
    static let scale = (x: 1.0, y: 1.0, z: 1.0)
}

extension TMObject {
    /// The first `tm_transform_component` attached to this entity, searched across
    /// both `components` (authored) and `components__instantiated` (inherited).
    fileprivate var transformComponent: TMObject? {
        for key in ["components", "components__instantiated"] {
            guard let array = self[key]?.arrayValue else { continue }
            for value in array {
                guard let component = value.objectValue else { continue }
                if (component.type ?? component.prototypeType) == "tm_transform_component" {
                    return component
                }
            }
        }
        return nil
    }

    /// Resolves this entity's local translation, rotation, and scale. Missing
    /// components or sub-objects fall back to the schema identity defaults — empty
    /// (UUID-only) sub-objects inherit their prototype's value, which for the
    /// geometry library is identity.
    func resolvedLocalTransform() -> (
        translation: (x: Double, y: Double, z: Double),
        rotation: (x: Double, y: Double, z: Double, w: Double),
        scale: (x: Double, y: Double, z: Double)
    ) {
        let transform = transformComponent

        let translation = transform?["local_position_double"]?.objectValue.map { sub in
            (
                x: sub["x"]?.doubleValue ?? RCP3TransformDefaults.translation.x,
                y: sub["y"]?.doubleValue ?? RCP3TransformDefaults.translation.y,
                z: sub["z"]?.doubleValue ?? RCP3TransformDefaults.translation.z
            )
        } ?? RCP3TransformDefaults.translation

        let rotation = transform?["local_rotation"]?.objectValue.map { sub in
            (
                x: sub["x"]?.doubleValue ?? RCP3TransformDefaults.rotation.x,
                y: sub["y"]?.doubleValue ?? RCP3TransformDefaults.rotation.y,
                z: sub["z"]?.doubleValue ?? RCP3TransformDefaults.rotation.z,
                w: sub["w"]?.doubleValue ?? RCP3TransformDefaults.rotation.w
            )
        } ?? RCP3TransformDefaults.rotation

        let scale = transform?["local_scale"]?.objectValue.map { sub in
            (
                x: sub["x"]?.doubleValue ?? RCP3TransformDefaults.scale.x,
                y: sub["y"]?.doubleValue ?? RCP3TransformDefaults.scale.y,
                z: sub["z"]?.doubleValue ?? RCP3TransformDefaults.scale.z
            )
        } ?? RCP3TransformDefaults.scale

        return (translation, rotation, scale)
    }
}
