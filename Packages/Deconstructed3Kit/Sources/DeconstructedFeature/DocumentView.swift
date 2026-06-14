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

    public init(store: StoreOf<DocumentFeature>) {
        self.store = store
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
                // Fall back to the viewport whenever the current selection has no
                // script graph, so the mode can't get stuck on an empty canvas.
                .onChange(of: store.selectedScriptGraph == nil) { _, noGraph in
                    if noGraph { centerMode = .viewport }
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

    /// The 3D viewport, or — when the selected entity has a script graph and the
    /// user switches to it — the visual node-graph canvas.
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
            .navigationTitle("Viewport")
        case .graph:
            if let graph = store.selectedScriptGraph {
                // Re-create the canvas when the selected graph changes (the bridge
                // builds a fresh `FlowStore` per graph). `id` keys it to the graph.
                ScriptGraphCanvas(graph: graph)
                    .id(store.selection)
                    .navigationTitle("Script Graph")
            } else {
                ContentUnavailableView(
                    "No script graph",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Select an entity with a script graph to see its nodes.")
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var centerToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $centerMode) {
                ForEach(CenterMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            // Graph mode is only meaningful when the selection carries a graph.
            .disabled(store.selectedScriptGraph == nil)
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem {
            Button("Open…", systemImage: "folder") { presentOpenPanel() }
        }
        ToolbarItem {
            Button("Save", systemImage: "square.and.arrow.down") {
                store.send(.saveTapped)
            }
            .disabled(!store.hasUnsavedChanges)
            .keyboardShortcut("s", modifiers: .command)
        }
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
