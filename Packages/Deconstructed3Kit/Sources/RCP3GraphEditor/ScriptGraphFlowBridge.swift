import CoreGraphics
import Foundation
import RCP3Document
import SwiftFlow

/// Maps a parsed ``RCP3ScriptGraph`` onto SwiftFlow's document model.
///
/// The bridge is the *data* half of the editor (the ``ScriptGraphNodeView`` is the
/// *visual* half): it turns each ``RCP3ScriptGraph/Node`` into a
/// `FlowNode<ScriptGraphNodePayload>` whose `handles` mirror the payload's `pins`,
/// and each ``RCP3ScriptGraph/Wire`` into a `FlowEdge` joining two of those handles.
///
/// Everything is derived deterministically from the source graph, so the same
/// graph always produces the same nodes/edges/handle-ids — which is what lets the
/// edges reference handles by a stable id.
///
/// ## Handle-id scheme
/// Each node declares one handle per pin; the pin's `id` *is* the SwiftFlow handle
/// id an edge references:
/// - exec input  — id `"exec.in"`,  `HandleType.target`, `HandlePosition.left`
/// - exec output — id `"exec.out"`, `HandleType.source`, `HandlePosition.right`
/// - data input  — id `"in.<hex>"`,  `HandleType.target`, `HandlePosition.left`
/// - data output — id `"out.<hex>"`, `HandleType.source`, `HandlePosition.right`
///
/// where `<hex>` is the lowercase, zero-padded 16-digit hex of the pin's
/// `connector_hash` — identical to `TMFormat.TMHash.hex(_:)`, reproduced locally
/// (see ``hex(_:)``) because this target does not depend on `TMFormat`.
public enum ScriptGraphFlowBridge {

    // MARK: - Layout constants

    /// Default node size when one is not derived from content.
    static let defaultNodeSize = CGSize(width: 200, height: 84)
    /// Horizontal spacing used when a node carries no canvas position.
    static let fallbackColumnWidth: Double = 220

    // MARK: - Handle ids

    /// The handle id for a node's exec (control-flow) input pin.
    static let execInHandleID = "exec.in"
    /// The handle id for a node's exec (control-flow) output pin.
    static let execOutHandleID = "exec.out"

    /// The handle id for a data *input* pin keyed by `connector_hash`.
    static func inputHandleID(forHash hash: UInt64) -> String {
        "in." + hex(hash)
    }

    /// The handle id for a data *output* pin keyed by `connector_hash`.
    static func outputHandleID(forHash hash: UInt64) -> String {
        "out." + hex(hash)
    }

    /// Lowercase, zero-padded 16-digit hex for a 64-bit hash. Byte-for-byte
    /// identical to `TMFormat.TMHash.hex(_:)`; reproduced here so the bridge does
    /// not need a `TMFormat` dependency for a one-line formatter.
    static func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    // MARK: - Pins

    /// Builds the ordered pins for a single node by scanning the graph's wires and
    /// data literals. Order is stable: exec pins first (out then in), then data
    /// outputs and inputs sorted by hash, so a given graph always yields identical
    /// handle declarations.
    static func pins(for node: RCP3ScriptGraph.Node, in graph: RCP3ScriptGraph) -> [ScriptGraphNodePayload.Pin] {
        var pins: [ScriptGraphNodePayload.Pin] = []

        // Exec participation: a node has an exec output if it is the source of any
        // exec wire, and an exec input if it is the target of any exec wire.
        let hasExecOut = graph.wires.contains { $0.isExec && $0.from == node.id }
        let hasExecIn = graph.wires.contains { $0.isExec && $0.to == node.id }

        if hasExecOut {
            pins.append(.init(id: execOutHandleID, label: "exec", isInput: false, isExec: true))
        }
        if hasExecIn {
            pins.append(.init(id: execInHandleID, label: "exec", isInput: true, isExec: true))
        }

        // Data outputs: distinct `fromPin` hashes among data wires leaving this node.
        let outputHashes = distinctSorted(
            graph.wires.compactMap { wire -> UInt64? in
                guard !wire.isExec, wire.from == node.id else { return nil }
                return wire.fromPin
            }
        )
        for hash in outputHashes {
            pins.append(.init(
                id: outputHandleID(forHash: hash),
                label: RCP3ScriptGraph.label(forHash: hash),
                isInput: false,
                isExec: false
            ))
        }

        // Data inputs: distinct `toPin` hashes among data wires *and* data literals
        // arriving at this node.
        var inputHashSet = Set<UInt64>()
        for wire in graph.wires where !wire.isExec && wire.to == node.id {
            if let hash = wire.toPin { inputHashSet.insert(hash) }
        }
        for literal in graph.data where literal.toNode == node.id {
            inputHashSet.insert(literal.toPin)
        }
        for hash in inputHashSet.sorted() {
            pins.append(.init(
                id: inputHandleID(forHash: hash),
                label: RCP3ScriptGraph.label(forHash: hash),
                isInput: true,
                isExec: false
            ))
        }

        return pins
    }

