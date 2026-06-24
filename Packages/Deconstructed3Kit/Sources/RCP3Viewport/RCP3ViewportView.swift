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
/// We drive the viewport entirely through the provider (`setModel`). StageView
/// 0.3.27's `RealityKitConfiguration.source = .injectedEntity` gates picking on
/// the runtime being loaded alone, so no `modelURL` (or sentinel load command) is
/// needed. The store is otherwise used only for `sceneBounds` and selection
/// state. See `Docs/StageView-Adoption.md`.
///
/// ## Play-mode drag
/// In Play, the viewport uses StageView's native `.entityDrag` interaction mode:
/// a drag on the selected (Play target) entity is reported in scene space via
/// `RealityKitProvider.setEntityDragHandler`, which we forward to `onPlayDrag`.
/// StageView does the camera-basis screen→scene projection and does not move the
/// entity itself — Play routes the move through the script graph and publishes the
/// result back via `liveTransform`.
public struct RCP3ViewportView: View {
    /// The reconstructed scene to display. A new graph rebuilds the hierarchy.
    private let sceneGraph: RCP3SceneNode?
    /// The host's selected entity uuid (`RCP3SceneNode.id` == `RCP3Entity.id`).
    @Binding private var selection: String?

    /// Play mode: when `true`, the viewport runs StageView's `.entityDrag`
    /// interaction mode, reporting a drag on the selected entity to `onPlayDrag`
    /// as a **scene-space delta** instead of orbiting the camera. When `false`,
    /// interaction mode is `.camera`, so orbit / pan / pick / selection round-trip
    /// are untouched.
    private let playMode: Bool
    /// Called during a play-mode drag with the incremental scene-space delta since
    /// the last callback. The host (e.g. a `DocumentView` running a script graph)
    /// turns this into a runtime `"drag"` event and then publishes the resulting
    /// transform back via the `liveTransform` binding. No-op closure when not playing.
    private let onPlayDrag: (SIMD3<Double>) -> Void
    /// A host-published transform to apply live to one entity (by node uuid). The
    /// viewport applies it via `applyLiveTransform` whenever it changes. This binding
    /// is the robust host→viewport application path: because `RCP3ViewportView` is a
    /// value type recreated each `body` pass, a stored reference to call a method on
    /// would be brittle; an observed input is the SwiftUI-idiomatic alternative. The
    /// public `applyLiveTransform(...)` method is also available for direct callers.
    @Binding private var liveTransform: LiveTransform?

    @State private var provider = RealityKitProvider()
    @State private var store = Store(initialState: StageViewFeature.State()) {
        StageViewFeature()
    }
    /// `node.id` (uuid) → StageView prim-path string, rebuilt with the entities.
    @State private var primPathByNodeID: [String: String] = [:]
    /// `node.id` (uuid) → the reconstructed RealityKit entity, rebuilt with the
    /// tree. Used as a fallback for `applyLiveTransform` when the provider's
    /// prim-path mapping hasn't resolved (the entities are the very ones the
    /// provider holds via `setModel`, so mutating them is the same object).
    @State private var entityByNodeID: [String: Entity] = [:]

