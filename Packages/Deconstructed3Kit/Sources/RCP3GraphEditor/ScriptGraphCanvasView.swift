import SwiftUI

// MARK: - Interactive SwiftUI Canvas renderer
//
// A real node editor over `ScriptGraphEditorModel`: drag nodes, drag-to-connect
// ports, pan/zoom, select, delete. Geometry comes entirely from
// `ScriptGraphLayout`, so the edges this view routes and the ports it hit-tests
// agree with the dots `ScriptGraphCanvasNodeView` draws.
//
// Coordinate spaces — ONE transform
// ---------------------------------
// The model stores node positions in GRAPH space. ALL graph content — the grid,
// every edge path, the draft wire, and every node card — lives in a SINGLE
// container that is itself laid out in GRAPH coordinates. One transform is applied
// to the whole container:
//
//     .scaleEffect(zoom, anchor: .topLeading)
//     .offset(x: pan.width + center.width, y: pan.height + center.height)
//
// which means, for any graph point `p`:
//
//     screen = p * zoom + pan + center               (`canvasPoint(fromGraph:)`)
//     graph  = (screen - pan - center) / zoom         (`graphPoint(fromCanvas:)`)
//
// Because nodes and edges share the *exact same* single transform, ports and wires
// stay attached at every zoom. `center` keeps the unscaled graph origin near the
// middle of the view, so graphs authored around (0,0) are visible without panning.
//
// Hit-testing inverts that single transform: a gesture location reported in the
// gesture view's local (screen) space is converted to graph space via
// `graphPoint(fromCanvas:)` — the one inverse — so `model.canvasPort(near:)` and
// node hit-tests work at any zoom. Routing ALL conversions through that pair keeps
// the placement, the routing, and the hit-testing in lock-step.

public struct ScriptGraphCanvasView: View {
    @Bindable var model: ScriptGraphEditorModel

    public init(model: ScriptGraphEditorModel) {
        self.model = model
    }

    // Viewport transform (graph → canvas).
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var viewportSize: CGSize = .zero

    // Live gesture state. A single drag gesture multiplexes between panning,
    // moving a node, and drawing a connection, decided on the first change event.
    @State private var activeGesture: ActiveGesture?
    /// Cursor position in GRAPH space (draft wire endpoint, hover validation).
    @State private var cursorGraph: CGPoint?
    @State private var hoverTargetValid = false

    // Pinch-zoom accumulation.
    @State private var zoomBase: CGFloat = 1

    // Keyboard focus — required for `.onKeyPress` delete to fire.
    @FocusState private var focused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let zoomRange: ClosedRange<CGFloat> = 0.25...2.5

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Solid backing fills the whole viewport (drawn in screen space).
                gridBackground.ignoresSafeArea()

                // The single graph-space container: grid dots, edges, draft wire,
                // and node cards — all placed in GRAPH coordinates, then scaled and
                // offset by ONE transform so they can never desync. The container's
                // own coordinate origin IS graph (0,0) (it is pinned top-leading), so
                // the resulting screen mapping is exactly
                //   screen = graph * zoom + pan + center      (== `canvasPoint`).
                graphContainer
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(x: pan.width + center.width, y: pan.height + center.height)

