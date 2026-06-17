import Foundation
import TMFormat

/// A parsed, display-oriented projection of an RCP 3 script graph — the no-code
/// logic attached to an entity through a `re_scripting_component`.
///
/// The on-disk graph (a `re_scripting_source_graph` asset, `<Name>.tm_script_graph`)
/// holds a `tm_graph` of `nodes`, `connections`, and `data` literals. Nodes are
/// identified by `__uuid`; connections wire one node's pin to another's. A
/// connection with **no** connector hashes is an exec / control-flow wire; a
/// connection **with** `from_connector_hash` + `to_connector_hash` is a data wire.
/// Pins are referenced by `connector_hash = TMHash.murmur64a(pinName)`, so a wire
/// only knows the hash — `RCP3ScriptGraph` resolves the common ones back to names
/// via `RCP3ScriptGraph.pinName(forHash:)`, falling back to the hex hash.
public struct RCP3ScriptGraph: Equatable, Sendable {
    /// A graph node — one logic block (an event, an action, a getter, …).
    public struct Node: Equatable, Sendable, Identifiable {
        /// The node's `__uuid` (what connections/data reference).
        public let id: String
        /// The node `type` (e.g. `tm_gesture_event_drag`, `tm_set_component`).
        public let type: String
        /// An author-given `label` (e.g. `"Set Transform"`), when present.
        public let label: String?
        /// Canvas position, when present.
        public let x: Double?
        public let y: Double?
        /// For a variable Get/Set/Clear node, the name of the script-graph variable it
        /// references (the simplified `tm_graph_variable_ref`). A LOCAL variable
        /// compiles to a stable per-script slot derived from this name (see
        /// `CanonicalScriptGraphCompiler`); `nil` for non-variable nodes (the default,
        /// so all existing call sites compile unchanged).
        ///
        /// This is the **in-memory** reference only. The **on-disk `.tm_` round-trip**
        /// of this field is DEFERRED — it needs a captured `.tm_` graph that uses a
        /// variable to lock the byte layout of the `tm_graph_variable_ref` settings
        /// field, so it is intentionally NOT wired into the parser/writer here.
        public let variableName: String?

        public init(id: String, type: String, label: String? = nil, x: Double? = nil, y: Double? = nil, variableName: String? = nil) {
            self.id = id
            self.type = type
            self.label = label
            self.x = x
            self.y = y
            self.variableName = variableName
        }
    }

    /// A connection between two nodes. With no pin hashes it is an exec wire;
    /// with both it is a data wire from `fromPin` to `toPin`.
    public struct Wire: Equatable, Sendable, Identifiable {
        public let id: String
        /// Source node `__uuid` (`from_node`).
        public let from: String
        /// Destination node `__uuid` (`to_node`).
        public let to: String
        /// `from_connector_hash`, when this is a data wire.
        public let fromPin: UInt64?
        /// `to_connector_hash`, when this is a data wire.
        public let toPin: UInt64?

        /// `true` when the wire carries no pin hashes — a control-flow (exec) edge.
        public var isExec: Bool { fromPin == nil && toPin == nil }

        public init(id: String, from: String, to: String, fromPin: UInt64? = nil, toPin: UInt64? = nil) {
            self.id = id
            self.from = from
            self.to = to
            self.fromPin = fromPin
            self.toPin = toPin
        }
    }

    /// A constant input bound to a node's pin (`data[{to_node, to_connector_hash, data}]`).
    public struct DataLiteral: Equatable, Sendable, Identifiable {
        public let id: String
        /// Destination node `__uuid` (`to_node`).
        public let toNode: String
        /// `to_connector_hash` — the bound pin.
        public let toPin: UInt64
        /// The literal value's `__type`, when the value is an object.
        public let valueType: String?
        /// The literal value's own `type` member parsed as a 64-bit hash, when the
        /// value object carries one — e.g. a `re_scripting_graph_component_type`
        /// literal stores the chosen component type's `murmur64a` hash here (as a
        /// 16-digit hex string). Lets a consumer resolve *which* value the literal
        /// names (the component type, the enum case, …), not just its container type.
        public let valueHash: UInt64?
        /// A scalar (numeric) constant bound to the pin, when the literal is a plain
        /// number — e.g. an unwired `make_vector3` component or a math operand. Read by
        /// the canonical compiler (an unwired numeric pin compiles to this value), and
        /// round-tripped through the on-disk `data[]` by the editor's scalar-literal
        /// authoring: the value object carries a `value` number member
        /// (`data: { value: <number> }`) which the parser reads back into `scalarValue`.
        public let scalarValue: Double?