    /// - Parameters:
    ///   - sceneGraph: the `.tm_*`-reconstructed scene to materialize, or `nil`.
    ///   - selection: a two-way binding to the selected entity uuid.
    ///   - playMode: when `true`, drags drive `onPlayDrag` instead of the camera.
    ///   - liveTransform: a host-published transform applied live to one entity.
    ///   - onPlayDrag: receives the incremental scene-space drag delta in play mode.
    public init(
        sceneGraph: RCP3SceneNode?,
        selection: Binding<String?>,
        playMode: Bool = false,
        liveTransform: Binding<LiveTransform?> = .constant(nil),
        onPlayDrag: @escaping (SIMD3<Double>) -> Void = { _ in }
    ) {
        self.sceneGraph = sceneGraph
        self._selection = selection
        self.playMode = playMode
        self._liveTransform = liveTransform
        self.onPlayDrag = onPlayDrag
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
        .onAppear {
            rebuild(from: sceneGraph)
            installEntityDragHandler()
        }
        .onChange(of: sceneGraph) { _, newValue in rebuild(from: newValue) }
        // Re-bind the entity-drag forwarder when play mode toggles so it captures
        // the current `onPlayDrag`.
        .onChange(of: playMode) { _, _ in installEntityDragHandler() }
        // Host → viewport selection.
        .onChange(of: selection) { _, newValue in pushSelection(newValue) }
        // Viewport → host selection: a pick bumps the provider's selection state.
        .onChange(of: provider.selectionGeneration) { _, _ in
            adoptViewportSelection(provider.selectedPrimPath)
        }
        // Host → viewport live transform (Play mode): apply each published value to
        // the target entity. A no-op when `nil` or the node isn't found.
        .onChange(of: liveTransform) { _, newValue in apply(newValue) }
    }

    /// Forwards StageView's scene-space entity-drag samples to `onPlayDrag` as
    /// incremental deltas while playing. Registered on appear and whenever play
    /// mode toggles (to capture the current `onPlayDrag`).
    @MainActor
    private func installEntityDragHandler() {
        let forward = onPlayDrag
        provider.setEntityDragHandler { sample in
            guard sample.phase == .changed else { return }
            if sample.delta != .zero { forward(sample.delta) }
        }
    }

    /// Applies a published `LiveTransform` to its target entity (no-op if `nil`).
    @MainActor
    private func apply(_ transform: LiveTransform?) {
        guard let transform else { return }
        applyLiveTransform(
            translation: transform.translation,
            rotation: transform.rotation,
            scale: transform.scale,
            toNodeID: transform.nodeID
        )
    }

    /// Drives one entity's local transform live, by node uuid, on the reconstructed
    /// RealityKit entity the provider holds. A no-op if the node isn't found. Does
    /// NOT touch the camera or selection.
    ///
    /// GUARD (box-vanish safety): a non-finite (NaN/Inf) translation, rotation, or
    /// scale, or a zero/negative scale on any axis, would collapse the entity to an
    /// invisible point or push it off-screen. Such an apply is REJECTED (no-op) so a
    /// bad runtime value can't make the entity disappear; the entity keeps its last
    /// good transform.
    ///
    /// Resolution order: the provider's prim-path mapping (`entity(for:)`, the
    /// canonical live entity) first, then the builder's `entityByNodeID` as a
    /// fallback (same object — the entities passed to `setModel`).
    @MainActor
    public func applyLiveTransform(
        translation: SIMD3<Float>,
        rotation: simd_quatf,
        scale: SIMD3<Float>,
        toNodeID nodeID: String
    ) {
        guard Self.isApplicable(translation: translation, rotation: rotation, scale: scale) else { return }
        guard let entity = entity(forNodeID: nodeID) else { return }
        entity.transform = Transform(scale: scale, rotation: rotation, translation: translation)
    }

    /// Whether a live transform is safe to apply: every component finite, and every
    /// scale axis strictly positive (a zero/negative scale collapses or mirrors the
    /// entity). Static + pure so it is unit-testable without a viewport.
    public static func isApplicable(
        translation: SIMD3<Float>,
        rotation: simd_quatf,
        scale: SIMD3<Float>
    ) -> Bool {
        let finite = translation.x.isFinite && translation.y.isFinite && translation.z.isFinite
            && rotation.vector.x.isFinite && rotation.vector.y.isFinite
            && rotation.vector.z.isFinite && rotation.vector.w.isFinite
            && scale.x.isFinite && scale.y.isFinite && scale.z.isFinite
        let positiveScale = scale.x > 0 && scale.y > 0 && scale.z > 0
        return finite && positiveScale
    }

