import CoreGraphics
import RCP3Document
import RealityKit
import RealityKitStageView
import Testing
import simd

@testable import RCP3Viewport

/// Verifies the `.tm_*` → RealityKit reconstruction and the uuid ⇄ StageView
/// prim-path identity bridge that backs viewport selection.
@MainActor
@Suite struct RCP3EntityBuilderTests {
    // A small box-under-world scene with stable uuids.
    private func makeScene() -> RCP3SceneNode {
        let box = RCP3SceneNode(
            id: "box-uuid",
            name: "box",
            translation: (1, 2, 3),
            rotation: (0, 0, 0, 1),
            scale: (2, 2, 2),
            primitiveKind: .box,
            children: []
        )
        return RCP3SceneNode(
            id: "world-uuid",
            name: "world",
            translation: (0, 0, 0),
            rotation: (0, 0, 0, 1),
            scale: (1, 1, 1),
            primitiveKind: .none,
            children: [box]
        )
    }

    /// `build.root` is the anonymous wrapper (mirrors `Entity(contentsOf:)`); our
    /// `world` node is its single child, and `box` is `world`'s child.
    private func sceneRoot(of build: RCP3EntityBuilder.Build) throws -> Entity {
        try #require(build.root.children.first)
    }

    @Test func wrapperHoldsNamedSceneRoot() throws {
        let build = RCP3EntityBuilder.build(from: makeScene())
        // The wrapper itself is anonymous so the provider treats `world` as a prim.
        #expect(build.root.name.isEmpty)
        let world = try sceneRoot(of: build)
        #expect(world.name == "world-uuid")
        let box = try #require(world.children.first)
        #expect(box.name == "box-uuid")
    }

    @Test func boxNodeBecomesModelEntityWithCollision() throws {
        let build = RCP3EntityBuilder.build(from: makeScene())
        let world = try sceneRoot(of: build)
        let box = try #require(world.children.first)
        // ModelEntity carries a ModelComponent; structural world root does not.
        #expect(box.components.has(ModelComponent.self))
        #expect(!world.components.has(ModelComponent.self))
        // generateCollisionShapes is what makes the entity pickable.
        #expect(box.components.has(CollisionComponent.self))
    }

    @Test func transformIsAppliedFromNode() throws {
        let build = RCP3EntityBuilder.build(from: makeScene())
        let world = try sceneRoot(of: build)
        let box = try #require(world.children.first)
        #expect(box.transform.translation == SIMD3<Float>(1, 2, 3))
        #expect(box.transform.scale == SIMD3<Float>(2, 2, 2))
    }

    @Test func primPathMirrorsStageViewNameWalk() throws {
        // StageView builds prim paths by slash-joining entity names from the root's
        // children down. Our paths must match so selection round-trips.
        let build = RCP3EntityBuilder.build(from: makeScene())
        #expect(build.primPathByNodeID["world-uuid"] == "/world-uuid")
        #expect(build.primPathByNodeID["box-uuid"] == "/world-uuid/box-uuid")

        // The component we set must equal the same string the provider's mapping
        // would compute from entity names.
        let world = try sceneRoot(of: build)
        let box = try #require(world.children.first)
        let component = try #require(box.components[USDPrimPathComponent.self])
        #expect(component.primPath == "/world-uuid/box-uuid")
    }

    @Test func providerMappingAgreesWithOurPrimPaths() {
        // Inject into a real provider and confirm StageView's name-based mapping
        // resolves our prim paths back to the same entities we registered.
        let build = RCP3EntityBuilder.build(from: makeScene())
        let provider = RealityKitProvider()
        provider.setModel(build.root, metersPerUnit: 1, isZUp: false)

        let boxEntity = provider.entity(for: "/world-uuid/box-uuid")
        #expect(boxEntity?.name == "box-uuid")

        // And the reverse: the entity resolves to our prim path.
        if let boxEntity {
            #expect(provider.primPath(for: boxEntity) == "/world-uuid/box-uuid")
        }
    }

    @Test func entityByNodeIDMapsUUIDsToTheirEntities() throws {
        // The node→entity map backs Play mode's live transform drive: a node uuid
        // must resolve to the entity carrying that uuid as its name. The entities
        // returned are the very ones in `build.root`, so mutating them moves the
        // reconstructed tree the provider holds.
        let build = RCP3EntityBuilder.build(from: makeScene())
        let world = try #require(build.entityByNodeID["world-uuid"])
        let box = try #require(build.entityByNodeID["box-uuid"])
        #expect(world.name == "world-uuid")
        #expect(box.name == "box-uuid")
        // The map points at the live tree, not copies.
        let liveWorld = try sceneRoot(of: build)
        #expect(world === liveWorld)
        #expect(box === liveWorld.children.first)
        // An unknown uuid is absent (so `applyLiveTransform` is a no-op for it).
        #expect(build.entityByNodeID["nope"] == nil)
    }

    @Test func authoredTransformSnapshotRestoresEntityOnStop() throws {
        // Play snapshots the entity's authored pose, the run mutates it live, and
        // Stop restores from the snapshot. This exercises that round-trip at the
        // entity level (the snapshot is a `Transform` captured before mutation, then
        // re-applied after), which is the contract `stopPlaying`/`applyLiveTransform`
        // rely on: restoring the snapshot returns the entity exactly to authored.
        let build = RCP3EntityBuilder.build(from: makeScene())
        let box = try #require(build.entityByNodeID["box-uuid"])

        // Authored pose (from makeScene): translation (1,2,3), scale (2,2,2).
        let authored = box.transform
        #expect(authored.translation == SIMD3<Float>(1, 2, 3))
        #expect(authored.scale == SIMD3<Float>(2, 2, 2))

        // A live run moves it somewhere else (a drag would do this).
        box.transform = Transform(
            scale: SIMD3(5, 5, 5),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: SIMD3(10, 20, 30)
        )
        #expect(box.transform.translation == SIMD3<Float>(10, 20, 30))

        // Stop restores the snapshot exactly.
        box.transform = authored
        #expect(box.transform.translation == SIMD3<Float>(1, 2, 3))
        #expect(box.transform.scale == SIMD3<Float>(2, 2, 2))
    }