                // A discoverable delete affordance for the selected wire, floated in
                // screen space at the wire's midpoint (edges live in a non-hit-testing
                // Canvas, so they can't host their own context menu).
                selectedConnectionDeleteButton
            }
            .contentShape(Rectangle())
            // Gestures are observed in this view's LOCAL (screen) space; every
            // location is converted to graph space via `graphPoint(fromCanvas:)`.
            .gesture(dragGesture)
            .gesture(magnifyGesture)
            .onAppear {
                viewportSize = proxy.size
                focused = true
            }
            .onChange(of: proxy.size) { _, new in viewportSize = new }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture { focused = true }
        .onKeyPress(.delete) { deleteSelection() }
        .onKeyPress(.deleteForward) { deleteSelection() }
        // The responder-chain delete (Delete/Backspace + the Edit menu). More
        // reliable than `.onKeyPress` for a focusable view inside a split-view
        // column, where key events may not reach the focused subview.
        .onDeleteCommand { model.deleteSelection() }
        .onKeyPress(.escape) {
            if model.draftSource != nil { model.cancelConnection(); return .handled }
            return .ignored
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Script graph canvas")
        .accessibilityHint("Nodes connected by control-flow and data wires. Select a node, then use the Delete action to remove it.")
        .accessibilityAction(named: Text("Delete selection")) { model.deleteSelection() }
    }

    // MARK: Coordinate transforms (single source of truth)

    /// The centering offset that maps the graph origin to the viewport middle.
    private var center: CGSize {
        CGSize(width: viewportSize.width / 2, height: viewportSize.height / 2)
    }

    /// Graph point → canvas (screen) point. Matches the container's transform exactly.
    public func canvasPoint(fromGraph p: CGPoint) -> CGPoint {
        CGPoint(
            x: p.x * zoom + pan.width + center.width,
            y: p.y * zoom + pan.height + center.height
        )
    }

    /// Canvas (screen) point → graph point. Inverse of `canvasPoint(fromGraph:)`.
    public func graphPoint(fromCanvas p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - pan.width - center.width) / zoom,
            y: (p.y - pan.height - center.height) / zoom
        )
    }

    /// Test hook: seed the viewport transform directly so coordinate round-trips can
    /// be exercised at representative zoom/pan values outside the SwiftUI graph.
    func configureViewportForTesting(size: CGSize, zoom: CGFloat, pan: CGSize) {
        viewportSize = size
        self.zoom = zoom
        self.pan = pan
    }

    // MARK: Graph-space container

    /// Everything that lives in graph coordinates. The container is a ZERO-size view
    /// pinned so its coordinate origin is graph (0,0); all content is overlaid and
    /// allowed to overflow in every direction (graph coordinates can be negative).
    /// A single transform on the caller scales/offsets the whole thing, so edges and
    /// nodes can never diverge. Because the container origin is graph (0,0), the
    /// screen mapping is exactly `screen = graph * zoom + pan + center`.
    private var graphContainer: some View {
        // A zero-size anchor at graph origin. `.overlay` content is centered on this
        // point and unclipped, so a child drawn at graph `g` lands at container-local
        // `g` — matching `.position(x: g.x, y: g.y)` for node cards.
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .center) { grid }
            .overlay(alignment: .center) { edges }
            .overlay(alignment: .center) { nodes }
            .allowsHitTesting(false)
    }

    /// The graph-space extent the grid/edge Canvases reserve around the origin. Large
    /// enough to cover any authored graph and panning at min zoom.
    private var containerSpan: CGFloat { 20_000 }

    // MARK: Background grid (graph space)

    private var grid: some View {
        Canvas { ctx, size in
            guard !reduceMotion else { return }
            // The Canvas is centered on graph origin (its center == container origin),
            // so translate the context so drawing is in graph coordinates.
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            // Spacing is in GRAPH units (the container transform scales it on screen).
            let spacing: CGFloat = 32
            let half = size.width / 2
            var dots = Path()
            let dot: CGFloat = 1
            var y = -half
            while y < half {
                var x = -half
                while x < half {
                    dots.addEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
                    x += spacing
                }
                y += spacing
            }
            ctx.fill(dots, with: .color(.primary.opacity(0.10)))
        }
        .frame(width: containerSpan, height: containerSpan)
        .allowsHitTesting(false)
    }

    private var gridBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    // MARK: Edges (graph space)

    private var edges: some View {
        Canvas { ctx, size in
            // Graph origin is drawn at the Canvas center (matching the node `.position`
            // origin shift), so translate the context by half the span once.
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            for connection in model.connections {
                guard
                    let a = model.canvasPortPoint(connection.from),
                    let b = model.canvasPortPoint(connection.to)
                else { continue }
                let selected = connection.id == model.selectedConnectionID
                drawEdge(ctx, from: a, to: b, isExec: connection.isExec,
                         color: edgeColor(connection), selected: selected, label: connection.label)
            }

            // The in-progress (draft) connection: from the draft port to the cursor,
            // tinted by whether the hovered target is a valid completion. All points
            // are GRAPH-space — same as the edges above.
            if let source = model.draftSource,
               let a = model.canvasPortPoint(source),
               let cursor = cursorGraph ?? activeGesture?.lastGraph {
                let isExec = model.pin(source)?.isExec ?? false
                let color: Color = hoverTargetValid ? .green : .accentColor
                drawEdge(ctx, from: a, to: cursor, isExec: isExec, color: color,
                         selected: true, label: nil, dashed: !hoverTargetValid)
            }
        }
        .frame(width: containerSpan, height: containerSpan)
        .allowsHitTesting(false)
    }

    private func drawEdge(
        _ ctx: GraphicsContext,
        from a: CGPoint, to b: CGPoint,
        isExec: Bool, color: Color, selected: Bool,
        label: String?, dashed: Bool = false
    ) {
        var path = Path()
        path.move(to: a)
        // Horizontal-ish bezier: control points pushed out along x by half the gap
        // (clamped), giving the classic node-editor "S" routing. All in graph units.
        let dx = max(40, abs(b.x - a.x) * 0.5)
        path.addCurve(
            to: b,
            control1: CGPoint(x: a.x + dx, y: a.y),
            control2: CGPoint(x: b.x - dx, y: b.y)
        )

        // Widths are graph-space; the container scale renders them at the right size.
        let baseWidth: CGFloat = isExec ? 3.0 : 2.0
        let width = selected ? baseWidth + 1.5 : baseWidth
        var style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        if dashed { style.dash = [6, 5] }

        if selected {
            // A soft halo behind the selected/draft wire.
            ctx.stroke(path, with: .color(color.opacity(0.30)),
                       style: StrokeStyle(lineWidth: width + 5, lineCap: .round))
        }
        ctx.stroke(path, with: .color(color), style: style)

        // Data wires show their label near the midpoint.
        if let label, !isExec, !label.isEmpty {
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let text = Text(label).font(.caption2).foregroundStyle(.secondary)
            ctx.draw(text, at: CGPoint(x: mid.x, y: mid.y - 8), anchor: .center)
        }
    }

    private func edgeColor(_ connection: GraphConnection) -> Color {
        if connection.id == model.selectedConnectionID { return .accentColor }
        if connection.isExec {
            // Exec wires read as control flow: tint by the source node's role.
            return model.node(connection.from.nodeID)?.payload.role.tint ?? .primary
        }
        return .secondary
    }

    // MARK: Nodes (graph space)

    private var nodes: some View {
        // Hosted in a `containerSpan` frame centered on graph origin (matching the
        // Canvases, which draw graph (0,0) at their center). `.position` is measured
        // from this frame's top-left, so graph point `g` maps to `containerSpan/2 + g`.
        let originShift = containerSpan / 2
        return ZStack(alignment: .topLeading) {
            ForEach(model.nodes) { box in
                let size = ScriptGraphLayout.size(box.payload)
                ScriptGraphCanvasNodeView(
                    payload: box.payload,
                    isSelected: box.id == model.selectedNodeID,
                    onDelete: {
                        model.selectNode(box.id)
                        model.deleteSelection()
                    }
                )
                // NO per-node scaleEffect — the container transform scales it. Place
                // the card at its graph-space frame (`.position` centers it; add half).
                .position(
                    x: originShift + box.position.x + size.width / 2,
                    y: originShift + box.position.y + size.height / 2
                )
                // A discoverable delete affordance that doesn't rely on the keyboard.
                .contextMenu {
                    Button(role: .destructive) {
                        model.selectNode(box.id)
                        model.deleteSelection()
                    } label: {
                        Label("Delete Node", systemImage: "trash")
                    }
                }
            }
        }
        .frame(width: containerSpan, height: containerSpan)
        .allowsHitTesting(false)
    }

    // MARK: Selection affordance

    /// A small "delete" button floated over the midpoint of the selected wire, so the
    /// selection can be removed without the keyboard. Positioned in screen space via
    /// the single transform, so it tracks the wire under pan/zoom.
    @ViewBuilder
    private var selectedConnectionDeleteButton: some View {
        if let id = model.selectedConnectionID,
           let connection = model.connections.first(where: { $0.id == id }),
           let a = model.canvasPortPoint(connection.from),
           let b = model.canvasPortPoint(connection.to) {
            let midGraph = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let screen = canvasPoint(fromGraph: midGraph)
            Button {
                model.removeConnection(id)
            } label: {
                Image(systemName: "trash.fill")
                    .font(.caption)
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.red.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete connection")
            .position(screen)
        }
    }

    // MARK: Gestures
    //
    // The drag gesture is observed in the view's LOCAL (screen) space. Every location
    // is converted to graph space via `graphPoint(fromCanvas:)` — the single inverse —
    // so hit-tests work identically at any zoom.

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in handleDragChanged(value) }
            .onEnded { value in handleDragEnded(value) }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        focused = true
        // Convert the screen-space location to graph space through the one inverse.
        let location = graphPoint(fromCanvas: value.location)
        cursorGraph = location

        // Decide the gesture's role on the first change. Port hit-test takes PRIORITY
        // over node-body drag when the press is near a port.
        if activeGesture == nil {
            let start = graphPoint(fromCanvas: value.startLocation)
            if let port = model.canvasPort(near: start) {
                beginConnectionGesture(from: port, at: location)
            } else if let nodeID = nodeID(atGraph: start) {
                // Move (and select) this node.
                model.selectNode(nodeID)
                let origin = model.node(nodeID)?.position ?? .zero
                activeGesture = ActiveGesture(kind: .moveNode(id: nodeID, origin: origin),
                                              lastGraph: location)
            } else {
                // Pan the canvas.
                activeGesture = ActiveGesture(kind: .pan(origin: pan), lastGraph: location)
            }
        }

        guard var gesture = activeGesture else { return }
        gesture.lastGraph = location
        activeGesture = gesture

        switch gesture.kind {
        case .pan(let origin):
            // `pan` is a screen-space offset; the drag translation is screen-space too.
            pan = CGSize(width: origin.width + value.translation.width,
                         height: origin.height + value.translation.height)
        case .moveNode(let id, let origin):
            // Translation is screen-space; convert to graph units by dividing by zoom.
            model.moveNode(id, to: CGPoint(x: origin.x + value.translation.width / zoom,
                                           y: origin.y + value.translation.height / zoom))
        case .connect:
            // Live-validate the target under the cursor for affordance.
            if let target = model.canvasPort(near: location),
               let source = model.draftSource {
                hoverTargetValid = model.canConnect(source, target)
            } else {
                hoverTargetValid = false
            }
        }
    }

    /// Begins a connection from `port`. If `port` is an INPUT that already has an
    /// incoming wire, this RECONNECTS: it detaches the existing wire and starts a new
    /// drag from that wire's original OUTPUT source (so the user can rewire). If
    /// dropped on empty, the detached wire stays removed.
    private func beginConnectionGesture(from port: GraphPortRef, at location: CGPoint) {
        if let pin = model.pin(port), pin.isInput,
           let existing = model.connections(touching: port).first(where: { $0.to == port }) {
            // Detach the existing wire and rewire from its source output.
            let source = existing.from
            model.removeConnection(existing.id)
            model.beginConnection(from: source)
            activeGesture = ActiveGesture(kind: .connect(from: source), lastGraph: location)
        } else {
            model.beginConnection(from: port)
            activeGesture = ActiveGesture(kind: .connect(from: port), lastGraph: location)
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        let kind = activeGesture?.kind
        defer {
            activeGesture = nil
            hoverTargetValid = false
            cursorGraph = nil
        }
        let drop = graphPoint(fromCanvas: value.location)
        // Screen-space movement threshold (so a click reads as a tap, not a pan).
        let moved = abs(value.translation.width) + abs(value.translation.height) > 4

        switch kind {
        case .connect:
            if let target = model.canvasPort(near: drop) {
                model.completeConnection(to: target)
            } else {
                // Dropped on empty: cancel (a reconnect's detached wire stays removed).
                model.cancelConnection()
            }
        case .pan where !moved:
            // A tap on empty canvas (or an edge): hit-test edges, else clear.
            if let edgeID = connectionID(nearGraph: drop) {
                model.selectConnection(edgeID)
            } else {
                model.selectNode(nil)
            }
        case .moveNode, .pan, .none:
            break
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // `startLocation` is in the gesture view's local (screen) space; map it
                // to graph space so we can keep that graph point fixed under the pinch.
                let anchorGraph = graphPoint(fromCanvas: value.startLocation)
                let newZoom = (zoomBase * value.magnification).clamped(to: zoomRange)
                applyZoom(newZoom, anchorGraph: anchorGraph)
            }
            .onEnded { _ in zoomBase = zoom }
    }

    /// Sets `zoom` to `newZoom` while keeping the graph point `anchorGraph` fixed on
    /// screen.
    private func applyZoom(_ newZoom: CGFloat, anchorGraph: CGPoint) {
        // Where the anchor currently sits on screen.
        let screen = canvasPoint(fromGraph: anchorGraph)
        zoom = newZoom
        // Solve pan so that `canvasPoint(anchorGraph) == screen` after the change.
        pan = CGSize(
            width: screen.x - anchorGraph.x * zoom - center.width,
            height: screen.y - anchorGraph.y * zoom - center.height
        )
    }

    // MARK: Hit-testing helpers (graph space)

    /// The topmost node whose body contains `graphPoint`. Iterated in reverse so
    /// later-drawn nodes win.
    private func nodeID(atGraph graphPoint: CGPoint) -> String? {
        for box in model.nodes.reversed() {
            let size = ScriptGraphLayout.size(box.payload)
            let rect = CGRect(origin: box.position, size: size)
            if rect.contains(graphPoint) { return box.id }
        }
        return nil
    }

    /// The id of a connection whose routed path passes near `graphPoint`, or `nil`.
    /// Tolerance is in graph units, so the on-screen pick radius scales with zoom.
    private func connectionID(nearGraph point: CGPoint, tolerance: CGFloat = 8) -> String? {
        let tol = tolerance / zoom
        var best: (id: String, distance: CGFloat)?
        for connection in model.connections {
            guard
                let a = model.canvasPortPoint(connection.from),
                let b = model.canvasPortPoint(connection.to)
            else { continue }
            let dx = max(40, abs(b.x - a.x) * 0.5)
            let c1 = CGPoint(x: a.x + dx, y: a.y)
            let c2 = CGPoint(x: b.x - dx, y: b.y)
            let distance = Self.distanceToBezier(point, a, c1, c2, b)
            if distance <= tol, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (connection.id, distance)
            }
        }
        return best?.id
    }

    /// Approximate distance from `p` to the cubic bezier by sampling.
    private static func distanceToBezier(
        _ p: CGPoint, _ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint
    ) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        let steps = 24
        var prev = a
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let point = cubicPoint(a, c1, c2, b, t)
            best = min(best, distanceToSegment(p, prev, point))
            prev = point
        }
        return best
    }

    private static func cubicPoint(
        _ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, _ t: CGFloat
    ) -> CGPoint {
        let u = 1 - t
        let w0 = u * u * u
        let w1 = 3 * u * u * t
        let w2 = 3 * u * t * t
        let w3 = t * t * t
        return CGPoint(
            x: w0 * a.x + w1 * c1.x + w2 * c2.x + w3 * b.x,
            y: w0 * a.y + w1 * c1.y + w2 * c2.y + w3 * b.y
        )
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    // MARK: Commands

    private func deleteSelection() -> KeyPress.Result {
        guard model.selectedNodeID != nil || model.selectedConnectionID != nil else {
            return .ignored
        }
        model.deleteSelection()
        return .handled
    }
}

// MARK: - Gesture state

private struct ActiveGesture {
    enum Kind {
        case pan(origin: CGSize)
        case moveNode(id: String, origin: CGPoint)
        case connect(from: GraphPortRef)
    }
    var kind: Kind
    /// Last cursor location in GRAPH space.
    var lastGraph: CGPoint
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
