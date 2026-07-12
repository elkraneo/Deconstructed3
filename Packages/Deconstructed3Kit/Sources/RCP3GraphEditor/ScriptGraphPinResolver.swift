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

    static func execInputHandleID(forHash hash: UInt64?) -> String {
        guard let hash, hash != TMHash.murmur64a("") else { return execInHandleID }
        return "exec.in." + TMHash.hex(hash)
    }

    static func execOutputHandleID(forHash hash: UInt64?) -> String {
        guard let hash, hash != TMHash.murmur64a("") else { return execOutHandleID }
        return "exec.out." + TMHash.hex(hash)
    }

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
    static func payload(
        for node: RCP3ScriptGraph.Node,
        in graph: RCP3ScriptGraph,
        registry: ScriptGraphNodeRegistry = .builtins
    ) -> ScriptGraphNodePayload {
        ScriptGraphNodePayload(
            id: node.id,
            type: node.type,
            label: node.label,
            role: ScriptGraphNodeRole.role(forType: node.type),
            pins: pins(for: node, in: graph, registry: registry)
        )
    }

    // MARK: - Pins

    /// Builds the ordered pins for a single node, preferring its declared interface
    /// from ``ScriptGraphNodeLibrary`` (full named pin set, parity with RCP) and
    /// falling back to wire-derived pins for unknown node types.
    static func pins(
        for node: RCP3ScriptGraph.Node,
        in graph: RCP3ScriptGraph,
        registry: ScriptGraphNodeRegistry = .builtins
    ) -> [ScriptGraphNodePayload.Pin] {
        if node.type == "tm_constant_bitset" {
            let count = Int(graph.literal(node: node.id, pin: TMHash.murmur64a("count"))?.number ?? 0)
            let bitPins = (0..<min(max(count, 0), 32)).map {
                ScriptGraphNodeLibrary.PinSpec.data(String($0), String($0))
            }
            let spec = ScriptGraphNodeLibrary.NodeSpec(
                inputs: [.data("count", "Count")] + bitPins,
                outputs: [.data("value", "Value")],
                category: .math
            )
            return libraryPins(for: node, spec: spec, in: graph)
        }
        if let settings = node.materialSettings,
           let spec = ScriptGraphNodeLibrary.materialSpec(for: node.type, settings: settings) {
            return libraryPins(for: node, spec: spec, in: graph)
        }
        if let settings = node.entityParameterSettings,
           let spec = ScriptGraphNodeLibrary.entityParameterSpec(for: node.type, settings: settings) {
            return libraryPins(for: node, spec: spec, in: graph)
        }
        if let settings = node.dynamicConnectorSettings,
           let policy = ScriptGraphNodeLibrary.dynamicPinPolicy(for: node.type) {
            return dynamicPins(for: node, settings: settings, policy: policy, in: graph)
        }
        if let policy = ScriptGraphNodeLibrary.enumPinPolicy(for: node.type),
           let selectedCase = policy.selectedCase(named: node.enumSelection?.caseName) {
            let associated = selectedCase.associatedValues.map {
                ScriptGraphNodeLibrary.PinSpec.data($0.name, enumAssociatedValueDisplayName($0.name))
            }
            let spec: ScriptGraphNodeLibrary.NodeSpec
            switch policy.direction {
            case .make:
                spec = .init(inputs: associated, outputs: policy.fixedPins, category: .make)
            case .break:
                spec = .init(inputs: policy.fixedPins, outputs: associated, category: .make)
            }
            return libraryPins(for: node, spec: spec, in: graph)
        }
        if let spec = registry.spec(for: node.type) {
            return libraryPins(for: node, spec: spec, in: graph)
        }
        return wireDerivedPins(for: node, in: graph)
    }

    private static func dynamicPins(
        for node: RCP3ScriptGraph.Node,
        settings: RCP3ScriptGraph.Node.DynamicConnectorSettings,
        policy: ScriptGraphNodeLibrary.DynamicPinPolicy,
        in graph: RCP3ScriptGraph
    ) -> [ScriptGraphNodePayload.Pin] {
        let dynamicInputs = settings.inputs.map {
            ScriptGraphNodeLibrary.PinSpec.data(
                $0.name, $0.displayName ?? dynamicConnectorDisplayName($0.name)
            )
        }
        let dynamicOutputs = settings.outputs.map {
            ScriptGraphNodeLibrary.PinSpec.data(
                $0.name, $0.displayName ?? dynamicConnectorDisplayName($0.name)
            )
        }
        let inputSpecs: [ScriptGraphNodeLibrary.PinSpec]
        switch node.type {
        case "tm_array_set":
            // Source emitter connector indices are exec, index, array, element.
            // The typed array pin therefore sits between the two fixed data pins.
            inputSpecs = Array(policy.fixedInputs.prefix(2))
                + dynamicInputs
                + Array(policy.fixedInputs.dropFirst(2))
        case "tm_array_add":
            inputSpecs = Array(policy.fixedInputs.prefix(1))
                + dynamicInputs
                + Array(policy.fixedInputs.dropFirst())
        case "tm_array_find":
            inputSpecs = Array(policy.fixedInputs.prefix(1))
                + dynamicInputs
                + Array(policy.fixedInputs.dropFirst())
        default:
            inputSpecs = policy.fixedInputs + dynamicInputs
        }
        let outputSpecs: [ScriptGraphNodeLibrary.PinSpec]
        switch node.type {
        case "tm_break_material"
            where settings.inputs.first?.name == "PhysicallyBasedMaterial":
            // Break outputs are reconstructed from the selected Inspectable
            // descriptor; RCP serializes no dynamic output connector records.
            outputSpecs = ScriptGraphNodeLibrary.defaultDynamicSpec(for: node.type)?.outputs ?? []
        case "tm_break_physically_based_material_types"
            where settings.inputs.first?.name == "PhysicallyBasedMaterial.Roughness":
            outputSpecs = ScriptGraphNodeLibrary.defaultDynamicSpec(for: node.type)?.outputs ?? []
        case "tm_array_set", "tm_array_add", "tm_array_remove", "tm_is_valid_branch":
            // Their connector builders mirror the typed array INPUT connector as
            // output connector 1; it is not duplicated in settings.outputs.
            outputSpecs = policy.fixedOutputs + dynamicInputs
        default:
            outputSpecs = dynamicOutputs + policy.fixedOutputs
        }
        let category: ScriptGraphNodeLibrary.Category = switch node.type {
        case let type where type.hasPrefix("tm_array_"): .utility
        case "tm_is_valid", "tm_is_valid_branch": .logic
        case "tm_break_material", "tm_break_physically_based_material_types": .make
        default: .string
        }
        let spec = ScriptGraphNodeLibrary.NodeSpec(
            inputs: inputSpecs,
            outputs: outputSpecs,
            category: category
        )
        return libraryPins(for: node, spec: spec, in: graph)
    }

    private static func dynamicConnectorDisplayName(_ name: String) -> String {
        name
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func enumAssociatedValueDisplayName(_ name: String) -> String {
        guard name.hasPrefix("value"), Int(name.dropFirst(5)) != nil else {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return "Value " + name.dropFirst(5)
    }

    /// Pins for a node with a known interface: every declared input and output pin
    /// (wired or not), plus — for a `tm_set_component`/`tm_get_component` whose
    /// `component_type` literal resolves to a known component — that component's
    /// property pins. They are added as data INPUTS on a Set Component (you write
    /// them) and as data OUTPUTS on a Get Component (you read them) — symmetric
    /// mirrors of one another. Exposed literal values (`source = (Self)`,
    /// `component_type = Transform`, …) are carried on the pin's `valueLabel`.
    /// Finally, any pin actually referenced by a wire/literal that the declared
    /// interface does not cover is appended (as a hex-labelled data pin) so no edge
    /// is left dangling.
    private static func libraryPins(
        for node: RCP3ScriptGraph.Node,
        spec: ScriptGraphNodeLibrary.NodeSpec,
        in graph: RCP3ScriptGraph
    ) -> [ScriptGraphNodePayload.Pin] {
        // Resolve the component type once (Set/Get Component only): used both to add
        // the component's property pins and to expose the `component_type` value label.
        let componentTypeHash = resolvedComponentTypeHash(forNode: node, in: graph)
        let resolvedComponentName = componentTypeHash.flatMap(ScriptGraphNodeLibrary.componentTypeName(forHash:))
        let componentProperties = componentTypeHash
            .flatMap(ScriptGraphNodeLibrary.componentProperties(forComponentTypeHash:)) ?? []

        // Set Component writes the component's properties (INPUTS); Get Component reads
        // them (OUTPUTS). A node that is neither — or that has no resolved component —
        // gets no extra property pins.
        var inputSpecs = spec.inputs
        var outputSpecs = spec.outputs
        switch node.type {
        case "tm_set_component": inputSpecs.append(contentsOf: componentProperties)
        case "tm_get_component": outputSpecs.append(contentsOf: componentProperties)
        default: break
        }

        var pins: [ScriptGraphNodePayload.Pin] = []
        pins.append(contentsOf: outputSpecs.map { pin(from: $0, isInput: false, componentTypeName: resolvedComponentName) })
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
            id = isInput
                ? execInputHandleID(forHash: spec.connectorHash)
                : execOutputHandleID(forHash: spec.connectorHash)
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

    /// The chosen component type's `murmur64a` hash for a Set/Get Component node (the
    /// only node types with a `component_type` selector), or `nil` for any other node
    /// type. Shared by both so they resolve their component identically.
    private static func resolvedComponentTypeHash(forNode node: RCP3ScriptGraph.Node, in graph: RCP3ScriptGraph) -> UInt64? {
        guard node.type == "tm_set_component" || node.type == "tm_get_component" else { return nil }
        return componentTypeHash(forNode: node, in: graph)
    }

    /// The `valueHash` of the data literal bound to a node's `component_type` pin — the
    /// chosen component type's `murmur64a` hash, or `nil` when no such literal exists.
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
        if node.type == "tm_sequence" || node.type == "tm_switch" {
            for hash in distinctSorted(graph.wires.compactMap { wire -> UInt64? in
                guard !wire.isExec, wire.from == node.id else { return nil }
                return wire.fromPin
            }) {
                let id = execOutputHandleID(forHash: hash)
                if id != execOutHandleID {
                    pins.append(.init(
                        id: id,
                        label: RCP3ScriptGraph.label(forHash: hash),
                        isInput: false,
                        isExec: true
                    ))
                }
            }
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