    /// Approximate SIMD3<Double> equality (quaternion·vector introduces tiny float
    /// rounding once we leave the identity camera).
    private func approxEqual(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tol: Double = 1e-5) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.z - b.z) < tol
    }

    @Test func sceneDeltaMapsScreenDragToSceneSpace() {
        // Front-on (identity) camera at the canonical distance (4) reduces to the old
        // mapping: screen +x → scene +x; screen +y (down) → scene −y (drag up = up).
        let id = simd_quatf(angle: 0, axis: [0, 1, 0])
        let right = RCP3ViewportView.sceneDelta(for: CGSize(width: 200, height: 0), cameraRotation: id, distance: 4)
        #expect(approxEqual(right, SIMD3(1, 0, 0)))
        let down = RCP3ViewportView.sceneDelta(for: CGSize(width: 0, height: 200), cameraRotation: id, distance: 4)
        #expect(approxEqual(down, SIMD3(0, -1, 0)))

        // Distance scales magnitude: zoomed out (distance 8) → twice the move.
        let far = RCP3ViewportView.sceneDelta(for: CGSize(width: 200, height: 0), cameraRotation: id, distance: 8)
        #expect(approxEqual(far, SIMD3(2, 0, 0)))
    }

    /// The 3D-correctness fix: the drag is projected onto the *camera's* view plane,
    /// so the world axes it moves along follow the orbit (they are NOT a fixed front-on
    /// world x/y). Orbiting 90° about Y turns a horizontal drag into motion along world
    /// −Z, while a vertical drag stays world-up.
    @Test func sceneDeltaFollowsCameraOrbit() {
        let yaw = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]) // camera orbited 90° about Y
        let right = RCP3ViewportView.sceneDelta(for: CGSize(width: 200, height: 0), cameraRotation: yaw, distance: 4)
        #expect(approxEqual(right, SIMD3(0, 0, -1)))
        let up = RCP3ViewportView.sceneDelta(for: CGSize(width: 0, height: 200), cameraRotation: yaw, distance: 4)
        #expect(approxEqual(up, SIMD3(0, -1, 0)))
    }

    @Test func applicableTransformIsAccepted() {
        // A finite transform with positive scale is safe to apply.
        #expect(RCP3ViewportView.isApplicable(
            translation: SIMD3(1, 2, 3),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            scale: SIMD3(2, 2, 2)
        ))
    }

    @Test func nonFiniteTranslationIsRejected() {
        #expect(!RCP3ViewportView.isApplicable(
            translation: SIMD3(.nan, 0, 0),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            scale: SIMD3(1, 1, 1)
        ))
        #expect(!RCP3ViewportView.isApplicable(
            translation: SIMD3(.infinity, 0, 0),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            scale: SIMD3(1, 1, 1)
        ))
    }

    @Test func nonFiniteRotationIsRejected() {
        #expect(!RCP3ViewportView.isApplicable(
            translation: .zero,
            rotation: simd_quatf(ix: .nan, iy: 0, iz: 0, r: 1),
            scale: SIMD3(1, 1, 1)
        ))
    }

    @Test func nonFiniteScaleIsRejected() {
        #expect(!RCP3ViewportView.isApplicable(
            translation: .zero,
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            scale: SIMD3(.nan, 1, 1)
        ))
    }

    @Test func zeroOrNegativeScaleIsRejected() {
        // A zero scale collapses the entity to a point (vanishes); a negative scale
        // mirrors it. Both are rejected so a bad runtime value can't hide the box.
        #expect(!RCP3ViewportView.isApplicable(
            translation: .zero,
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            scale: SIMD3(0, 1, 1)
        ))
        #expect(!RCP3ViewportView.isApplicable(
            translation: .zero,
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            scale: SIMD3(1, -1, 1)
        ))
    }

    @Test func nodeIDDecodesFromLeafOfPrimPath() {
        #expect(RCP3EntityBuilder.nodeID(forPrimPath: "/world-uuid/box-uuid") == "box-uuid")
        #expect(RCP3EntityBuilder.nodeID(forPrimPath: "/world-uuid") == "world-uuid")
        #expect(RCP3EntityBuilder.nodeID(forPrimPath: nil) == nil)
        #expect(RCP3EntityBuilder.nodeID(forPrimPath: "") == nil)
    }

    @Test func boundsAreFrameableForAScene() {
        let build = RCP3EntityBuilder.build(from: makeScene())
        #expect(build.bounds.isFrameable)
    }

    @Test func emptyStructuralSceneGetsFallbackBounds() {
        let structural = RCP3SceneNode(
            id: "world-uuid",
            name: "world",
            translation: (0, 0, 0),
            rotation: (0, 0, 0, 1),
            scale: (1, 1, 1),
            primitiveKind: .none,
            children: []
        )
        let build = RCP3EntityBuilder.build(from: structural)
        // No geometry → padded to a small frameable cube so the camera/grid work.
        #expect(build.bounds.isFrameable)
    }
}
