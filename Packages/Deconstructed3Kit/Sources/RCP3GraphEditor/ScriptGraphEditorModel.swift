import CoreGraphics
import Foundation
import Observation
import RCP3Document
import TMFormat

// MARK: - Renderer-agnostic core model
//
// This file is the *core* of the script-graph editor: the logical graph plus the
// interaction semantics, with NO SwiftUI and NO RealityKit. It knows WHAT the user
// is doing (begin a connection, move a node, delete) — never WHERE pixels are.
//
// Renderers consume this model:
// - the SwiftUI **Canvas** renderer (`ScriptGraphLayout` + the canvas views) — 2D,
//   now;
// - a future **RealityKit spatial** renderer (Vision Pro) — nodes as entities,
//   ports as 3D anchors, connections as splines, physics, hand/gaze interaction.
//
// Both call the same verbs here (`beginConnection`/`completeConnection`/`moveNode`/
// `delete…`). Geometry, hit-testing, and gestures live in each renderer, not here.

/// A reference to one port (a pin on a node): the connection endpoint identity.
public struct GraphPortRef: Hashable, Sendable {
    public let nodeID: String
    /// The pin id (the bridge's stable handle id: `exec.in`/`exec.out`/`in.<hex>`/`out.<hex>`).
    public let pinID: String

    public init(nodeID: String, pinID: String) {
        self.nodeID = nodeID
        self.pinID = pinID
    }
}

/// A connection between an output port and an input port (renderer-agnostic).
public struct GraphConnection: Identifiable, Hashable, Sendable {
    public let id: String
    /// The output (source) port.
    public let from: GraphPortRef
    /// The input (target) port.
    public let to: GraphPortRef
    /// `true` for a control-flow (exec) connection, `false` for a data connection.
    public let isExec: Bool
    /// A readable label (the target pin's name) for display/accessibility.
    public let label: String

    public init(id: String, from: GraphPortRef, to: GraphPortRef, isExec: Bool, label: String) {
        self.id = id
        self.from = from
        self.to = to
        self.isExec = isExec
        self.label = label
    }
}

/// A node placed at an authored position. `position` is the 2D layout from the
/// graph file; spatial renderers may reinterpret it (e.g. lay nodes on a plane and
/// let physics take over). The node's *logical* interface is `payload.pins`.
public struct GraphNodeBox: Identifiable, Hashable, Sendable {
    public let id: String
    public var position: CGPoint
    public var payload: ScriptGraphNodePayload

    public init(id: String, position: CGPoint, payload: ScriptGraphNodePayload) {
        self.id = id
        self.position = position
        self.payload = payload
    }
}

/// The editor's observable state + interaction logic, shared across renderers.
///
/// It owns the logical graph (nodes + connections), selection, and an in-progress
/// connection (`draftSource`). Mutations go through verbs that enforce the rules
/// (output→input, exec↔exec / data↔data, no self-loops, one data wire per input).
@MainActor
@Observable
public final class ScriptGraphEditorModel {
    public private(set) var nodes: [GraphNodeBox]
    public private(set) var connections: [GraphConnection]

    /// The selected node, if any.
    public var selectedNodeID: String?
    /// The selected connection, if any.
    public var selectedConnectionID: String?

    /// The port a connection is currently being dragged FROM, if a connection
    /// gesture is in progress. The renderer tracks the moving endpoint (cursor /
    /// hand) itself and calls `completeConnection(to:)` on drop.
    public private(set) var draftSource: GraphPortRef?

    /// Builds the editor state from a parsed script graph. Node interfaces (the full
    /// named pin set + exposed values) come from the shared pin derivation; node
    /// positions come from the file (`x`/`y`), falling back to a left-to-right lane.
    public init(graph: RCP3ScriptGraph) {
        var boxes: [GraphNodeBox] = []
        for (index, node) in graph.nodes.enumerated() {
            let payload = ScriptGraphFlowBridge.payload(for: node, in: graph)
            let position = CGPoint(
                x: node.x ?? Double(index) * Self.fallbackLaneSpacing,
                y: node.y ?? 0
            )
            boxes.append(GraphNodeBox(id: node.id, position: position, payload: payload))
        }
        nodes = boxes

        let ids = Set(boxes.map(\.id))
        var conns: [GraphConnection] = []
        for wire in graph.wires where ids.contains(wire.from) && ids.contains(wire.to) {
            if wire.isExec {
                conns.append(GraphConnection(
                    id: wire.id,
                    from: GraphPortRef(nodeID: wire.from, pinID: "exec.out"),
                    to: GraphPortRef(nodeID: wire.to, pinID: "exec.in"),
                    isExec: true,
                    label: "exec"
                ))
            } else if let fromPin = wire.fromPin, let toPin = wire.toPin {
                conns.append(GraphConnection(
                    id: wire.id,
                    from: GraphPortRef(nodeID: wire.from, pinID: "out." + TMHash.hex(fromPin)),
                    to: GraphPortRef(nodeID: wire.to, pinID: "in." + TMHash.hex(toPin)),
                    isExec: false,
                    label: RCP3ScriptGraph.label(forHash: toPin)
                ))
            }
        }
        connections = conns
    }

