import SwiftUI
import RealityKit
import RealityKitScripting
import RCP3Document
import RCP3Runtime
import simd

/// The canonical **Play** view: it runs an RCP 3 script graph on Apple's *real*
/// `RealityKitScripting` runtime, in a `RealityView` we own, with Apple's own
/// debugging surfaced — a live **console** (the structured runtime log) and the
/// **JS debugger** (Safari Web Inspector).
///
/// Mirrors RCP 3's model: the **whole captured scene** is reconstructed into
/// RealityKit entities, and the graph (compiled to public-runtime JavaScript by
/// ``RCP3Runtime/CanonicalScriptGraphCompiler``) is attached — via
/// `ScriptingComponent(source:)` — to the **selected entity**, exactly where RCP
/// authors a scripting component. So pressing ▶ Play runs the graph against
/// whatever entity is selected, in the context of its siblings (entity-lookup nodes
/// resolve against the real scene). When no scene is captured (e.g. an example graph
/// with no project open) a neutral box stands in so the graph still runs.
///
/// Self-contained (its own `RealityView` + orbit camera, not StageView's) so the
/// canonical runtime can be exercised without entangling StageView with a macOS-27
/// binary dependency — the scene reconstruction here is RealityKit-only. Designed to
/// fill a view region INLINE (the document's center column), so its console is a
/// small collapsible OVERLAY rather than a fixed panel that would dominate the view.
@MainActor
public struct CanonicalPlayView: View {
    /// The scene to reconstruct + the per-entity scripts to run. Driven LIVE by the
    /// host and the view is re-`id`'d on `input.signature`, so adding/assigning a graph
    /// to any entity during Play rebuilds and runs it (RCP-like scene simulation).
    private let input: CanonicalPlayScene
    @State private var validationError: String?
    /// Whether the runtime-log console overlay is shown. Collapsed by default so the
    /// inline 3D viewport isn't dominated; a small toolbar button toggles it.
    @State private var showsConsole = false
    /// Weakly holds the running scene so Stop (this view disappearing) can make the
    /// SYMMETRIC `enableDebugger(false)` call for the context it enabled below. RKS
    /// exposes no auto-teardown, so without this each Play leaves a debugger-registered
    /// JSContext behind. Weak: this view must never keep the scene/context alive.
    @State private var session = PlaySession()

    public init(_ input: CanonicalPlayScene) {
        self.input = input
    }

    /// Compiles a graph to the public-runtime JavaScript.
    private static func compile(_ graph: RCP3ScriptGraph) -> String {
        CanonicalScriptGraphCompiler().compile(graph)
    }

    /// A representative compiled source for pre-run validation: the first entity
    /// script, else the preview graph, else `nil`.
    private var representativeSource: String? {
        if let first = input.scripts.first { return Self.compile(first.graph) }
        return input.previewGraph.map(Self.compile)
    }

    /// Reconstructs `node` (and its subtree) into RealityKit entities — the same
    /// node→mesh/transform mapping the viewport uses — and indexes them by node id so
    /// the script can be attached to the selected one. RealityKit-only (no StageView)
    /// to keep this module off the viewport package.
    private static func reconstruct(_ node: RCP3SceneNode) -> (root: Entity, byID: [String: Entity]) {
        var byID: [String: Entity] = [:]
        func build(_ node: RCP3SceneNode) -> Entity {
            let entity: Entity
            if let mesh = mesh(for: node.primitiveKind) {
                entity = ModelEntity(mesh: mesh, materials: [SimpleMaterial(color: .gray, isMetallic: false)])
            } else {
                entity = Entity()
            }
            entity.name = node.name
            entity.transform = transform(of: node)
            byID[node.id] = entity
            for child in node.children {
                entity.addChild(build(child))
            }
            return entity
        }
        return (build(node), byID)
    }

    /// The mesh for a node's primitive kind (`.none` → structural, no mesh). Unit-sized
    /// like the viewport's reconstruction; the node's own scale carries any sizing.
    private static func mesh(for kind: RCP3PrimitiveKind) -> MeshResource? {
        switch kind {
        case .box: return .generateBox(size: 1)
        case .sphere: return .generateSphere(radius: 0.5)
        case .plane: return .generatePlane(width: 1, depth: 1)
        case .none: return nil
        }
    }

    /// Maps a node's `Double` transform tuples to a RealityKit `Transform`.
    private static func transform(of node: RCP3SceneNode) -> Transform {
        let t = node.translation, r = node.rotation, s = node.scale
        return Transform(
            scale: SIMD3(Float(s.x), Float(s.y), Float(s.z)),
            rotation: simd_quatf(ix: Float(r.x), iy: Float(r.y), iz: Float(r.z), r: Float(r.w)),
            translation: SIMD3(Float(t.x), Float(t.y), Float(t.z))
        )
    }

