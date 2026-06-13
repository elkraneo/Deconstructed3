import RCP3Document
import RealityKit
import SwiftUI
import simd

/// The 3D viewport — option 1: reconstruct **public** RealityKit entities directly
/// from the parsed RCP 3 `.tm_*` scene graph. No USD, no `USDStageComponent`, no
/// private/commercial frameworks: every `RCP3SceneNode` with a `primitiveKind`
/// becomes a `ModelEntity` with a generated mesh; structural nodes become bare
/// `Entity`s; the resolved local transform is applied per node.
struct SceneViewportView: View {
    /// The scene to materialize. A new graph rebuilds the hierarchy.
    let sceneGraph: RCP3SceneNode?
    /// The currently-selected entity id (`RCP3SceneNode.id` == `RCP3Entity.id`).
    @Binding var selection: RCP3Entity.ID?

    /// uuid → reconstructed entity, for selection highlight and picking.
    @State private var entitiesByID: [String: Entity] = [:]
    /// The container holding the reconstructed scene (rebuilt on graph change).
    @State private var sceneRoot = Entity()

    var body: some View {
        Group {
            if let sceneGraph {
                RealityView { content in
                    content.add(makeRig())
                    rebuild(from: sceneGraph)
                    content.add(sceneRoot)
                } update: { _ in
                    applySelectionHighlight()
                }
                .onChange(of: sceneGraph) { _, newValue in
                    rebuild(from: newValue)
                }
                .gesture(
                    SpatialTapGesture()
                        .targetedToAnyEntity()
                        .onEnded { value in
                            selection = pickedID(for: value.entity)
                        }
                )
                .ignoresSafeArea()
            } else {
                ContentUnavailableView("No scene", systemImage: "cube.transparent")
            }
        }
    }

    // MARK: Reconstruction

    /// Replaces `sceneRoot`'s children with entities reconstructed from `node`,
    /// and rebuilds the id→entity map.
    private func rebuild(from node: RCP3SceneNode) {
        sceneRoot.children.removeAll()
        var map: [String: Entity] = [:]
        sceneRoot.addChild(makeEntity(from: node, into: &map))
        entitiesByID = map
        applySelectionHighlight()
    }

    /// Builds a RealityKit `Entity` for a scene node (recursively), registering it
    /// in `map` by its stable id for picking and highlight.
    private func makeEntity(from node: RCP3SceneNode, into map: inout [String: Entity]) -> Entity {
        let entity: Entity
        if let mesh = Self.mesh(for: node.primitiveKind) {
            let model = ModelEntity(mesh: mesh, materials: [Self.material(selected: false)])
            model.generateCollisionShapes(recursive: false) // enables tap-picking
            entity = model
        } else {
            entity = Entity()
        }

        entity.name = node.id
        entity.transform = Self.transform(of: node)
        map[node.id] = entity

        for child in node.children {
            entity.addChild(makeEntity(from: child, into: &map))
        }
        return entity
    }

    /// Generates the public RealityKit mesh for a primitive kind. The library
    /// prototypes are unit-sized (box 1×1×1, plane 1×1 in XZ, sphere default), so
    /// the node's resolved scale carries any sizing.
    private static func mesh(for kind: RCP3PrimitiveKind) -> MeshResource? {
        switch kind {
        case .box: return .generateBox(size: 1)
        case .sphere: return .generateSphere(radius: 0.5)
        case .plane: return .generatePlane(width: 1, depth: 1)
        case .none: return nil
        }
    }

    private static func material(selected: Bool) -> SimpleMaterial {
        SimpleMaterial(
            color: selected ? .systemYellow : .init(white: 0.8, alpha: 1.0),
            roughness: 0.4,
            isMetallic: false
        )
    }

    /// Maps a node's `Double` transform tuples to a public `Transform`.
    private static func transform(of node: RCP3SceneNode) -> Transform {
        let t = node.translation, r = node.rotation, s = node.scale
        return Transform(
            scale: SIMD3(Float(s.x), Float(s.y), Float(s.z)),
            rotation: simd_quatf(
                ix: Float(r.x), iy: Float(r.y), iz: Float(r.z), r: Float(r.w)
            ),
            translation: SIMD3(Float(t.x), Float(t.y), Float(t.z))
        )
    }

    // MARK: Selection

    /// Resolves a tapped entity (or its nearest named ancestor) to a scene id.
    private func pickedID(for entity: Entity) -> RCP3Entity.ID? {
        var current: Entity? = entity
        while let e = current {
            if !e.name.isEmpty, entitiesByID[e.name] != nil { return e.name }
            current = e.parent
        }
        return nil
    }

    /// Tints the selected primitive yellow and resets the rest.
    private func applySelectionHighlight() {
        for (id, entity) in entitiesByID {
            guard let model = entity as? ModelEntity else { continue }
            model.model?.materials = [Self.material(selected: id == selection)]
        }
    }

    // MARK: Rig (camera + light + ground grid)

    /// A camera, key light, and ground grid so a reconstructed scene is visible
    /// without relying solely on `RealityView` defaults.
    private func makeRig() -> Entity {
        let rig = Entity()
        rig.name = "__rig"

        let camera = PerspectiveCamera()
        camera.look(at: .zero, from: SIMD3(1.5, 1.5, 2.5), relativeTo: nil)
        rig.addChild(camera)

        let light = DirectionalLight()
        light.light.intensity = 4000
        light.look(at: .zero, from: SIMD3(2, 4, 3), relativeTo: nil)
        rig.addChild(light)

        rig.addChild(makeGroundGrid())
        return rig
    }

    /// A thin gridded ground plane for spatial reference.
    private func makeGroundGrid() -> Entity {
        let plane = ModelEntity(
            mesh: .generatePlane(width: 10, depth: 10),
            materials: [SimpleMaterial(color: .init(white: 0.25, alpha: 1.0), isMetallic: false)]
        )
        plane.name = "__ground"
        return plane
    }
}
