import AppKit
import ComposableArchitecture
import RCP3Document
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
            // Center column: the reconstructed 3D viewport (StageView-backed).
            // It is fed the live (possibly unsaved) scene graph + a selection
            // binding so renames reflect and picks flow back to the store.
            RCP3ViewportView(
                sceneGraph: store.sceneGraph,
                selection: $store.selection.sending(\.selected)
            )
            .navigationTitle("Viewport")
            .frame(minWidth: 320)
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
        }
        .formStyle(.grouped)
        .navigationTitle(entity.displayName)
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
