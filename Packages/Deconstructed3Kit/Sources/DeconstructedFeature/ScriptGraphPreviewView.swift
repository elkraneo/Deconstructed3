import RCP3Document
import RCP3Runtime
import SwiftUI

/// RUN / PREVIEW for an open script graph: compile it to JS, run it on our
/// `RCP3Runtime` host, and let the user drive it with a simulated gesture while
/// watching the entity move. This closes the author → run loop — the same graph the
/// canvas edits is the graph that executes here.
///
/// ## How it runs the graph
///
/// On appear it does exactly what a test would: `ScriptGraphRunner.run(graph, into:
/// state)` compiles the graph (`ScriptGraphCompiler`), loads the JS into a fresh
/// `ScriptJSHost` bound to a `RuntimeEntityState`, and returns the host ready to
/// receive events. The host and state are `@MainActor`-isolated (a `JSContext` is
/// not `Sendable`), so they live in `@State` and are only ever touched on the main
/// actor — which is where SwiftUI body / gesture callbacks run.
///
/// ## What the user sees and does
///
/// - A **drag pad** (a `DragGesture` square) plus **± step buttons** dispatch a
///   `"drag"` event with a `delta`, and a **tap** button dispatches `"tap"`.
/// - A **2D entity dot** positioned by `state.translation.x/.y` moves live as the
///   graph executes, proving the handler ran.
/// - A **live transform readout** of translation / rotation / scale.
/// - A **disclosure** with the compiled JS and any `lastException` / console output,
///   so errors and unsupported nodes are visible rather than silent.
///
/// When the graph compiles to no handlers (e.g. only unsupported nodes), the view
/// says so honestly and shows the `// unsupported node` JS instead of pretending to
/// run something.
public struct ScriptGraphPreviewView: View {
    let graph: RCP3ScriptGraph

    /// The live entity model the running graph mutates. `@MainActor`, held across
    /// body re-evaluations so drags accumulate.
    @State private var state = RuntimeEntityState()
    /// The running host (compiled graph + bound state). `nil` until `start()` runs on
    /// appear.
    @State private var host: ScriptJSHost?
    /// A monotonically bumped tick so the readout / dot recompute after each dispatch
    /// (the host mutates `state` in place — a reference type SwiftUI can't observe).
    @State private var tick = 0
    /// Whether the compiled-JS disclosure is expanded.
    @State private var showsCompiledJS = false

    /// One drag-step magnitude for the ± buttons.
    private let step = 0.25

    public init(graph: RCP3ScriptGraph) {
        self.graph = graph
    }

    /// The compiled JS for `graph` (also what the host loaded). Computed once per
    /// body; cheap and pure.
    private var compiledJS: String {
        ScriptGraphCompiler().compile(graph)
    }

