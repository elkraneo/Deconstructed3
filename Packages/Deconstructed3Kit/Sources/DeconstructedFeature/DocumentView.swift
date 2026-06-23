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

    // MARK: Play mode (canonical, inline)

    /// Whether the canonical Play view is filling the center column instead of the
    /// viewport/graph. Pure presentation state. Pressing ▶ Play sets it; Stop clears
    /// it and returns to the normal viewport. The graph it runs is captured at the
    /// moment Play starts, so a selection change while playing doesn't swap targets.
    @State private var isPlaying = false
    /// The graph the in-flight canonical Play is running, captured when Play begins so
    /// the canonical view's identity is stable across body passes. `nil` when stopped.
    @State private var playingGraph: RCP3ScriptGraph?

    /// Builds the canonical Play view for a graph: the **app** injects its concrete
    /// `CanonicalPlayView` here (it owns the presentation + links the binary
    /// `RealityKitScripting` framework). The tested library never names that view, so
    /// `swift test` stays free of the binary dependency. The default returns
    /// `EmptyView`, so previews/tests construct `DocumentView` with no canonical view.
    private let canonicalPlay: (RCP3ScriptGraph) -> CanonicalPlay

    public init(
        store: StoreOf<DocumentFeature>,
        @ViewBuilder canonicalPlay: @escaping (RCP3ScriptGraph) -> CanonicalPlay
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
        previewableGraph != nil
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(store.bundleName ?? "Deconstructed 3")
                .toolbar { sidebarToolbar }
                .frame(minWidth: 240)
        } content: {
            centerColumn
                .frame(minWidth: 320)
                .toolbar { centerToolbar }
                // Fall back to the viewport whenever there's nothing to show in the
                // graph canvas (no open asset and the selection has no graph), so the
                // mode can't get stuck on an empty canvas.
                .onChange(of: store.openScriptGraphID == nil && store.selectedScriptGraph == nil) { _, empty in
                    if empty { centerMode = .viewport }
                }
                // Opening a graph asset from the sidebar switches the center to it.
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
        } else if let selection = selectedOutlinerComponent,
                  selection.entityID == store.selection,
                  let entity = store.selectedEntity {
            ComponentInspectorView(store: store, entity: entity, component: selection.component)
        } else if let entity = store.selectedEntity {
            EntityInspectorView(store: store, entity: entity)
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "cube")
        }
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if let root = store.rootEntity {
            List {
                // The entire entity tree is pre-flattened into one identified row
                // list and rendered by a SINGLE `ForEach`. This is the fix for the
                // "selecting one row highlights several" bug: a recursively-nested
                // `Group` + conditional `ForEach` view tree gives `List` ambiguous
                // row identity, so its row reuse can paint the selection highlight on
                // the wrong (or extra) rows. A flat `ForEach` over rows with unique,
                // path-stable ids removes that ambiguity entirely.
                ForEach(OutlinerRow.flatten(root: root, expanded: expandedEntityIDs)) { row in
                    OutlinerRowView(
                        store: store,
                        row: row,
                        rootID: root.id,
                        expandedEntityIDs: $expandedEntityIDs,
                        selectedComponent: $selectedOutlinerComponent
                    )
                }

                // Script graphs as first-class, browsable assets: open the editor
                // directly here instead of hunting for which entity references one.
                // Buttons (not selectable rows) so they don't fight the entity tree's
                // selection binding.
                if !store.scriptGraphAssets.isEmpty {
                    Section("Script Graphs") {
                        ForEach(store.scriptGraphAssets) { asset in
                            Button {
                                store.send(.scriptGraphOpened(asset.id))
                            } label: {
                                Label(asset.name, systemImage: "point.3.connected.trianglepath.dotted")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(asset.id == store.openScriptGraphID ? Color.accentColor : .primary)
                        }
                    }
                }
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
        if isPlaying, let graph = playingGraph {
            // CANONICAL PLAY (inline): the app injects its concrete play view here.
            // Fills the column; `.id(graphKey)` keeps its identity stable for the run.
            canonicalPlay(graph)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(playKey)
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

    /// The key for the graph the Run/Play affordance would run, for `.id(_:)` stability
    /// of the inline canonical Play view across body passes. Same derivation as
    /// `graphKey(for:)`, off the previewable graph; falls back to a constant when nothing
    /// is runnable (the Play view isn't shown then).
    private var playKey: String {
        previewableGraph.map { graphKey(for: $0) } ?? "graph"
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

    // MARK: Play lifecycle (canonical, inline)

    /// Starts the inline canonical Play: captures the graph to run and swaps the
    /// center column to the app-injected canonical view. A no-op if already playing
    /// or there's nothing runnable.
    private func startPlaying() {
        guard !isPlaying, let graph = previewableGraph else { return }
        playingGraph = graph
        isPlaying = true
    }

    /// Stops the inline canonical Play: tears down the canonical view (which releases
    /// its `RealityView`/runtime) and returns the center column to the viewport.
    private func stopPlaying() {
        isPlaying = false
        playingGraph = nil
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
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

/// One visible line in the outliner: an entity, or one of that entity's component
/// rows. Carries a unique, path-stable `id` so the whole tree can be rendered by a
/// single `ForEach` — see `OutlinerRow.flatten`. Internal (not private) so the pure
/// `flatten` can be unit-tested for unique ids.
struct OutlinerRow: Identifiable {
    enum Kind: Equatable {
        case entity
        case component(EntityOutlinerComponent)
    }

    /// Globally-unique, stable identity: the slash-joined ancestor *index* path plus
    /// each entity's `id` (and, for component rows, the component id). Index-keyed so
    /// it stays unique even if two entities ever shared a content id.
    let id: String
    let entity: RCP3Entity
    /// The row's own indentation depth (component rows sit one level under their entity).
    let depth: Int
    let kind: Kind
    /// Entity rows only: whether a disclosure triangle is shown / the row is expanded.
    let hasChildren: Bool
    let isExpanded: Bool

    /// Pre-flattens the entity tree (honoring `expanded`) into the ordered rows the
    /// outliner draws. A pure function — unit-tested for unique ids — so the view can
    /// render one flat, unambiguously-identified `ForEach` instead of a recursively
    /// nested `Group`/`ForEach` whose identity `List` mis-assigns.
    static func flatten(
        root: RCP3Entity,
        expanded: Set<RCP3Entity.ID>
    ) -> [OutlinerRow] {
        var rows: [OutlinerRow] = []

        func visit(_ entity: RCP3Entity, depth: Int, pathPrefix: String) {
            let path = "\(pathPrefix)/\(entity.id)"
            let components = entity.outlinerComponents
            let isExpanded = expanded.contains(entity.id)
            let hasChildren = !components.isEmpty || !entity.children.isEmpty

            rows.append(
                OutlinerRow(
                    id: path,
                    entity: entity,
                    depth: depth,
                    kind: .entity,
                    hasChildren: hasChildren,
                    isExpanded: isExpanded
                )
            )

            guard isExpanded else { return }

            for component in components {
                rows.append(
                    OutlinerRow(
                        id: "\(path)#\(component.id)",
                        entity: entity,
                        depth: depth + 1,
                        kind: .component(component),
                        hasChildren: false,
                        isExpanded: false
                    )
                )
            }

            for (index, child) in entity.children.enumerated() {
                visit(child, depth: depth + 1, pathPrefix: "\(path)/\(index)")
            }
        }

        visit(root, depth: 0, pathPrefix: "")
        return rows
    }
}

/// Draws a single pre-flattened `OutlinerRow`. All rows live in one `List` `ForEach`,
/// so identity is unambiguous; the selection highlight is a plain per-row comparison.
private struct OutlinerRowView: View {
    @Bindable var store: StoreOf<DocumentFeature>
    let row: OutlinerRow
    let rootID: RCP3Entity.ID
    @Binding var expandedEntityIDs: Set<RCP3Entity.ID>
    @Binding var selectedComponent: EntityOutlinerComponentSelection?

    private var entity: RCP3Entity { row.entity }
    private var depth: Int { row.depth }
    private var isExpanded: Bool { row.isExpanded }
    private var hasChildren: Bool { row.hasChildren }
    private var isEntitySelected: Bool {
        store.selection == entity.id && selectedComponent?.entityID != entity.id
    }

    var body: some View {
        switch row.kind {
        case .entity:
            entityRow
        case let .component(component):
            componentRow(component)
        }
    }

    private var entityRow: some View {
        HStack(spacing: 6) {
            disclosure
            Image(systemName: entity.outlinerSymbolName)
                .foregroundStyle(entity.outlinerSymbolStyle)
                .frame(width: 16)
            Text(entity.displayName)
                .lineLimit(1)
                .fontWeight(isEntitySelected ? .semibold : .regular)
            Spacer(minLength: 8)
            if isEntitySelected {
                Image(systemName: "lock.open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isEntitySelected ? Color.accentColor : Color.clear)
        }
        .foregroundStyle(isEntitySelected ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedComponent = nil
            store.send(.selected(entity.id))
        }
        .contextMenu { entityContextMenu }
        .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
    }

    private var disclosure: some View {
        Button {
            toggleExpanded()
        } label: {
            Image(systemName: hasChildren ? (isExpanded ? "chevron.down" : "chevron.right") : "")
                .font(.caption)
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasChildren)
    }

    private func componentRow(_ component: EntityOutlinerComponent) -> some View {
        let isSelected = selectedComponent == .init(entityID: entity.id, component: component)
        return HStack(spacing: 6) {
            Color.clear.frame(width: 12, height: 16)
            Image(systemName: component.symbolName)
                .foregroundStyle(isSelected ? Color.white : component.tint)
                .frame(width: 16)
            Text(component.displayName)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .fontWeight(component.kind == .transform ? .semibold : .regular)
            Spacer(minLength: 8)
        }
        // `row.depth` already includes the +1 offset for component rows.
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedComponent = .init(entityID: entity.id, component: component)
            store.send(.selected(entity.id))
        }
        .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
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

        Button("Add Component...") {}
            .disabled(true)
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

    private func toggleExpanded() {
        if isExpanded {
            expandedEntityIDs.remove(entity.id)
        } else {
            expandedEntityIDs.insert(entity.id)
        }
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
            }
            .formStyle(.grouped)
            .navigationTitle(component.displayName)
        }
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

            if let graph = store.selectedScriptGraph {
                ScriptGraphSection(graph: graph)
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

    var body: some View {
        Form {
            if let title = model.node(nodeID)?.payload.title {
                LabeledContent("Node", value: title)
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

/// One editable scalar-literal row: a labelled numeric `TextField` plus a `Stepper`,
/// both writing through `setLiteral`. The binding reads the pin's current value
/// (authored, else `0`) and writes the edited number straight to the model.
private struct LiteralRow: View {
    @Bindable var model: ScriptGraphEditorModel
    let literal: EditableLiteral

    private var value: Binding<Double> {
        Binding(
            get: { model.literal(nodeID: literal.key.nodeID, pinConnectorHash: literal.key.pinConnectorHash) ?? 0 },
            set: { model.setLiteral(nodeID: literal.key.nodeID, pinConnectorHash: literal.key.pinConnectorHash, value: $0) }
        )
    }

    var body: some View {
        LabeledContent(literal.displayName) {
            HStack(spacing: 8) {
                TextField(literal.displayName, value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .accessibilityLabel(literal.displayName)
                Stepper(literal.displayName, value: value)
                    .labelsHidden()
                    .accessibilityLabel("\(literal.displayName) stepper")
            }
        }
    }
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

private extension RCP3Entity {
    var displayName: String { name.isEmpty ? "(unnamed)" : name }
    var symbolName: String {
        if name == "world" { return "globe" }
        if prototypeUUID != nil { return "cube.fill" }
        return "cube"
    }
    var outlinerSymbolName: String {
        if name == "world" { return "cube" }
        if isGeometryPrototypeInstance { return "shippingbox" }
        return prototypeUUID == nil ? "cube" : "shippingbox"
    }
    var outlinerSymbolStyle: Color {
        isGeometryPrototypeInstance ? .purple : .secondary
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
