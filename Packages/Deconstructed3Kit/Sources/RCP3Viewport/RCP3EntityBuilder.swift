import RCP3Document
import RealityKit
import RealityKitStageView
import simd

/// Builds public RealityKit entities from a `.tm_*`-reconstructed `RCP3SceneNode`
/// tree, in the shape StageView's `RealityKitProvider` expects.
///
/// RCP 3 renders `.tm_*` entities directly — there is no USD here. We therefore
/// reuse StageView's *RealityKit* viewport (camera, grid, IBL, selection outline)
/// and bypass its `Entity(contentsOf:)`/USD-import lane by injecting an
/// externally-built hierarchy through `RealityKitProvider.setModel(_:metersPerUnit:isZUp:)`.
///
/// Identity bridging: StageView keys selection on **"prim path" strings** that it
/// reconstructs by walking entity names (`buildPrimPathMapping`). To make those
/// strings round-trip to *our* RCP 3 uuids, every entity is named with its node
/// `id` (the entity uuid) and additionally tagged with `USDPrimPathComponent`.
/// The resulting prim path of a node is the slash-joined chain of ancestor uuids,
/// e.g. `/<worldUUID>/<boxUUID>`. The leaf component is always the node's uuid, so
/// a viewport pick decodes back to our uuid by taking the path's last component,
/// and a selection push looks up the full path via `primPath(forNodeID:)`.
public enum RCP3EntityBuilder {
    /// The product of reconstructing a scene graph into RealityKit entities.
    public struct Build {
        /// The single root entity to hand to `RealityKitProvider.setModel`.
        public let root: Entity
        /// Authored scene bounds for `RealityKitProvider.setExternalSceneBounds`.
        public let bounds: SceneBounds
        /// `node.id` (our uuid) → StageView prim-path string, for pushing a
        /// host selection into the viewport (`provider.setSelection`).
        public let primPathByNodeID: [String: String]
        /// `node.id` (our uuid) → the reconstructed RealityKit `Entity`, for driving
        /// a single entity's transform live (Play mode `applyLiveTransform`). This is
        /// the same entity injected into the provider via `setModel(root:)`, so it can
        /// be mutated in place; the provider observes nothing about transforms.
        public let entityByNodeID: [String: Entity]

        public init(
            root: Entity,
            bounds: SceneBounds,
            primPathByNodeID: [String: String],
            entityByNodeID: [String: Entity]
        ) {
            self.root = root
            self.bounds = bounds
            self.primPathByNodeID = primPathByNodeID
            self.entityByNodeID = entityByNodeID
        }
    }

    /// Reconstructs `node` (and its subtree) into RealityKit entities.
    ///
    /// FRICTION: `RealityKitProvider` was written for `Entity(contentsOf:)`, whose
    /// result is an **anonymous wrapper** whose children are the real prims.
    /// `refreshPrimPathMapping` therefore skips the entity you hand to `setModel`
    /// (empty-name root) and only walks its children. To make *our* top node
    /// (`world`) a first-class, selectable prim — and to make the provider's
    /// name-walked prim paths match the `USDPrimPathComponent`s we register — we
    /// hand `setModel` an unnamed container whose single child is our scene root.
    @MainActor
    public static func build(from node: RCP3SceneNode) -> Build {
        var primPathByNodeID: [String: String] = [:]
        var entityByNodeID: [String: Entity] = [:]
        let sceneRoot = makeEntity(
            from: node,
            parentPrimPath: "",
            primPathByNodeID: &primPathByNodeID,
            entityByNodeID: &entityByNodeID
        )

        // Anonymous wrapper: matches the shape `Entity(contentsOf:)` produces, so
        // the provider's prim-path mapping treats `sceneRoot` (our `world`) as the
        // first prim rather than discarding it.
        let container = Entity()
        container.addChild(sceneRoot)

        let bounds = sceneBounds(of: container)
        return Build(
            root: container,
            bounds: bounds,
            primPathByNodeID: primPathByNodeID,
            entityByNodeID: entityByNodeID
        )
    }

    // MARK: - Reconstruction

