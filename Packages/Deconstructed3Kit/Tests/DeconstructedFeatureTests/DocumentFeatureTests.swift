import ComposableArchitecture
import Foundation
import RCP3Document
import Testing

@testable import DeconstructedFeature

@MainActor
@Suite struct DocumentFeatureTests {
    // MARK: Fixtures (never mutate references/ — always a temp copy or synth)

    /// Ascend from this file until the workspace `references/` dir is found.
    static func referencesDir() -> URL? {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let refs = dir.appending(path: "references")
            if FileManager.default.fileExists(
                atPath: refs.appending(path: "Empty/Empty.realitycomposerpro").path
            ) {
                return refs
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Copies the real `Empty` bundle into a temp dir so the source capture is
    /// never mutated. Returns `nil` if the capture is absent.
    static func copyEmptyBundleToTemp() throws -> URL? {
        guard let src = referencesDir()?.appending(path: "Empty/Empty.realitycomposerpro") else {
            return nil
        }
        let dst = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-feature-\(UUID().uuidString).realitycomposerpro")
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

    /// A self-contained minimal bundle dir in the temp directory.
    static func makeTempBundle(world source: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rcp3-feature-\(UUID().uuidString).realitycomposerpro")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appending(path: "project.rcp").path, contents: Data())
        try source.write(to: dir.appending(path: "world.tm_entity"), atomically: true, encoding: .utf8)
        return dir
    }

    /// The workspace-local `Random` capture (a box with a `re_scripting_component`
    /// and a `*.tm_script_graph` asset), if present. No-ops cleanly when absent.
    static func randomBundleURL() -> URL? {
        guard let refs = referencesDir() else { return nil }
        let bundle = refs.appending(path: "Random/Random.realitycomposerpro")
        return FileManager.default.fileExists(
            atPath: bundle.appending(path: "world.tm_entity").path
        ) ? bundle : nil
    }

    // MARK: open a script graph as an asset (sidebar → center editor)

    @Test func opensScriptGraphAsset() async throws {
        guard let dir = Self.randomBundleURL() else { return } // capture absent

        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        } withDependencies: {
            $0.documentClient = .live
        }

        let opened = try RCP3Editor.open(dir)
        await store.send(.openTapped(dir))
        await store.receive(\.opened.success) {
            $0.editor = opened
            $0.selection = opened.entity.id
        }

        // The bundle exposes its script graphs as browsable assets.
        let asset = try #require(store.state.scriptGraphAssets.first)

        // Opening one sets `openScriptGraphID` and resolves `openScriptGraph`.
        await store.send(.scriptGraphOpened(asset.id)) {
            $0.openScriptGraphID = asset.id
        }
        #expect(store.state.openScriptGraph != nil)
        #expect(store.state.openScriptGraph?.nodes.isEmpty == false)

        // Clearing it resets the open graph.
        await store.send(.scriptGraphOpened(nil)) {
            $0.openScriptGraphID = nil
        }
        #expect(store.state.openScriptGraph == nil)
    }

    // MARK: open → select → nameEdited → saveTapped → reopen

    @Test func openEditSaveRoundTripsToDisk() async throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        } withDependencies: {
            $0.documentClient = .live
        }

        // OPEN
        let opened = try RCP3Editor.open(dir)
        await store.send(.openTapped(dir))
        await store.receive(\.opened.success) {
            $0.editor = opened
            $0.selection = opened.entity.id // root "world" is auto-selected
        }

        // SELECT the box child
        let boxID = try #require(opened.entity.children.first?.id)
        await store.send(.selected(boxID)) {
            $0.selection = boxID
        }

        // EDIT the selected entity's name
        var renamedEditor = opened
        renamedEditor.renameEntity(id: boxID, to: "crate")
        await store.send(.nameEdited("crate")) {
            $0.editor = renamedEditor
        }
        #expect(store.state.hasUnsavedChanges)
        #expect(store.state.selectedEntity?.name == "crate")

        // SAVE
        var savedEditor = renamedEditor
        try savedEditor.save()
        await store.send(.saveTapped)
        await store.receive(\.saved.success) {
            $0.editor = savedEditor
        }
        #expect(!store.state.hasUnsavedChanges)

        // REOPEN from disk: the rename persisted, structure intact.
        let reopened = try RCP3Editor.open(dir)
        #expect(reopened.entity.name == "world")
        #expect(reopened.entity.children.first?.name == "crate")
        #expect(
            reopened.entity.children.first?.prototypeUUID == "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0"
        )
    }

    @Test func renamingRootReflectsInSceneGraph() async throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        } withDependencies: {
            $0.documentClient = .live
        }

        let opened = try RCP3Editor.open(dir)
        await store.send(.openTapped(dir))
        await store.receive(\.opened.success) {
            $0.editor = opened
            $0.selection = opened.entity.id
        }

        // The live scene graph (viewport feed) reflects the unsaved rename.
        var renamedEditor = opened
        renamedEditor.renameEntity(id: opened.entity.id, to: "stage")
        await store.send(.nameEdited("stage")) {
            $0.editor = renamedEditor
        }
        #expect(store.state.sceneGraph?.name == "stage")
    }

    // MARK: open failure surfaces an error, no editor

    @Test func openFailureSurfacesError() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "does-not-exist-\(UUID().uuidString).realitycomposerpro")

        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        } withDependencies: {
            $0.documentClient = .live
        }

        await store.send(.openTapped(missing))
        // RCP3Bundle.LoadError.notADirectory → deterministic description.
        await store.receive(\.opened.failure) {
            $0.editor = nil
            $0.selection = nil
            $0.errorMessage = "notADirectory"
        }
        #expect(store.state.editor == nil)
    }

    // MARK: saveTapped is a no-op when there are no unsaved changes

    @Test func saveTappedNoOpWhenClean() async throws {
        let dir = try Self.makeTempBundle(world: Self.minimalWorld)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        } withDependencies: {
            $0.documentClient = .live
        }

        let opened = try RCP3Editor.open(dir)
        await store.send(.openTapped(dir))
        await store.receive(\.opened.success) {
            $0.editor = opened
            $0.selection = opened.entity.id
        }

        // No edits → save does nothing (no `.saved` action, no state change).
        await store.send(.saveTapped)
    }

    // MARK: real-capture copy (when present)

    @Test func realEmptyCaptureRoundTrips() async throws {
        guard let dir = try Self.copyEmptyBundleToTemp() else { return } // capture absent
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        } withDependencies: {
            $0.documentClient = .live
        }

        let opened = try RCP3Editor.open(dir)
        await store.send(.openTapped(dir))
        await store.receive(\.opened.success) {
            $0.editor = opened
            $0.selection = opened.entity.id
        }

        // Rename the root world entity, save, reopen.
        var renamedEditor = opened
        renamedEditor.renameEntity(id: opened.entity.id, to: "world-renamed")
        await store.send(.nameEdited("world-renamed")) {
            $0.editor = renamedEditor
        }

        var savedEditor = renamedEditor
        try savedEditor.save()
        await store.send(.saveTapped)
        await store.receive(\.saved.success) {
            $0.editor = savedEditor
        }

        let reopened = try RCP3Editor.open(dir)
        #expect(reopened.entity.name == "world-renamed")
        #expect(reopened.entity.children.count == opened.entity.children.count)
    }
}
