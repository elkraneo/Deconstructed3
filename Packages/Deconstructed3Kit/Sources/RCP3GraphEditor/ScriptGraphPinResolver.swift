import Foundation
import RCP3Document
import TMFormat

/// Derives the renderer-agnostic pin/payload model for a ``RCP3ScriptGraph``.
///
/// This is the *data* half of the editor (the SwiftUI ``ScriptGraphCanvasNodeView``
/// is the *visual* half): it turns each ``RCP3ScriptGraph/Node`` into a
/// ``ScriptGraphNodePayload`` whose ordered `pins` mirror the node's interface —
/// every named pin a node type declares (wired or not), with resolved labels and
/// exposed literal values.
///
/// Everything is derived deterministically from the source graph, so the same
/// graph always produces the same pins/handle-ids — which is what lets wires
/// reference pins by a stable id. The resolver knows nothing about any particular
/// renderer; the live canvas (`ScriptGraphCanvas`/`ScriptGraphCanvasNodeView`)
/// consumes its `payload(for:in:)` output.
///
/// ## Handle-id scheme
/// Each pin's `id` *is* the stable handle id a wire references:
/// - exec input  — id `"exec.in"`
/// - exec output — id `"exec.out"`
/// - data input  — id `"in.<hex>"`
/// - data output — id `"out.<hex>"`
///
/// where `<hex>` is the lowercase, zero-padded 16-digit hex of the pin's
/// `connector_hash` — `TMFormat.TMHash.hex(_:)`.
///
/// ## Full named interfaces
/// On its own the source graph only records *wired* pins. To match RCP 3 — which
/// draws every named pin a node type declares, wired or not — the resolver first
/// consults ``ScriptGraphNodeLibrary``: when a node type has a `NodeSpec`, it emits
/// a pin for each declared pin (computing data handle ids from
/// `TMHash.murmur64a(connectorName)`, so they coincide with the wired-pin ids and
/// edges keep resolving). Node types with no spec fall back to wire-derived pins.
public enum ScriptGraphPinResolver {

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

    /// Lowercase, zero-padded 16-digit hex for a 64-bit hash (`TMHash.hex`).
    static func hex(_ value: UInt64) -> String {
        TMHash.hex(value)
    }

    // MARK: - Payload

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

    // MARK: - Pins

    /// Builds the ordered pins for a single node, preferring its declared interface
    /// from ``ScriptGraphNodeLibrary`` (full named pin set, parity with RCP) and
    /// falling back to wire-derived pins for unknown node types.
    static func pins(for node: RCP3ScriptGraph.Node, in graph: RCP3ScriptGraph) -> [ScriptGraphNodePayload.Pin] {
        if let spec = ScriptGraphNodeLibrary.spec(for: node.type) {
            return libraryPins(for: node, spec: spec, in: graph)
        }
        return wireDerivedPins(for: node, in: graph)
    }

    /// Pins for a node with a known interface: every declared input and output pin
    /// (wired or not), plus — for a `tm_set_component` whose `component_type` literal
    /// resolves to a known component — that component's property pins. Exposed
    /// literal values (`source = (Self)`, `component_type = Transform`, …) are
    /// carried on the pin's `valueLabel`. Finally, any pin actually referenced by a
    /// wire/literal that the declared interface does not cover is appended (as a
    /// hex-labelled data pin) so no edge is left dangling.
    private static func libraryPins(
        for node: RCP3ScriptGraph.Node,
        spec: ScriptGraphNodeLibrary.NodeSpec,
        in graph: RCP3ScriptGraph
    ) -> [ScriptGraphNodePayload.Pin] {
        // Resolve the component type once (Set Component only): used both to add the
        // component's property pins and to expose the `component_type` value label.
        let componentTypeHash = node.type == "tm_set_component"
            ? componentTypeHash(forNode: node, in: graph)
            : nil
        let resolvedComponentName = componentTypeHash.flatMap(ScriptGraphNodeLibrary.componentTypeName(forHash:))

        var inputSpecs = spec.inputs
        if let componentTypeHash,
           let properties = ScriptGraphNodeLibrary.componentProperties(forComponentTypeHash: componentTypeHash) {
            inputSpecs.append(contentsOf: properties)
        }

        var pins: [ScriptGraphNodePayload.Pin] = []
        pins.append(contentsOf: spec.outputs.map { pin(from: $0, isInput: false, componentTypeName: resolvedComponentName) })
        pins.append(contentsOf: inputSpecs.map { pin(from: $0, isInput: true, componentTypeName: resolvedComponentName) })

        // Safety net: include any wired/literal pin the declared interface omits, so
        // an edge never references a handle that does not exist.
        let declaredIDs = Set(pins.map(\.id))
        for extra in wireDerivedPins(for: node, in: graph) where !declaredIDs.contains(extra.id) {
            pins.append(extra)
        }
        return pins
    }

    /// Converts a library ``ScriptGraphNodeLibrary/PinSpec`` into a payload pin,
    /// assigning the handle id (fixed for exec, hashed for data) and any exposed
    /// literal value RCP shows for it.
    private static func pin(
        from spec: ScriptGraphNodeLibrary.PinSpec,
        isInput: Bool,
        componentTypeName: String?
    ) -> ScriptGraphNodePayload.Pin {
        let id: String
        if spec.isExec {
            id = isInput ? execInHandleID : execOutHandleID
        } else if isInput {
            id = inputHandleID(forHash: spec.connectorHash)
        } else {
            id = outputHandleID(forHash: spec.connectorHash)
        }
        return .init(
            id: id,
            label: spec.displayName,
            isInput: isInput,
            isExec: spec.isExec,
            valueLabel: exposedValue(for: spec, componentTypeName: componentTypeName)
        )
    }

    /// The exposed literal value RCP shows next to a pin, when one is known:
    /// `source` reads `(Self)`; `component_type` reads the resolved component name.
    private static func exposedValue(
        for spec: ScriptGraphNodeLibrary.PinSpec,
        componentTypeName: String?
    ) -> String? {
        switch spec.connectorName {
        case "source": return "(Self)"
        case "component_type": return componentTypeName
        default: return nil
        }
    }

    /// The chosen component type's `murmur64a` hash for a `tm_set_component` node:
    /// the `valueHash` of the data literal bound to its `component_type` pin.
    private static func componentTypeHash(forNode node: RCP3ScriptGraph.Node, in graph: RCP3ScriptGraph) -> UInt64? {
        let componentTypePin = TMHash.murmur64a("component_type")
        return graph.data.first { $0.toNode == node.id && $0.toPin == componentTypePin }?.valueHash
    }

    /// Pins derived purely from wires + data literals — the fallback for node types
    /// with no library spec. Order is stable: exec pins first (out then in), then
    /// data outputs and inputs sorted by hash.
    private static func wireDerivedPins(for node: RCP3ScriptGraph.Node, in graph: RCP3ScriptGraph) -> [ScriptGraphNodePayload.Pin] {
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

    // MARK: - Helpers

    /// Distinct, ascending hashes from a sequence of optionals (nils dropped).
    private static func distinctSorted(_ hashes: [UInt64]) -> [UInt64] {
        Array(Set(hashes)).sorted()
    }
}
