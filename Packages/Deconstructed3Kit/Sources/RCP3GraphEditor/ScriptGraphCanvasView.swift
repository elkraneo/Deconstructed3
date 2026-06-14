import SwiftUI

// MARK: - Interactive SwiftUI Canvas renderer
//
// A real node editor over `ScriptGraphEditorModel`: drag nodes, drag-to-connect
// ports, pan/zoom, select, delete. Geometry comes entirely from
// `ScriptGraphLayout`, so the edges this view routes and the ports it hit-tests
// agree with the dots `ScriptGraphCanvasNodeView` draws.
//
// Coordinate spaces
// -----------------
// The model stores node positions in GRAPH space. The view keeps `zoom` and `pan`
// and maps:
//
//     canvas = graph * zoom + pan + center
//     graph  = (canvas - pan - center) / zoom
//
// `center` keeps the unscaled graph origin near the middle of the view, so
// graphs authored around (0,0) are visible without panning. Every node placement,
// edge endpoint, and hit-test goes through `canvasPoint(fromGraph:)` /
// `graphPoint(fromCanvas:)`, so the whole scene stays consistent under pan/zoom.

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
    @State private var cursorCanvas: CGPoint?
    @State private var hoverTargetValid = false

    // Pinch-zoom accumulation.
    @State private var zoomBase: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let zoomRange: ClosedRange<CGFloat> = 0.25...2.5

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                edges
                nodes
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .gesture(magnifyGesture)
            .onAppear { viewportSize = proxy.size }
            .onChange(of: proxy.size) { _, new in viewportSize = new }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.delete) { deleteSelection() }
        .onKeyPress(.deleteForward) { deleteSelection() }
        .onKeyPress(.escape) {
            if model.draftSource != nil { model.cancelConnection(); return .handled }
            return .ignored
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Script graph canvas")
        .accessibilityHint("Nodes connected by control-flow and data wires. Select a node, then use the Delete action to remove it.")
        .accessibilityAction(named: Text("Delete selection")) { model.deleteSelection() }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): cursorCanvas = p
            case .ended: cursorCanvas = nil
            }
        }
        #endif
    }

    // MARK: Coordinate transforms

    /// The centering offset that maps the graph origin to the viewport middle.
    private var center: CGSize {
        CGSize(width: viewportSize.width / 2, height: viewportSize.height / 2)
    }

    /// Graph point → canvas (view) point.
    public func canvasPoint(fromGraph p: CGPoint) -> CGPoint {
        CGPoint(
            x: p.x * zoom + pan.width + center.width,
            y: p.y * zoom + pan.height + center.height
        )
    }

    /// Canvas (view) point → graph point. Inverse of `canvasPoint(fromGraph:)`.
    public func graphPoint(fromCanvas p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - pan.width - center.width) / zoom,
            y: (p.y - pan.height - center.height) / zoom
        )
    }

    // MARK: Background grid

    private var background: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(gridBackground))
            // A dotted grid that tracks pan/zoom. Spacing grows with zoom; skip when
            // it would be too dense or motion is reduced (then a flat fill is fine).
            guard !reduceMotion else { return }
            let spacing = 32 * zoom
            guard spacing > 6 else { return }
            let originX = (pan.width + center.width).truncatingRemainder(dividingBy: spacing)
            let originY = (pan.height + center.height).truncatingRemainder(dividingBy: spacing)
            var dots = Path()
            let dot: CGFloat = 1
            var y = originY
            while y < size.height {
                var x = originX
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
                    x += spacing
                }
                y += spacing
            }
            ctx.fill(dots, with: .color(.primary.opacity(0.10)))
        }
        .ignoresSafeArea()
    }

    private var gridBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    // MARK: Edges

    private var edges: some View {
        Canvas { ctx, _ in
            for connection in model.connections {
                guard
                    let fromGraph = model.canvasPortPoint(connection.from),
                    let toGraph = model.canvasPortPoint(connection.to)
                else { continue }
                let a = canvasPoint(fromGraph: fromGraph)
                let b = canvasPoint(fromGraph: toGraph)
                let selected = connection.id == model.selectedConnectionID
                drawEdge(ctx, from: a, to: b, isExec: connection.isExec,
                         color: edgeColor(connection), selected: selected, label: connection.label)
            }

            // The in-progress (draft) connection: from the draft port to the cursor,
            // tinted by whether the hovered target is a valid completion.
            if let source = model.draftSource,
               let fromGraph = model.canvasPortPoint(source),
               let cursor = cursorCanvas ?? activeGesture?.lastCanvas {
                let a = canvasPoint(fromGraph: fromGraph)
                let isExec = model.pin(source)?.isExec ?? false
                let color: Color = hoverTargetValid ? .green : .accentColor
                drawEdge(ctx, from: a, to: cursor, isExec: isExec, color: color,
                         selected: true, label: nil, dashed: !hoverTargetValid)
            }
        }
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
        // (clamped), giving the classic node-editor "S" routing.
        let dx = max(40, abs(b.x - a.x) * 0.5)
        path.addCurve(
            to: b,
            control1: CGPoint(x: a.x + dx, y: a.y),
            control2: CGPoint(x: b.x - dx, y: b.y)
        )

        let baseWidth: CGFloat = isExec ? 3.0 : 2.0
        let width = (selected ? baseWidth + 1.5 : baseWidth) * max(0.6, min(zoom, 1.4))
        var style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        if dashed { style.dash = [6, 5] }

        if selected {
            // A soft halo behind the selected/draft wire.
            ctx.stroke(path, with: .color(color.opacity(0.30)),
                       style: StrokeStyle(lineWidth: width + 5, lineCap: .round))
        }
        ctx.stroke(path, with: .color(color), style: style)

        // Data wires show their label near the midpoint.
        if let label, !isExec, !label.isEmpty, zoom > 0.6 {
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

    // MARK: Nodes

    private var nodes: some View {
        ForEach(model.nodes) { box in
            let topLeft = canvasPoint(fromGraph: box.position)
            ScriptGraphCanvasNodeView(
                payload: box.payload,
                isSelected: box.id == model.selectedNodeID,
                onDelete: {
                    model.selectNode(box.id)
                    model.deleteSelection()
                }
            )
            .scaleEffect(zoom, anchor: .topLeading)
            // `.position` centers the frame, so offset by the (scaled) half-size to
            // place the node's top-left at `topLeft`.
            .position(centerForNode(box, topLeft: topLeft))
        }
    }

    private func centerForNode(_ box: GraphNodeBox, topLeft: CGPoint) -> CGPoint {
        let size = ScriptGraphLayout.size(box.payload)
        return CGPoint(
            x: topLeft.x + size.width / 2 * zoom,
            y: topLeft.y + size.height / 2 * zoom
        )
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in handleDragChanged(value) }
            .onEnded { value in handleDragEnded(value) }
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        cursorCanvas = value.location
        let cursorGraph = graphPoint(fromCanvas: value.location)

        // Decide the gesture's role on the first change.
        if activeGesture == nil {
            let startGraph = graphPoint(fromCanvas: value.startLocation)
            if let port = model.canvasPort(near: startGraph) {
                // Begin a connection from this port.
                model.beginConnection(from: port)
                activeGesture = ActiveGesture(kind: .connect(from: port), lastCanvas: value.location)
            } else if let nodeID = nodeID(atGraph: startGraph) {
                // Move (and select) this node.
                model.selectNode(nodeID)
                let origin = model.node(nodeID)?.position ?? .zero
                activeGesture = ActiveGesture(kind: .moveNode(id: nodeID, origin: origin),
                                              lastCanvas: value.location)
            } else {
                // Pan the canvas.
                activeGesture = ActiveGesture(kind: .pan(origin: pan), lastCanvas: value.location)
            }
        }

        guard var gesture = activeGesture else { return }
        gesture.lastCanvas = value.location
        activeGesture = gesture

        switch gesture.kind {
        case .pan(let origin):
            pan = CGSize(width: origin.width + value.translation.width,
                         height: origin.height + value.translation.height)
        case .moveNode(let id, let origin):
            // Translation is in canvas space; convert to graph space.
            let dx = value.translation.width / zoom
            let dy = value.translation.height / zoom
            model.moveNode(id, to: CGPoint(x: origin.x + dx, y: origin.y + dy))
        case .connect:
            // Live-validate the target under the cursor for affordance.
            if let target = model.canvasPort(near: cursorGraph),
               let source = model.draftSource {
                hoverTargetValid = model.canConnect(source, target)
            } else {
                hoverTargetValid = false
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        defer {
            activeGesture = nil
            hoverTargetValid = false
        }
        let dropGraph = graphPoint(fromCanvas: value.location)
        let moved = abs(value.translation.width) + abs(value.translation.height) > 4

        switch activeGesture?.kind {
        case .connect:
            if let target = model.canvasPort(near: dropGraph) {
                model.completeConnection(to: target)
            } else {
                model.cancelConnection()
            }
        case .pan where !moved:
            // A tap on empty canvas (or an edge): hit-test edges, else clear.
            if let edgeID = connectionID(nearCanvas: value.location) {
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
                // Zoom toward the gesture's start anchor.
                let anchor = cursorCanvas ?? CGPoint(x: center.width, y: center.height)
                let newZoom = (zoomBase * value.magnification).clamped(to: zoomRange)
                applyZoom(newZoom, anchor: anchor)
            }
            .onEnded { _ in zoomBase = zoom }
    }

    /// Sets `zoom` to `newZoom` while keeping the graph point under `anchor` fixed.
    private func applyZoom(_ newZoom: CGFloat, anchor: CGPoint) {
        let graphAtAnchor = graphPoint(fromCanvas: anchor)
        zoom = newZoom
        // Solve pan so that `canvasPoint(graphAtAnchor) == anchor` after the change.
        pan = CGSize(
            width: anchor.x - graphAtAnchor.x * zoom - center.width,
            height: anchor.y - graphAtAnchor.y * zoom - center.height
        )
    }

    // MARK: Hit-testing helpers

    /// The topmost node whose body (header + rows, excluding the port columns)
    /// contains `graphPoint`. Iterated in reverse so later-drawn nodes win.
    private func nodeID(atGraph graphPoint: CGPoint) -> String? {
        for box in model.nodes.reversed() {
            let size = ScriptGraphLayout.size(box.payload)
            let rect = CGRect(origin: box.position, size: size)
            if rect.contains(graphPoint) { return box.id }
        }
        return nil
    }

    /// The id of a connection whose routed path passes near `canvasPoint`, or `nil`.
    private func connectionID(nearCanvas point: CGPoint, tolerance: CGFloat = 8) -> String? {
        var best: (id: String, distance: CGFloat)?
        for connection in model.connections {
            guard
                let fromGraph = model.canvasPortPoint(connection.from),
                let toGraph = model.canvasPortPoint(connection.to)
            else { continue }
            let a = canvasPoint(fromGraph: fromGraph)
            let b = canvasPoint(fromGraph: toGraph)
            let dx = max(40, abs(b.x - a.x) * 0.5)
            let c1 = CGPoint(x: a.x + dx, y: a.y)
            let c2 = CGPoint(x: b.x - dx, y: b.y)
            let distance = Self.distanceToBezier(point, a, c1, c2, b)
            if distance <= tolerance, distance < (best?.distance ?? .greatestFiniteMagnitude) {
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
    var lastCanvas: CGPoint
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