    /// Builds a RealityKit `Entity` for a scene node (recursively).
    ///
    /// `entity.name` is set to the node uuid so StageView's name-based prim-path
    /// reconstruction yields uuid-keyed paths; `USDPrimPathComponent` is set with
    /// the same full path the provider would compute, keeping the identity we read
    /// on pick identical to the one StageView stores.
    @MainActor
    private static func makeEntity(
        from node: RCP3SceneNode,
        parentPrimPath: String,
        primPathByNodeID: inout [String: String],
        entityByNodeID: inout [String: Entity]
    ) -> Entity {
        let entity: Entity
        if let mesh = mesh(for: node.primitiveKind) {
            let model = ModelEntity(mesh: mesh, materials: [defaultMaterial])
            // Enables raycast/collision-based picking inside the viewport.
            model.generateCollisionShapes(recursive: false)
            entity = model
        } else {
            entity = Entity()
        }

        entity.name = node.id
        entity.transform = transform(of: node)

        // Mirror RealityKitProvider.buildPrimPathMapping's path construction so the
        // prim path we register matches what StageView will key selection on.
        let primPath = parentPrimPath.isEmpty ? "/\(node.id)" : "\(parentPrimPath)/\(node.id)"
        entity.components.set(USDPrimPathComponent(primPath: primPath))
        primPathByNodeID[node.id] = primPath
        entityByNodeID[node.id] = entity

        for child in node.children {
            entity.addChild(
                makeEntity(
                    from: child,
                    parentPrimPath: primPath,
                    primPathByNodeID: &primPathByNodeID,
                    entityByNodeID: &entityByNodeID
                )
            )
        }
        return entity
    }

    /// Generates the public RealityKit mesh for a primitive kind. The `core.lib`
    /// geometry prototypes are unit-sized (box 1×1×1, plane 1×1 in XZ, sphere
    /// radius 0.5), so the node's resolved scale carries any sizing.
    private static func mesh(for kind: RCP3PrimitiveKind) -> MeshResource? {
        switch kind {
        case .box: return .generateBox(size: 1)
        case .sphere: return .generateSphere(radius: 0.5)
        case .plane: return .generatePlane(width: 1, depth: 1)
        case .none: return nil
        }
    }

    /// A neutral PBR-ish surface. StageView draws its own selection outline, so the
    /// builder no longer tints the selected entity (that was the hand-rolled
    /// viewport's job).
    private static var defaultMaterial: SimpleMaterial {
        SimpleMaterial(color: .init(white: 0.8, alpha: 1.0), roughness: 0.4, isMetallic: false)
    }

    /// Maps a node's `Double` transform tuples to a public RealityKit `Transform`.
    private static func transform(of node: RCP3SceneNode) -> Transform {
        let t = node.translation, r = node.rotation, s = node.scale
        return Transform(
            scale: SIMD3(Float(s.x), Float(s.y), Float(s.z)),
            rotation: simd_quatf(ix: Float(r.x), iy: Float(r.y), iz: Float(r.z), r: Float(r.w)),
            translation: SIMD3(Float(t.x), Float(t.y), Float(t.z))
        )
    }

    // MARK: - Bounds

    /// Computes a world-space `SceneBounds` over every entity in the reconstructed
    /// tree. StageView requires host-supplied bounds for camera auto-frame and grid
    /// sizing (`restoreExternallySuppliedSceneBounds`), so an empty/degenerate scene
    /// is padded to a small frameable cube to keep the viewport navigable.
    @MainActor
    static func sceneBounds(of root: Entity) -> SceneBounds {
        var minPoint = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var hasGeometry = false

        func accumulate(_ entity: Entity) {
            if entity.components.has(ModelComponent.self) {
                let box = entity.visualBounds(relativeTo: nil)
                let extents = box.max - box.min
                if extents.x.isFinite, extents.y.isFinite, extents.z.isFinite {
                    minPoint = simd_min(minPoint, box.min)
                    maxPoint = simd_max(maxPoint, box.max)
                    hasGeometry = true
                }
            }
            for child in entity.children { accumulate(child) }
        }
        accumulate(root)

        guard hasGeometry else {
            // Degenerate scene (only structural nodes): give the camera something
            // frameable so the grid renders and orbit works.
            return SceneBounds(min: SIMD3(repeating: -0.5), max: SIMD3(repeating: 0.5))
        }
        let bounds = SceneBounds(min: minPoint, max: maxPoint)
        return bounds.isFrameable
            ? bounds
            : SceneBounds(min: SIMD3(repeating: -0.5), max: SIMD3(repeating: 0.5))
    }

    /// Decodes a StageView prim-path string back to our node uuid.
    ///
    /// Our prim paths are slash-joined uuid chains, so the selected node's uuid is
    /// the path's last component. Returns `nil` for an empty/`nil` path.
    public static func nodeID(forPrimPath primPath: String?) -> String? {
        guard let primPath, !primPath.isEmpty else { return nil }
        return primPath.split(separator: "/").last.map(String.init)
    }
}
