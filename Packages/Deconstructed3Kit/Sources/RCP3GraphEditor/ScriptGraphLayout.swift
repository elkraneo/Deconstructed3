import CoreGraphics

// MARK: - SwiftUI Canvas renderer geometry
//
// Deterministic 2D layout for the Canvas renderer: a node's size and the exact
// connection point of every port, computed from a fixed row layout. Both the node
// view (which draws the ports) and the canvas (which routes edges and hit-tests
// ports) use these functions, so what you see and what you can wire always agree —
// the per-port connection points SwiftFlow could not give us.
//
// This is Canvas-specific (2D). A spatial renderer computes its own anchor points;
// only `ScriptGraphEditorModel` (the logical graph) is shared.

public enum ScriptGraphLayout {
    /// Node body width.
    public static let nodeWidth: CGFloat = 240
    /// Height of the node header (icon + title + type caption).
    public static let headerHeight: CGFloat = 48
    /// Height of one port row.
    public static let rowHeight: CGFloat = 26
    /// Padding below the last port row.
    public static let bottomPadding: CGFloat = 10
    /// Visible radius of a port dot.
    public static let portRadius: CGFloat = 5
    /// Hit-test radius around a port's connection point (generous for pointer/touch).
    public static let portHitRadius: CGFloat = 14

    /// Port rows shown = the taller of the input and output columns. Exec pins are
    /// first in each column (top row), matching RCP's layout.
    public static func rowCount(_ payload: ScriptGraphNodePayload) -> Int {
        max(payload.inputPins.count, payload.outputPins.count)
    }

    /// The node's body size for `payload`.
    public static func size(_ payload: ScriptGraphNodePayload) -> CGSize {
        CGSize(
            width: nodeWidth,
            height: headerHeight + CGFloat(rowCount(payload)) * rowHeight + bottomPadding
        )
    }

    /// Vertical center of row `index` (0-based), measured from the node's top.
    public static func rowCenterY(_ index: Int) -> CGFloat {
        headerHeight + CGFloat(index) * rowHeight + rowHeight / 2
    }

    /// The connection point of `pin`, relative to the node's top-left. Inputs sit on
    /// the left edge (x = 0), outputs on the right edge (x = width); the row is the
    /// pin's index within its column. `nil` if the pin isn't part of `payload`.
    public static func portOffset(
        for pin: ScriptGraphNodePayload.Pin,
        in payload: ScriptGraphNodePayload
    ) -> CGPoint? {
        if pin.isInput {
            guard let index = payload.inputPins.firstIndex(where: { $0.id == pin.id }) else { return nil }
            return CGPoint(x: 0, y: rowCenterY(index))
        } else {
            guard let index = payload.outputPins.firstIndex(where: { $0.id == pin.id }) else { return nil }
            return CGPoint(x: nodeWidth, y: rowCenterY(index))
        }
    }

    /// The connection point for a pin id, relative to the node's top-left.
    public static func portOffset(forPinID id: String, in payload: ScriptGraphNodePayload) -> CGPoint? {
        guard let pin = payload.pins.first(where: { $0.id == id }) else { return nil }
        return portOffset(for: pin, in: payload)
    }
}

public extension ScriptGraphEditorModel {
    /// The absolute connection point of a port in graph space (node position + the
    /// Canvas layout offset). Used by the Canvas renderer to route edges and
    /// hit-test ports. `nil` if the port can't be resolved.
    func canvasPortPoint(_ ref: GraphPortRef) -> CGPoint? {
        guard
            let box = node(ref.nodeID),
            let offset = ScriptGraphLayout.portOffset(forPinID: ref.pinID, in: box.payload)
        else { return nil }
        return CGPoint(x: box.position.x + offset.x, y: box.position.y + offset.y)
    }

    /// The port whose connection point is nearest `graphPoint` within the hit
    /// radius, or `nil`. Used by the Canvas renderer for drag-to-connect.
    func canvasPort(near graphPoint: CGPoint) -> GraphPortRef? {
        var best: (ref: GraphPortRef, distance: CGFloat)?
        for box in nodes {
            for pin in box.payload.pins {
                guard let offset = ScriptGraphLayout.portOffset(for: pin, in: box.payload) else { continue }
                let point = CGPoint(x: box.position.x + offset.x, y: box.position.y + offset.y)
                let distance = hypot(point.x - graphPoint.x, point.y - graphPoint.y)
                if distance <= ScriptGraphLayout.portHitRadius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                    best = (GraphPortRef(nodeID: box.id, pinID: pin.id), distance)
                }
            }
        }
        return best?.ref
    }
}