    static let fallbackLaneSpacing: Double = 320

    // MARK: Lookups

    public func node(_ id: String) -> GraphNodeBox? { nodes.first { $0.id == id } }

    public func pin(_ ref: GraphPortRef) -> ScriptGraphNodePayload.Pin? {
        node(ref.nodeID)?.payload.pins.first { $0.id == ref.pinID }
    }

    /// Connections touching a given port (either endpoint).
    public func connections(touching ref: GraphPortRef) -> [GraphConnection] {
        connections.filter { $0.from == ref || $0.to == ref }
    }

    // MARK: Node authoring (insert)

    /// Inserts a new node of `type` at `position` (graph space) and selects it.
    ///
    /// The node gets its full named interface from the shared pin derivation
    /// (``ScriptGraphFlowBridge/payload(for:in:)``): for a lone node with no wires
    /// that yields exactly the type's declared pins, so the inserted node is
    /// immediately connectable/movable/deletable like any authored one. A fresh UUID
    /// id avoids collisions with the loaded graph. Returns the new node's id.
    @discardableResult
    public func addNode(type: String, label: String? = nil, at position: CGPoint) -> String {
        let newID = UUID().uuidString
        let node = RCP3ScriptGraph.Node(id: newID, type: type, label: label)
        let payload = ScriptGraphFlowBridge.payload(
            for: node,
            in: RCP3ScriptGraph(nodes: [node], wires: [], data: [])
        )
        nodes.append(GraphNodeBox(id: newID, position: position, payload: payload))
        selectNode(newID)
        return newID
    }

    // MARK: Node movement (position is renderer-space-agnostic data)

    public func moveNode(_ id: String, to position: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].position = position
    }

    // MARK: Connection verbs

    /// Whether an `output` port may connect to an `input` port: different nodes,
    /// output→input, and matching control-flow vs data kind.
    public func canConnect(_ a: GraphPortRef, _ b: GraphPortRef) -> Bool {
        normalizedConnection(a, b) != nil
    }

    /// Begins a connection drag from `port`. Either an output or an input may start
    /// the drag; `completeConnection(to:)` resolves the direction.
    public func beginConnection(from port: GraphPortRef) {
        draftSource = port
    }

    /// Completes the in-progress connection to `port`, if valid. Returns the new
    /// connection's id, or `nil` if the pairing is invalid (the draft is cleared
    /// either way).
    @discardableResult
    public func completeConnection(to port: GraphPortRef) -> String? {
        defer { draftSource = nil }
        guard let source = draftSource else { return nil }
        return connect(source, port)
    }

    public func cancelConnection() { draftSource = nil }

    /// Creates a connection between two ports in either order, enforcing the rules.
    /// Replaces any existing connection already feeding the target input port (an
    /// input takes a single source, as in RCP).
    @discardableResult
    public func connect(_ a: GraphPortRef, _ b: GraphPortRef) -> String? {
        guard let (output, input, isExec) = normalizedConnection(a, b) else { return nil }
        // An input port accepts one incoming connection of its kind.
        connections.removeAll { $0.to == input }
        let id = UUID().uuidString
        let label = pin(input)?.label ?? "connection"
        connections.append(GraphConnection(id: id, from: output, to: input, isExec: isExec, label: label))
        return id
    }

    public func removeConnection(_ id: String) {
        connections.removeAll { $0.id == id }
        if selectedConnectionID == id { selectedConnectionID = nil }
    }

    // MARK: Selection + deletion

    public func selectNode(_ id: String?) {
        selectedNodeID = id
        selectedConnectionID = nil
    }

    public func selectConnection(_ id: String?) {
        selectedConnectionID = id
        selectedNodeID = nil
    }

    /// Deletes the current selection. A selected connection is removed; a selected
    /// node is removed along with every connection touching it.
    public func deleteSelection() {
        if let id = selectedConnectionID {
            removeConnection(id)
        } else if let id = selectedNodeID {
            connections.removeAll { $0.from.nodeID == id || $0.to.nodeID == id }
            nodes.removeAll { $0.id == id }
            selectedNodeID = nil
        }
    }

    // MARK: Rules

    /// Resolves two ports into `(output, input, isExec)` if they form a legal
    /// connection, else `nil`. Order-independent.
    private func normalizedConnection(
        _ a: GraphPortRef,
        _ b: GraphPortRef
    ) -> (output: GraphPortRef, input: GraphPortRef, isExec: Bool)? {
        guard a.nodeID != b.nodeID, let pa = pin(a), let pb = pin(b) else { return nil }
        let output: GraphPortRef
        let input: GraphPortRef
        let outputPin: ScriptGraphNodePayload.Pin
        let inputPin: ScriptGraphNodePayload.Pin
        if !pa.isInput, pb.isInput {
            (output, input, outputPin, inputPin) = (a, b, pa, pb)
        } else if pa.isInput, !pb.isInput {
            (output, input, outputPin, inputPin) = (b, a, pb, pa)
        } else {
            return nil // both inputs or both outputs
        }
        guard outputPin.isExec == inputPin.isExec else { return nil } // exec↔exec / data↔data
        return (output, input, outputPin.isExec)
    }
}
