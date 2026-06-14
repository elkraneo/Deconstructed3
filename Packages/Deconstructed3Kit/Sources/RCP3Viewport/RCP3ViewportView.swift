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

    /// Play mode: when `true`, a viewport drag is captured by an overlay and
    /// reported to `onPlayDrag` as a **scene-space delta** instead of orbiting the
    /// camera. When `false`, this view behaves exactly as before — the overlay does
    /// not exist, so orbit / pan / pick / selection round-trip are untouched.
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
    /// The last drag location during a play-mode drag, to compute incremental
    /// deltas. `nil` between drags.
    @State private var lastPlayDragLocation: CGPoint?

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
                // Play-mode drag capture: a transparent overlay that exists ONLY
                // while playing. It sits above the StageView and consumes the drag,
                // so the underlying camera gesture never sees it (no orbit). When
                // `playMode` is false the overlay is absent and the viewport behaves
                // exactly as before.
                .overlay { playDragOverlay }
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
        // Host → viewport live transform (Play mode): apply each published value to
        // the target entity. A no-op when `nil` or the node isn't found.
        .onChange(of: liveTransform) { _, newValue in apply(newValue) }
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

    // MARK: - Play-mode drag capture

    /// A transparent gesture surface shown only in play mode. It reads incremental
    /// drag deltas and maps screen drag → scene delta (see `sceneDelta(for:)`),
    /// reporting them to `onPlayDrag`. Returns `EmptyView` when not playing so the
    /// off path is allocation- and behavior-identical to before.
    @ViewBuilder
    private var playDragOverlay: some View {
        if playMode {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let last = lastPlayDragLocation ?? value.location
                            let dScreen = CGSize(
                                width: value.location.x - last.x,
                                height: value.location.y - last.y
                            )
                            lastPlayDragLocation = value.location
                            // Project the screen drag onto the *current* camera view
                            // plane so the move is correct from any orbit, not front-on.
                            let delta = Self.sceneDelta(
                                for: dScreen,
                                cameraRotation: provider.cameraRotation,
                                distance: provider.cameraDistance
                            )
                            if delta != .zero { onPlayDrag(delta) }
                        }
                        .onEnded { _ in lastPlayDragLocation = nil }
                )
        }
    }

    /// Maps an incremental **screen** drag (points) to a **scene-space** delta,
    /// projected onto the *camera's* view plane so the entity tracks the cursor from
    /// any orbit — not a fixed front-on world plane.
    ///
    /// The drag moves the entity in the plane facing the camera: screen +x follows
    /// the camera's world **right**, and screen +y (downward) follows the camera's
    /// world **down** (so a drag up moves the entity up on screen). The camera looks
    /// down its local −Z, so its world basis is `rotation·(+X)` = right and
    /// `rotation·(+Y)` = up. With the default front-on camera this reduces to the old
    /// world x / −y mapping; once orbited, the axes follow the view — which is the
    /// 3D-correct behavior (the previous version ignored the camera, applying a flat
    /// front-on transform). Magnitude is proportional to the camera distance, mirroring
    /// StageView's pan feel (`distance * 0.00125`, which at the canonical distance of 4
    /// equals the old fixed 1/200), so the move tracks the cursor whether zoomed in or
    /// out.
    static func sceneDelta(
        for screen: CGSize,
        cameraRotation: simd_quatf,
        distance: Float
    ) -> SIMD3<Double> {
        // The camera's world right/up axes (it looks down local −Z).
        let right = cameraRotation.act(SIMD3<Float>(1, 0, 0))
        let up = cameraRotation.act(SIMD3<Float>(0, 1, 0))
        // Points → scene units, proportional to distance (so a fixed-pixel drag moves
        // farther when zoomed out). Clamped so a degenerate distance can't zero it out.
        let perPoint = Double(max(distance, 0.001)) * 0.00125
        let dRight = Double(screen.width) * perPoint
        let dUp = Double(-screen.height) * perPoint
        func d(_ v: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3(Double(v.x), Double(v.y), Double(v.z))
        }
        return d(right) * dRight + d(up) * dUp
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
            entityByNodeID = [:]
            return
        }

        let build = RCP3EntityBuilder.build(from: node)
        primPathByNodeID = build.primPathByNodeID
        entityByNodeID = build.entityByNodeID

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
