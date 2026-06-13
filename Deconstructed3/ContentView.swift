import RCP3Document
import RCP3Viewport
import SwiftUI

struct ContentView: View {
    @State private var model = SceneModel()

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView {
            Group {
                if let root = model.root {
                    List(selection: $model.selection) {
                        OutlineGroup(root, children: \.optionalChildren) { entity in
                            Label(entity.displayName, systemImage: entity.symbolName)
                                .tag(entity.id)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("No project open", systemImage: "shippingbox")
                    } description: {
                        Text(model.errorMessage ?? "Open a .realitycomposerpro bundle to inspect its scene tree.")
                    } actions: {
                        Button("Open…") { model.presentOpenPanel() }
                    }
                }
            }
            .navigationTitle(model.bundleURL?.lastPathComponent ?? "Deconstructed 3")
            .toolbar {
                ToolbarItem {
                    Button("Open…", systemImage: "folder") { model.presentOpenPanel() }
                }
            }
            .frame(minWidth: 240)
        } content: {
            // Center column: the reconstructed 3D viewport, rendered by StageView's
            // RealityKitStageView (we feed it `.tm_*`-reconstructed RealityKit
            // entities — no USD). See Packages/Deconstructed3Kit `RCP3Viewport`.
            RCP3ViewportView(sceneGraph: model.sceneGraph, selection: $model.selection)
                .navigationTitle("Viewport")
                .frame(minWidth: 320)
        } detail: {
            if let entity = model.selectedEntity {
                EntityDetailView(entity: entity)
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "cube")
            }
        }
    }
}

struct EntityDetailView: View {
    let entity: RCP3Entity

    var body: some View {
        Form {
            LabeledContent("Name", value: entity.displayName)
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

private extension RCP3Entity {
    var optionalChildren: [RCP3Entity]? { children.isEmpty ? nil : children }
    var displayName: String { name.isEmpty ? "(unnamed)" : name }
    var symbolName: String {
        if name == "world" { return "globe" }
        if prototypeUUID != nil { return "cube.fill" }
        return "cube"
    }
}
