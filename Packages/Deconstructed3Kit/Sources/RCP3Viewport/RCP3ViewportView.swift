import ComposableArchitecture
import RCP3Document
import RealityKit
import RealityKitStageView
import SwiftUI

/// The Deconstructed 3 viewport, built on StageView's `RealityKitStageView`.
///
/// Unlike the hand-rolled `SceneViewportView` it replaces, this view does not
/// implement its own camera, grid, picking, or selection outline — it reconstructs
/// our `.tm_*` scene graph into RealityKit entities and injects them into
/// StageView's proven RealityKit viewport via `RealityKitProvider.setModel`.
///
/// ## Selection bridge (on our uuid)
/// - **Host → viewport:** when `selection` changes, the matching node's full
///   StageView prim path is pushed via `provider.setSelection`.
/// - **Viewport → host:** a viewport pick is observed on `provider.selectedPrimPath`
///   (bumped by `RealityKitProvider.userDidPick`); we decode its leaf component
///   back to our uuid and write the `selection` binding.
///
/// ## Store wiring
/// `RealityKitStageView`'s load flow is URL/command driven and its pick gate
/// (`shouldAcceptViewportPick`) refuses picks unless `store.modelURL != nil`. We
/// drive the viewport entirely through the provider (`setModel`), so we set a
/// **sentinel `modelURL`** in the store to satisfy that gate without ever issuing
/// a real load command (`activeLoadCommand` is cleared immediately). The store is
/// otherwise used only for `sceneBounds` and selection state. See
/// `Docs/StageView-Adoption.md`.
public struct RCP3ViewportView: View {
    /// The reconstructed scene to display. A new graph rebuilds the hierarchy.
    private let sceneGraph: RCP3SceneNode?
    /// The host's selected entity uuid (`RCP3SceneNode.id` == `RCP3Entity.id`).
    @Binding private var selection: String?

    @State private var provider = RealityKitProvider()
    @State private var store = Store(initialState: StageViewFeature.State()) {
        StageViewFeature()
    }
    /// `node.id` (uuid) → StageView prim-path string, rebuilt with the entities.
    @State private var primPathByNodeID: [String: String] = [:]

    /// - Parameters:
    ///   - sceneGraph: the `.tm_*`-reconstructed scene to materialize, or `nil`.
    ///   - selection: a two-way binding to the selected entity uuid.
    public init(sceneGraph: RCP3SceneNode?, selection: Binding<String?>) {
        self.sceneGraph = sceneGraph
        self._selection = selection
    }

    public var body: some View {
        Group {
            if sceneGraph != nil {
                RealityKitStageView(
                    provider: provider,
                    store: store,
                    configuration: configuration
                )
            } else {
                ContentUnavailableView("No scene", systemImage: "cube.transparent")
            }
        }
        .onAppear { rebuild(from: sceneGraph) }
        .onChange(of: sceneGraph) { _, newValue in rebuild(from: newValue) }
        // Host → viewport selection.
        .onChange(of: selection) { _, newValue in pushSelection(newValue) }
        // Viewport → host selection: a pick bumps the provider's selection state.
        .onChange(of: provider.selectionGeneration) { _, _ in
            adoptViewportSelection(provider.selectedPrimPath)
        }
    }

    /// Minimal viewport configuration: RealityKit Y-up, 1 unit = 1 meter (matching
    /// what we pass to `setModel`); everything else is StageView's default. Dark-
    /// mode theming is an open StageView-adoption friction — see
    /// `Docs/StageView-Adoption.md`.
    private var configuration: RealityKitConfiguration {
        var config = RealityKitConfiguration()
        config.metersPerUnit = 1
        config.isZUp = false
        return config
    }

    // MARK: - Model injection

    @MainActor
    private func rebuild(from node: RCP3SceneNode?) {
        guard let node else {
            store.send(.clearRequested)
            primPathByNodeID = [:]
            return
        }

        let build = RCP3EntityBuilder.build(from: node)
        primPathByNodeID = build.primPathByNodeID

        store.send(.setSceneBounds(build.bounds))
        setSentinelModelURL()

        provider.setModel(build.root, metersPerUnit: 1, isZUp: false)
        provider.setExternalSceneBounds(build.bounds)

        // Re-apply any standing host selection to the freshly built tree.
        pushSelection(selection)
    }

    /// Sets a non-file sentinel `modelURL` so `shouldAcceptViewportPick` passes,
    /// then clears the load command so the URL/command lane never runs. The
    /// provider owns the actual entity via `setModel`.
    @MainActor
    private func setSentinelModelURL() {
        guard store.modelURL == nil else { return }
        store.send(
            .loadRequested(
                commandID: UUID(),
                url: URL(string: "rcp3-viewport://injected")!,
                preserveCamera: false
            )
        )
        if let command = store.activeLoadCommand {
            store.send(.loadCommandCompleted(command.id))
        }
    }

    // MARK: - Selection bridge

    /// Host → viewport: push the prim path for `nodeID` into the provider.
    @MainActor
    private func pushSelection(_ nodeID: String?) {
        let path = nodeID.flatMap { primPathByNodeID[$0] }
        guard provider.selectedPrimPath != path else { return }
        provider.setSelection(path)
    }

    /// Viewport → host: decode a prim path back to our uuid and write `selection`.
    @MainActor
    private func adoptViewportSelection(_ path: String?) {
        let nodeID = RCP3EntityBuilder.nodeID(forPrimPath: path)
        if selection != nodeID {
            selection = nodeID
        }
    }
}
