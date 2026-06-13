import Foundation
import simd

/// The Swift-side entity that a running script graph mutates.
///
/// RCP 3 runs a no-code script graph as JavaScript: the entity and its components
/// are exposed to the script, gesture events drive handlers, and the script mutates
/// the entity's transform. `RuntimeEntityState` is the authored side of that bridge
/// — the live transform the JS host reads and writes through `entity.transform`.
///
/// It is a reference type held by the `@MainActor`-isolated `ScriptJSHost` (a
/// `JSContext` is not `Sendable`), so mutations from JS are visible to the caller
/// after each `dispatch`. Values use `Double` to match the format's number model
/// (the `.tm_*` grammar stores all numbers as doubles).
@MainActor
public final class RuntimeEntityState {
    /// Local translation. Starts at the origin.
    public var translation: SIMD3<Double>
    /// Local rotation as a unit quaternion `(ix, iy, iz, r)`. Starts identity.
    public var rotation: simd_quatd
    /// Local scale. Starts at unit scale.
    public var scale: SIMD3<Double>

    public init(
        translation: SIMD3<Double> = .zero,
        rotation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
        scale: SIMD3<Double> = SIMD3(1, 1, 1)
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }
}
