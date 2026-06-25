import ComposableArchitecture
import Foundation
import RCP3Document

/// The open → edit → save feature for an RCP 3 bundle.
///
/// State holds an optional `RCP3Editor` editing session. Disk I/O (open, save) is
/// routed through the controllable `documentClient` dependency; the in-between
/// edits (selection, rename) are pure value mutations on the editor the feature
/// holds in state, so the derived projections — the `RCP3Entity` tree, the
/// `RCP3SceneNode` viewport graph, and `hasUnsavedChanges` — all fall out of the
/// editor for free and stay consistent with the live (possibly unsaved) root.
@Reducer
public struct DocumentFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        /// The active editing session, or `nil` until a bundle is opened.
        public var editor: RCP3Editor?
        /// Bumped whenever the bundle's asset FILES change (create / rename) — the
        /// observation token that invalidates `scriptGraphAssets` (a disk scan, which
        /// editing the in-memory editor doesn't otherwise touch), so the Project
        /// Browser reflects new/renamed graphs.
        public var assetsRevision = 0
        /// The selected entity's `RCP3Entity.id` (uuid), bridged to tree + viewport.
        public var selection: RCP3Entity.ID?
        /// The id (asset root `__uuid`) of the script-graph asset opened directly from
        /// the sidebar, or `nil` when none is open. When set, the center graph view
        /// shows this asset instead of the selected entity's graph.
        public var openAssetGraphID: String?
        /// An in-memory **example** graph loaded from the Examples gallery (no backing
        /// `.tm_script_graph` asset), or `nil` when none is loaded. When set it takes
        /// precedence over a sidebar-opened asset and the selection, so the canvas shows
        /// the example and ▶ Play runs it on the box.
        public var loadedExample: RCP3ScriptGraph?
        /// The synthetic open-graph key for the loaded example (its example `id`), used
        /// to key the canvas/Play identity. `nil` when no example is loaded.
        public var loadedExampleID: String?
        /// Last error surfaced to the UI (open/save failure), if any.
        public var errorMessage: String?

        public init(
            editor: RCP3Editor? = nil,
            selection: RCP3Entity.ID? = nil,
            openScriptGraphID: String? = nil,
            errorMessage: String? = nil
        ) {
            self.editor = editor
            self.selection = selection
            self.openAssetGraphID = openScriptGraphID
            self.errorMessage = errorMessage
        }

        /// The id keying the open graph in the center column: the loaded example's id
        /// takes precedence over a sidebar-opened asset id. `nil` when neither is open.
        /// (The view keys the canvas / Play identity on this.)
        public var openScriptGraphID: String? {
            loadedExampleID ?? openAssetGraphID
        }

        // MARK: Derived projections (single source of truth: `editor`)

        /// The display entity tree of the live (possibly unsaved) root.
        public var rootEntity: RCP3Entity? { editor?.entity }

        /// The render projection of the live root, reflecting unsaved edits.
        public var sceneGraph: RCP3SceneNode? { editor?.sceneGraph }

        /// `true` when the session has edits not yet written to disk.
        public var hasUnsavedChanges: Bool { editor?.hasUnsavedChanges ?? false }

        /// The bundle file name, for the window/tree title.
        public var bundleName: String? { editor?.bundle.url.lastPathComponent }

        /// The currently selected display entity, found in the live tree.
        public var selectedEntity: RCP3Entity? {
            guard let rootEntity, let selection else { return nil }
            return Self.find(selection, in: rootEntity)
        }

        /// The local transform of the currently selected entity, read from the live
        /// editor (inherited/omitted components fall back to the identity defaults).
        /// `nil` when nothing is selected or the entity has no `tm_transform_component`.
        public var selectedEntityTransform: RCP3Transform? {
            guard let editor, let selection else { return nil }
            return editor.transform(forEntityID: selection)
        }

        /// The script graph attached to the selected entity (via its
        /// `re_scripting_component`), or `nil` when there is none. Resolved against
        /// the live editor's root + bundle, so it follows the current selection.
        public var selectedScriptGraph: RCP3ScriptGraph? {
            guard let editor, let selection else { return nil }
            return editor.scriptGraph(forEntityID: selection)
        }

        /// Whether the selected entity carries a `re_scripting_component` — drives the
        /// inspector's Scripting Component section + its script-graph picker.
        public var selectedEntityHasScriptingComponent: Bool {
            guard let editor, let selection else { return false }
            return editor.hasScriptingComponent(entityID: selection)
        }

        /// The script-graph asset root `__uuid` assigned to the selected entity's
        /// scripting component, or `nil` for `(none)`. The picker's current value.
        public var assignedScriptGraphAssetID: String? {
            guard let editor, let selection else { return nil }
            return editor.assignedScriptGraphAssetID(entityID: selection)
        }

        /// The live input for a canonical Play/Simulate run: the scene, every scripted
        /// entity's graph, and a preview fallback (open/selected graph). Read live so
        /// the running preview reflects graphs added/assigned during Play (the host
        /// re-keys the Play view on `.signature`). Depends on `assetsRevision` so an
        /// assignment that scans disk re-derives.
        public var canonicalPlayScene: CanonicalPlayScene {
            _ = assetsRevision
            return CanonicalPlayScene(
                scene: sceneGraph,
                scripts: editor?.scriptedEntities() ?? [],
                previewGraph: openScriptGraph ?? selectedScriptGraph,
                previewEntityID: selection
            )
        }

        /// The browsable `*.tm_script_graph` assets in the open bundle (sorted by
        /// name), empty when no project is open. The sidebar lists these so a user can
        /// open a graph editor directly.
        public var scriptGraphAssets: [RCP3ScriptGraphAsset] {
            _ = assetsRevision // establish an observation dependency on file changes
            return editor?.scriptGraphAssets() ?? []
        }

        /// The graph currently open in the center column: the loaded example graph (if
        /// any) takes precedence; otherwise the asset opened from the sidebar (by
        /// `openAssetGraphID`), resolved against the live editor's bundle. `nil` when
        /// none is open. The ▶ Play affordance runs this on the box.
        public var openScriptGraph: RCP3ScriptGraph? {
            if let loadedExample { return loadedExample }
            return openAssetGraphID.flatMap { editor?.scriptGraph(assetID: $0) }
        }

        private static func find(_ id: RCP3Entity.ID, in entity: RCP3Entity) -> RCP3Entity? {
            if entity.id == id { return entity }
            for child in entity.children {
                if let found = find(id, in: child) { return found }
            }
            return nil
        }
    }

    public enum Action: Sendable {
        /// User invoked "Open…" (the view presents the file picker and feeds back a URL).
        case openTapped(URL)
        /// `documentClient.open` finished (success or failure).
        case opened(Result<RCP3Editor, DocumentError>)
        /// Tree/viewport selection changed to this entity id (or cleared).
        case selected(RCP3Entity.ID?)
        /// A script-graph asset was opened directly from the sidebar (or cleared with
        /// `nil`). The center switches to the graph editor for this asset.
        case scriptGraphOpened(String?)
        /// An in-memory **example** graph was chosen from the Examples gallery. Loads it
        /// into the center as the open graph (with a synthetic id) so the canvas shows
        /// it and the existing ▶ Play runs it on the box. `nil` clears the loaded
        /// example, returning to the asset/selection graph.
        case exampleSelected(id: String, graph: RCP3ScriptGraph?)
        /// The inspector's name field edited the selected entity to this string.
        case nameEdited(String)
        /// The inspector's transform fields edited the selected entity's local
        /// transform. Mutates the live `tm_transform_component` and marks dirty.
        case transformEdited(RCP3Transform)
        /// User duplicated the selected entity beside the original.
        case duplicateSelectedEntity
        /// User deleted the selected entity from its parent.
        case deleteSelectedEntity
        /// User added a built-in primitive under the selected entity.
        case addPrimitive(RCP3PrimitiveKind)
        /// User created a new Script Graph asset (browser "+"). Writes a new
        /// `*.tm_script_graph` to the bundle and opens it in the editor.
        case newScriptGraphTapped
        /// User renamed a script-graph asset (by root `__uuid`) in the Project Browser.
        case renameScriptGraph(id: String, to: String)
        /// User added a component (by `__type`) to the selected entity, via the
        /// shared Add Component picker. Today only `re_scripting_component` is wired.
        case addComponent(String)
        /// User assigned a script-graph asset (by root `__uuid`) to the selected
        /// entity's scripting component, or cleared it with `nil` ("(none)").
        case assignScriptGraph(String?)
        /// User invoked Save (toolbar / ⌘S).
        case saveTapped
        /// `documentClient.save` finished (success or failure).
        case saved(Result<RCP3Editor, DocumentError>)
    }

    @Dependency(\.documentClient) var documentClient

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case let .openTapped(url):
                return .run { send in
                    await send(
                        .opened(Result { try documentClient.open(url) }.mapError(DocumentError.init))
                    )
                }

            case let .opened(.success(editor)):
                state.editor = editor
                state.selection = editor.entity.id
                // A fresh bundle has its own assets — drop any graph open from the last
                // (asset or example).
                state.openAssetGraphID = nil
                state.loadedExample = nil
                state.loadedExampleID = nil
                state.errorMessage = nil
                return .none

            case let .opened(.failure(error)):
                state.editor = nil
                state.selection = nil
                state.openAssetGraphID = nil
                state.loadedExample = nil
                state.loadedExampleID = nil
                state.errorMessage = error.message
                return .none

            case let .selected(id):
                state.selection = id
                // Selecting an entity leaves a loaded Examples-gallery graph behind, so a
                // hardcoded sample can no longer SHADOW the selected entity's real graph
                // (mirrors what `.scriptGraphOpened(non-nil)` / open already do). Without
                // this, `openScriptGraph` keeps PREFERRING `loadedExample`, reverting the
                // canvas to the demo fixture after any selection change.
                state.loadedExample = nil
                state.loadedExampleID = nil
                return .none

            case let .scriptGraphOpened(id):
                state.openAssetGraphID = id
                // Opening a real asset clears any loaded example so the asset shows.
                if id != nil {
                    state.loadedExample = nil
                    state.loadedExampleID = nil
                }
                return .none

            case let .exampleSelected(id, graph):
                // Load (or clear) an in-memory example graph. When loading, it takes
                // precedence over a sidebar asset (`openScriptGraph` prefers it), so the
                // canvas shows it and ▶ Play runs it on the box.
                state.loadedExample = graph
                state.loadedExampleID = graph == nil ? nil : id
                return .none

            case let .nameEdited(newName):
                guard let id = state.selection else { return .none }
                state.editor?.renameEntity(id: id, to: newName)
                return .none

            case let .transformEdited(transform):
                guard let id = state.selection else { return .none }
                state.editor?.setTransform(transform, forEntityID: id)
                return .none

            case .duplicateSelectedEntity:
                guard let id = state.selection else { return .none }
                @Dependency(\.uuid) var uuid
                let makeUUID = { uuid().uuidString.lowercased() }
                if let duplicatedID = state.editor?.duplicateEntity(id: id, makeUUID: makeUUID) {
                    state.selection = duplicatedID
                    state.loadedExample = nil
                    state.loadedExampleID = nil
                }
                return .none

            case .deleteSelectedEntity:
                guard let id = state.selection else { return .none }
                @Dependency(\.uuid) var uuid
                let makeUUID = { uuid().uuidString.lowercased() }
                if state.editor?.deleteEntity(id: id, makeUUID: makeUUID) == true {
                    state.selection = state.editor?.entity.id
                    state.loadedExample = nil
                    state.loadedExampleID = nil
                }
                return .none

            case let .addPrimitive(kind):
                guard let parentID = state.selection else { return .none }
                @Dependency(\.uuid) var uuid
                let makeUUID = { uuid().uuidString.lowercased() }
                if let addedID = state.editor?.addPrimitive(kind, parentID: parentID, makeUUID: makeUUID) {
                    state.selection = addedID
                    state.loadedExample = nil
                    state.loadedExampleID = nil
                }
                return .none

            case .newScriptGraphTapped:
                guard let editor = state.editor else { return .none }
                @Dependency(\.uuid) var uuid
                let makeUUID = { uuid().uuidString.lowercased() }
                guard let asset = try? editor.createScriptGraphAsset(makeUUID: makeUUID) else {
                    return .none
                }
                // Open the new asset; bump the token so the Project Browser re-scans.
                state.assetsRevision += 1
                state.openAssetGraphID = asset.id
                state.loadedExample = nil
                state.loadedExampleID = nil
                return .none

            case let .renameScriptGraph(id, newName):
                guard let renamed = try? state.editor?.renameScriptGraphAsset(id: id, to: newName) else {
                    return .none
                }
                // Filename changed on disk but no in-memory editor state did — bump the
                // token so the browser list reflects the new name.
                state.assetsRevision += 1
                _ = renamed
                return .none

            case let .addComponent(componentType):
                guard let id = state.selection else { return .none }
                @Dependency(\.uuid) var uuid
                let makeUUID = { uuid().uuidString.lowercased() }
                // Only the scripting component is wired today; the picker lists it
                // under Gameplay (more components slot in as they're supported).
                if componentType == "re_scripting_component" {
                    state.editor?.addScriptingComponent(toEntityID: id, makeUUID: makeUUID)
                    state.assetsRevision += 1
                }
                return .none

            case let .assignScriptGraph(assetRootUUID):
                guard let id = state.selection else { return .none }
                state.editor?.assignScriptGraph(toEntityID: id, assetRootUUID: assetRootUUID)
                // Bump so the live play scene (and any preview) re-derives the scripts.
                state.assetsRevision += 1
                return .none

            case .saveTapped:
                guard let editor = state.editor, editor.hasUnsavedChanges else { return .none }
                return .run { send in
                    await send(
                        .saved(Result { try documentClient.save(editor) }.mapError(DocumentError.init))
                    )
                }

            case let .saved(.success(editor)):
                state.editor = editor
                state.errorMessage = nil
                return .none

            case let .saved(.failure(error)):
                state.errorMessage = error.message
                return .none
            }
        }
    }
}

/// A `Sendable`, `Equatable` projection of an open/save failure, so the feature's
/// `Result` actions can be compared in `TestStore` without the underlying error
/// type needing `Equatable`.
public struct DocumentError: Error, Equatable, Sendable {
    public let message: String
    public init(_ error: any Error) {
        self.message = String(describing: error)
    }
}
