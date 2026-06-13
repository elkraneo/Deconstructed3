import Foundation
import TMFormat

extension RCP3Bundle {
    /// A render-oriented projection of the bundle's scene: the root entity tree
    /// with each node's local transform resolved and its `primitiveKind` resolved
    /// against the bundle's built-in geometry library.
    ///
    /// Primitive resolution reads `core.lib/geometry/{box,plane,sphere}.tm_entity`,
    /// keys each prototype by its `__uuid`, and matches an entity's
    /// `__prototype_uuid` against that map. When `core.lib` is absent (e.g. a
    /// synthesized test bundle), the prototype filename convention provides a
    /// best-effort fallback and unmatched entities resolve to `.none`.
    public var sceneGraph: RCP3SceneNode {
        sceneGraph(for: root)
    }

    /// Projects an arbitrary `root` entity tree into a scene graph using *this*
    /// bundle's built-in geometry library for primitive resolution.
    ///
    /// This is the live-edit seam: an editing session can rename/restructure the
    /// root in memory (without saving) and re-derive the viewport scene by passing
    /// the edited root here — the `core.lib` resolution still keys off this
    /// bundle's `url`, so prototype instances keep their primitive kinds.
    public func sceneGraph(for root: TMObject) -> RCP3SceneNode {
        let kinds = Self.geometryPrototypeKinds(in: url)
        return Self.node(from: root, geometryKinds: kinds)
    }

    /// Builds `[prototypeUUID: RCP3PrimitiveKind]` from the geometry prototypes in
    /// `core.lib/geometry/`. The kind is taken from the prototype's
    /// `tm_model_component.mesh_resource.__type` (`tm_box_mesh_resource` etc.),
    /// falling back to the filename when the component can't be read.
    static func geometryPrototypeKinds(in bundleURL: URL) -> [String: RCP3PrimitiveKind] {
        let geometryDir = bundleURL.appending(path: "core.lib/geometry")
        var map: [String: RCP3PrimitiveKind] = [:]

        let files: [(name: String, kind: RCP3PrimitiveKind)] = [
            ("box.tm_entity", .box),
            ("plane.tm_entity", .plane),
            ("sphere.tm_entity", .sphere),
        ]
        for file in files {
            let fileURL = geometryDir.appending(path: file.name)
            guard
                let text = try? String(contentsOf: fileURL, encoding: .utf8),
                let entity = try? TM.parse(text).objectValue,
                let uuid = entity.uuid
            else { continue }
            map[uuid] = meshKind(of: entity) ?? file.kind
        }
        return map
    }

    /// Resolves a geometry prototype entity's primitive kind from its model
    /// component's mesh-resource type.
    private static func meshKind(of entity: TMObject) -> RCP3PrimitiveKind? {
        guard let components = entity["components"]?.arrayValue else { return nil }
        for value in components {
            guard
                let component = value.objectValue,
                component.type == "tm_model_component",
                let meshType = component["mesh_resource"]?.objectValue?.type
            else { continue }
            switch meshType {
            case "tm_box_mesh_resource": return .box
            case "tm_plane_mesh_resource": return .plane
            case "tm_sphere_mesh_resource": return .sphere
            default: continue
            }
        }
        return nil
    }

    /// Projects a `tm_entity` object (and its subtree) into an `RCP3SceneNode`.
    static func node(
        from object: TMObject,
        geometryKinds: [String: RCP3PrimitiveKind]
    ) -> RCP3SceneNode {
        let transform = object.resolvedLocalTransform()

        let kind: RCP3PrimitiveKind = {
            guard let prototype = object.prototypeUUID else { return .none }
            return geometryKinds[prototype] ?? .none
        }()

        let children = (object["children"]?.arrayValue ?? []).compactMap { value -> RCP3SceneNode? in
            value.objectValue.map { node(from: $0, geometryKinds: geometryKinds) }
        }

        return RCP3SceneNode(
            id: RCP3Entity(object).id,
            name: object.name ?? "",
            translation: transform.translation,
            rotation: transform.rotation,
            scale: transform.scale,
            primitiveKind: kind,
            children: children
        )
    }
}