    /// The authored local transform of `nodeID`'s entity, for snapshotting before a
    /// live run so the caller can restore it on Stop. `nil` if the node isn't found.
    @MainActor
    public func authoredTransform(forNodeID nodeID: String) -> LiveTransform? {
        guard let entity = entity(forNodeID: nodeID) else { return nil }
        let t = entity.transform
        return LiveTransform(
            nodeID: nodeID,
            translation: t.translation,
            rotation: t.rotation,
            scale: t.scale
        )
    }

    /// Resolves the live RealityKit entity for `nodeID`, preferring the provider's
    /// mapping and falling back to the builder map.
    @MainActor
    private func entity(forNodeID nodeID: String) -> Entity? {
        if let path = primPathByNodeID[nodeID], let entity = provider.entity(for: path) {
            return entity
        }
        return entityByNodeID[nodeID]
    }

    /// Viewport configuration: RealityKit Y-up, 1 unit = 1 meter (matching what we
    /// pass to `setModel`). `source = .injectedEntity` unlocks picking without a
    /// `modelURL`; `appearance = .dark` themes the background + grid; and play mode
    /// switches the interaction mode to `.entityDrag` so a drag on the Play target
    /// is reported in scene space instead of orbiting the camera.
    private var configuration: RealityKitConfiguration {
        var config = RealityKitConfiguration()
        config.metersPerUnit = 1
        config.isZUp = false
        config.source = .injectedEntity
        config.appearance = .dark
        config.interactionMode = playMode ? .entityDrag : .camera
        // Selection outline: StageView defaults to a bounding-box cage; opt into the
        // mesh outline, color it RCP orange, and keep it thin (default width 0.1 reads
        // as a thick halo on unit-sized primitives).
        config.selectionHighlightStyle = .outline
        config.outlineConfiguration = OutlineConfiguration(color: .orange, width: 0.03)
        return config
    }

    // MARK: - Model injection

    @MainActor
    private func rebuild(from node: RCP3SceneNode?) {
        guard let node else {
            store.send(.clearRequested)
            primPathByNodeID = [:]
            entityByNodeID = [:]
            return
        }

        let build = RCP3EntityBuilder.build(from: node)
        primPathByNodeID = build.primPathByNodeID
        entityByNodeID = build.entityByNodeID

        store.send(.setSceneBounds(build.bounds))

        // `source = .injectedEntity` (see `configuration`) unlocks picking on the
        // injected model without a sentinel `modelURL` — no load command needed.
        provider.setModel(build.root, metersPerUnit: 1, isZUp: false)
        provider.setExternalSceneBounds(build.bounds)

        // Re-apply any standing host selection to the freshly built tree.
        pushSelection(selection)
    }

    // MARK: - Selection bridge

    /// Host → viewport: push the prim path for `nodeID` into the provider — but only
    /// for an entity that actually has geometry. StageView's outline recurses into the
    /// selected entity's whole subtree, so selecting a STRUCTURAL node (the `world`
    /// root or a group, which carry no `ModelComponent`) would outline every descendant
    /// — making the entire scene look selected (notably the root auto-selected at open).
    /// A model-less selection therefore clears the viewport outline instead.
    @MainActor
    private func pushSelection(_ nodeID: String?) {
        let path = nodeID.flatMap { id -> String? in
            guard let entity = entity(forNodeID: id),
                  entity.components.has(ModelComponent.self) else { return nil }
            return primPathByNodeID[id]
        }
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

/// A target entity's full local transform to apply live in the viewport, addressed
/// by node uuid. Published by a host (Play mode) through `RCP3ViewportView`'s
/// `liveTransform` binding; `Equatable` so `.onChange` only fires on real changes.
public struct LiveTransform: Equatable, Sendable {
    /// The node uuid (`RCP3SceneNode.id`) of the entity to drive.
    public let nodeID: String
    public let translation: SIMD3<Float>
    public let rotation: simd_quatf
    public let scale: SIMD3<Float>

    public init(
        nodeID: String,
        translation: SIMD3<Float>,
        rotation: simd_quatf,
        scale: SIMD3<Float>
    ) {
        self.nodeID = nodeID
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }
}
