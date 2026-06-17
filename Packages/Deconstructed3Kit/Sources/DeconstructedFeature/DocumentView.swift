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
            List(selection: $store.selection.sending(\.selected)) {
                OutlineGroup(root, children: \.optionalChildren) { entity in
                    Label(entity.displayName, systemImage: entity.symbolName)
                        .tag(entity.id)
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
                .id(graphKey)
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
            let key = graphKey
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

    /// The identity of the currently shown graph (open asset id, else the selection).
    private var graphKey: String {
        store.openScriptGraphID ?? store.selection ?? "graph"
    }

    /// The canvas over the host-owned model for `graph`, (re)building the model when
    /// the shown graph changes. The build happens in `task(id:)` (not in `body`), so
    /// `@State` is never mutated mid-evaluation.
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
        // ▶ Play to run it on the box. Runs-today examples are listed first; the
        // needs-variables ports are marked "(needs variables)".
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
                    Text(example.runsToday ? example.name : "\(example.name) (needs variables)")
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
        // Only write back to a REAL on-disk asset (`openAssetGraphID`). A loaded
        // Examples-gallery graph has no backing `.tm_script_graph`, so Save skips the
        // graph write-back for it (the entity save below still runs).
        if isGraphShown,
           let model = graphModel,
           let rootUUID = store.openAssetGraphID,
           let bundleURL = store.editor?.bundle.url {
            do {
                try ScriptGraphWriteBack.write(
                    model: model,
                    toAssetWithRootUUID: rootUUID,
                    in: bundleURL
                )
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

            if !entity.componentTypes.isEmpty {
                Section("Components") {
                    ForEach(Array(entity.componentTypes.enumerated()), id: \.offset) { _, type in
                        Text(type).font(.callout.monospaced())
                    }
                }
            }

            if let graph = store.selectedScriptGraph {
                ScriptGraphSection(graph: graph)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(entity.displayName)
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
}

private extension RCP3Entity {
    var optionalChildren: [RCP3Entity]? { children.isEmpty ? nil : children }
    var displayName: String { name.isEmpty ? "(unnamed)" : name }
    var symbolName: String {
        if name == "world" { return "globe" }
        if prototypeUUID != nil { return "cube.fill" }
        return "cube"
    }
}
