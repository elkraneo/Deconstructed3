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
        /// On disk the reference rides on the node's `name` input connector
        /// (`murmur64a("name")`) as a `tm_graph_variable_ref` data literal pointing at
        /// the graph-level ``RCP3ScriptGraph/variables`` table by `ref` (uuid) and
        /// denormalizing the `name`. The parser reads it into this field; the editor's
        /// write-back re-emits it (see `ScriptGraphWriteBack`).
        public var variableName: String?

        /// For a variable node, the `__uuid` of the ``Variable`` table entry its
        /// on-disk `tm_graph_variable_ref` pointed at (`ref`), preserved so write-back
        /// can re-emit the reference against a stable variable identity. `nil` for a
        /// non-variable node or a name set in-memory with no resolved table entry yet.
        public var variableRefUUID: String?

        /// PROVENANCE (instance-override graphs). When this node came from an entity's
        /// embedded `re_scripting_component.source.graph` as a `nodes__instantiated`
        /// entry — an INSTANCE of a node declared in the standalone prototype graph —
        /// this holds that prototype node's `__prototype_uuid`. `nil` for a node ADDED on
        /// the instance (it lives in the instance graph's `nodes`) AND for every node of a
        /// standalone `*.tm_script_graph` asset (which has no instantiation split). So
        /// `instanceOf == nil` ⇒ "instance-authored / standalone" and `instanceOf != nil`
        /// ⇒ "prototype-instantiated", which is exactly the split write-back must restore
        /// (see `ScriptGraphWriteBack.patchedEntityOverride`). Defaulting to `nil` keeps
        /// all existing call sites and standalone-asset reads behaving as before.
        public var instanceOf: String?

        public init(id: String, type: String, label: String? = nil, x: Double? = nil, y: Double? = nil, variableName: String? = nil, variableRefUUID: String? = nil, instanceOf: String? = nil) {
            self.id = id
            self.type = type
            self.label = label
            self.x = x
            self.y = y
            self.variableName = variableName
            self.variableRefUUID = variableRefUUID
            self.instanceOf = instanceOf
        }
    }

    /// A declared script-graph variable: one entry of the graph-level `variables:`
    /// table. The fixture's table is **name-only** (`{ __uuid, name }`); a type and a
    /// default presumably appear once set, but are not modeled here yet. The variable
    /// node's `tm_graph_variable_ref` resolves against this table by `ref == uuid`.
    public struct Variable: Equatable, Sendable, Identifiable {
        /// The variable's `__uuid` (what a node's `tm_graph_variable_ref.ref` points at).
        public let uuid: String
        /// The author-given variable name (e.g. `"Name1"`). The compile slot derives
        /// from `MurmurHash64A(lowercase(name))`.
        public let name: String

        public var id: String { uuid }

        public init(uuid: String, name: String) {
            self.uuid = uuid
            self.name = name
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

    /// The graph's own STABLE identity — the `tm_graph`'s root `__uuid` (the `graph`
    /// member's `__uuid`), carried through parsing so a consumer can key UI state on the
    /// graph itself rather than on a coupled selection. `nil` for a synthetic graph built
    /// in memory with no assigned identity (e.g. a `make_node` scratch graph); the
    /// Examples gallery assigns a stable id via the memberwise init.
    ///
    /// Why this matters: the editor's live model is keyed on the SHOWN graph's identity,
    /// so a selection change that doesn't change the shown graph must NOT re-key (and
    /// thus must not discard unsaved live edits). This is that identity.
    public let id: String?

    public let nodes: [Node]
    public let wires: [Wire]
    public let data: [DataLiteral]
    /// The graph-level variable table (`variables:`). Empty for a graph that declares
    /// no variables — so existing graphs are unaffected.
    public let variables: [Variable]

    /// The murmur64a hash of the `name` connector that a variable node's
    /// `tm_graph_variable_ref` literal binds to (observed as `d4c943cba60c270b`).
    public static let variableNameConnectorHash: UInt64 = TMHash.murmur64a("name")

    public init(id: String? = nil, nodes: [Node], wires: [Wire], data: [DataLiteral], variables: [Variable] = []) {
        self.id = id
        self.nodes = nodes
        self.wires = wires
        self.data = data
        self.variables = variables
    }

    /// Parses a `tm_graph` object (the `graph` member of a
    /// `re_scripting_source_graph`) into a display graph.
    public init(tmGraph: TMObject) {
        self.init(tmGraph: tmGraph, prototypeNodeTypes: [:])
    }

    /// Parses a `tm_graph` object into a display graph, resolving any
    /// `nodes__instantiated` entries (prototype-node instances) against
    /// `prototypeNodeTypes` — a `[prototypeNodeUUID: type]` lookup recovered from
    /// the prototype graph.
    ///
    /// A prototype-INSTANCE graph (the `source.graph` embedded on an entity's
    /// `re_scripting_component`) splits its node list into two arrays:
    /// - `nodes` — nodes ADDED on the instance. Each carries its own `type`.
    /// - `nodes__instantiated` — instances of PROTOTYPE nodes. Each carries a
    ///   `__prototype_uuid` (pointing at a node in the prototype graph) and an
    ///   optional `position` override, but NO `type`; the type is recovered from
    ///   `prototypeNodeTypes` keyed by that prototype uuid.
    ///
    /// The full edited node list is (instance `nodes`) ∪ (resolved
    /// `nodes__instantiated`). An instantiated node whose prototype uuid can't be
    /// resolved is retained with type `"?"` rather than dropped.
    ///
    /// `connections` and `data` are read from the instance graph as-is (they fully
    /// re-state the edited graph's wires/literals — they are not deltas here).
    public init(tmGraph: TMObject, prototypeNodeTypes: [String: String]) {
        // The graph's own stable identity (the `graph` member's `__uuid`), carried so UI
        // state can key on the graph itself rather than a coupled selection.
        id = tmGraph.uuid

        var parsedNodes: [Node] = (tmGraph["nodes"]?.arrayValue ?? []).compactMap { value in
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

        // `nodes__instantiated`: prototype-node instances. The node's own identity
        // is its `__uuid`; its `type` comes from the prototype node it instances
        // (via `__prototype_uuid` → `prototypeNodeTypes`). A `position` override on
        // the instance, when present, supersedes the prototype's.
        for value in tmGraph["nodes__instantiated"]?.arrayValue ?? [] {
            guard let object = value.objectValue, let id = object.uuid else { continue }
            let position = object["position"]?.objectValue
            let type = object.prototypeUUID.flatMap { prototypeNodeTypes[$0] }
                ?? object["type"]?.stringValue
                ?? "?"
            parsedNodes.append(Node(
                id: id,
                type: type,
                label: object["label"]?.stringValue,
                x: position?["x"]?.doubleValue,
                y: position?["y"]?.doubleValue,
                // PROVENANCE: remember this is an instance of a prototype node, keyed by
                // the prototype's `__prototype_uuid`. Recorded even when the type couldn't
                // be resolved (it drives write-back's nodes/nodes__instantiated split, not
                // type recovery).
                instanceOf: object.prototypeUUID
            ))
        }

        // The graph-level variable table (`variables: [{ __uuid, name }]`). Absent on a
        // graph that declares no variables → an empty table (existing graphs unaffected).
        variables = (tmGraph["variables"]?.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue, let uuid = object.uuid, let name = object.name
            else { return nil }
            return Variable(uuid: uuid, name: name)
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

        // Collect `[nodeUUID: (name, refUUID)]` for any `tm_graph_variable_ref` literal
        // so the variable name lands on the node (NOT surfaced as a scalar/component
        // data literal). All other literals become `DataLiteral`s as before.
        var variableRefByNode: [String: (name: String, ref: String?)] = [:]
        var parsedData: [DataLiteral] = []
        for value in tmGraph["data"]?.arrayValue ?? [] {
            guard
                let object = value.objectValue,
                let toNode = object["to_node"]?.stringValue,
                let pinHex = object["to_connector_hash"]?.stringValue,
                let toPin = UInt64(pinHex, radix: 16)
            else { continue }
            let valueObject = object["data"]?.objectValue

            // A variable reference: attach its `name`/`ref` to `to_node`, don't surface
            // it as a literal (it isn't a scalar/component the inspector/compiler reads).
            if valueObject?.type == "tm_graph_variable_ref", let name = valueObject?.name {
                variableRefByNode[toNode] = (name, valueObject?["ref"]?.stringValue)
                continue
            }

            parsedData.append(DataLiteral(
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
            ))
        }
        data = parsedData

        // Fold the resolved variable references onto their nodes.
        if !variableRefByNode.isEmpty {
            for index in parsedNodes.indices {
                if let ref = variableRefByNode[parsedNodes[index].id] {
                    parsedNodes[index].variableName = ref.name
                    parsedNodes[index].variableRefUUID = ref.ref
                }
            }
        }

        nodes = parsedNodes
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
