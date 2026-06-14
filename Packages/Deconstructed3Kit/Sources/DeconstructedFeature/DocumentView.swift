import AppKit
import ComposableArchitecture
import RCP3Document
import RCP3GraphEditor
import RCP3Runtime
import RCP3Viewport
import SwiftUI
import simd

/// The Deconstructed 3 main window: a 3-pane `NavigationSplitView` driven entirely
/// by `StoreOf<DocumentFeature>`.
///
/// - **Sidebar:** the entity tree, selection bound to the store.
/// - **Center:** `RCP3ViewportView`, fed the store's live `sceneGraph` and a
///   selection binding — a rename re-derives the graph, so the viewport entity
///   name updates without a reload.
/// - **Detail:** the *editable* inspector, whose Name field drives `nameEdited`.
///
/// Save lives on the toolbar (and ⌘S), enabled only while `hasUnsavedChanges`.
public struct DocumentView: View {
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

    // MARK: Play mode (spatial run)

    /// Whether the script graph is running LIVE in the 3D viewport (Play). When on,
    /// the viewport reports drags to the runtime instead of orbiting the camera, and
    /// the resulting transform drives the real reconstructed entity.
    @State private var isPlaying = false
    /// The live entity model the running graph mutates (the runtime's authored side
    /// of the bridge). Held across body passes so drags accumulate. `nil` when not
    /// playing.
    @State private var playState: RuntimeEntityState?
    /// The running JS host (compiled graph + bound `playState`). `nil` when stopped.
    @State private var playHost: ScriptJSHost?
    /// The node uuid Play is driving (captured when Play starts, so the target is
    /// stable even if the selection changes while playing). `nil` when stopped.
    @State private var playTargetNodeID: String?
    /// The transform published to the viewport to apply live to `playTargetNodeID`.
    /// Set after each drag dispatch; the viewport applies it via `applyLiveTransform`.
    @State private var liveTransform: LiveTransform?
    /// The target entity's AUTHORED transform, snapshotted when Play begins (keyed by
    /// node uuid). On Stop it is published back through `liveTransform` so the entity
    /// returns exactly to its authored pose — `applyLiveTransform` mutates the live
    /// entity in place and never restored it otherwise. `nil` when not playing.
    @State private var authoredSnapshot: LiveTransform?

