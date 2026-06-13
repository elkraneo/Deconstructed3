import Testing
import Foundation
import TMFormat
@testable import RCP3Document

@Suite struct RCP3SceneGraphTests {
    // MARK: References capture (optional — tests no-op cleanly when absent)

    /// Ascend from this file until the workspace `references/` dir is found.
    static func referencesDir() -> URL? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let refs = dir.appending(path: "references")
            if FileManager.default.fileExists(atPath: refs.appending(path: "Empty/Empty.realitycomposerpro").path) {
                return refs
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static var emptyBundleURL: URL? {
        referencesDir()?.appending(path: "Empty/Empty.realitycomposerpro")
    }

    // MARK: Real capture — the `box` child resolves to `.box`

    @Test func emptyCaptureResolvesBoxPrimitive() throws {
        guard let url = Self.emptyBundleURL else { return } // capture not present
        let bundle = try RCP3Bundle.open(url)
        let scene = bundle.sceneGraph

        #expect(scene.name == "world")
        // World root is structural (no geometry prototype).
        #expect(scene.primitiveKind == .none)

        let box = try #require(scene.children.first { $0.name == "box" })
        // Resolved from its `__prototype_uuid` → core.lib/geometry/box.tm_entity.
        #expect(box.primitiveKind == .box)
        // Selection id matches the entity projection's id (cross-pane picking).
        #expect(box.id == bundle.entity.children.first { $0.name == "box" }?.id)
    }

    @Test func emptyCaptureTransformsDefaultSanely() throws {
        guard let url = Self.emptyBundleURL else { return }
        let scene = try RCP3Bundle.open(url).sceneGraph
        let box = try #require(scene.children.first { $0.name == "box" })

        // The box's transform sub-objects are UUID-only (inherit identity), so the
        // resolved transform must be identity, not garbage.
        #expect(box.translation == (0, 0, 0))
        #expect(box.rotation == (0, 0, 0, 1))
        #expect(box.scale == (1, 1, 1))
    }

    @Test func geometryPrototypesMapAllThreeKinds() throws {
        guard let url = Self.emptyBundleURL else { return }
        let kinds = RCP3Bundle.geometryPrototypeKinds(in: url)

        // The canonical box prototype uuid (also asserted in RCP3BundleTests).
        #expect(kinds["05fe482f-df58-c56a-fa4b-ddf77c8dcfa0"] == .box)
        // All three library prototypes resolve.
        #expect(Set(kinds.values) == [.box, .plane, .sphere])
    }

    // MARK: Synthesized bundle — transform values are read through

    @Test func readsAuthoredTransformValues() throws {
        let world = """
        __type: "tm_entity"
        name: "world"
        children: [
          {
            __uuid: "11111111-1111-1111-1111-111111111111"
            __prototype_type: "tm_entity"
            __prototype_uuid: "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0"
            name: "box"
            components__instantiated: [
              {
                __type: "tm_transform_component"
                local_position_double: { x: 1 y: 2 z: 3 }
                local_rotation: { x: 0.70105737447738648 y: 0.092295952141284943 z: -0.092295952141284943 w: 0.70105737447738648 }
                local_scale: { x: 2 y: 2 z: 2 }
              }
            ]
          }
        ]
        """
        let root = try #require(try TM.parse(world).objectValue)
        // No core.lib here → kind resolves to .none, but transforms must read through.
        let node = RCP3Bundle.node(from: root, geometryKinds: [:])
        let box = try #require(node.children.first)

        #expect(box.translation == (1, 2, 3))
        #expect(box.rotation.w == 0.70105737447738648)
        #expect(box.rotation.x == 0.70105737447738648)
        #expect(box.scale == (2, 2, 2))
    }

    @Test func missingTransformComponentFallsBackToIdentity() throws {
        let world = """
        __type: "tm_entity"
        name: "world"
        children: [ { name: "bare" } ]
        """
        let root = try #require(try TM.parse(world).objectValue)
        let node = RCP3Bundle.node(from: root, geometryKinds: [:])
        let bare = try #require(node.children.first)

        #expect(bare.primitiveKind == .none)
        #expect(bare.translation == (0, 0, 0))
        #expect(bare.rotation == (0, 0, 0, 1))
        #expect(bare.scale == (1, 1, 1))
    }
}
