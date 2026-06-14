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

    public init(store: StoreOf<DocumentFeature>) {
        self.store = store
    }

    /// Whether a script-graph canvas is currently shown (graph mode with a graph).
    private var isGraphShown: Bool {
        centerMode == .graph && (store.openScriptGraph ?? store.selectedScriptGraph) != nil
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

    /// The center column: the 3D viewport, or the visual script-graph canvas when
    /// the user switches to it (via the toolbar segmented control, which only
    /// appears while the selected entity carries a script graph).
    @ViewBuilder
    private var centerColumn: some View {
        switch centerMode {
        case .viewport:
            // The reconstructed 3D viewport (StageView-backed), fed the live
            // (possibly unsaved) scene graph + a selection binding so renames
            // reflect and picks flow back to the store.
            RCP3ViewportView(
                sceneGraph: store.sceneGraph,
                selection: $store.selection.sending(\.selected)
            )
        case .graph:
            // An asset opened from the sidebar takes precedence; otherwise fall back
            // to the selected entity's graph.
            if let graph = store.openScriptGraph ?? store.selectedScriptGraph {
                let key = graphKey
                // The model is owned HERE (not by the canvas) so Save can write its
                // live edits back to the `.tm_script_graph`. It is (re)built by
                // `syncGraphModel(for:)` whenever the shown graph changes; `id` keys
                // the canvas to the graph so SwiftUI rebuilds it too.
                graphCanvas(for: graph, key: key)
            } else {
                ContentUnavailableView(
                    "No script graph",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Open a script graph from the sidebar, or select an entity that has one.")
                )
            }
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
