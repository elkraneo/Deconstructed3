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

        /// The script graph attached to the selected entity (via its
        /// `re_scripting_component`), or `nil` when there is none. Resolved against
        /// the live editor's root + bundle, so it follows the current selection.
        public var selectedScriptGraph: RCP3ScriptGraph? {
            guard let editor, let selection else { return nil }
            return editor.scriptGraph(forEntityID: selection)
        }

        /// The browsable `*.tm_script_graph` assets in the open bundle (sorted by
        /// name), empty when no project is open. The sidebar lists these so a user can
        /// open a graph editor directly.
        public var scriptGraphAssets: [RCP3ScriptGraphAsset] { editor?.scriptGraphAssets() ?? [] }

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