    /// Whether the running host registered any handler at all. When false, the graph
    /// compiled to no behavior (only unsupported / unwired nodes) — an honest empty
    /// state.
    private var hasAnyHandler: Bool {
        guard let host else { return false }
        return host.hasHandler(for: "drag") || host.hasHandler(for: "tap")
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if hasAnyHandler {
                    entityStage
                    simulatorControls
                } else {
                    emptyState
                }
                transformReadout
                diagnostics
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 520)
        .navigationTitle("Run Preview")
        .task { start() }
    }

    // MARK: Lifecycle

    /// Compiles + runs the graph on the runtime host. Idempotent: only starts once.
    private func start() {
        guard host == nil else { return }
        let fresh = RuntimeEntityState()
        let runningHost = ScriptGraphRunner.run(graph, into: fresh)
        state = fresh
        host = runningHost
        tick += 1
    }

    /// Dispatches a `"drag"` with the given delta and re-reads the live state.
    private func drag(_ dx: Double, _ dy: Double, _ dz: Double) {
        host?.dispatch(event: "drag", payload: ["delta": [dx, dy, dz]])
        tick += 1
    }

    /// Dispatches a `"tap"` (no payload) and re-reads the live state.
    private func tapDispatch() {
        host?.dispatch(event: "tap")
        tick += 1
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Running this graph")
                .font(.headline)
            Text("\(graph.nodes.count) node\(graph.nodes.count == 1 ? "" : "s"), compiled to JavaScript and run on the RCP3 runtime. Drag the pad to drive it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The 2D entity representation: a dot inside a framed stage, positioned by
    /// `state.translation.x/.y`. This is what visibly moves when the graph runs.
    private var entityStage: some View {
        // `tick` read so the stage recomputes after each dispatch.
        let _ = tick
        let stageSize: CGFloat = 240
        let half = stageSize / 2
        // Map translation units → points. Clamp so the dot stays on the stage.
        let scale: CGFloat = 40
        let x = max(-half + 14, min(half - 14, CGFloat(state.translation.x) * scale))
        // Screen y grows downward; entity +y is up, so negate.
        let y = max(-half + 14, min(half - 14, -CGFloat(state.translation.y) * scale))

        return VStack(alignment: .leading, spacing: 8) {
            Text("Entity")
                .font(.subheadline.weight(.semibold))
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
                // Origin crosshair.
                Path { p in
                    p.move(to: CGPoint(x: half, y: 0)); p.addLine(to: CGPoint(x: half, y: stageSize))
                    p.move(to: CGPoint(x: 0, y: half)); p.addLine(to: CGPoint(x: stageSize, y: half))
                }
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .offset(x: x, y: y)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: tick)
            }
            .frame(width: stageSize, height: stageSize)
            .accessibilityElement()
            .accessibilityLabel("Entity position")
            .accessibilityValue(positionDescription)
        }
    }

    /// The drag simulator: an interactive pad plus ± step buttons and a tap button.
    private var simulatorControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag simulator")
                .font(.subheadline.weight(.semibold))

            // Interactive pad: drag distance becomes the per-frame delta. We feed the
            // incremental change so the entity tracks the finger/cursor.
            DragPad { dx, dy in
                // Pad +y is down; entity +y is up — negate so up-drag moves up.
                drag(Double(dx) / 40, Double(-dy) / 40, 0)
            }
            .frame(width: 160, height: 100)
            .accessibilityLabel("Drag pad")
            .accessibilityHint("Drag to move the entity along X and Y.")

            // Discrete ± buttons (keyboard / accessibility friendly).
            HStack(spacing: 12) {
                stepButton("−X", systemImage: "arrow.left") { drag(-step, 0, 0) }
                stepButton("+X", systemImage: "arrow.right") { drag(step, 0, 0) }
                stepButton("+Y", systemImage: "arrow.up") { drag(0, step, 0) }
                stepButton("−Y", systemImage: "arrow.down") { drag(0, -step, 0) }
            }
            HStack(spacing: 12) {
                Button { tapDispatch() } label: {
                    Label("Dispatch tap", systemImage: "hand.tap")
                }
                .disabled(host?.hasHandler(for: "tap") != true)
                Button(role: .destructive) { reset() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func stepButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .accessibilityLabel("Drag \(title)")
    }

    /// Re-runs the graph from a clean state (re-compiles + reloads the host).
    private func reset() {
        host = nil
        start()
    }

    /// The live transform readout. Re-reads each `tick`.
    private var transformReadout: some View {
        let _ = tick
        return GroupBox("Live transform") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("translation", value: format(state.translation))
                LabeledContent("rotation", value: formatQuat())
                LabeledContent("scale", value: format(state.scale))
            }
            .font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transform readout")
        .accessibilityValue(positionDescription)
    }

    private var emptyState: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("No runnable behavior", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text("This graph compiled to no event handlers. Its nodes aren't a recognized gesture → action pattern yet, so there's nothing to drive. The compiled output below shows what the runtime saw.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// The compiled JS and any runtime diagnostics (exception / console output).
    private var diagnostics: some View {
        let _ = tick
        return DisclosureGroup(isExpanded: $showsCompiledJS) {
            VStack(alignment: .leading, spacing: 12) {
                codeBlock(compiledJS)

                if let exception = host?.lastException {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Exception", systemImage: "xmark.octagon")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        codeBlock(exception)
                    }
                }

                if let messages = host?.consoleMessages, !messages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Console")
                            .font(.caption.weight(.semibold))
                        codeBlock(messages.joined(separator: "\n"))
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("Compiled JavaScript", systemImage: "curlybraces")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel("Compiled JavaScript and diagnostics")
    }

    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quinary))
    }

    // MARK: Formatting

    private func format(_ v: SIMD3<Double>) -> String {
        "[\(num(v.x)), \(num(v.y)), \(num(v.z))]"
    }

    private func formatQuat() -> String {
        let q = state.rotation
        return "[\(num(q.imag.x)), \(num(q.imag.y)), \(num(q.imag.z)), \(num(q.real))]"
    }

    private func num(_ d: Double) -> String {
        String(format: "%.2f", d)
    }

    /// A spoken description of the entity's position, for accessibility values.
    private var positionDescription: String {
        let t = state.translation
        return "x \(num(t.x)), y \(num(t.y)), z \(num(t.z))"
    }
}

// MARK: - Drag pad

/// A small interactive square that reports incremental drag deltas (the change since
/// the previous callback) so the bound entity tracks the gesture.
private struct DragPad: View {
    /// Called with the incremental (dx, dy) in points since the last update.
    let onDelta: (CGFloat, CGFloat) -> Void

    @State private var last: CGPoint?
    @GestureState private var isDragging = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isDragging ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(.tertiary, lineWidth: 1)
            )
            .overlay(
                Label("Drag here", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { value in
                        if let last {
                            onDelta(value.location.x - last.x, value.location.y - last.y)
                        }
                        last = value.location
                    }
                    .onEnded { _ in last = nil }
            )
    }
}