        public init(id: String, toNode: String, toPin: UInt64, valueType: String? = nil, valueHash: UInt64? = nil, scalarValue: Double? = nil) {
            self.id = id
            self.toNode = toNode
            self.toPin = toPin
            self.valueType = valueType
            self.valueHash = valueHash
            self.scalarValue = scalarValue
        }
    }

    public let nodes: [Node]
    public let wires: [Wire]
    public let data: [DataLiteral]

    public init(nodes: [Node], wires: [Wire], data: [DataLiteral]) {
        self.nodes = nodes
        self.wires = wires
        self.data = data
    }

    /// Parses a `tm_graph` object (the `graph` member of a
    /// `re_scripting_source_graph`) into a display graph.
    public init(tmGraph: TMObject) {
        nodes = (tmGraph["nodes"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue, let id = object.uuid else { return nil }
            let position = object["position"]?.objectValue
            // Node kind is the plain `type` member (not the reserved `__type`).
            return Node(
                id: id,
                type: object["type"]?.stringValue ?? object.prototypeType ?? "?",
                label: object["label"]?.stringValue,
                x: position?["x"]?.doubleValue,
                y: position?["y"]?.doubleValue
            )
        }

        wires = (tmGraph["connections"]?.arrayValue ?? []).compactMap { value in
            guard
                let object = value.objectValue,
                let from = object["from_node"]?.stringValue,
                let to = object["to_node"]?.stringValue
            else { return nil }
            return Wire(
                id: object.uuid ?? "\(from)->\(to)",
                from: from,
                to: to,
                fromPin: object["from_connector_hash"]?.stringValue.flatMap { UInt64($0, radix: 16) },
                toPin: object["to_connector_hash"]?.stringValue.flatMap { UInt64($0, radix: 16) }
            )
        }

        data = (tmGraph["data"]?.arrayValue ?? []).compactMap { value in
            guard
                let object = value.objectValue,
                let toNode = object["to_node"]?.stringValue,
                let pinHex = object["to_connector_hash"]?.stringValue,
                let toPin = UInt64(pinHex, radix: 16)
            else { return nil }
            let valueObject = object["data"]?.objectValue
            return DataLiteral(
                id: object.uuid ?? "\(toNode)#\(pinHex)",
                toNode: toNode,
                toPin: toPin,
                valueType: valueObject?.type,
                // The value object's plain `type` member (not the reserved `__type`)
                // carries the named value's hash as a 16-digit hex string.
                valueHash: valueObject?["type"]?.stringValue.flatMap { UInt64($0, radix: 16) },
                // A scalar literal stores its number as the value object's `value`
                // member (`data: { value: <number> }`) — what the editor authors and
                // the compiler reads back for an unwired numeric pin.
                scalarValue: valueObject?["value"]?.doubleValue
            )
        }
    }

    // MARK: Pin-name resolution

    /// Common script-graph pin names, keyed by their `murmur64a` hash. Used to turn
    /// a stored `connector_hash` back into a readable label; unknown hashes fall
    /// back to their hex form via `label(forHash:)`.
    ///
    /// The list is intentionally small and built from observed/common pin names;
    /// it does not need to be exhaustive — it only improves the inspector's labels.
    static let knownPinNames: [String] = [
        "exec", "then", "completed", "entity", "target", "value",
        "translation", "rotation", "scale", "transform",
        "component_type", "component", "position", "orientation",
        "input", "output", "result", "delta", "location", "phase", "state",
    ]

    /// `[hash: name]` built from `knownPinNames`.
    static let pinNamesByHash: [UInt64: String] = {
        var map: [UInt64: String] = [:]
        for name in knownPinNames {
            map[TMHash.murmur64a(name)] = name
        }
        return map
    }()

    /// A readable name for a pin hash, or `nil` when the hash isn't a known pin.
    public static func pinName(forHash hash: UInt64) -> String? {
        pinNamesByHash[hash]
    }

    /// A readable label for a pin hash: the resolved name, else its hex form.
    public static func label(forHash hash: UInt64?) -> String {
        guard let hash else { return "exec" }
        return pinName(forHash: hash) ?? TMHash.hex(hash)
    }

    /// Convenience used by callers/views: the node with this `__uuid`.
    public func node(id: String) -> Node? {
        nodes.first { $0.id == id }
    }

    /// The scalar constant bound to `pin` of node `nodeID` via a `data` literal, if
    /// any — the value an unwired numeric pin carries.
    public func scalarLiteral(node nodeID: String, pin: UInt64) -> Double? {
        data.first { $0.toNode == nodeID && $0.toPin == pin && $0.scalarValue != nil }?.scalarValue
    }
}
