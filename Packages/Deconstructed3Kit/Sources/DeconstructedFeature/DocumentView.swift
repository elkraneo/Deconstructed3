import AppKit
import ComposableArchitecture
import RCP3Document
import RCP3GraphEditor
import RCP3Viewport
import SwiftUI

/// The Deconstructed 3 main window: a 3-pane `NavigationSplitView` driven entirely
/// by `StoreOf<DocumentFeature>`.
///
/// - **Sidebar:** the entity tree, selection bound to the store.
/// - **Center:** `RCP3ViewportView`, fed the store's live `sceneGraph` and a
///   selection binding — a rename re-derives the graph, so the viewport entity
///   name updates without a reload. While **Play** is active the center is
///   swapped INLINE for the app-supplied canonical play view (Apple's real
///   `RealityKitScripting` runtime).
/// - **Detail:** the *editable* inspector, whose Name field drives `nameEdited`.
///
/// Save lives on the toolbar (and ⌘S), enabled only while `hasUnsavedChanges`.
///
/// Generic over `CanonicalPlay` — the concrete canonical-play view the **app**
/// injects via a `@ViewBuilder` closure. The tested library never names that view
/// (or the binary `RealityKitScripting` framework it needs); previews and tests use
/// the `EmptyView`-returning default. No `AnyView`.
public struct DocumentView<CanonicalPlay: View>: View {
    @Bindable var store: StoreOf<DocumentFeature>

    /// Which view fills the center column. Pure presentation state, so it lives in
    /// the view rather than the reducer. `.graph` is only reachable while the
    /// selected entity carries a script graph.
    enum CenterMode: String, CaseIterable, Hashable {
        case viewport, graph
        var title: String { self == .viewport ? "Viewport" : "Graph" }
        var symbol: String { self == .viewport ? "cube" : "point.3.connected.trianglepath.dotted" }
    }
    @State private var centerMode: CenterMode = .viewport

    /// The live, *editable* model behind the script-graph canvas, owned here (not by
    /// the canvas) so Save can reach the edits and write them back to the
    /// `.tm_script_graph`. Re-created whenever the shown graph changes (keyed below
    /// on the open asset / selection). `nil` until a graph is shown.
    @State private var graphModel: ScriptGraphEditorModel?
    /// The identity of the graph `graphModel` was built for, so we only rebuild it
    /// when the shown graph actually changes (not on every body re-evaluation).
    @State private var graphModelKey: String?

    /// Whether the Run / Preview sheet is presented. Pure presentation state.
    @State private var showsPreview = false
    /// Expanded entity ids in the RCP-style scene outline. Components are display-only
    /// child rows, so expansion is keyed only by entity identity.
    @State private var expandedEntityIDs: Set<RCP3Entity.ID> = []
    /// Component-row selection in the outliner. The viewport/entity selection remains
    /// `store.selection`; this only decides which inspector surface is shown.
    @State private var selectedOutlinerComponent: EntityOutlinerComponentSelection?
    /// Whether the shared Add Component picker is presented. Opened from any of the
    /// three RCP entry points (sidebar menu, outliner context menu, inspector button);
    /// it adds to the current `store.selection`.
    @State private var showingAddComponent = false

    // MARK: Play mode (canonical, inline)

    /// Whether the canonical Play view is filling the center column instead of the
    /// viewport/graph. Pure presentation state. Pressing ▶ Play sets it; Stop clears
    /// it. Play reads the LIVE scene (`store.canonicalPlayScene`) and the view is
    /// re-`id`'d on its signature, so adding/assigning a graph during Play rebuilds and
    /// runs it.
    @State private var isPlaying = false

    /// Builds the canonical Play view from the live `CanonicalPlayScene`: the **app**
    /// injects its concrete `CanonicalPlayView` here (it owns the presentation + links
    /// the binary `RealityKitScripting` framework). The tested library never names that
    /// view, so `swift test` stays free of the binary dependency. The default returns
    /// `EmptyView`, so previews/tests construct `DocumentView` with no canonical view.
    private let canonicalPlay: (CanonicalPlayScene) -> CanonicalPlay

    public init(
        store: StoreOf<DocumentFeature>,
        @ViewBuilder canonicalPlay: @escaping (CanonicalPlayScene) -> CanonicalPlay
    ) {
        self.store = store
        self.canonicalPlay = canonicalPlay
    }

    /// Whether a script-graph canvas is currently shown (graph mode with a graph).
    private var isGraphShown: Bool {
        centerMode == .graph && (store.openScriptGraph ?? store.selectedScriptGraph) != nil
    }

    /// The graph the Run / Preview affordance would run: the open asset's graph (the
    /// brief's `store.openScriptGraph`), falling back to the selected entity's graph
    /// so the Play button is useful in either path. `nil` when there's nothing to run.
    private var previewableGraph: RCP3ScriptGraph? {
        store.openScriptGraph ?? store.selectedScriptGraph
    }

    /// Whether the Run/Preview affordances should be ENABLED: whenever a graph is open
    /// in the editor (`store.openScriptGraph`), falling back to the selected entity's
    /// graph (`store.selectedScriptGraph`). Deliberately independent of the center
    /// mode and of *which* entity is selected — with "world" selected the graph lives
    /// on a box child, so gating on the selected entity (or on viewport mode) wrongly
    /// greyed these out. Run/Preview just needs a graph to run.
    private var canRunPreview: Bool {
        store.openScriptGraph != nil || store.selectedScriptGraph != nil
    }