    public init(store: StoreOf<DocumentFeature>) {
        self.store = store
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

    /// The graph the spatial Play would run in the 3D viewport. v1 drives the
    /// *selected* entity, so this is the selected entity's graph (the box, when
    /// selected). `nil` when the selection has no graph — Play is then disabled.
    private var playableGraph: RCP3ScriptGraph? {
        store.selectedScriptGraph
    }

    /// The node uuid Play would drive: the selected entity (v1 limitation — see the
    /// Play button doc). Valid only when that entity actually carries a graph.
    private var playableTargetNodeID: String? {
        store.selectedScriptGraph == nil ? nil : store.selection
    }

    /// Whether the spatial Play toggle is available: the center shows the viewport
    /// and the selected entity has a runnable graph + a resolvable target uuid.
    private var canPlay: Bool {
        centerMode == .viewport && playableGraph != nil && playableTargetNodeID != nil
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
            if let entity = store.selectedEntity {
                EntityInspectorView(store: store, entity: entity)
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "cube")
            }
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

    // MARK: Center column (viewport ⇄ script-graph canvas)

    /// The center column: the 3D viewport, with the visual script-graph canvas
    /// overlaid ON TOP when the user switches to Graph mode (via the toolbar
    /// segmented control).
    ///
    /// CRITICAL (box-vanish fix): the `RCP3ViewportView` is ALWAYS mounted — it is
    /// the bottom layer of a `ZStack` and is never torn down by a mode switch. Were
    /// it conditionally swapped out for the graph canvas (as it once was), switching
    /// to Graph would destroy the viewport's `@State` (provider/store + the injected
    /// RealityKit model); switching back would create a fresh viewport whose
    /// re-injection doesn't reliably re-render (StageView recreation fragility), so
    /// the reconstructed box disappeared. Keeping the viewport mounted means it
    /// builds ONCE (on `onAppear`) and only updates on `sceneGraph` changes —
    /// `setModel` is not re-run on each Graph↔Viewport toggle, so the box persists.
    ///
    /// When `centerMode == .graph`, the graph canvas is drawn on top with an OPAQUE
    /// background so the (still-live) viewport is fully hidden behind it.
    @ViewBuilder
    private var centerColumn: some View {
        ZStack {
            // The reconstructed 3D viewport (StageView-backed), fed the live
            // (possibly unsaved) scene graph + a selection binding so renames
            // reflect and picks flow back to the store. ALWAYS present so it is
            // never torn down (see the type doc above).
            //
            // PLAY: while `isPlaying`, drags are reported to the runtime (camera
            // orbit suppressed by the viewport's play overlay) and the resulting
            // transform is pushed back through `liveTransform` to move the real
            // reconstructed entity. With Play OFF every input is `nil`/false, so the
            // viewport behaves exactly as before.
            RCP3ViewportView(
                sceneGraph: store.sceneGraph,
                selection: $store.selection.sending(\.selected),
                playMode: isPlaying,
                liveTransform: $liveTransform,
                onPlayDrag: handlePlayDrag
            )
            // If the run target disappears (selection/graph change) while playing,
            // stop cleanly rather than driving a stale uuid.
            .onChange(of: canPlay) { _, possible in
                if isPlaying && !possible { stopPlaying() }
            }
            // Leaving the viewport (to the graph canvas) stops a running graph.
            .onChange(of: centerMode) { _, mode in
                if mode != .viewport && isPlaying { stopPlaying() }
            }

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
        // PLAY / STOP: run the script graph LIVE in the 3D viewport, driving the
        // real reconstructed entity. AVAILABILITY is relaxed to "a graph is open"
        // (`canRunPreview`) so the toggle isn't wrongly greyed out when the graph
        // lives on a box child rather than the selected entity. Actually DRIVING the
        // 3D entity still requires viewport mode + a resolvable target — `startPlaying`
        // is a no-op without `playableGraph`/`playableTargetNodeID`, so the live-Play
        // behavior is otherwise unchanged.
        ToolbarItem {
            Button(
                isPlaying ? "Stop" : "Play",
                systemImage: isPlaying ? "stop.fill" : "play.fill"
            ) {
                if isPlaying { stopPlaying() } else { startPlaying() }
            }
            .disabled(!canRunPreview && !isPlaying)
            .help(isPlaying
                ? "Stop the running graph and restore the entity"
                : "Run this script graph live in the viewport (drag to drive the entity)")
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
    }

    // MARK: Play lifecycle (spatial run)

    /// Starts a live spatial run: compiles + runs the selected entity's graph on the
    /// RCP3 runtime, captures the target uuid, snapshots the target's AUTHORED pose
    /// (for restore on Stop), seeds the runtime from that pose, and flips the
    /// viewport into play mode. Idempotent and a no-op if there's nothing runnable.
    private func startPlaying() {
        guard !isPlaying, let graph = playableGraph, let target = playableTargetNodeID else { return }

        // Make the result visible: Play from the Graph view would otherwise be blind.
        centerMode = .viewport

        // Snapshot the authored pose so Stop can restore the entity exactly.
        let authored = authoredTransform(forNodeID: target)
        authoredSnapshot = authored

        // Seed the runtime from the AUTHORED transform so the run starts at the box's
        // real pose; drags then accumulate from there (publishing identity here would
        // teleport the box to the origin on Play). Falls back to identity if the node
        // has no resolvable authored transform.
        let state = RuntimeEntityState()
        if let authored {
            state.translation = SIMD3(
                Double(authored.translation.x),
                Double(authored.translation.y),
                Double(authored.translation.z)
            )
            let q = authored.rotation
            state.rotation = simd_quatd(ix: Double(q.imag.x), iy: Double(q.imag.y), iz: Double(q.imag.z), r: Double(q.real))
            state.scale = SIMD3(Double(authored.scale.x), Double(authored.scale.y), Double(authored.scale.z))
        }

        playHost = ScriptGraphRunner.run(graph, into: state)
        playState = state
        playTargetNodeID = target
        isPlaying = true
        // Don't publish a transform on start — the entity is already at the authored
        // pose (and the runtime is seeded from it). The first drag publishes the first
        // delta from there, so Play start is visually a no-op.
    }

    /// Stops the run, restores the entity to its authored pose, and tears down the
    /// runtime. Restore publishes the snapshot through `liveTransform` so the viewport
    /// (kept mounted — Bug 1) sets the live entity back exactly; clearing the snapshot
    /// + runtime then leaves the box at its authored transform.
    private func stopPlaying() {
        isPlaying = false
        playHost = nil
        playState = nil
        // Restore the authored pose: re-publish the snapshot as the final live
        // transform so the viewport sets the entity back. (The viewport mutated it in
        // place during the run; nothing else restores it.)
        if let snapshot = authoredSnapshot {
            liveTransform = snapshot
        } else {
            liveTransform = nil
        }
        playTargetNodeID = nil
        authoredSnapshot = nil
    }

    /// The authored local transform of `nodeID` from the live scene graph, as a
    /// `LiveTransform` (so it round-trips through the same viewport apply path). `nil`
    /// if the node isn't in the scene graph.
    private func authoredTransform(forNodeID nodeID: String) -> LiveTransform? {
        guard let node = sceneNode(id: nodeID, in: store.sceneGraph) else { return nil }
        let t = node.translation, r = node.rotation, s = node.scale
        return LiveTransform(
            nodeID: nodeID,
            translation: SIMD3(Float(t.x), Float(t.y), Float(t.z)),
            rotation: simd_quatf(ix: Float(r.x), iy: Float(r.y), iz: Float(r.z), r: Float(r.w)),
            scale: SIMD3(Float(s.x), Float(s.y), Float(s.z))
        )
    }

    /// Depth-first search for the scene node with `id` in the reconstructed tree.
    private func sceneNode(id: String, in node: RCP3SceneNode?) -> RCP3SceneNode? {
        guard let node else { return nil }
        if node.id == id { return node }
        for child in node.children {
            if let found = sceneNode(id: id, in: child) { return found }
        }
        return nil
    }

    /// A play-mode drag from the viewport: dispatch a `"drag"` to the runtime, then
    /// publish the updated transform so the viewport moves the real entity.
    private func handlePlayDrag(_ delta: SIMD3<Double>) {
        guard isPlaying, let host = playHost else { return }
        host.dispatch(event: "drag", payload: ["delta": [delta.x, delta.y, delta.z]])
        publishLiveTransform()
    }

    /// Reads the runtime's live `RuntimeEntityState` and publishes it as a
    /// `LiveTransform` (converted to `Float`) for the viewport's target entity.
    private func publishLiveTransform() {
        guard let state = playState, let target = playTargetNodeID else { return }
        let t = state.translation, s = state.scale, q = state.rotation
        liveTransform = LiveTransform(
            nodeID: target,
            translation: SIMD3(Float(t.x), Float(t.y), Float(t.z)),
            rotation: simd_quatf(
                ix: Float(q.imag.x),
                iy: Float(q.imag.y),
                iz: Float(q.imag.z),
                r: Float(q.real)
            ),
            scale: SIMD3(Float(s.x), Float(s.y), Float(s.z))
        )
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
        if isGraphShown,
           let model = graphModel,
           let rootUUID = store.openScriptGraphID,
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