    /// Centers and uniformly scales `container` so the reconstructed scene fits a
    /// small volume around the origin — the inline orbit camera then frames it
    /// regardless of the scene's authored transforms. A no-op for a scene with no
    /// visible geometry (degenerate bounds).
    private static func normalizeForFraming(_ container: Entity) {
        let bounds = container.visualBounds(relativeTo: nil)
        let extents = bounds.extents
        let maxExtent = max(extents.x, extents.y, extents.z)
        guard maxExtent.isFinite, maxExtent > 0 else { return }
        let scale = 0.4 / maxExtent
        container.scale = SIMD3(repeating: scale)
        container.position = -bounds.center * scale
    }

    public var body: some View {
        RealityView { content in
            // Boot the runtime + install the log listener before mounting scripted
            // entities (idempotent).
            try? CanonicalRuntime.initializeOnce()

            // Reconstruct the scene and attach EACH entity's compiled script to its
            // entity — like RCP, where every scripting component runs. The compiled
            // script binds to `this.entity`, so it drives the entity it's attached to.
            let container = Entity()
            if let sceneRoot = input.scene {
                let built = Self.reconstruct(sceneRoot)
                container.addChild(built.root)
                if input.scripts.isEmpty {
                    // No entity-attached scripts: preview the open/example graph on the
                    // selected entity (or the scene root) so ▶-on-a-graph still works.
                    if let previewGraph = input.previewGraph {
                        let host = input.previewEntityID.flatMap { built.byID[$0] } ?? built.root
                        host.components.set(ScriptingComponent(source: Self.compile(previewGraph)))
                    }
                } else {
                    for binding in input.scripts {
                        guard let host = built.byID[binding.entityID] else { continue }
                        host.components.set(ScriptingComponent(source: Self.compile(binding.graph)))
                    }
                }
            } else {
                // No project open (e.g. an example graph): a neutral box stands in so
                // the preview graph still runs and can be exercised.
                let box = ModelEntity(
                    mesh: .generateBox(size: 1),
                    materials: [SimpleMaterial(color: .gray, isMetallic: false)]
                )
                box.name = "entity"
                container.addChild(box)
                if let previewGraph = input.previewGraph {
                    box.components.set(ScriptingComponent(source: Self.compile(previewGraph)))
                }
            }
            content.add(container)
            // Frame the reconstructed scene for the inline orbit camera.
            Self.normalizeForFraming(container)

            // Apple's JS debugger: name + enable so this script's JavaScriptCore
            // context appears in Safari ▸ Develop ▸ this Mac ▸ the named context
            // (breakpoints, stepping, live console, evaluate).
            container.scene?.renameJSContext("Deconstructed 3 — Script Graph")
            container.scene?.enableDebugger(true)
            // Capture the scene so teardown can disable the debugger it just enabled
            // (mutates the holder, not @State — safe inside the make closure).
            session.scene = container.scene
        }
        .realityScripting()
        #if os(macOS) || os(iOS)
        .realityViewCameraControls(.orbit)
        #endif
        // Stop = this view disappears. Disable the debugger for the context we enabled
        // so it doesn't linger registered with the Web Inspector (the leak fix). If the
        // scene already deallocated, the weak ref is nil and this is a no-op.
        .onDisappear { session.scene?.enableDebugger(false) }
        // Console as a small, collapsible OVERLAY pinned to the bottom — it doesn't
        // dominate the inline viewport, and a toggle in the top-right reveals it.
        .overlay(alignment: .topTrailing) {
            Button {
                showsConsole.toggle()
            } label: {
                Label("Console", systemImage: "terminal")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .padding(8)
            .help(showsConsole ? "Hide the runtime log" : "Show the runtime log")
        }
        .overlay(alignment: .bottom) {
            if showsConsole {
                ConsolePanel(log: CanonicalRuntime.log, validationError: validationError)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: showsConsole)
        .task(id: input.signature) {
            validationError = representativeSource.flatMap(CanonicalRuntime.validationError(in:))
        }
    }
}

/// Weakly retains the running Play scene so the view's teardown can disable the JS
/// debugger it enabled. A reference holder (not a value) so the make closure can set
/// it without mutating `@State` during a view update; weak so it never keeps the
/// scene — and thus the JSContext — alive past Stop.
@MainActor
final class PlaySession {
    weak var scene: RealityKit.Scene?
    init() {}
}

/// A live console showing Apple's structured runtime log — script `console` output
/// and uncaught exceptions — plus a pre-run validation error if the JS is invalid.
@MainActor
private struct ConsolePanel: View {
    let log: ScriptLog
    let validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Label("Runtime log", systemImage: "terminal")
                Spacer()
                Button("Clear") { log.clear() }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let validationError {
                        Text("Script did not validate: \(validationError)")
                            .foregroundStyle(.red)
                    }
                    ForEach(log.entries) { entry in
                        Text(ScriptLog.line(entry))
                            .foregroundStyle(ScriptLog.isError(entry) ? Color.red : .secondary)
                            .textSelection(.enabled)
                    }
                    if log.entries.isEmpty && validationError == nil {
                        Text("No runtime output yet — drag the box.")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .background(.black.opacity(0.85))
    }
}