    /// Whether the ▶ Play toggle is available: there's a graph to run. Play runs it
    /// inline on Apple's real `RealityKitScripting` runtime (the canonical view),
    /// independent of which entity is selected or the center mode — same availability
    /// as Run Preview.
    private var canPlay: Bool {
        store.canonicalPlayScene.hasRunnable
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(store.bundleName ?? "Deconstructed 3")
                .toolbar { sidebarToolbar }
                .frame(minWidth: 240)
        } content: {
            // Center column over a RCP-style Project Browser bottom panel (resizable).
            VSplitView {
                centerColumn
                    .frame(minWidth: 320, minHeight: 220)
                ProjectBrowserPanel(
                    store: store,
                    onNewGraph: {
                        store.send(.newScriptGraphTapped)
                        centerMode = .graph
                    },
                    onNewFromSample: { example in
                        createScriptGraph(fromSample: example)
                    },
                    onOpenGraph: { id in
                        store.send(.scriptGraphOpened(id))
                        centerMode = .graph
                    },
                    onRename: { id, newName in
                        store.send(.renameScriptGraph(id: id, to: newName))
                    },
                    onDelete: { id in
                        store.send(.deleteScriptGraph(id: id))
                    }
                )
                .frame(minHeight: 120, idealHeight: 160)
            }
            .toolbar { centerToolbar }
            // Fall back to the viewport whenever there's nothing to show in the
            // graph canvas (no open asset and the selection has no graph), so the
            // mode can't get stuck on an empty canvas.
            .onChange(of: store.openScriptGraphID == nil && store.selectedScriptGraph == nil) { _, empty in
                if empty { centerMode = .viewport }
            }
            // Opening a graph asset switches the center to it.
            .onChange(of: store.openScriptGraphID) { _, id in
                if id != nil { centerMode = .graph }
            }
            // RUN / PREVIEW: compile + run the shown graph on the RCP3 runtime.
            .sheet(isPresented: $showsPreview) {
                if let graph = previewableGraph {
                    ScriptGraphPreviewView(graph: graph)
                }
            }
        } detail: {
            detailColumn
        }
        // The shared Add Component picker (categorized + search), opened from the
        // sidebar menu, the outliner context menu, or the inspector button. Adds to
        // the current selection.
        .sheet(isPresented: $showingAddComponent) {
            AddComponentPicker(
                onSelect: { type in
                    store.send(.addComponent(type))
                    showingAddComponent = false
                },
                onCancel: { showingAddComponent = false }
            )
        }
    }

    /// The detail (inspector) column. In Graph mode with a node selected it shows the
    /// **Node inspector** (its editable, unwired scalar pin literals) over the
    /// host-owned `graphModel`; otherwise it falls back to the entity inspector.
    @ViewBuilder
    private var detailColumn: some View {
        if centerMode == .graph,
           let model = graphModel,
           let nodeID = model.selectedNodeID,
           model.node(nodeID) != nil {
            NodeInspectorView(model: model, nodeID: nodeID)
        } else if let selection = validComponentSelection,
                  let entity = store.selectedEntity {
            ComponentInspectorView(store: store, entity: entity, component: selection.component)
        } else if let entity = store.selectedEntity {
            EntityInspectorView(store: store, entity: entity, showingAddComponent: $showingAddComponent)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "cube")
        }
    }

    /// The outliner component-row selection, but ONLY while the selected entity still
    /// carries that component. Derived from the live entity, so removing a component
    /// (e.g. "Remove Component") makes the now-stale selection fall back to the entity
    /// inspector — the component row's "parent" — instead of rendering a gone component.
    private var validComponentSelection: EntityOutlinerComponentSelection? {
        guard let selection = selectedOutlinerComponent,
              selection.entityID == store.selection,
              let entity = store.selectedEntity,
              entity.outlinerComponents.contains(where: { $0.id == selection.component.id })
        else { return nil }
        return selection
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if let root = store.rootEntity {
            // `List(selection:)` owns row identity AND the selection highlight — the
            // idiomatic SwiftUI design. Every row is `.tag`-ged with its selection id, so
            // SwiftUI (not hand-rolled booleans + `onTapGesture`) decides which single
            // row is highlighted; that is the actual fix for "selecting one row
            // highlights several". The tree is a recursive `DisclosureGroup` rather than
            // `OutlineGroup`/`List(children:)` because the editor needs programmatic
            // expansion (auto-expand the root; reveal a freshly-inserted entity), which
            // those start-collapsed APIs don't expose.
            List(selection: outlineSelection) {
                EntityOutlineRows(
                    store: store,
                    entity: root,
                    rootID: root.id,
                    expandedEntityIDs: $expandedEntityIDs,
                    showingAddComponent: $showingAddComponent
                )
                // Script-graph documents live in the bottom Project Browser panel
                // (RCP-style), not in this entity outliner.
            }
            .listStyle(.sidebar)
            .onAppear { expandRootIfNeeded(root) }
            .onChange(of: root.id) { _, _ in expandRootIfNeeded(root) }
            .onChange(of: store.selection) { _, entityID in
                guard selectedOutlinerComponent?.entityID == entityID else {
                    selectedOutlinerComponent = nil
                    return
                }
            }
        } else {
            ContentUnavailableView {
                Label("No project open", systemImage: "shippingbox")
            } description: {
                Text(store.errorMessage ?? "Open a .realitycomposerpro bundle to inspect its scene tree.")
            } actions: {
                Button("Open…") { presentOpenPanel() }
            }
        }
    }

    private func expandRootIfNeeded(_ root: RCP3Entity) {
        guard expandedEntityIDs.isEmpty || !expandedEntityIDs.contains(root.id) else { return }
        expandedEntityIDs.insert(root.id)
    }

    /// The single source of truth for `List(selection:)`, bridged to the store. The
    /// *getter* projects the current selection to a row tag — a component tag when a
    /// component of the selected entity is chosen, otherwise the entity's id. The
    /// *setter* decodes the tag the user clicked and pushes it back: a component tag
    /// sets `selectedOutlinerComponent` (the inspector surface) and selects its owning
    /// entity; an entity tag clears the component and selects the entity. Selection
    /// thus stays consistent with the viewport (which also writes `store.selection`).
    private var outlineSelection: Binding<String?> {
        Binding(
            get: {
                if let component = validComponentSelection {
                    return OutlineSelectionID.component(
                        entityID: component.entityID,
                        componentID: component.component.id
                    )
                }
                return store.selection
            },
            set: { newValue in
                guard let newValue else {
                    selectedOutlinerComponent = nil
                    store.send(.selected(nil))
                    return
                }
                if let decoded = OutlineSelectionID.decode(newValue) {
                    selectedOutlinerComponent = .init(
                        entityID: decoded.entityID,
                        component: EntityOutlinerComponent(id: decoded.componentID)
                    )
                    store.send(.selected(decoded.entityID))
                } else {
                    selectedOutlinerComponent = nil
                    store.send(.selected(newValue))
                }
            }
        )
    }

    // MARK: Center column (viewport ⇄ script-graph canvas ⇄ canonical Play)

    /// The center column. In the normal (not-playing) state it is the 3D viewport
    /// with the visual script-graph canvas overlaid ON TOP in Graph mode. While
    /// ▶ Play is active it is swapped INLINE for the app-supplied canonical Play view
    /// (Apple's real `RealityKitScripting` runtime), filling the whole column.
    ///
    /// CRITICAL (box-vanish fix, applies to the not-playing state): the
    /// `RCP3ViewportView` is ALWAYS mounted while not playing — it is the bottom layer
    /// of a `ZStack` and is never torn down by a Graph↔Viewport mode switch. Were it
    /// conditionally swapped out for the graph canvas (as it once was), switching to
    /// Graph would destroy the viewport's `@State` (provider/store + the injected
    /// RealityKit model); switching back would create a fresh viewport whose
    /// re-injection doesn't reliably re-render (StageView recreation fragility), so
    /// the reconstructed box disappeared. Keeping the viewport mounted means it builds
    /// ONCE (on `onAppear`) and only updates on `sceneGraph` changes — `setModel` is
    /// not re-run on each Graph↔Viewport toggle, so the box persists.
    ///
    /// (Entering Play does tear the viewport down — that's intended: Play is a
    /// distinct mode, and StageView rebuilds cleanly when Play stops.)
    @ViewBuilder
    private var centerColumn: some View {
        if isPlaying {
            // CANONICAL PLAY (inline): the app injects its concrete play view here,
            // reconstructing the LIVE scene and attaching every scripted entity's graph.
            // `.id(signature)` rebuilds the run when the set of scripts changes (a graph
            // added/assigned during Play), so the preview reflects it.
            let playScene = store.canonicalPlayScene
            canonicalPlay(playScene)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(playScene.signature)
        } else {
            viewportColumn
        }
    }

    /// The not-playing center: the always-mounted 3D viewport with the Graph-mode
    /// canvas overlaid on top.
    @ViewBuilder
    private var viewportColumn: some View {
        ZStack {
            // The reconstructed 3D viewport (StageView-backed), fed the live
            // (possibly unsaved) scene graph + a selection binding so renames
            // reflect and picks flow back to the store. ALWAYS present (while not
            // playing) so it is never torn down (see the type doc above). The old
            // hand-rolled spatial-Play plumbing (playMode/liveTransform/onPlayDrag)
            // is retired — Play now runs canonically, inline, above.
            RCP3ViewportView(
                sceneGraph: store.sceneGraph,
                selection: $store.selection.sending(\.selected)
            )

            // GRAPH overlay: only present in Graph mode, drawn on top of the live
            // viewport with an opaque background so the viewport doesn't show
            // through. The canvas/placeholder is unchanged; only its mounting moved
            // from a `switch` branch to this overlay.
            if centerMode == .graph {
                graphOverlay
                    // Fill the whole column and back it with an OPAQUE surface so the
                    // live viewport behind it is fully hidden — including the
                    // placeholder case, whose `ContentUnavailableView` doesn't fill
                    // on its own. (The real canvas already paints an opaque grid.)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.windowBackground)
            }
        }
    }

    /// The Graph-mode overlay content: the script-graph canvas over the
    /// host-owned model, or a placeholder when there's no graph to show. Drawn on
    /// top of the always-mounted viewport (see `centerColumn`).
    @ViewBuilder
    private var graphOverlay: some View {
        // An asset opened from the sidebar takes precedence; otherwise fall back
        // to the selected entity's graph.
        if let graph = store.openScriptGraph ?? store.selectedScriptGraph {
            let key = graphKey(for: graph)
            // The model is owned HERE (not by the canvas) so Save can write its
            // live edits back to the `.tm_script_graph`. It is (re)built by
            // `graphCanvas(for:key:)`'s `.task(id:)` whenever the shown graph
            // changes; `id` keys the canvas to the graph so SwiftUI rebuilds it too.
            graphCanvas(for: graph, key: key)
        } else {
            ContentUnavailableView(
                "No script graph",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Open a script graph from the sidebar, or select an entity that has one.")
            )
        }
    }

    /// The STABLE identity of a shown graph — the key the canvas/Play view is keyed on.
    ///
    /// Derived from the GRAPH being shown, never from `store.selection`: the open
    /// asset/example id (`openScriptGraphID`), else the graph's own root identity
    /// (`graph.id`, the `tm_graph`'s `__uuid` carried through parsing), else a stable
    /// fallback. This is the root fix for the data-loss bug: when a graph comes from the
    /// selected entity, a selection change (or the selection/focus churn around opening
    /// the "+" palette) must NOT change the key — otherwise the keyed `.task` re-fires
    /// and rebuilds the live model from the pristine source, discarding live edits.
    ///
    /// A different graph (different open id, or a different selected entity carrying a
    /// different graph identity) still yields a different key, so the model rebuilds for a
    /// genuinely different graph as before.
    private func graphKey(for graph: RCP3ScriptGraph) -> String {
        store.state.canvasKey(forShownGraph: graph)
    }

    /// The canvas over the host-owned model for `graph`, (re)building the model when the
    /// shown graph changes. The build happens in `task(id:)` (not in `body`), so `@State`
    /// is never mutated mid-evaluation.
    ///
    /// DIRTY-GUARD (belt-and-suspenders, paired with the selection-decoupled `key`): the
    /// `.task` only re-fires when `key` — the SHOWN GRAPH's stable identity — changes, so
    /// a selection change for the same graph no longer re-keys and no longer rebuilds.
    /// On top of that, the rebuild itself refuses to REPLACE an existing model that still
    /// has unsaved live edits with one for the SAME graph identity: a re-fire is only
    /// honoured when it carries a genuinely DIFFERENT key (a different graph). This makes
    /// it structurally impossible to silently discard a user's in-flight edits.
    @ViewBuilder
    private func graphCanvas(for graph: RCP3ScriptGraph, key: String) -> some View {
        Group {
            if let model = graphModel, graphModelKey == key {
                ScriptGraphCanvas(model: model)
            } else {
                // First frame for this graph: model is built in `.task(id:)` below.
                Color.clear
            }
        }
        .id(key)
        .task(id: key) {
            // Same graph identity as the live model? Never rebuild — that would discard
            // the user's unsaved edits. (Belt-and-suspenders: with the key now derived
            // from the shown graph, a same-graph re-fire shouldn't happen, but a dirty
            // model is never silently replaced regardless.)
            if let model = graphModel, graphModelKey == key, model.isDirty { return }
            graphModel = ScriptGraphEditorModel(graph: graph)
            graphModelKey = key
        }
    }

    /// The Viewport / Graph segmented switch. Always present (so it can't get
    /// dropped by conditional toolbar rebuilds); selecting `.graph` for an entity
    /// without a script graph shows a placeholder in the center column.
    @ToolbarContentBuilder
    private var centerToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $centerMode) {
                ForEach(CenterMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        // PLAY / STOP: run the script graph INLINE on Apple's real
        // `RealityKitScripting` runtime — the center column swaps to the
        // app-injected canonical Play view. ENABLED whenever there's a graph to run
        // (`canPlay`), independent of the selected entity or center mode. With no
        // canonical view injected (tests/previews use the `EmptyView` default), the
        // swap shows nothing — harmless, and the app always injects the real view.
        ToolbarItem {
            Button(
                isPlaying ? "Stop" : "Play",
                systemImage: isPlaying ? "stop.fill" : "play.fill"
            ) {
                if isPlaying { stopPlaying() } else { startPlaying() }
            }
            .disabled(!canPlay && !isPlaying)
            .help(isPlaying
                ? "Stop the running graph and return to the viewport"
                : "Run this script graph on Apple's RealityKitScripting runtime")
        }
        // RUN / PREVIEW affordance: ENABLED whenever a graph is open in the editor
        // (or the selected entity has one) — see `canRunPreview`. Opens
        // `ScriptGraphPreviewView` in a sheet, which compiles + runs the graph on the
        // RCP3 runtime, so it works from the Graph view too.
        ToolbarItem {
            Button("Run Preview", systemImage: "rectangle.on.rectangle") {
                showsPreview = true
            }
            .disabled(!canRunPreview)
            .help("Compile and run this script graph with a 2D drag simulator")
        }
        // EXAMPLES gallery: a curated set of canonical script-graph examples. Selecting
        // one LOADs it into the center as the open graph (`.exampleSelected`), switches
        // the center to Graph mode so the canvas shows it, and leaves the user to press
        // ▶ Play to run it on the box. Every curated example runs today (the
        // variable-driven ones compile to real local slots); a future example that
        // doesn't yet run is still labeled generically.
        ToolbarItem {
            examplesMenu
        }
    }

    /// The Examples gallery menu: lists `ScriptGraphExamples` by name, each loading the
    /// in-memory example graph into the editor on selection (summary shown as help).
    @ViewBuilder
    private var examplesMenu: some View {
        Menu {
            ForEach(ScriptGraphExamples.all) { example in
                Button {
                    loadExample(example)
                } label: {
                    Text(example.runsToday ? example.name : "\(example.name) (pending)")
                }
                .help(example.summary)
            }
        } label: {
            Label("Examples", systemImage: "sparkles.rectangle.stack")
        }
        .help("Load a curated script-graph example, then press Play")
    }

    /// Loads an example graph into the editor (open graph) and shows it on the canvas.
    private func loadExample(_ example: ScriptGraphExample) {
        store.send(.exampleSelected(id: example.id, graph: example.graph))
        centerMode = .graph
    }

    /// Materializes a curated SAMPLE into a real `.tm_script_graph` document in the
    /// project, then opens it. Unlike `loadExample` (an ephemeral in-memory graph),
    /// this writes a proper asset file — so a scripting component can point at it.
    /// Done host-side (MainActor) like `save()`: create the empty asset, then write the
    /// sample's nodes/connections/data into it via the proven write-back path.
    private func createScriptGraph(fromSample example: ScriptGraphExample) {
        guard let editor = store.editor else { return }
        do {
            let asset = try editor.createScriptGraphAsset(named: example.name)
            let model = ScriptGraphEditorModel(graph: example.graph)
            try ScriptGraphWriteBack.write(
                model: model,
                toAssetWithRootUUID: asset.id,
                in: editor.bundle.url
            )
            // The file now exists on disk; let the store re-read its owned asset list
            // (so the browser + picker list it) and open it.
            store.send(.scriptGraphMaterialized(id: asset.id))
            centerMode = .graph
        } catch {
            assertionFailure("create-from-sample failed: \(error)")
        }
    }

    // MARK: Play lifecycle (canonical, inline)

    /// Starts the inline canonical Play, swapping the center column to the app-injected
    /// canonical view. It reads the LIVE `store.canonicalPlayScene`, so no capture is
    /// needed — edits during Play re-key the view and rebuild. No-op if already playing
    /// or nothing is runnable.
    private func startPlaying() {
        guard !isPlaying, store.canonicalPlayScene.hasRunnable else { return }
        isPlaying = true
    }

    /// Stops the inline canonical Play: tears down the canonical view (which releases
    /// its `RealityView`/runtime) and returns the center column to the viewport.
    private func stopPlaying() {
        isPlaying = false
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem {
            // Browser "+" — create a new project asset. RCP lists many asset types
            // here; the script graph is the one we author today.
            Menu {
                Button("Script Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                    store.send(.newScriptGraphTapped)
                    centerMode = .graph
                }
                if store.selection != nil {
                    Divider()
                    Button("Add Component…", systemImage: "puzzlepiece.extension") {
                        showingAddComponent = true
                    }
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .disabled(store.rootEntity == nil)
            .help("Create an asset or add a component to the selected entity")
        }
        ToolbarItem {
            Button("Open…", systemImage: "folder") { presentOpenPanel() }
        }
        ToolbarItem {
            Button("Save", systemImage: "square.and.arrow.down") {
                save()
            }
            // Enabled when the entity session has edits, OR a graph canvas is shown
            // (its edits live in `graphModel`, outside the entity change-tracking).
            .disabled(!store.hasUnsavedChanges && !isGraphShown)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    /// Save: write back the live script-graph edits (when a graph is shown) directly
    /// to its `.tm_script_graph`, then run the entity Save through the store.
    ///
    /// The graph path is intentionally separate from the TCA entity-save flow: the
    /// graph model is host-owned UI state (not in the reducer), and its edits don't
    /// dirty the entity editor, so it is persisted here. The entity save (rename, …)
    /// still goes through `.saveTapped` and is untouched.
    private func save() {
        // Persist the live graph edits, choosing the write target by how the graph was
        // opened:
        //  - a sidebar-opened STANDALONE asset (`openAssetGraphID`) → its `.tm_script_graph`;
        //  - otherwise the graph belongs to the SELECTED ENTITY (an instance-override graph
        //    embedded in `world.tm_entity`'s `re_scripting_component.source.graph`) → write
        //    back into the root entity file.
        // A loaded Examples-gallery graph has no on-disk backing, so it matches neither and
        // is skipped (the entity save below still runs).
        if isGraphShown, let model = graphModel, let editor = store.editor {
            do {
                if let rootUUID = store.openAssetGraphID {
                    try ScriptGraphWriteBack.write(
                        model: model,
                        toAssetWithRootUUID: rootUUID,
                        in: editor.bundle.url
                    )
                    model.markSaved()
                } else if store.openScriptGraph == nil,
                          store.selectedScriptGraph != nil,
                          let entityID = store.selection {
                    // Entity-attached (instance-override) graph: write into world.tm_entity.
                    try ScriptGraphWriteBack.write(
                        model: model,
                        toEntityWithID: entityID,
                        rootFileURL: editor.bundle.rootURL
                    )
                    model.markSaved()
                }
            } catch {
                // Surface nothing fancy yet; a graph write failure shouldn't block
                // the entity save below. (Error reporting can be lifted into the
                // reducer in a later pass.)
                assertionFailure("script-graph write-back failed: \(error)")
            }
        }
        store.send(.saveTapped)
    }

    /// Presents the file picker (AppKit) and feeds the chosen URL to the store.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a .realitycomposerpro bundle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.send(.openTapped(url))
    }
}

// MARK: - RCP-style entity outliner

private struct EntityOutlinerComponentSelection: Equatable {
    var entityID: RCP3Entity.ID
    var component: EntityOutlinerComponent
}

/// Identity scheme for the outliner's `List(selection:)` row tags. An entity row is
/// tagged with its entity id; a component row with `"<entityID>#<componentID>"`.
/// Entity ids (uuids) and component ids never contain `#`, so the delimiter decodes
/// unambiguously. Pure + internal so the encode/decode is unit-tested.
enum OutlineSelectionID {
    static func component(entityID: String, componentID: String) -> String {
        "\(entityID)#\(componentID)"
    }

    /// Decodes a component tag into its parts, or `nil` for a plain entity tag.
    static func decode(_ tag: String) -> (entityID: String, componentID: String)? {
        guard let separator = tag.range(of: "#") else { return nil }
        return (
            entityID: String(tag[..<separator.lowerBound]),
            componentID: String(tag[separator.upperBound...])
        )
    }
}

/// One entity and its subtree in the outliner, rendered as a native
/// `DisclosureGroup`. `List` owns indentation and disclosure; the row `.tag`s plus
/// the enclosing `List(selection:)` own identity and the selection highlight — so
/// there is no `onTapGesture` and no hand-drawn highlight (selecting a row is just
/// "`List` set the bound selection to this row's tag"). Component rows hang off the
/// disclosure group as leaves alongside child entities.
///
/// The body branches between a `DisclosureGroup` (has children) and a bare label
/// (leaf), making it a multi-shape row — that trades `List`'s id-templating fast
/// path for native disclosure. A scene outliner is a handful of nested rows, so the
/// trade is right; the fast path matters for long *flat* lists.
private struct EntityOutlineRows: View {
    @Bindable var store: StoreOf<DocumentFeature>
    let entity: RCP3Entity
    let rootID: RCP3Entity.ID
    @Binding var expandedEntityIDs: Set<RCP3Entity.ID>
    @Binding var showingAddComponent: Bool

    private var components: [EntityOutlinerComponent] { entity.outlinerComponents }
    private var hasChildren: Bool { !components.isEmpty || !entity.children.isEmpty }

    var body: some View {
        if hasChildren {
            DisclosureGroup(isExpanded: expansion) {
                ForEach(components) { component in
                    Label(component.displayName, systemImage: component.symbolName)
                        .lineLimit(1)
                        .tag(OutlineSelectionID.component(entityID: entity.id, componentID: component.id))
                }
                ForEach(entity.children) { child in
                    EntityOutlineRows(
                        store: store,
                        entity: child,
                        rootID: rootID,
                        expandedEntityIDs: $expandedEntityIDs,
                        showingAddComponent: $showingAddComponent
                    )
                }
            } label: {
                entityLabel
            }
        } else {
            entityLabel
        }
    }

    /// The selectable entity row: tagged with the entity id so `List(selection:)`
    /// highlights exactly it, and carrying the entity context menu.
    private var entityLabel: some View {
        Label(entity.displayName, systemImage: entity.outlinerSymbolName)
            .lineLimit(1)
            .tag(entity.id)
            .contextMenu { entityContextMenu }
    }

    /// Two-way expansion for this entity, backed by the shared `expandedEntityIDs`.
    private var expansion: Binding<Bool> {
        Binding(
            get: { expandedEntityIDs.contains(entity.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedEntityIDs.insert(entity.id)
                } else {
                    expandedEntityIDs.remove(entity.id)
                }
            }
        )
    }

    @ViewBuilder
    private var entityContextMenu: some View {
        Button("Deactivate") {}
            .disabled(true)

        Menu("Add Child Entity") {
            Button("Empty") {}
                .disabled(true)
            Button("From Asset...") {}
                .disabled(true)
            Divider()
            Button("Add Portal Hierarchy") {}
                .disabled(true)
            Menu("Geometry") {
                Button("plane") { add(.plane) }
                Button("sphere") { add(.sphere) }
                Button("box") { add(.box) }
            }
        }

        Button("Add Component...") {
            store.send(.selected(entity.id))
            showingAddComponent = true
        }
        Button("Frame Selection") {}
            .disabled(true)
        Button("Replace With Asset...") {}
            .disabled(true)

        Divider()
        Button("Rename") {}
            .disabled(true)
        Button("Copy") {}
            .disabled(true)
        Button("Duplicate") {
            store.send(.selected(entity.id))
            store.send(.duplicateSelectedEntity)
        }
        .disabled(entity.id == rootID)
        Button("Delete", role: .destructive) {
            store.send(.selected(entity.id))
            store.send(.deleteSelectedEntity)
        }
        .disabled(entity.id == rootID)
    }

    private func add(_ kind: RCP3PrimitiveKind) {
        store.send(.selected(entity.id))
        store.send(.addPrimitive(kind))
        expandedEntityIDs.insert(entity.id)
    }
}

struct EntityOutlinerComponent: Identifiable, Equatable {
    enum Kind: Equatable {
        case transform
        case model
        case other(String)
    }

    var kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    /// Reconstructs a component from its row id — the inverse of `id`. The known keys
    /// map back to their kind; anything else is an `.other(type)`. Used when decoding
    /// a `List(selection:)` component tag.
    init(id: String) {
        switch id {
        case "transform": self.kind = .transform
        case "model": self.kind = .model
        default: self.kind = .other(id)
        }
    }

    var id: String {
        switch kind {
        case .transform: return "transform"
        case .model: return "model"
        case let .other(type): return type
        }
    }

    var displayName: String {
        switch kind {
        case .transform: return "Transform"
        case .model: return "Model"
        case let .other(type): return type.outlinerComponentDisplayName
        }
    }

    var symbolName: String {
        switch kind {
        case .transform: return "arrow.triangle.2.circlepath"
        case .model: return "puzzlepiece.extension"
        case .other: return "puzzlepiece.extension"
        }
    }

    var tint: Color {
        switch kind {
        case .transform: return .purple
        case .model: return .purple
        case .other: return .secondary
        }
    }
}

// MARK: - Canonical-play default (EmptyView)

public extension DocumentView where CanonicalPlay == EmptyView {
    /// Constructs a `DocumentView` with NO canonical Play view: pressing ▶ Play swaps
    /// the center to an `EmptyView`. Used by previews and `swift test` (which can't
    /// load the binary `RealityKitScripting` framework); the real app always provides
    /// a concrete canonical view via the designated `@ViewBuilder` init.
    init(store: StoreOf<DocumentFeature>) {
        self.init(store: store) { _ in EmptyView() }
    }
}

// MARK: - Component inspectors

private struct ComponentInspectorView: View {
    @Bindable var store: StoreOf<DocumentFeature>
    let entity: RCP3Entity
    let component: EntityOutlinerComponent

    var body: some View {
        switch component.kind {
        case .transform:
            Form {
                TransformSection(store: store)
            }
            .formStyle(.grouped)
            .navigationTitle("Transform Component")

        case .model:
            Form {
                Section {
                    LabeledContent("Type", value: entity.displayName.prototypeBaseName.capitalized)
                    LabeledContent("Material", value: "default_material")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Model Component")

        case let .other(type):
            Form {
                LabeledContent("Type", value: type)
                // RCP's Scripting Component shows its Script → Prototype picker right
                // here when the component row is selected.
                if type == "re_scripting_component" {
                    Section("Script") {
                        Picker("Prototype", selection: scriptGraphAssignment) {
                            Text("(none)").tag(String?.none)
                            ForEach(store.scriptGraphAssets) { asset in
                                Text(asset.name).tag(String?.some(asset.id))
                            }
                        }
                        Button("Remove Component", systemImage: "trash", role: .destructive) {
                            store.send(.removeScriptingComponent)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(component.displayName)
        }
    }

    /// Binding for the scripting component's assigned asset; writing sends
    /// `.assignScriptGraph`. Shared semantics with the entity inspector's picker.
    private var scriptGraphAssignment: Binding<String?> {
        Binding(
            get: { store.assignedScriptGraphAssetID },
            set: { store.send(.assignScriptGraph($0)) }
        )
    }
}

// MARK: - Editable inspector

/// The detail pane: an *editable* inspector for the selected entity. The Name row
/// is a `TextField` whose edits drive `DocumentFeature.Action.nameEdited`, which
/// mutates the live `TMObject` and marks the session dirty. Save (⌘S / toolbar)
/// then writes to disk.
struct EntityInspectorView: View {
    @Bindable var store: StoreOf<DocumentFeature>
    let entity: RCP3Entity
    @Binding var showingAddComponent: Bool

    /// The scripting component's assigned asset (root `__uuid`), or `nil` for `(none)`.
    /// Writing sends `.assignScriptGraph`, which wires the component's `source`.
    private var scriptGraphAssignment: Binding<String?> {
        Binding(
            get: { store.assignedScriptGraphAssetID },
            set: { store.send(.assignScriptGraph($0)) }
        )
    }

    var body: some View {
        Form {
            TextField(
                "Name",
                text: $store.selectedEntityName.sending(\.nameEdited)
            )

            LabeledContent("Type", value: entity.type ?? "—")
            if let uuid = entity.uuid {
                LabeledContent("UUID", value: uuid)
            }
            if let prototype = entity.prototypeUUID {
                LabeledContent("Prototype", value: prototype)
            }
            LabeledContent("Children", value: "\(entity.children.count)")

            if store.selectedEntityTransform != nil {
                TransformSection(store: store)
            }

            let secondaryComponents = entity.inspectorSecondaryComponents
            if !secondaryComponents.isEmpty {
                Section("Components") {
                    ForEach(secondaryComponents) { component in
                        Label(component.displayName, systemImage: component.symbolName)
                            .foregroundStyle(component.tint)
                    }
                }
            }

            // RCP's Scripting Component: a Script picker (Prototype dropdown) listing
            // the project's script-graph assets, applied to this entity's component.
            if store.selectedEntityHasScriptingComponent {
                Section("Scripting Component") {
                    Picker("Script", selection: scriptGraphAssignment) {
                        Text("(none)").tag(String?.none)
                        ForEach(store.scriptGraphAssets) { asset in
                            Text(asset.name).tag(String?.some(asset.id))
                        }
                    }
                    Button("Remove Component", systemImage: "trash", role: .destructive) {
                        store.send(.removeScriptingComponent)
                    }
                }
            }

            if let graph = store.selectedScriptGraph {
                ScriptGraphSection(graph: graph)
            }

            // RCP's bottom "Add Component" button — opens the shared component picker.
            Section {
                Button("Add Component", systemImage: "puzzlepiece.extension") {
                    showingAddComponent = true
                }
                .frame(maxWidth: .infinity)
            }

            Section {
                Menu("Add", systemImage: "plus") {
                    Button("Box", systemImage: "cube") {
                        store.send(.addPrimitive(.box))
                    }
                    Button("Sphere", systemImage: "circle") {
                        store.send(.addPrimitive(.sphere))
                    }
                    Button("Plane", systemImage: "square") {
                        store.send(.addPrimitive(.plane))
                    }
                }

                Button("Duplicate", systemImage: "plus.square.on.square") {
                    store.send(.duplicateSelectedEntity)
                }
                .disabled(entity.id == store.rootEntity?.id)

                Button("Delete", systemImage: "trash", role: .destructive) {
                    store.send(.deleteSelectedEntity)
                }
                .disabled(entity.id == store.rootEntity?.id)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(entity.displayName)
    }
}

// MARK: - Project Browser (bottom panel)

/// The RCP-style **Project Browser**: a bottom panel listing the project's
/// script-graph documents (Name / Kind), with a `+` to create one. Selecting a row
/// opens it in the center canvas. This is the home for *isolated* script graphs —
/// the documents a scripting component points at.
private struct ProjectBrowserPanel: View {
    @Bindable var store: StoreOf<DocumentFeature>
    let onNewGraph: () -> Void
    let onNewFromSample: (ScriptGraphExample) -> Void
    let onOpenGraph: (String) -> Void
    let onRename: (String, String) -> Void
    let onDelete: (String) -> Void

    /// The asset being renamed (drives the rename alert) and its edit buffer.
    @State private var renamingAssetID: String?
    @State private var renameText = ""
    /// The asset pending deletion (drives the confirmation alert).
    @State private var deletingAsset: RCP3ScriptGraphAsset?

    private var isRenaming: Binding<Bool> {
        Binding(get: { renamingAssetID != nil }, set: { if !$0 { renamingAssetID = nil } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Project Browser", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                Spacer()
                // "+" creates a blank Script Graph, or materializes a curated SAMPLE
                // into a real `.tm_script_graph` document (so it's assignable).
                Menu {
                    Button("Empty Script Graph", systemImage: "doc") { onNewGraph() }
                    Divider()
                    Section("Samples") {
                        ForEach(ScriptGraphExamples.all) { example in
                            Button(example.name) { onNewFromSample(example) }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .help("New Script Graph (blank or from a sample)")
                .accessibilityLabel("New Script Graph")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if store.scriptGraphAssets.isEmpty {
                VStack(spacing: 4) {
                    Text("No assets").foregroundStyle(.secondary)
                    Text("Tap + to create a Script Graph.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.scriptGraphAssets) { asset in
                        Button {
                            onOpenGraph(asset.id)
                        } label: {
                            HStack(spacing: 8) {
                                Label(asset.name, systemImage: "point.3.connected.trianglepath.dotted")
                                Spacer()
                                Text("Script Graph")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(asset.id == store.openScriptGraphID ? Color.accentColor : .primary)
                        .contextMenu {
                            Button("Rename…", systemImage: "pencil") {
                                renameText = asset.name
                                renamingAssetID = asset.id
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deletingAsset = asset
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.background)
        .alert("Rename Script Graph", isPresented: isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = renamingAssetID { onRename(id, renameText) }
                renamingAssetID = nil
            }
            Button("Cancel", role: .cancel) { renamingAssetID = nil }
        }
        .alert(
            "Delete “\(deletingAsset?.name ?? "")”?",
            isPresented: Binding(get: { deletingAsset != nil }, set: { if !$0 { deletingAsset = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = deletingAsset?.id { onDelete(id) }
                deletingAsset = nil
            }
            Button("Cancel", role: .cancel) { deletingAsset = nil }
        } message: {
            Text("This removes the Script Graph from the project. Entities referencing it will lose their assignment.")
        }
    }
}

// MARK: - Add Component picker (shared across entry points)

/// One component the Add Component picker can offer, grouped by `category`. Only
/// `isSupported` items are addable today; the rest are shown disabled (RCP lists the
/// full catalog). `type` is the on-disk `__type` written when added.
private struct AddComponentItem: Identifiable, Sendable {
    let id: String          // component `__type`
    let name: String
    let category: String
    let systemImage: String
    let isSupported: Bool
}

private enum ComponentCatalog {
    /// The components the picker lists. Categories mirror RCP's grouping; only the
    /// ones Deconstructed 3 can author today are enabled. More enable as supported.
    static let all: [AddComponentItem] = [
        .init(id: "re_scripting_component", name: "Scripting", category: "Gameplay",
              systemImage: "chevron.left.forwardslash.chevron.right", isSupported: true),
    ]
}

/// The shared, searchable, categorized component picker — the same floating menu RCP
/// opens from its sidebar, outliner context menu, and inspector button.
private struct AddComponentPicker: View {
    let onSelect: (String) -> Void
    let onCancel: () -> Void
    @State private var query = ""

    private var groups: [(category: String, items: [AddComponentItem])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = ComponentCatalog.all.filter {
            q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)
        }
        return Dictionary(grouping: items, by: \.category)
            .map { (category: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category < $1.category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Component").font(.headline)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            List {
                if groups.isEmpty {
                    Text("No components match \u{201C}\(query)\u{201D}")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.category) { group in
                    Section(group.category.uppercased()) {
                        ForEach(group.items) { item in
                            Button {
                                onSelect(item.id)
                            } label: {
                                Label(item.name, systemImage: item.systemImage)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!item.isSupported)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }
}

// MARK: - Transform section (editable local transform)

/// The editable local-transform block of the entity inspector: position (x/y/z),
/// rotation (presented as **Euler degrees** x/y/z for usability, converted to/from the
/// stored quaternion on every edit), and scale (x/y/z). Each field writes through
/// `DocumentFeature.Action.transformEdited`, which folds the value into the entity's
/// `tm_transform_component` and marks the document dirty so Save (⌘S) persists it.
///
/// The fields read the live (possibly unsaved) transform off the store, so an edit to
/// one axis re-renders the others consistently. Only shown when the selected entity
/// actually carries a transform (`store.selectedEntityTransform != nil`).
struct TransformSection: View {
    @Bindable var store: StoreOf<DocumentFeature>

    /// The live transform, or identity as a safe fallback (the parent only mounts this
    /// view when a transform is present, so the fallback is never displayed).
    private var transform: RCP3Transform {
        store.selectedEntityTransform ?? .identity
    }

    var body: some View {
        Section("Transform Component") {
            transformRow(
                "Position",
                x: positionBinding(\.translation.x) { $0.translation.x = $1 },
                y: positionBinding(\.translation.y) { $0.translation.y = $1 },
                z: positionBinding(\.translation.z) { $0.translation.z = $1 }
            )
            transformRow(
                "Rotation",
                x: eulerBinding(\.x) { $0.x = $1 },
                y: eulerBinding(\.y) { $0.y = $1 },
                z: eulerBinding(\.z) { $0.z = $1 },
                suffix: "°"
            )
            transformRow(
                "Scale",
                x: positionBinding(\.scale.x) { $0.scale.x = $1 },
                y: positionBinding(\.scale.y) { $0.scale.y = $1 },
                z: positionBinding(\.scale.z) { $0.scale.z = $1 }
            )
        }
    }

    /// A binding to a translation/scale component: reads through `read`, and on write
    /// rebuilds the whole transform via `write` and sends `.transformEdited`.
    private func positionBinding(
        _ read: KeyPath<RCP3Transform, Double>,
        write: @escaping (inout RCP3Transform, Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: { transform[keyPath: read] },
            set: { newValue in
                var edited = transform
                write(&edited, newValue)
                store.send(.transformEdited(edited))
            }
        )
    }

    /// A binding to one Euler-degree axis of the rotation: reads the derived Euler
    /// angles, and on write rebuilds the quaternion from the edited angles.
    private func eulerBinding(
        _ axis: KeyPath<(x: Double, y: Double, z: Double), Double>,
        write: @escaping (inout (x: Double, y: Double, z: Double), Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: { transform.eulerDegrees[keyPath: axis] },
            set: { newValue in
                var degrees = transform.eulerDegrees
                write(&degrees, newValue)
                store.send(.transformEdited(transform.settingEulerDegrees(degrees)))
            }
        )
    }

    /// A labelled x/y/z row of numeric fields, each with an optional unit suffix.
    @ViewBuilder
    private func transformRow(
        _ title: String,
        x: Binding<Double>,
        y: Binding<Double>,
        z: Binding<Double>,
        suffix: String = ""
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                axisField("X", title: title, value: x, suffix: suffix)
                axisField("Y", title: title, value: y, suffix: suffix)
                axisField("Z", title: title, value: z, suffix: suffix)
            }
        }
    }

    @ViewBuilder
    private func axisField(
        _ axis: String,
        title: String,
        value: Binding<Double>,
        suffix: String
    ) -> some View {
        HStack(spacing: 2) {
            Text(axis).font(.caption2).foregroundStyle(.secondary)
            TextField(axis, value: value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 64)
                .accessibilityLabel("\(title) \(axis)")
            if !suffix.isEmpty {
                Text(suffix).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Node inspector (scalar pin literals)

/// The detail-pane inspector for a SELECTED graph node: a numeric field per editable
/// unwired data pin, bound through the host-owned `ScriptGraphEditorModel`. Editing a
/// value authors a scalar `data[]` literal on that pin; Save (⌘S) writes it back to
/// the `.tm_script_graph`, and the canonical compiler reads it so Play reflects the
/// value.
///
/// v1 scope is NUMERIC (`Double`) literals — the `make_vector*` components and math
/// operands the compiler reads as scalars. A node with no editable numeric pins (an
/// event source, a wired-only node) shows an explanatory placeholder. (Boolean /
/// string literals, and variable-name authoring, are noted follow-ups that reuse this
/// inspector.)
struct NodeInspectorView: View {
    @Bindable var model: ScriptGraphEditorModel
    let nodeID: String

    /// The node's editable name, bound through the model. Blank clears the label, so
    /// the canvas falls back to the humanized type.
    private var name: Binding<String> {
        Binding(
            get: { model.nodeLabel(nodeID: nodeID) },
            set: { model.setNodeLabel(nodeID: nodeID, label: $0) }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Name", text: name, prompt: Text(model.node(nodeID)?.payload.title ?? "Node"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 180)
                        .accessibilityLabel("Node name")
                }
                if let type = model.node(nodeID)?.payload.type {
                    LabeledContent("Type", value: type)
                        .font(.callout)
                }
            }

            if model.isVariableNode(nodeID) {
                Section("Variable") {
                    VariableRow(model: model, nodeID: nodeID)
                }
            }

            let literals = model.editableLiterals(forNode: nodeID)
            if literals.isEmpty {
                Section("Inputs") {
                    Text("This node has no editable values. Wire its inputs, or select a node with numeric pins (e.g. a Vector or a math operator).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Inputs") {
                    ForEach(literals) { literal in
                        LiteralRow(model: model, literal: literal)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.node(nodeID)?.payload.title ?? "Node")
    }
}

/// The Variable row for a Get/Set/Clear variable node: a text field bound to the
/// node's referenced variable name, with a menu of the graph's declared variables
/// for quick reuse. Editing writes through ``ScriptGraphEditorModel/setVariableName(nodeID:name:)``,
/// which declares a new variable when the name isn't in the table yet; write-back
/// then persists the `tm_graph_variable_ref` + the `variables:` table on Save.
private struct VariableRow: View {
    @Bindable var model: ScriptGraphEditorModel
    let nodeID: String

    private var name: Binding<String> {
        Binding(
            get: { model.variableName(nodeID: nodeID) ?? "" },
            set: { model.setVariableName(nodeID: nodeID, name: $0) }
        )
    }

    var body: some View {
        LabeledContent("Name") {
            HStack(spacing: 8) {
                TextField("Variable name", text: name)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Variable name")
                if !model.variableNamesInOrder.isEmpty {
                    Menu {
                        ForEach(model.variableNamesInOrder, id: \.self) { declared in
                            Button(declared) { model.setVariableName(nodeID: nodeID, name: declared) }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Choose a declared variable")
                }
            }
        }
    }
}

/// One editable pin-literal row, rendering the control that matches the value's kind:
/// a numeric `TextField` + `Stepper` for a number, a `Toggle` for a bool, a text field
/// for a string. Each writes the typed value straight to the model via `setValue`.
private struct LiteralRow: View {
    @Bindable var model: ScriptGraphEditorModel
    let literal: EditableLiteral

    var body: some View {
        LabeledContent(literal.displayName) {
            switch literal.value {
            case .bool:
                Toggle(literal.displayName, isOn: boolBinding)
                    .labelsHidden()
                    .accessibilityLabel(literal.displayName)
            case .string:
                TextField(literal.displayName, text: stringBinding)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 160)
                    .accessibilityLabel(literal.displayName)
            case .number, .variableRef:
                HStack(spacing: 8) {
                    TextField(literal.displayName, value: numberBinding, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                        .accessibilityLabel(literal.displayName)
                    Stepper(literal.displayName, value: numberBinding)
                        .labelsHidden()
                        .accessibilityLabel("\(literal.displayName) stepper")
                }
            }
        }
    }

    private var numberBinding: Binding<Double> {
        Binding(
            get: { model.value(nodeID: nodeID, pinConnectorHash: pinHash)?.number ?? 0 },
            set: { model.setValue(nodeID: nodeID, pinConnectorHash: pinHash, value: .number($0)) }
        )
    }

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { model.value(nodeID: nodeID, pinConnectorHash: pinHash)?.bool ?? false },
            set: { model.setValue(nodeID: nodeID, pinConnectorHash: pinHash, value: .bool($0)) }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: { model.value(nodeID: nodeID, pinConnectorHash: pinHash)?.string ?? "" },
            set: { model.setValue(nodeID: nodeID, pinConnectorHash: pinHash, value: .string($0)) }
        )
    }

    private var nodeID: String { literal.key.nodeID }
    private var pinHash: UInt64 { literal.key.pinConnectorHash }
}

// MARK: - Script-graph section

/// A readable, structured rendering of the entity's script graph (the no-code
/// logic behind a `re_scripting_component`): its nodes, the wires between them
/// (exec vs. data, with resolved pin names), and bound data literals. A list, not
/// a visual canvas — the canvas comes later.
struct ScriptGraphSection: View {
    let graph: RCP3ScriptGraph

    var body: some View {
        Section("Script Graph") {
            nodesGroup
            wiresGroup
            dataGroup
        }
    }

    @ViewBuilder
    private var nodesGroup: some View {
        LabeledContent("Nodes", value: "\(graph.nodes.count)")
        ForEach(graph.nodes) { node in
            VStack(alignment: .leading, spacing: 2) {
                Text(node.label ?? node.type)
                    .font(.callout)
                if node.label != nil {
                    Text(node.type).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var wiresGroup: some View {
        if !graph.wires.isEmpty {
            LabeledContent("Wires", value: "\(graph.wires.count)")
            ForEach(graph.wires) { wire in
                Text(describe(wire)).font(.caption.monospaced())
            }
        }
    }

    @ViewBuilder
    private var dataGroup: some View {
        if !graph.data.isEmpty {
            LabeledContent("Inputs", value: "\(graph.data.count)")
            ForEach(graph.data) { literal in
                Text(describe(literal)).font(.caption.monospaced())
            }
        }
    }

    /// `fromNode → toNode  [exec]` or `fromNode → toNode  [fromPin → toPin]`.
    private func describe(_ wire: RCP3ScriptGraph.Wire) -> String {
        let from = nodeName(wire.from)
        let to = nodeName(wire.to)
        let detail = wire.isExec
            ? "[exec]"
            : "[\(RCP3ScriptGraph.label(forHash: wire.fromPin)) → \(RCP3ScriptGraph.label(forHash: wire.toPin))]"
        return "\(from) → \(to)  \(detail)"
    }

    /// `toNode.pin = <type>` for a bound data literal.
    private func describe(_ literal: RCP3ScriptGraph.DataLiteral) -> String {
        let pin = RCP3ScriptGraph.label(forHash: literal.toPin)
        let value = literal.valueType.map { " = \($0)" } ?? ""
        return "\(nodeName(literal.toNode)).\(pin)\(value)"
    }

    /// A node's display label by uuid: its author label, else its type, else a
    /// short uuid prefix.
    private func nodeName(_ id: String) -> String {
        guard let node = graph.node(id: id) else { return String(id.prefix(8)) }
        return node.label ?? node.type
    }
}

// MARK: - View-facing helpers

extension DocumentFeature.State {
    /// The selected entity's name, as a plain `String` for the inspector's
    /// `TextField` (empty when nothing is selected). Writes go through
    /// `.nameEdited`; this is the read side of that binding.
    var selectedEntityName: String {
        selectedEntity?.name ?? ""
    }

    /// The STABLE canvas key for a SHOWN graph: the open asset/example id
    /// (`openScriptGraphID`), else the graph's own root identity (`graph.id`), else a
    /// constant fallback. Deliberately INDEPENDENT of `selection` — when a graph comes
    /// from the selected entity, a selection change (or the selection/focus churn around
    /// opening the "+" palette) must NOT change this key, or the keyed canvas `.task`
    /// re-fires and rebuilds the live model from the pristine source, discarding live
    /// edits. A genuinely different graph (different open id, or a different selected
    /// entity's graph identity) still yields a different key.
    func canvasKey(forShownGraph graph: RCP3ScriptGraph) -> String {
        openScriptGraphID ?? graph.id ?? "graph"
    }
}

// Internal (not `private`) so `outlinerComponents` — the component de-duplication
// behind the outliner rows — is reachable from unit tests.
extension RCP3Entity {
    var displayName: String { name.isEmpty ? "(unnamed)" : name }
    var outlinerSymbolName: String {
        if name == "world" { return "cube" }
        if isGeometryPrototypeInstance { return "shippingbox" }
        return prototypeUUID == nil ? "cube" : "shippingbox"
    }

    var outlinerComponents: [EntityOutlinerComponent] {
        var components: [EntityOutlinerComponent] = [.init(kind: .transform)]
        if hasModelComponent {
            components.append(.init(kind: .model))
        }
        for type in componentTypes {
            guard !type.isTransformComponentType, !type.isModelComponentType else { continue }
            components.append(.init(kind: .other(type)))
        }
        // De-duplicate by id: a component type present in BOTH `components` and
        // `components__instantiated` (authored + inherited) would otherwise yield two
        // rows sharing one selection key, so selecting it would highlight both.
        var seen = Set<String>()
        return components.filter { seen.insert($0.id).inserted }
    }

    var inspectorSecondaryComponents: [EntityOutlinerComponent] {
        outlinerComponents.filter { $0.kind != .transform }
    }

    private var hasModelComponent: Bool {
        componentTypes.contains { $0.isModelComponentType } || isGeometryPrototypeInstance
    }

    private var isGeometryPrototypeInstance: Bool {
        guard prototypeUUID != nil else { return false }
        return ["box", "sphere", "plane"].contains(name.prototypeBaseName)
    }
}

private extension String {
    var prototypeBaseName: String {
        guard hasSuffix(")") else { return self }
        guard let open = lastIndex(of: "("),
              open > startIndex,
              self[index(before: open)] == " "
        else { return self }
        let numberStart = index(after: open)
        let numberEnd = index(before: endIndex)
        guard Int(self[numberStart..<numberEnd]) != nil else { return self }
        return String(self[..<index(before: open)])
    }

    var isTransformComponentType: Bool {
        self == "tm_transform_component"
    }

    var isModelComponentType: Bool {
        self == "tm_model_component"
            || self == "re_model_component"
            || self == "ModelComponent"
    }

    var outlinerComponentDisplayName: String {
        var name = self
        for prefix in ["tm_", "re_"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if name.hasSuffix("_component") {
            name.removeLast("_component".count)
        } else if name.hasSuffix("Component") {
            name.removeLast("Component".count)
        }
        return name
            .split(separator: "_")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
