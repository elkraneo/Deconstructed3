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

    // Local drag state for an active node move. While a node is being dragged we DO
    // NOT mutate the model (which would invalidate every `model.nodes` reader — all
    // cards and all edges — on every frame); instead we keep the dragged id and its
    // screen-space translation here and apply that offset visually to the card and to
    // every edge endpoint on that node. `moveNode` is committed once, on drag end.
    @State private var draggingNodeID: String?
    /// Screen-space translation of the active node drag (graph offset = / zoom).
    @State private var dragTranslation: CGSize = .zero

    // Pinch-zoom accumulation.
    @State private var zoomBase: CGFloat = 1

    // Whether the node-insert palette popover is open.
    @State private var showingPalette = false
    // Free-text filter for the node palette (250+ types). Reset when the palette opens.
    @State private var paletteQuery = ""

    // Keyboard focus — required for `.onKeyPress` delete to fire.
    @FocusState private var focused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let zoomRange: ClosedRange<CGFloat> = 0.25...2.5

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Solid backing fills the whole viewport (drawn in screen space).
                gridBackground.ignoresSafeArea()

                // Grid dots and edges are drawn in VIEWPORT (screen) space: each
                // Canvas is sized to `proxy.size`, and the single transform is applied
                // to each point INSIDE the draw closure via `canvasPoint(fromGraph:)`.
                // Only the on-screen area is composited (not a 20k surface), while the
                // points still map through the exact same transform as the node cards,
                // so wires stay attached to ports at every zoom.
                grid
                edges

                // The node cards live in the single graph-space container, scaled and
                // offset by ONE transform so the card frame matches `canvasPoint`. Its
                // coordinate origin IS graph (0,0) (pinned top-leading), so the screen
                // mapping is exactly screen = graph * zoom + pan + center.
                graphContainer
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(x: pan.width + center.width, y: pan.height + center.height)

                // A discoverable delete affordance for the selected wire, floated in
                // screen space at the wire's midpoint (edges live in a non-hit-testing
                // Canvas, so they can't host their own context menu).
                selectedConnectionDeleteButton

                // The same affordance for a selected NODE: a floating trash at the
                // node's top-right corner, above the gesture layer. The node cards
                // can't host their own buttons (the canvas gesture layer would swallow
                // them), and keyboard delete is unreliable in a split-view column — so
                // this is the dependable way to remove a node.
                selectedNodeDeleteButton

                // The node-insert palette: a toolbar-style "+" pinned top-leading. It
                // is the LAST child, so it sits above the gesture layer; being a
                // `Button` it also takes hit priority over the canvas `DragGesture`, so
                // tapping it doesn't pan/connect.
                paletteButton
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

    /// Test hook: the SCREEN-space point an edge endpoint is routed to, given an
    /// explicit in-progress node drag (the local state the gesture would set). Mirrors
    /// what `edges` draws. Passing the drag state explicitly keeps the check
    /// independent of the SwiftUI `@State` runtime.
    func screenPortPointForTesting(
        _ ref: GraphPortRef, draggingNodeID: String?, dragTranslation: CGSize
    ) -> CGPoint? {
        screenPortPoint(ref, draggingNodeID: draggingNodeID, dragTranslation: dragTranslation)
    }

    /// Test hook: the GRAPH-space offset a screen-space drag translation maps to under
    /// the current transform — i.e. exactly what `handleDragEnded` commits via
    /// `moveNode`. Lets a test commit the same delta the live drag previews.
    func graphDragOffsetForTesting(translation: CGSize) -> CGPoint {
        CGPoint(x: translation.width / zoom, y: translation.height / zoom)
    }

    // MARK: Live node-drag offset (no per-frame model mutation)

    /// The live graph-space offset to apply to the node currently being dragged. While
    /// a node move is in progress the model is NOT mutated; the dragged card and the
    /// endpoints of any edge on that node are shifted by this offset so everything
    /// follows the cursor without invalidating every `model.nodes` reader each frame.
    /// `.zero` for any node that isn't the one being dragged.
    private func graphDragOffset(
        for nodeID: String, draggingNodeID: String?, dragTranslation: CGSize
    ) -> CGPoint {
        guard nodeID == draggingNodeID else { return .zero }
        return CGPoint(x: dragTranslation.width / zoom, y: dragTranslation.height / zoom)
    }

    /// A port's connection point in GRAPH space, including the live node-drag offset if
    /// its node is being dragged. `nil` if the port can't be resolved.
    private func livePortGraphPoint(
        _ ref: GraphPortRef, draggingNodeID: String?, dragTranslation: CGSize
    ) -> CGPoint? {
        guard let base = model.canvasPortPoint(ref) else { return nil }
        let offset = graphDragOffset(for: ref.nodeID, draggingNodeID: draggingNodeID,
                                     dragTranslation: dragTranslation)
        return CGPoint(x: base.x + offset.x, y: base.y + offset.y)
    }

    /// A port's connection point in SCREEN space (live drag offset applied, then the
    /// single transform). `nil` if the port can't be resolved.
    private func screenPortPoint(
        _ ref: GraphPortRef, draggingNodeID: String?, dragTranslation: CGSize
    ) -> CGPoint? {
        livePortGraphPoint(ref, draggingNodeID: draggingNodeID, dragTranslation: dragTranslation)
            .map(canvasPoint(fromGraph:))
    }

    /// Convenience overloads that read the current live-drag `@State`. Used by the
    /// SwiftUI body; the explicit-parameter forms above are also reused by tests.
    private func graphDragOffset(for nodeID: String) -> CGPoint {
        graphDragOffset(for: nodeID, draggingNodeID: draggingNodeID, dragTranslation: dragTranslation)
    }

    private func livePortGraphPoint(_ ref: GraphPortRef) -> CGPoint? {
        livePortGraphPoint(ref, draggingNodeID: draggingNodeID, dragTranslation: dragTranslation)
    }

    private func screenPortPoint(_ ref: GraphPortRef) -> CGPoint? {
        screenPortPoint(ref, draggingNodeID: draggingNodeID, dragTranslation: dragTranslation)
    }

    // MARK: Graph-space container

    /// The node cards, which live in graph coordinates. The container is a ZERO-size
    /// view pinned so its coordinate origin is graph (0,0); the cards are overlaid and
    /// allowed to overflow in every direction (graph coordinates can be negative). A
    /// single transform on the caller scales/offsets the whole thing, so the card
    /// frames match `canvasPoint` exactly. The grid and edges are drawn separately, in
    /// viewport space, through the SAME transform — see `grid`/`edges`.
    private var graphContainer: some View {
        // A zero-size anchor at graph origin. `.overlay` content is centered on this
        // point and unclipped, so a child drawn at graph `g` lands at container-local
        // `g` — matching `.position(x: g.x, y: g.y)` for node cards.
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .center) { nodes }
            .allowsHitTesting(false)
    }

    /// The graph-space extent the nodes container reserves around the origin. Large
    /// enough to host any authored graph; the `.position`'d cards are unclipped.
    private var containerSpan: CGFloat { 20_000 }

    // MARK: Background grid (viewport space)

    /// Dotted grid, drawn in VIEWPORT space. The Canvas is sized to the viewport, and
    /// the dot lattice is stepped in SCREEN units (graph spacing × zoom) starting from
    /// the screen image of a graph lattice point, so it tracks pan/zoom exactly while
    /// only ever compositing the on-screen area (not a 20k surface).
    private var grid: some View {
        Canvas { ctx, size in
            guard !reduceMotion else { return }
            let graphSpacing: CGFloat = 32
            let step = graphSpacing * zoom
            guard step > 0.5 else { return }   // avoid an unbounded loop at tiny zoom
            // Screen position of graph origin, then back up to the first lattice line
            // at or before the left/top edge so the lattice is phase-locked to graph.
            let origin = canvasPoint(fromGraph: .zero)
            let startX = origin.x - (origin.x / step).rounded(.up) * step
            let startY = origin.y - (origin.y / step).rounded(.up) * step
            let dot: CGFloat = max(0.5, 1 * zoom)
            var dots = Path()
            var y = startY
            while y < size.height {
                var x = startX
                while x < size.width {
                    dots.addEllipse(in: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2))
                    x += step
                }
                y += step
            }
            ctx.fill(dots, with: .color(.primary.opacity(0.10)))
        }
        .allowsHitTesting(false)
    }

    private var gridBackground: Color {
        #if os(macOS)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    // MARK: Edges (viewport space)

    private var edges: some View {
        Canvas { ctx, _ in
            // Each port point is resolved in GRAPH space (with the live node-drag
            // offset applied if its node is being dragged) and mapped to SCREEN with
            // the single transform, so the wires track the cards at every zoom.
            for connection in model.connections {
                guard
                    let a = screenPortPoint(connection.from),
                    let b = screenPortPoint(connection.to)
                else { continue }
                let selected = connection.id == model.selectedConnectionID
                drawEdge(ctx, from: a, to: b, isExec: connection.isExec,
                         color: edgeColor(connection), selected: selected, label: connection.label)
            }

            // The in-progress (draft) connection: from the draft port to the cursor,
            // tinted by whether the hovered target is a valid completion.
            if let source = model.draftSource,
               let a = screenPortPoint(source),
               let cursorGraphPoint = cursorGraph ?? activeGesture?.lastGraph {
                let cursor = canvasPoint(fromGraph: cursorGraphPoint)
                let isExec = model.pin(source)?.isExec ?? false
                let color: Color = hoverTargetValid ? .green : .accentColor
                drawEdge(ctx, from: a, to: cursor, isExec: isExec, color: color,
                         selected: true, label: nil, dashed: !hoverTargetValid)
            }
        }
        .allowsHitTesting(false)
    }

    /// Draws one edge. Endpoints `a`/`b` are in SCREEN space; line widths are scaled by
    /// `zoom` so the stroke reads identically to the old graph-space drawing under the
    /// container transform.
    private func drawEdge(
        _ ctx: GraphicsContext,
        from a: CGPoint, to b: CGPoint,
        isExec: Bool, color: Color, selected: Bool,
        label: String?, dashed: Bool = false
    ) {
        var path = Path()
        path.move(to: a)
        // Horizontal-ish bezier: control points pushed out along x by half the gap
        // (clamped). The clamp is a graph-space 40 → scale by zoom for screen space.
        let dx = max(40 * zoom, abs(b.x - a.x) * 0.5)
        path.addCurve(
            to: b,
            control1: CGPoint(x: a.x + dx, y: a.y),
            control2: CGPoint(x: b.x - dx, y: b.y)
        )

        // Widths were graph-space (× container scale); reproduce that by × zoom.
        let baseWidth: CGFloat = isExec ? 3.0 : 2.0
        let width = (selected ? baseWidth + 1.5 : baseWidth) * zoom
        var style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        if dashed { style.dash = [6 * zoom, 5 * zoom] }

        if selected {
            // A soft halo behind the selected/draft wire.
            ctx.stroke(path, with: .color(color.opacity(0.30)),
                       style: StrokeStyle(lineWidth: width + 5 * zoom, lineCap: .round))
        }
        ctx.stroke(path, with: .color(color), style: style)

        // Data wires show their label near the midpoint.
        if let label, !isExec, !label.isEmpty {
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let text = Text(label).font(.caption2).foregroundStyle(.secondary)
            ctx.draw(text, at: CGPoint(x: mid.x, y: mid.y - 8 * zoom), anchor: .center)
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
                // Apply the live drag offset for the dragged node, so the card follows
                // the cursor without committing to the model on every frame.
                let dragOffset = graphDragOffset(for: box.id)
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
                    x: originShift + box.position.x + dragOffset.x + size.width / 2,
                    y: originShift + box.position.y + dragOffset.y + size.height / 2
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
           let a = livePortGraphPoint(connection.from),
           let b = livePortGraphPoint(connection.to) {
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

    /// A floating "delete" button at the selected node's top-right corner, so a node
    /// can be removed with a click — no keyboard, no right-click discovery. Positioned
    /// in screen space via the same transform the ports/edges use, so it tracks the
    /// node under pan/zoom.
    @ViewBuilder
    private var selectedNodeDeleteButton: some View {
        if let id = model.selectedNodeID, let box = model.node(id) {
            let size = ScriptGraphLayout.size(box.payload)
            let cornerGraph = CGPoint(x: box.position.x + size.width, y: box.position.y)
            let screen = canvasPoint(fromGraph: cornerGraph)
            Button {
                model.deleteSelection()
            } label: {
                Image(systemName: "trash.fill")
                    .font(.caption)
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.red.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete node")
            .position(screen)
        }
    }

    // MARK: Node-insert palette

    /// The "+" button that opens the node palette, pinned to the top-leading corner in
    /// SCREEN space. As a `Button` it takes hit priority over the canvas drag gesture,
    /// so the affordance and its popover are not swallowed by pan/connect.
    private var paletteButton: some View {
        Button {
            showingPalette = true
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .padding(8)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel("Add node")
        .accessibilityHint("Insert a new node at the center of the canvas.")
        .popover(isPresented: $showingPalette, arrowEdge: .leading) {
            palettePopover
        }
        .onChange(of: showingPalette) { _, isOpen in
            if isOpen { paletteQuery = "" }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The palette contents: insertable node types grouped into labeled sections
    /// (Events, Components, Math, Make, String). Each section header is followed by one
    /// labeled, keyboard-navigable button per node type; selecting one inserts that
    /// node at the viewport center. A flat list doesn't scale once the library grows,
    /// so the popover scrolls and groups by `ScriptGraphNodeLibrary.paletteSections`.
    private var palettePopover: some View {
        let sections = ScriptGraphNodeLibrary.paletteSections(matching: paletteQuery)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Add Node")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search nodes", text: $paletteQuery)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search nodes")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Divider()

            if sections.isEmpty {
                Text("No nodes match \u{201C}\(paletteQuery)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.category.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 4)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(section.items) { item in
                                    Button {
                                        insertNode(type: item.type)
                                    } label: {
                                        Text(item.displayName)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.displayName)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: 220, alignment: .leading)
        .frame(maxHeight: 420)
    }

    /// Inserts a node of `type` at the GRAPH point under the viewport center, then
    /// closes the palette. The new node flows through the same model + rendering, so it
    /// appears centered, selected, and is immediately connectable/movable/deletable.
    private func insertNode(type: String) {
        let centerScreen = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let centerGraph = graphPoint(fromCanvas: centerScreen)
        model.addNode(type: type, at: centerGraph)
        showingPalette = false
        focused = true
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
                // Move (and select) this node. The actual position is kept in LOCAL
                // state during the drag (see `.moveNode` below) so the model — and thus
                // every card/edge reading it — isn't invalidated on every frame.
                model.selectNode(nodeID)
                let origin = model.node(nodeID)?.position ?? .zero
                draggingNodeID = nodeID
                dragTranslation = .zero
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
        case .moveNode(let id, _):
            // Keep the live translation in LOCAL state only — do NOT mutate the model
            // here. `graphDragOffset(for:)` applies this offset to the dragged card and
            // to every edge endpoint on that node; the model commits once on drag end.
            draggingNodeID = id
            dragTranslation = value.translation
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
            draggingNodeID = nil
            dragTranslation = .zero
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
        case .moveNode(let id, let origin):
            // Commit the accumulated drag ONCE, now that the gesture is done. (During
            // the drag the position lived in `dragTranslation`/`draggingNodeID`.)
            model.moveNode(id, to: CGPoint(x: origin.x + value.translation.width / zoom,
                                           y: origin.y + value.translation.height / zoom))
        case .pan where !moved:
            // A tap on empty canvas (or an edge): hit-test edges, else clear.
            if let edgeID = connectionID(nearGraph: drop) {
                model.selectConnection(edgeID)
            } else {
                model.selectNode(nil)
            }
        case .pan, .none:
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
