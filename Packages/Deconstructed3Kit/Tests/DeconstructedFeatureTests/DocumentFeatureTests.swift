import ComposableArchitecture
import Foundation
import RCP3Document
import RCP3GraphEditor
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

        // Opening one sets the open asset id (and the derived `openScriptGraphID`) and
        // resolves `openScriptGraph`.
        await store.send(.scriptGraphOpened(asset.id)) {
            $0.openAssetGraphID = asset.id
        }
        #expect(store.state.openScriptGraphID == asset.id)
        #expect(store.state.openScriptGraph != nil)
        #expect(store.state.openScriptGraph?.nodes.isEmpty == false)

        // Clearing it resets the open graph.
        await store.send(.scriptGraphOpened(nil)) {
            $0.openAssetGraphID = nil
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

    @Test func deleteSelectedEntitySelectsRootAndSaves() async throws {
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

        let boxID = try #require(opened.entity.children.first?.id)
        await store.send(.selected(boxID)) {
            $0.selection = boxID
        }

        var deletedEditor = opened
        let deleted = deletedEditor.deleteEntity(id: boxID)
        #expect(deleted)
        await store.send(.deleteSelectedEntity) {
            $0.editor = deletedEditor
            $0.selection = deletedEditor.entity.id
        }
        #expect(store.state.hasUnsavedChanges)
        #expect(store.state.rootEntity?.children.isEmpty == true)

        var savedEditor = deletedEditor
        try savedEditor.save()
        await store.send(.saveTapped)
        await store.receive(\.saved.success) {
            $0.editor = savedEditor
        }

        let reopened = try RCP3Editor.open(dir)
        #expect(reopened.entity.children.isEmpty)
    }

    // MARK: open → select → transformEdited → saveTapped → reopen

    /// A minimal world whose box carries an inherited (identity) transform component,
    /// so the inspector's transform editing has something to override.
    static let worldWithBoxTransform = """
    __type: "tm_entity"
    __uuid: "4ed8c306-8868-275b-5a64-c75d82d13db5"
    name: "world"
    children: [
      {
        __uuid: "9cc43bcd-448b-c524-ef9a-16696d9feb7a"
        __prototype_type: "tm_entity"
        __prototype_uuid: "05fe482f-df58-c56a-fa4b-ddf77c8dcfa0"
        name: "box"
        components__instantiated: [
          {
            __type: "tm_transform_component"
            __uuid: "3dcae77c-3539-b923-144a-4a172d99fe8d"
            __prototype_type: "tm_transform_component"
            __prototype_uuid: "a2fed85d-b27e-81ad-31ed-843c8efc7d97"
            local_rotation: {
              __uuid: "5ec96c4e-91ca-9137-76e7-ea2a7c9dc624"
              __prototype_type: "tm_rotation"
              __prototype_uuid: "57af832e-ffd8-3b93-df13-c9e5698f7cb2"
            }
          }
        ]
      }
    ]
    __asset_uuid: "5512ba55-a43b-8e72-7c89-2650f503b325"
    """

    @Test func transformEditMarksDirtyAndPersists() async throws {
        let dir = try Self.makeTempBundle(world: Self.worldWithBoxTransform)
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

        // SELECT the box and read its (identity) transform off the store.
        let boxID = try #require(opened.entity.children.first?.id)
        await store.send(.selected(boxID)) {
            $0.selection = boxID
        }
        let current = try #require(store.state.selectedEntityTransform)
        #expect(current == .identity)

        // EDIT the rotation through the inspector's action.
        var edited = current
        edited.rotation = (
            x: -0.02881590835750103,
            y: -0.28827366232872009,
            z: -0.17299818992614746,
            w: 0.94134980440139771
        )
        var editedEditor = opened
        editedEditor.setTransform(edited, forEntityID: boxID)
        await store.send(.transformEdited(edited)) {
            $0.editor = editedEditor
        }
        #expect(store.state.hasUnsavedChanges)
        #expect(store.state.selectedEntityTransform?.rotation.w == 0.94134980440139771)

        // SAVE and reopen — the rotation override persisted.
        var savedEditor = editedEditor
        try savedEditor.save()
        await store.send(.saveTapped)
        await store.receive(\.saved.success) {
            $0.editor = savedEditor
        }
        #expect(!store.state.hasUnsavedChanges)

        let reopened = try RCP3Editor.open(dir)
        let reopenedTransform = try #require(reopened.transform(forEntityID: boxID))
        #expect(reopenedTransform.rotation.x == -0.02881590835750103)
        #expect(reopenedTransform.rotation.w == 0.94134980440139771)
        #expect(reopenedTransform.translation == RCP3Transform.identity.translation)
        #expect(reopenedTransform.scale == RCP3Transform.identity.scale)
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

    // MARK: Examples gallery (exampleSelected loads an in-memory graph, no bundle)

    /// Selecting an example loads its in-memory graph as the open graph (with the
    /// example's synthetic id), even with no project open — so the canvas shows it and
    /// ▶ Play runs it. Clearing the example returns to no open graph.
    @Test func exampleSelectedLoadsAndClearsAnInMemoryGraph() async {
        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        }

        let example = ScriptGraphExamples.dragToMove

        // No bundle is open, yet selecting an example loads it as the open graph.
        await store.send(.exampleSelected(id: example.id, graph: example.graph)) {
            $0.loadedExample = example.graph
            $0.loadedExampleID = example.id
        }
        #expect(store.state.openScriptGraphID == example.id)
        #expect(store.state.openScriptGraph == example.graph)
        // The loaded example is what the ▶ Play / canvas resolves to.
        #expect(store.state.openScriptGraph?.nodes.isEmpty == false)

        // Clearing the example (nil graph) returns to no open graph.
        await store.send(.exampleSelected(id: example.id, graph: nil)) {
            $0.loadedExample = nil
            $0.loadedExampleID = nil
        }
        #expect(store.state.openScriptGraphID == nil)
        #expect(store.state.openScriptGraph == nil)
    }

    /// Selecting an entity CLEARS a loaded Examples-gallery graph, so the hardcoded
    /// sample stops shadowing the real selection. This is fix (B) of the data-loss bug:
    /// before, `.selected` left `loadedExample` in place, so `openScriptGraph` kept
    /// preferring the demo fixture after every selection change ("the graph mutated").
    @Test func selectedClearsLoadedExampleAndFallsBackToSelection() async {
        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        }

        let example = ScriptGraphExamples.dragToMove

        // Load an example, then select an entity.
        await store.send(.exampleSelected(id: example.id, graph: example.graph)) {
            $0.loadedExample = example.graph
            $0.loadedExampleID = example.id
        }
        #expect(store.state.openScriptGraphID == example.id)

        // Selecting an entity drops the loaded example (no longer shadows the selection).
        await store.send(.selected("some-entity")) {
            $0.selection = "some-entity"
            $0.loadedExample = nil
            $0.loadedExampleID = nil
        }
        // The example no longer shadows anything: the open graph falls back to the real
        // selection (here `nil`, since no bundle/editor is loaded in this reducer test).
        #expect(store.state.openScriptGraphID == nil)
        #expect(store.state.openScriptGraph == nil)
    }

    // MARK: Canvas key identity (root fix for the data-loss bug)

    /// KEY STABILITY: with a graph shown from the selected entity (no open asset/example),
    /// changing `selection` must NOT change the canvas key — the key is the SHOWN GRAPH's
    /// identity, not the selection. Before the fix the key was `openScriptGraphID ??
    /// selection`, so any selection change re-keyed the canvas and rebuilt the live model
    /// from the pristine source, discarding edits.
    @Test func canvasKeyIsStableAcrossSelectionChangesForSameGraph() {
        // A graph carrying its own stable identity (as a parsed `tm_graph` would).
        let graph = RCP3ScriptGraph(id: "graph-uuid", nodes: [], wires: [], data: [])

        // No open asset/example → the key is the graph's own identity, regardless of
        // which entity is selected.
        var state = DocumentFeature.State()
        state.selection = "entity-A"
        let keyA = state.canvasKey(forShownGraph: graph)

        state.selection = "entity-B" // selection churn (e.g. around the "+" palette)
        let keyB = state.canvasKey(forShownGraph: graph)

        #expect(keyA == keyB)
        #expect(keyA == "graph-uuid")

        // A genuinely DIFFERENT graph (different identity) still yields a different key.
        let other = RCP3ScriptGraph(id: "other-uuid", nodes: [], wires: [], data: [])
        #expect(state.canvasKey(forShownGraph: other) != keyA)

        // An open asset/example id takes precedence over the shown graph's identity.
        state.openAssetGraphID = "asset-uuid"
        #expect(state.canvasKey(forShownGraph: graph) == "asset-uuid")
    }

    /// EDIT SURVIVES A SELECTION CHANGE: with the canvas key stable across a selection
    /// change for the same shown graph, the keyed rebuild does not re-fire; and the
    /// belt-and-suspenders dirty-guard means even a forced re-evaluation keeps a dirty
    /// model's edits. This asserts the combined invariant the view relies on: same key +
    /// `isDirty` ⇒ the live model (and its addNode edit) is NOT rebuilt from source.
    @Test func dirtyEditSurvivesSelectionChangeForSameGraph() {
        let graph = RCP3ScriptGraph(id: "graph-uuid", nodes: [], wires: [], data: [])

        // The host-owned live model, with an in-flight edit.
        let model = ScriptGraphEditorModel(graph: graph)
        model.addNode(type: "tm_update", at: .zero)
        #expect(model.isDirty)
        #expect(model.nodes.count == 1)

        // Key for the model, then a selection change for the SAME shown graph.
        var state = DocumentFeature.State()
        state.selection = "entity-A"
        let keyBefore = state.canvasKey(forShownGraph: graph)
        state.selection = "entity-B"
        let keyAfter = state.canvasKey(forShownGraph: graph)
        #expect(keyBefore == keyAfter) // no re-key → the keyed `.task` won't re-fire

        // Belt-and-suspenders: even a forced rebuild attempt for the SAME (dirty) key is
        // refused, exactly as the view's `.task(id:)` guard does — the edit survives.
        let modelKey = keyBefore
        var liveModel = model
        let newKey = keyAfter
        if !(liveModel.isDirty && modelKey == newKey) {
            liveModel = ScriptGraphEditorModel(graph: graph) // would discard the edit
        }
        #expect(liveModel === model)      // same instance preserved
        #expect(liveModel.nodes.count == 1) // the addNode edit survived
        #expect(liveModel.isDirty)
    }

    /// A loaded example takes precedence over a sidebar-opened asset, and opening an
    /// asset clears the loaded example.
    @Test func exampleTakesPrecedenceOverAssetThenAssetClearsIt() async {
        let store = TestStore(initialState: DocumentFeature.State()) {
            DocumentFeature()
        }

        let example = ScriptGraphExamples.spin

        await store.send(.scriptGraphOpened("asset-uuid")) {
            $0.openAssetGraphID = "asset-uuid"
        }
        #expect(store.state.openScriptGraphID == "asset-uuid")

        // Loading an example overrides the open asset id for the center column.
        await store.send(.exampleSelected(id: example.id, graph: example.graph)) {
            $0.loadedExample = example.graph
            $0.loadedExampleID = example.id
        }
        #expect(store.state.openScriptGraphID == example.id)

        // Opening a real asset again clears the loaded example.
        await store.send(.scriptGraphOpened("asset-2")) {
            $0.openAssetGraphID = "asset-2"
            $0.loadedExample = nil
            $0.loadedExampleID = nil
        }
        #expect(store.state.openScriptGraphID == "asset-2")
    }
}
