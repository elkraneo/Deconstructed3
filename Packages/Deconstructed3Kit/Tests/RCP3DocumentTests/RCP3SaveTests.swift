import Testing
import Foundation
import TMFormat
import RCP3Document

@Suite struct RCP3SaveTests {
    // MARK: References capture (optional, copied — never mutated in place)

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

    // MARK: Synthesized minimal bundle (capture-independent)

    /// A self-contained minimal bundle dir in `temporaryDirectory`: a directory
    /// holding a `world.tm_entity` written from `source`. The caller cleans up.
    static func makeTempBundle(world source: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-save-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 0-byte sentinel, mirroring real bundles.
        FileManager.default.createFile(atPath: dir.appending(path: "project.rcp").path, contents: Data())
        try source.write(to: dir.appending(path: "world.tm_entity"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Copies the real `Empty` bundle into `temporaryDirectory` for write tests, so
    /// the source capture under `references/` is never mutated. Returns `nil` if the
    /// capture is absent. The caller cleans up.
    static func copyEmptyBundleToTemp() throws -> URL? {
        guard let src = emptyBundleURL else { return nil }
        let dst = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-copy-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    static let minimalWorld = """
    __type: "tm_entity"
    __uuid: "4ed8c306-8868-275b-5a64-c75d82d13db5"
    name: "world"
    children: [
      {
        __uuid: "9cc43bcd-448b-c524-ef9a-16696d9feb7a"
        __prototype_type: "tm_entity"
        __prototype_uuid: "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0"
        name: "box"
      }
    ]
    __asset_uuid: "5512ba55-a43b-8e72-7c89-2650f503b325"
    """

    // MARK: Synthesized-bundle save round-trip

    @Test func savesRenamedWorldAndReopens() throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }

        // open → edit → save
        let bundle = try RCP3Bundle.open(dir)
        #expect(bundle.entity.name == "world")
        let renamed = bundle.root.settingName("renamed-world")
        try bundle.save(renamed)

        // REOPEN from disk and assert the change persisted + structure intact.
        let reopened = try RCP3Bundle.open(dir)
        #expect(reopened.entity.name == "renamed-world")
        let box = try #require(reopened.entity.children.first)
        #expect(box.name == "box")
        #expect(box.prototypeUUID == "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0")
        // Untargeted root fields survive.
        #expect(reopened.root.uuid == "4ed8c306-8868-275b-5a64-c75d82d13db5")
        #expect(reopened.root["__asset_uuid"]?.stringValue == "5512ba55-a43b-8e72-7c89-2650f503b325")
    }

    @Test func savesNestedChildNameAndReopens() throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try RCP3Bundle.open(dir)
        let mutated = try bundle.root.setting(.string("crate"), at: "children[0].name")
        try bundle.save(mutated)

        let reopened = try RCP3Bundle.open(dir)
        #expect(reopened.entity.name == "world")              // parent unchanged
        #expect(reopened.entity.children.first?.name == "crate") // child renamed
        #expect(reopened.entity.children.first?.prototypeUUID == "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0")
    }

    @Test func saveWithoutArgumentPersistsCurrentRoot() throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }

        let opened = try RCP3Bundle.open(dir)
        let edited = try opened.save(opened.root.settingName("v2")) // returns a new bundle value
        try edited.save()                                           // persist its own root

        #expect(try RCP3Bundle.open(dir).entity.name == "v2")
    }

    // MARK: RCP3Editor session

    @Test func editorTracksChangesSavesAndReverts() throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }

        var editor = try RCP3Editor.open(dir)
        #expect(!editor.hasUnsavedChanges)

        let changed = editor.apply { $0.set(.string("edited"), forKey: "name") }
        #expect(changed)
        #expect(editor.hasUnsavedChanges)
        #expect(editor.entity.name == "edited")

        try editor.save()
        #expect(!editor.hasUnsavedChanges)
        #expect(try RCP3Bundle.open(dir).entity.name == "edited")

        // revert returns to last-saved state.
        editor.root = editor.root.settingName("scratch")
        #expect(editor.hasUnsavedChanges)
        editor.revert()
        #expect(!editor.hasUnsavedChanges)
        #expect(editor.entity.name == "edited")
    }

    @Test func editorPathMutationPersists() throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }

        var editor = try RCP3Editor.open(dir)
        editor.root = try editor.root.setting(.string("widget"), at: "children[0].name")
        try editor.save()

        #expect(try RCP3Editor.open(dir).entity.children.first?.name == "widget")
    }

    // MARK: Real-capture copy (when present) — never mutates the source

    @Test func savesRealBundleCopyAndReopens() throws {
        guard let dir = try Self.copyEmptyBundleToTemp() else { return } // capture absent
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = try RCP3Bundle.open(dir)
        let originalChildCount = original.entity.children.count
        let originalTypeCount = original.typeCount

        // Rename the world entity, save, reopen.
        try original.save(original.root.settingName("world-renamed"))
        let reopened = try RCP3Bundle.open(dir)

        #expect(reopened.entity.name == "world-renamed")
        // Structurally intact: same children, same sibling type index untouched.
        #expect(reopened.entity.children.count == originalChildCount)
        #expect(reopened.typeCount == originalTypeCount)
        // The whole tree (minus the rename) round-trips.
        #expect(reopened.root.removing(key: "name") == original.root.removing(key: "name"))
    }

    // MARK: Create a Script Graph asset (the browser "+" action)

    @Test func createScriptGraphAssetWritesEnumerableEmptyGraph() throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try RCP3Bundle.open(dir)

        // No assets to start.
        #expect(bundle.scriptGraphAssets().isEmpty)

        let asset = try bundle.createScriptGraphAsset()

        // The file exists, enumerates, and its id matches.
        let onDisk = bundle.scriptGraphAssets()
        #expect(onDisk.map(\.id) == [asset.id])
        #expect(asset.name == "Script Graph")
        #expect(FileManager.default.fileExists(
            atPath: dir.appending(path: "Script Graph.tm_script_graph").path
        ))

        // It loads as an empty, well-formed graph (no nodes), keyed by the asset id.
        let graph = try #require(bundle.scriptGraph(assetID: asset.id))
        #expect(graph.nodes.isEmpty)

        // A second create de-duplicates the filename.
        let second = try bundle.createScriptGraphAsset()
        #expect(second.name == "Script Graph 1")
        #expect(bundle.scriptGraphAssets().count == 2)
    }

    @Test func renameScriptGraphAssetMovesFileAndPreservesID() throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try RCP3Bundle.open(dir)

        let asset = try bundle.createScriptGraphAsset()       // "Script Graph"
        let renamed = try bundle.renameScriptGraphAsset(id: asset.id, to: "Spin")

        // Same root uuid (so a component assignment survives), new filename on disk.
        #expect(renamed.id == asset.id)
        #expect(renamed.name == "Spin")
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Script Graph.tm_script_graph").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Spin.tm_script_graph").path))
        #expect(bundle.scriptGraphAssets().map(\.id) == [asset.id])
        #expect(bundle.scriptGraph(assetID: asset.id) != nil)

        // Renaming onto an existing name de-duplicates.
        let other = try bundle.createScriptGraphAsset(named: "Other")
        let collided = try bundle.renameScriptGraphAsset(id: other.id, to: "Spin")
        #expect(collided.name == "Spin 1")

        // Unknown id throws notFound.
        #expect(throws: RCP3ScriptGraphAssetError.notFound(id: "nope")) {
            try bundle.renameScriptGraphAsset(id: "nope", to: "X")
        }
    }
}