    /// The SwiftFlow handle declaration matching a pin: inputs are `.target` on the
    /// `.left`, outputs are `.source` on the `.right`.
    static func handle(for pin: ScriptGraphNodePayload.Pin) -> HandleDeclaration {
        HandleDeclaration(
            id: pin.id,
            type: pin.isInput ? .target : .source,
            position: pin.isInput ? .left : .right
        )
    }

    // MARK: - Nodes

    /// The payload (data) carried by a node: id, type, label, role, and pins.
    static func payload(for node: RCP3ScriptGraph.Node, in graph: RCP3ScriptGraph) -> ScriptGraphNodePayload {
        ScriptGraphNodePayload(
            id: node.id,
            type: node.type,
            label: node.label,
            role: ScriptGraphNodeRole.role(forType: node.type),
            pins: pins(for: node, in: graph)
        )
    }

    /// All SwiftFlow nodes for a graph, in source order. A node carrying explicit
    /// `x`/`y` is placed there; otherwise it is laid out left-to-right by index.
    public static func nodes(for graph: RCP3ScriptGraph) -> [FlowNode<ScriptGraphNodePayload>] {
        graph.nodes.enumerated().map { index, node in
            let payload = payload(for: node, in: graph)
            let position: CGPoint
            if let x = node.x, let y = node.y {
                position = CGPoint(x: x, y: y)
            } else {
                position = CGPoint(x: Double(index) * fallbackColumnWidth, y: 0)
            }
            return FlowNode(
                id: node.id,
                position: position,
                size: defaultNodeSize,
                data: payload,
                handles: payload.pins.map(handle(for:))
            )
        }
    }

    // MARK: - Edges

    /// All SwiftFlow edges for a graph. A wire is skipped only when one of its
    /// endpoint nodes is missing from the graph. Exec wires use the exec handles and
    /// a stepped path; data wires use the hashed data handles and a bezier path.
    public static func edges(for graph: RCP3ScriptGraph) -> [FlowEdge] {
        let nodeIDs = Set(graph.nodes.map(\.id))
        return graph.wires.compactMap { wire -> FlowEdge? in
            guard nodeIDs.contains(wire.from), nodeIDs.contains(wire.to) else { return nil }

            if wire.isExec {
                return FlowEdge(
                    id: wire.id,
                    sourceNodeID: wire.from,
                    sourceHandleID: execOutHandleID,
                    targetNodeID: wire.to,
                    targetHandleID: execInHandleID,
                    pathType: .smoothStep,
                    label: "exec"
                )
            }

            // Data wire: both pin hashes are present by construction (a wire with any
            // hash is a data wire). Fall back defensively if one is somehow missing.
            guard let fromPin = wire.fromPin, let toPin = wire.toPin else { return nil }
            return FlowEdge(
                id: wire.id,
                sourceNodeID: wire.from,
                sourceHandleID: outputHandleID(forHash: fromPin),
                targetNodeID: wire.to,
                targetHandleID: inputHandleID(forHash: toPin),
                pathType: .bezier,
                label: RCP3ScriptGraph.label(forHash: toPin)
            )
        }
    }

    // MARK: - Store

    /// A ready-to-render `FlowStore` populated with the graph's nodes and edges.
    ///
    /// Edges are added after nodes so SwiftFlow's `addEdge` endpoint validation
    /// (which requires both nodes to exist) always passes for well-formed wires.
    @MainActor
    public static func store(for graph: RCP3ScriptGraph) -> FlowStore<ScriptGraphNodePayload> {
        let store = FlowStore<ScriptGraphNodePayload>()
        for node in nodes(for: graph) {
            store.addNode(node)
        }
        for edge in edges(for: graph) {
            store.addEdge(edge)
        }
        return store
    }

    // MARK: - Helpers

    /// Distinct, ascending hashes from a sequence of optionals (nils dropped).
    private static func distinctSorted(_ hashes: [UInt64]) -> [UInt64] {
        Array(Set(hashes)).sorted()
    }
}
