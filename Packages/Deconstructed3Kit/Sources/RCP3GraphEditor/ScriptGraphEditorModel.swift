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
    /// Selected enum case for source-generated enum Make/Break nodes.
    public var enumSelection: RCP3ScriptGraph.Node.EnumSelection?
    /// Typed dynamic connectors, including their source settings container.
    public var dynamicConnectorSettings: RCP3ScriptGraph.Node.DynamicConnectorSettings?
    /// Inspectable-derived connector schema for generated Material nodes.
    public var materialSettings: RCP3ScriptGraph.Node.MaterialSettings?
    /// Selected value type for Get/Set Entity Parameter nodes.
    public var entityParameterSettings: RCP3ScriptGraph.Node.EntityParameterSettings?

    /// PROVENANCE for an instance-override graph (mirrors ``RCP3ScriptGraph/Node/instanceOf``):
    /// the `__prototype_uuid` of the prototype node this box INSTANCES, when it came from the
    /// entity graph's `nodes__instantiated`. `nil` for an instance-authored node, a node ADDED
    /// in the editor, and every node of a standalone asset. Carried so write-back can split the
    /// node list back into `nodes` (authored) vs `nodes__instantiated` (prototype instances).
    public var instanceOf: String?

    /// Whether the on-disk node stated explicit `position.x` / `position.y` coordinates.
    /// An instantiated node may carry an INHERITED, coordinate-less position (only a
    /// `__uuid`/`__prototype_*`); the loader then seeds `position` to a fallback lane. These
    /// flags let write-back tell that fallback apart from a real coordinate, so a no-edit
    /// round-trip preserves a coordinate-less position instead of materializing a fabricated
    /// override. `true`/`true` for an authored node (always has both) and a freshly added one.
    public var authoredX: Bool
    public var authoredY: Bool

    public init(
        id: String,
        position: CGPoint,
        payload: ScriptGraphNodePayload,
        enumSelection: RCP3ScriptGraph.Node.EnumSelection? = nil,
        dynamicConnectorSettings: RCP3ScriptGraph.Node.DynamicConnectorSettings? = nil,
        materialSettings: RCP3ScriptGraph.Node.MaterialSettings? = nil,
        entityParameterSettings: RCP3ScriptGraph.Node.EntityParameterSettings? = nil,
        instanceOf: String? = nil,
        authoredX: Bool = true,
        authoredY: Bool = true
    ) {
        self.id = id
        self.position = position
        self.payload = payload
        self.enumSelection = enumSelection
        self.dynamicConnectorSettings = dynamicConnectorSettings
        self.materialSettings = materialSettings
        self.entityParameterSettings = entityParameterSettings
        self.instanceOf = instanceOf
        self.authoredX = authoredX
        self.authoredY = authoredY
    }
}

/// Identifies a single authored pin literal: a node and one of its INPUT data pins
/// (by `connector_hash = murmur64a(pinName)`). The key into a node's editable
/// literals and the address ``ScriptGraphEditorModel/setLiteral(nodeID:pinConnectorHash:value:)``
/// writes through.
public struct LiteralKey: Hashable, Sendable {
    public let nodeID: String
    /// The bound pin's `connector_hash` (`murmur64a(connectorName)`).
    public let pinConnectorHash: UInt64

    public init(nodeID: String, pinConnectorHash: UInt64) {
        self.nodeID = nodeID
        self.pinConnectorHash = pinConnectorHash
    }
}

/// One editable, unwired numeric input pin of a node, as surfaced to the inspector:
/// the pin to author (`key`), its readable name, and its current literal value (the
/// authored value if set, else the default `0`). Renderer-agnostic — the SwiftUI
/// inspector binds a numeric field through ``ScriptGraphEditorModel/setLiteral(nodeID:pinConnectorHash:value:)``.
public struct EditableLiteral: Identifiable, Hashable, Sendable {
    /// Stable identity for `ForEach`: the pin's handle id (`in.<hex>`).
    public let id: String
    /// The bound pin (node + connector hash).
    public let key: LiteralKey
    /// The Title Case pin name (e.g. `"X"`, `"A"`, `"Initial Value"`).
    public let displayName: String
    /// The pin's current value as the canonical ``TMGraphValue`` — the authored value,
    /// else `.number(0)` for an empty numeric pin. The inspector renders the control by
    /// its kind (number field / Toggle / text field).
    public let value: TMGraphValue

    public init(id: String, key: LiteralKey, displayName: String, value: TMGraphValue) {
        self.id = id
        self.key = key
        self.displayName = displayName
        self.value = value
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
    /// Built-in plus document-provided NodeLib authoring metadata.
    @ObservationIgnored public let nodeRegistry: ScriptGraphNodeRegistry
    /// Stable identity of the source graph, retained for live snapshots compiled or
    /// inspected before the graph is saved back to disk.
    public let sourceGraphID: String?
    public private(set) var nodes: [GraphNodeBox]
    public private(set) var connections: [GraphConnection]

    /// Authored pin literals, keyed by the bound pin — the ONE store for every value
    /// kind (number / bool / string / …), the editor's writable mirror of the graph's
    /// `data[]` constants. Seeded from the source graph at `init`, updated by
    /// ``setLiteral(nodeID:pinConnectorHash:value:)`` (number) and
    /// ``setValue(nodeID:pinConnectorHash:value:)`` (any), and folded back into `data[]`
    /// by ``ScriptGraphWriteBack``. The canonical compiler reads these so an edited
    /// value is reflected in Play.
    public private(set) var literals: [LiteralKey: TMGraphValue]

    /// Typed literals the editor does not expose as editable scalar/bool/string
    /// values yet, but which are structurally required by RCP3. The important current
    /// case is `re_scripting_graph_component_type` bound to a Set/Get Component
    /// node's `component_type` pin. Existing assets preserve these through write-back;
    /// fresh materialized graphs need the model to carry them so they can be emitted
    /// into an otherwise-empty `data[]` array.
    public private(set) var unmodeledLiterals: [RCP3ScriptGraph.DataLiteral]

    /// The numeric subset of `literals`, for the scalar write-back/compiler paths still
    /// keyed on `Double`. A read-only bridge over the unified store.
    public var scalarLiterals: [LiteralKey: Double] {
        literals.compactMapValues(\.number)
    }

    /// The graph-level variable table (`variables:`), keyed for round-trip by `uuid`.
    /// Seeded from the source graph; grown by ``setVariableName(nodeID:name:)`` when a
    /// node names a variable not yet declared. Empty when the graph declares none, so
    /// write-back emits no `variables:` for graphs that never had any.
    public private(set) var variables: [RCP3ScriptGraph.Variable]

    /// Per-node variable reference, keyed by the variable node's `__uuid`: the name of
    /// the script-graph variable a `tm_get/set/clear_variable_node` references. The
    /// editor's writable mirror of the on-disk `tm_graph_variable_ref` data literal.
    /// Seeded from the source graph's nodes; updated by ``setVariableName(nodeID:name:)``;
    /// folded back into `data[]` + `variables:` by ``ScriptGraphWriteBack``.
    public private(set) var variableNames: [String: String]

    /// The selected node, if any.
    public var selectedNodeID: String?
    /// The selected connection, if any.
    public var selectedConnectionID: String?

    /// The port a connection is currently being dragged FROM, if a connection
    /// gesture is in progress. The renderer tracks the moving endpoint (cursor /
    /// hand) itself and calls `completeConnection(to:)` on drop.
    public private(set) var draftSource: GraphPortRef?

    /// Whether this model carries UNSAVED live edits — set `true` by every mutating verb
    /// (add/move/connect/disconnect/delete/setLiteral/setVariableName) and cleared by
    /// ``markSaved()`` once write-back has persisted them.
    ///
    /// The host (`DocumentView`) reads this to AVOID silently rebuilding a dirty model
    /// from the pristine source graph when the canvas re-keys for the SAME graph — which
    /// is exactly how live edits used to get discarded (the "+ mutated my graph" bug).
    /// A genuinely different graph identity still rebuilds; only a same-graph re-key is
    /// guarded.
    public private(set) var isDirty = false

    /// Builds the editor state from a parsed script graph. Node interfaces (the full
    /// named pin set + exposed values) come from the shared pin derivation; node
    /// positions come from the file (`x`/`y`), falling back to a left-to-right lane.
    public init(
        graph: RCP3ScriptGraph,
        nodeRegistry: ScriptGraphNodeRegistry = .builtins
    ) {
        self.nodeRegistry = nodeRegistry
        self.sourceGraphID = graph.id
        var boxes: [GraphNodeBox] = []
        for (index, node) in graph.nodes.enumerated() {
            let payload = ScriptGraphPinResolver.payload(
                for: node,
                in: graph,
                registry: nodeRegistry
            )
            let position = CGPoint(
                x: node.x ?? Double(index) * Self.fallbackLaneSpacing,
                y: node.y ?? 0
            )
            // Carry the node's instance-override provenance through so write-back can
            // restore the nodes/nodes__instantiated split (nil for authored/standalone),
            // plus whether each coordinate was authored on disk (a coordinate-less,
            // inherited instantiated position seeds a fallback lane that write-back must
            // NOT mistake for a real override).
            boxes.append(GraphNodeBox(
                id: node.id,
                position: position,
                payload: payload,
                enumSelection: node.enumSelection,
                dynamicConnectorSettings: node.dynamicConnectorSettings,
                materialSettings: node.materialSettings,
                entityParameterSettings: node.entityParameterSettings,
                instanceOf: node.instanceOf,
                authoredX: node.x != nil,
                authoredY: node.y != nil
            ))
        }
        nodes = boxes

        let ids = Set(boxes.map(\.id))
        let pinIDsByNode = Dictionary(uniqueKeysWithValues: boxes.map { box in
            (box.id, Set(box.payload.pins.map(\.id)))
        })
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
            } else {
                // A wire with at least one connector hash. It is an exec wire when both
                // ends resolve to exec handles the payloads declare — a missing hash is
                // the UNNAMED exec pin (its connector name is the empty string, hash 0,
                // which the serializer omits as the member's default). Delay.once →
                // Set Transform is the canonical shape: named from, unnamed to.
                let execFromID = ScriptGraphPinResolver.execOutputHandleID(forHash: wire.fromPin)
                let execToID = ScriptGraphPinResolver.execInputHandleID(forHash: wire.toPin)
                if pinIDsByNode[wire.from]?.contains(execFromID) == true,
                   pinIDsByNode[wire.to]?.contains(execToID) == true {
                    conns.append(GraphConnection(
                        id: wire.id,
                        from: GraphPortRef(nodeID: wire.from, pinID: execFromID),
                        to: GraphPortRef(nodeID: wire.to, pinID: execToID),
                        isExec: true,
                        label: RCP3ScriptGraph.label(forHash: wire.fromPin ?? wire.toPin)
                    ))
                    continue
                }
                guard let fromPin = wire.fromPin, let toPin = wire.toPin else { continue }
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

        // Seed the writable literals from the source graph's `data[]`: any modeled
        // value (number / bool / string) on a pin becomes an authored value the
        // inspector can edit and write-back can persist.
        var seeded: [LiteralKey: TMGraphValue] = [:]
        var unmodeled: [RCP3ScriptGraph.DataLiteral] = []
        for literal in graph.data {
            if let value = literal.value {
                seeded[LiteralKey(nodeID: literal.toNode, pinConnectorHash: literal.toPin)] = value
            } else {
                unmodeled.append(literal)
            }
        }
        literals = seeded
        unmodeledLiterals = unmodeled

        // Seed the variable table and the per-node variable references from the graph.
        variables = graph.variables
        var names: [String: String] = [:]
        for node in graph.nodes {
            if let name = node.variableName { names[node.id] = name }
        }
        variableNames = names
    }

    static let fallbackLaneSpacing: Double = 320

    // MARK: Dirty tracking

    /// Marks the model as carrying unsaved live edits. Called by every mutating verb.
    private func markDirty() { isDirty = true }

    /// Clears the dirty flag — call after write-back has persisted the live edits, so the
    /// host may once again rebuild the model from the (now up-to-date) source on a re-key.
    public func markSaved() { isDirty = false }

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
    /// (``ScriptGraphPinResolver/payload(for:in:)``): for a lone node with no wires
    /// that yields exactly the type's declared pins, so the inserted node is
    /// immediately connectable/movable/deletable like any authored one. A fresh UUID
    /// id avoids collisions with the loaded graph. Returns the new node's id.
    @discardableResult
    public func addNode(type: String, label: String? = nil, at position: CGPoint) -> String {
        let newID = UUID().uuidString
        var firstUUID = true
        let makeUUID = {
            if firstUUID {
                firstUUID = false
                return newID
            }
            return UUID().uuidString
        }

        // Use the same recipe interpreter as the complete generated corpus. This is
        // the single insertion contract for canvas, agent, and generated fixtures:
        // component selectors, typed variables, material/dynamic/entity settings,
        // replacement nodes, and required literals cannot drift by authoring surface.
        let authored = ScriptGraphAuthoringRecipes.makeFragment(
            requestedType: type,
            label: label ?? type,
            makeUUID: makeUUID
        )
        var seed = authored?.node
        let mergedVariables = mergeAuthoredVariables(authored?.variables ?? [])
        if authored?.variables.first != nil, let resolved = mergedVariables.first {
            seed?.variableName = resolved.name
            seed?.variableRefUUID = resolved.uuid
        }
        let authoredType = seed?.type ?? type
        let enumSelection = seed?.enumSelection
            ?? ScriptGraphNodeLibrary.defaultEnumSelection(for: authoredType)
        let dynamicConnectorSettings = seed?.dynamicConnectorSettings
            ?? ScriptGraphNodeLibrary.defaultDynamicConnectorSettings(for: authoredType)
        let materialSettings = seed?.materialSettings
        let entityParameterSettings = seed?.entityParameterSettings
            ?? ScriptGraphNodeLibrary.defaultEntityParameterSettings(for: authoredType)
        let node = RCP3ScriptGraph.Node(
            id: newID,
            type: authoredType,
            label: label,
            x: Double(position.x),
            y: Double(position.y),
            variableName: seed?.variableName,
            variableRefUUID: seed?.variableRefUUID,
            enumSelection: enumSelection,
            dynamicConnectorSettings: dynamicConnectorSettings,
            materialSettings: materialSettings,
            entityParameterSettings: entityParameterSettings
        )
        let nodeData = authored?.data.filter { $0.toNode == newID } ?? []
        for literal in nodeData {
            if let value = literal.value {
                literals[LiteralKey(nodeID: newID, pinConnectorHash: literal.toPin)] = value
            } else {
                unmodeledLiterals.append(literal)
            }
        }
        if let variableName = node.variableName {
            variableNames[newID] = variableName
        }
        let payload = ScriptGraphPinResolver.payload(
            for: node,
            in: RCP3ScriptGraph(
                nodes: [node],
                wires: [],
                data: nodeData,
                variables: variables
            ),
            registry: nodeRegistry
        )
        nodes.append(GraphNodeBox(
            id: newID, position: position, payload: payload, enumSelection: enumSelection,
            dynamicConnectorSettings: dynamicConnectorSettings,
            materialSettings: materialSettings,
            entityParameterSettings: entityParameterSettings
        ))
        selectNode(newID)
        markDirty()
        return newID
    }

    /// Merges recipe-created variables without binding a typed node to an existing
    /// declaration of an incompatible concrete type.
    private func mergeAuthoredVariables(
        _ authoredVariables: [RCP3ScriptGraph.Variable]
    ) -> [RCP3ScriptGraph.Variable] {
        authoredVariables.map { authored in
            if let index = variables.firstIndex(where: {
                $0.name.caseInsensitiveCompare(authored.name) == .orderedSame
            }) {
                let existing = variables[index]
                if existing.typeHash == authored.typeHash,
                   existing.editHash == authored.editHash,
                   existing.dataType == authored.dataType {
                    return existing
                }
                if existing.typeHash == nil, existing.editHash == nil, existing.dataType == nil {
                    let upgraded = RCP3ScriptGraph.Variable(
                        uuid: existing.uuid,
                        name: existing.name,
                        typeHash: authored.typeHash,
                        editHash: authored.editHash,
                        dataType: authored.dataType
                    )
                    variables[index] = upgraded
                    return upgraded
                }

                var suffix = 2
                var uniqueName = "\(authored.name) \(suffix)"
                while variables.contains(where: {
                    $0.name.caseInsensitiveCompare(uniqueName) == .orderedSame
                }) {
                    suffix += 1
                    uniqueName = "\(authored.name) \(suffix)"
                }
                let renamed = RCP3ScriptGraph.Variable(
                    uuid: authored.uuid,
                    name: uniqueName,
                    typeHash: authored.typeHash,
                    editHash: authored.editHash,
                    dataType: authored.dataType
                )
                variables.append(renamed)
                return renamed
            }
            variables.append(authored)
            return authored
        }
    }

    // MARK: Node label (rename)

    /// The node's current author label, or `""` when it has none (the canvas then
    /// shows a humanized type). The read side of the inspector's Name field.
    public func nodeLabel(nodeID: String) -> String {
        node(nodeID)?.payload.label ?? ""
    }

    /// Renames node `nodeID`. A blank name clears the label (the node falls back to its
    /// humanized type). Mirrors to `payload.label`, which the canvas title reads and
    /// write-back persists to the on-disk `label`. No-op (no dirtying) when unchanged.
    public func setNodeLabel(nodeID: String, label: String) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLabel = trimmed.isEmpty ? nil : trimmed
        guard nodes[index].payload.label != newLabel else { return }
        nodes[index].payload.label = newLabel
        markDirty()
    }

    /// Changes an enum Make/Break node's selected case and rebuilds its dynamic
    /// associated-value pins. Connections to pins absent from the new case are
    /// removed, matching the editor invariant that every endpoint resolves.
    public func setEnumCase(nodeID: String, caseName: String) {
        guard
            let index = nodes.firstIndex(where: { $0.id == nodeID }),
            let selection = ScriptGraphNodeLibrary.enumSelection(
                for: nodes[index].payload.type, caseName: caseName
            ),
            nodes[index].enumSelection != selection
        else { return }

        let old = nodes[index]
        let node = RCP3ScriptGraph.Node(
            id: old.id,
            type: old.payload.type,
            label: old.payload.label,
            enumSelection: selection
        )
        nodes[index].enumSelection = selection
        nodes[index].payload = ScriptGraphPinResolver.payload(
            for: node,
            in: RCP3ScriptGraph(nodes: [node], wires: [], data: []),
            registry: nodeRegistry
        )
        let validPins = Set(nodes[index].payload.pins.map(\.id))
        connections.removeAll {
            ($0.from.nodeID == nodeID && !validPins.contains($0.from.pinID))
                || ($0.to.nodeID == nodeID && !validPins.contains($0.to.pinID))
        }
        markDirty()
    }

    /// Selects the RealityKit component schema used by a component-family node.
    /// The selection is the same typed `component_type` literal RCP3 authors and
    /// immediately rebuilds the node's schema-derived property pins.
    @discardableResult
    public func setComponentType(nodeID: String, componentName: String) -> Bool {
        guard
            let index = nodes.firstIndex(where: { $0.id == nodeID }),
            nodes[index].payload.inputPins.contains(where: {
                $0.id == "in." + TMHash.hex(TMHash.murmur64a("component_type"))
            }),
            let component = ScriptGraphNodeLibrary.registeredComponents.first(where: {
                $0.name.caseInsensitiveCompare(componentName) == .orderedSame
            })
        else { return false }

        let pin = TMHash.murmur64a("component_type")
        unmodeledLiterals.removeAll { $0.toNode == nodeID && $0.toPin == pin }
        unmodeledLiterals.append(.init(
            id: UUID().uuidString,
            toNode: nodeID,
            toPin: pin,
            valueType: "re_scripting_graph_component_type",
            valueHash: component.typeHash
        ))
        literals.removeValue(forKey: .init(nodeID: nodeID, pinConnectorHash: pin))
        rebuildPayload(at: index)
        markDirty()
        return true
    }

    public func supportsComponentType(nodeID: String) -> Bool {
        node(nodeID)?.payload.inputPins.contains {
            $0.id == "in." + TMHash.hex(TMHash.murmur64a("component_type"))
        } == true
    }

    public func componentTypeName(nodeID: String) -> String? {
        let pin = TMHash.murmur64a("component_type")
        return unmodeledLiterals.first {
            $0.toNode == nodeID && $0.toPin == pin
        }?.valueHash.flatMap(ScriptGraphNodeLibrary.componentTypeName(forHash:))
    }

    /// Changes one graph-authored dynamic connector's runtime/editor type pair.
    /// Connector identity, order, display name, optionality, and container shape are
    /// preserved; only the selected type changes.
    @discardableResult
    public func setDynamicConnectorType(
        nodeID: String,
        connectorName: String,
        isInput: Bool,
        typeName: String
    ) -> Bool {
        guard
            let index = nodes.firstIndex(where: { $0.id == nodeID }),
            let settings = nodes[index].dynamicConnectorSettings,
            let identity = ScriptGraphTypeRegistry.identity(named: typeName)
        else { return false }

        var changed = false
        func replacing(
            _ connectors: [RCP3ScriptGraph.Node.DynamicConnector]
        ) -> [RCP3ScriptGraph.Node.DynamicConnector] {
            connectors.map { connector in
                guard connector.name.caseInsensitiveCompare(connectorName) == .orderedSame else {
                    return connector
                }
                changed = true
                return identity.connector(
                    name: connector.name,
                    displayName: connector.displayName,
                    order: connector.order,
                    optionality: connector.optionality
                )
            }
        }
        let inputs = isInput ? replacing(settings.inputs) : settings.inputs
        let outputs = isInput ? settings.outputs : replacing(settings.outputs)
        guard changed else { return false }
        nodes[index].dynamicConnectorSettings = .init(
            container: settings.container,
            inputs: inputs,
            outputs: outputs
        )
        rebuildPayload(at: index)
        markDirty()
        return true
    }

    @discardableResult
    public func addDynamicConnector(
        nodeID: String,
        name: String,
        isInput: Bool,
        typeName: String
    ) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let index = nodes.firstIndex(where: { $0.id == nodeID }),
            let settings = nodes[index].dynamicConnectorSettings,
            let policy = ScriptGraphNodeLibrary.dynamicPinPolicy(for: nodes[index].payload.type),
            let identity = ScriptGraphTypeRegistry.identity(named: typeName)
        else { return false }
        let side = isInput ? settings.inputs : settings.outputs
        guard !side.contains(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return false }
        if isInput {
            let fixed = policy.fixedInputs.filter { !$0.isExec }.count
            guard policy.maximumInputCount.map({ fixed + side.count + 1 <= $0 }) ?? true else {
                return false
            }
        }
        let order = (side.map(\.order).max() ?? -1) + 1
        let connector = identity.connector(name: trimmed, order: order)
        nodes[index].dynamicConnectorSettings = .init(
            container: settings.container,
            inputs: isInput ? settings.inputs + [connector] : settings.inputs,
            outputs: isInput ? settings.outputs : settings.outputs + [connector]
        )
        rebuildPayload(at: index)
        markDirty()
        return true
    }

    @discardableResult
    public func removeDynamicConnector(
        nodeID: String,
        name: String,
        isInput: Bool
    ) -> Bool {
        guard
            let index = nodes.firstIndex(where: { $0.id == nodeID }),
            let settings = nodes[index].dynamicConnectorSettings,
            let policy = ScriptGraphNodeLibrary.dynamicPinPolicy(for: nodes[index].payload.type)
        else { return false }
        let side = isInput ? settings.inputs : settings.outputs
        guard side.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        let remaining = side.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        if isInput {
            let fixed = policy.fixedInputs.filter { !$0.isExec }.count
            guard fixed + remaining.count >= policy.minimumInputCount else { return false }
        }
        nodes[index].dynamicConnectorSettings = .init(
            container: settings.container,
            inputs: isInput ? remaining : settings.inputs,
            outputs: isInput ? settings.outputs : remaining
        )
        if isInput {
            let hash = TMHash.murmur64a(name)
            literals.removeValue(forKey: .init(nodeID: nodeID, pinConnectorHash: hash))
            unmodeledLiterals.removeAll { $0.toNode == nodeID && $0.toPin == hash }
        }
        rebuildPayload(at: index)
        markDirty()
        return true
    }

    @discardableResult
    public func renameDynamicConnector(
        nodeID: String,
        name: String,
        isInput: Bool,
        newName: String
    ) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let index = nodes.firstIndex(where: { $0.id == nodeID }),
            let settings = nodes[index].dynamicConnectorSettings
        else { return false }
        let side = isInput ? settings.inputs : settings.outputs
        guard !side.contains(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                && $0.name.caseInsensitiveCompare(name) != .orderedSame
        }) else { return false }
        var changed = false
        let renamed = side.map { connector in
            guard connector.name.caseInsensitiveCompare(name) == .orderedSame else { return connector }
            changed = true
            return RCP3ScriptGraph.Node.DynamicConnector(
                name: trimmed,
                displayName: trimmed,
                typeHash: connector.typeHash,
                editHash: connector.editHash,
                order: connector.order,
                optionality: connector.optionality
            )
        }
        guard changed else { return false }
        nodes[index].dynamicConnectorSettings = .init(
            container: settings.container,
            inputs: isInput ? renamed : settings.inputs,
            outputs: isInput ? settings.outputs : renamed
        )
        if isInput {
            let oldHash = TMHash.murmur64a(name)
            let newHash = TMHash.murmur64a(trimmed)
            let oldKey = LiteralKey(nodeID: nodeID, pinConnectorHash: oldHash)
            if let value = literals.removeValue(forKey: oldKey) {
                literals[.init(nodeID: nodeID, pinConnectorHash: newHash)] = value
            }
            unmodeledLiterals = unmodeledLiterals.map { literal in
                guard literal.toNode == nodeID && literal.toPin == oldHash else { return literal }
                return RCP3ScriptGraph.DataLiteral(
                    id: literal.id,
                    toNode: literal.toNode,
                    toPin: newHash,
                    valueType: literal.valueType,
                    valueHash: literal.valueHash,
                    value: literal.value
                )
            }
        }
        rebuildPayload(at: index)
        markDirty()
        return true
    }

    /// Selects the value type for Get/Set Entity Parameter. RCP3 persists the
    /// editor identity for this dedicated settings record.
    @discardableResult
    public func setEntityParameterType(nodeID: String, typeName: String) -> Bool {
        guard
            let index = nodes.firstIndex(where: { $0.id == nodeID }),
            ["tm_get_entity_parameter", "tm_set_entity_parameter"].contains(nodes[index].payload.type),
            let identity = ScriptGraphTypeRegistry.identity(named: typeName),
            identity.editHash != 0
        else { return false }
        let settings = RCP3ScriptGraph.Node.EntityParameterSettings(typeHash: identity.editHash)
        guard nodes[index].entityParameterSettings != settings else { return true }
        nodes[index].entityParameterSettings = settings
        rebuildPayload(at: index)
        markDirty()
        return true
    }

    /// Re-resolves one live node after a schema-setting mutation and removes wires
    /// whose endpoints no longer exist in the selected schema.
    private func rebuildPayload(at index: Int) {
        let box = nodes[index]
        let variableName = variableNames[box.id]
        let variable = variableName.flatMap { name in
            variables.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        let node = RCP3ScriptGraph.Node(
            id: box.id,
            type: box.payload.type,
            label: box.payload.label,
            x: Double(box.position.x),
            y: Double(box.position.y),
            variableName: variableName,
            variableRefUUID: variable?.uuid,
            instanceOf: box.instanceOf,
            enumSelection: box.enumSelection,
            dynamicConnectorSettings: box.dynamicConnectorSettings,
            materialSettings: box.materialSettings,
            entityParameterSettings: box.entityParameterSettings
        )
        let nodeData = unmodeledLiterals.filter { $0.toNode == box.id } + literals.compactMap { key, value in
            guard key.nodeID == box.id else { return nil }
            return RCP3ScriptGraph.DataLiteral(
                id: "live.\(box.id).\(TMHash.hex(key.pinConnectorHash))",
                toNode: box.id,
                toPin: key.pinConnectorHash,
                value: value
            )
        }
        nodes[index].payload = ScriptGraphPinResolver.payload(
            for: node,
            in: RCP3ScriptGraph(nodes: [node], wires: [], data: nodeData, variables: variables),
            registry: nodeRegistry
        )
        let validPins = Set(nodes[index].payload.pins.map(\.id))
        connections.removeAll {
            ($0.from.nodeID == box.id && !validPins.contains($0.from.pinID))
                || ($0.to.nodeID == box.id && !validPins.contains($0.to.pinID))
        }
    }

    // MARK: Scalar pin literals (author an unwired numeric input)

    /// The editable, unwired numeric INPUT pins of node `id`, in declared order — the
    /// rows the node inspector shows. A pin qualifies when it is a *numeric* data
    /// input the node type declares (per ``ScriptGraphNodeLibrary``) and **no wire**
    /// feeds it. Scope (v1): the components of `make_vector*`/`make_cgsize`/… and the
    /// math operands the compiler reads as scalars (`a`, `b`, `x`, `y`, `z`, `w`, …).
    /// Each row's `value` is the authored literal if set, else the default `0`.
    ///
    /// Returns `[]` for an unknown node id or a node with no editable numeric pins.
    public func editableLiterals(forNode id: String) -> [EditableLiteral] {
        guard let box = node(id) else { return [] }
        var rows: [EditableLiteral] = []
        var seen = Set<LiteralKey>()

        // 1. Numeric scalar pins the node declares — authorable from scratch (default 0).
        for pin in box.payload.inputPins {
            guard !pin.isExec,
                  let hash = Self.connectorHash(forInputPinID: pin.id),
                  Self.isScalarConnector(hash) else { continue }
            // An input already fed by a wire is not literal-editable (the wire wins).
            let ref = GraphPortRef(nodeID: id, pinID: pin.id)
            guard connections(touching: ref).allSatisfy({ $0.to != ref }) else { continue }
            let key = LiteralKey(nodeID: id, pinConnectorHash: hash)
            seen.insert(key)
            rows.append(EditableLiteral(
                id: pin.id,
                key: key,
                displayName: pin.label,
                value: literals[key] ?? .number(0)
            ))
        }

        // 2. Any other authored value already on this node (e.g. a bool/string
        // *Initial Value* whose pin the library doesn't declare as a scalar). Surfaced
        // so it's editable with the right control; named from its connector hash.
        for (key, value) in literals where key.nodeID == id && !seen.contains(key) {
            seen.insert(key)
            rows.append(EditableLiteral(
                id: "lit.\(TMHash.hex(key.pinConnectorHash))",
                key: key,
                displayName: RCP3ScriptGraph.label(forHash: key.pinConnectorHash),
                value: value
            ))
        }
        return rows
    }

    /// The authored value on a pin as the canonical ``TMGraphValue``, or `nil` when
    /// none is set.
    public func value(nodeID: String, pinConnectorHash: UInt64) -> TMGraphValue? {
        literals[LiteralKey(nodeID: nodeID, pinConnectorHash: pinConnectorHash)]
    }

    /// Sets (or clears) the value bound to a node's input data pin — any kind. The pin
    /// is addressed by its `connector_hash` (`murmur64a(connectorName)`). `nil` removes
    /// the authored value. Marks the model changed; write-back folds it into `data[]`.
    public func setValue(nodeID: String, pinConnectorHash: UInt64, value: TMGraphValue?) {
        let key = LiteralKey(nodeID: nodeID, pinConnectorHash: pinConnectorHash)
        if let value {
            literals[key] = value
        } else {
            literals.removeValue(forKey: key)
        }
        markDirty()
    }

    /// The authored scalar literal on a pin, or `nil` when none is set (numeric bridge).
    public func literal(nodeID: String, pinConnectorHash: UInt64) -> Double? {
        value(nodeID: nodeID, pinConnectorHash: pinConnectorHash)?.number
    }

    /// Sets (or clears) a NUMERIC literal on a pin — the scalar bridge over `setValue`.
    public func setLiteral(nodeID: String, pinConnectorHash: UInt64, value: Double?) {
        setValue(nodeID: nodeID, pinConnectorHash: pinConnectorHash, value: value.map(TMGraphValue.number))
    }

    /// The `connector_hash` carried by a data INPUT pin id (`in.<hex>`), or `nil` for
    /// an exec pin / an unparsable id.
    static func connectorHash(forInputPinID pinID: String) -> UInt64? {
        guard pinID.hasPrefix("in.") else { return nil }
        return UInt64(pinID.dropFirst(3), radix: 16)
    }

    /// The connector hashes of the input-pin names the editor treats as plain scalars
    /// (the values the canonical compiler reads as numbers): vector/size/color/matrix
    /// components and math operands. A pin whose hash is in this set gets a numeric
    /// literal field; everything else (Entity, Component, Vector inputs) does not.
    static let scalarConnectorHashes: Set<UInt64> = {
        // The faithful connector names of numeric component/operand pins across the
        // node library (make_vector*, make_color/cgcolor, make_cgsize, make_edge_insets,
        // and the math operands the compiler reads via `inputExpression`).
        let names = [
            "x", "y", "z", "w",                  // make_vector2/3/4
            "a", "b", "exponent",                // math operands (binary + pow)
            "min", "max", "val",                 // clamp / within_range / random
            "number",                            // multiply_by_scalar
            "degrees", "rad", "angle",           // rotation scalars
            "red", "green", "blue", "alpha",     // colors
            "width", "height",                   // cgsize
            "top", "left", "bottom", "right",    // edge insets
            "length", "index",                   // string slicing offsets
        ]
        return Set(names.map(TMHash.murmur64a))
    }()

    static func isScalarConnector(_ hash: UInt64) -> Bool {
        scalarConnectorHashes.contains(hash)
    }

    // MARK: Variable nodes (name a graph variable)

    /// The node types that reference a script-graph variable by name (Get/Set/Clear,
    /// local + remote). For these the inspector offers a Variable name field.
    public static let variableNodeTypes: Set<String> = [
        "tm_get_variable_node", "tm_set_variable_node", "tm_clear_variable_node",
        "tm_get_remote_variable_node", "tm_set_remote_variable_node", "tm_clear_remote_variable_node",
        "tm_variable_add", "tm_variable_subtract", "tm_variable_multiply", "tm_variable_divide",
        "tm_variable_multiply_by_scalar", "tm_variable_multiply_by_quaternion",
        "tm_variable_multiply_by_matrix",
    ]

    /// Whether node `id` references a script-graph variable (so the inspector shows the
    /// Variable row). `false` for an unknown id or a non-variable node.
    public func isVariableNode(_ id: String) -> Bool {
        guard let box = node(id) else { return false }
        return Self.variableNodeTypes.contains(box.payload.type)
    }

    /// The name of the variable node `id` references, or `nil` when none is set.
    public func variableName(nodeID: String) -> String? { variableNames[nodeID] }

    /// The declared variable names, in table order — the picker's choices.
    public var variableNamesInOrder: [String] { variables.map(\.name) }

    /// Sets (or clears) the variable a node references by name. A non-empty name that
    /// isn't already declared is appended to the variable table with a fresh `__uuid`
    /// (matching it case-insensitively to an existing entry first, since the compile
    /// slot is name-case-insensitive). Passing `nil` or an empty name clears the
    /// node's reference. Mutating the model marks it changed; write-back then folds
    /// the reference into `data[]` and the `variables:` table.
    public func setVariableName(nodeID: String, name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            variableNames.removeValue(forKey: nodeID)
            markDirty()
            return
        }
        variableNames[nodeID] = trimmed
        markDirty()
        // Declare the variable in the table if it isn't there yet (case-insensitive,
        // since the compile slot lowercases the name).
        let exists = variables.contains { $0.name.lowercased() == trimmed.lowercased() }
        if !exists {
            variables.append(RCP3ScriptGraph.Variable(uuid: UUID().uuidString, name: trimmed))
        }
    }

    // MARK: Node movement (position is renderer-space-agnostic data)

    public func moveNode(_ id: String, to position: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].position = position
        // A move gives the node an explicit position: an instantiated node whose on-disk
        // position was INHERITED (coordinate-less) now carries a genuine override, so
        // write-back must emit the coordinates rather than preserve the inherited shape.
        nodes[index].authoredX = true
        nodes[index].authoredY = true
        markDirty()
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
        markDirty()
        return id
    }

    public func removeConnection(_ id: String) {
        let before = connections.count
        connections.removeAll { $0.id == id }
        if selectedConnectionID == id { selectedConnectionID = nil }
        if connections.count != before { markDirty() }
    }

    /// Removes one node by identity, including its connections, literals, and
    /// variable reference. This is the programmatic counterpart to selecting a node
    /// and invoking ``deleteSelection()``; agent and import workflows should not need
    /// to perturb UI selection in order to perform the same edit.
    public func removeNode(_ id: String) {
        guard nodes.contains(where: { $0.id == id }) else { return }
        connections.removeAll { $0.from.nodeID == id || $0.to.nodeID == id }
        nodes.removeAll { $0.id == id }
        literals = literals.filter { $0.key.nodeID != id }
        unmodeledLiterals.removeAll { $0.toNode == id }
        variableNames.removeValue(forKey: id)
        if selectedNodeID == id { selectedNodeID = nil }
        markDirty()
    }

    /// Inserts a fully-formed connection directly, bypassing the port-pairing rules
    /// that `connect(_:_:)`/`completeConnection(to:)` enforce on interactive drags.
    ///
    /// This is the construction primitive for code that already knows the exact
    /// endpoints and kind — a programmatic graph builder, an import/paste, or a
    /// future undo of a delete — where the wire's validity is established elsewhere.
    /// As with `connect`, the target input keeps a single incoming wire of its kind,
    /// so an existing connection feeding `connection.to` is replaced.
    public func insert(connection: GraphConnection) {
        connections.removeAll { $0.to == connection.to }
        connections.append(connection)
        markDirty()
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
            removeConnection(id) // marks dirty when a wire is actually removed
        } else if let id = selectedNodeID {
            removeNode(id)
        }
    }

    // MARK: Live graph snapshot

    /// Reconstructs the exact currently edited graph as a public
    /// ``RCP3ScriptGraph`` value without touching disk.
    ///
    /// This is the shared boundary for preview compilation, validation, agents, and
    /// future web bridges. It includes unsaved node positions, settings, connections,
    /// literals, variables, and instance provenance; unmodeled typed literals are
    /// retained verbatim so a snapshot never narrows the graph to only scalar values.
    public func graphSnapshot() -> RCP3ScriptGraph {
        let variableByName = Dictionary(
            variables.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let snapshotNodes = nodes.map { box in
            let variableName = variableNames[box.id]
            return RCP3ScriptGraph.Node(
                id: box.id,
                type: box.payload.type,
                label: box.payload.label,
                x: Double(box.position.x),
                y: Double(box.position.y),
                variableName: variableName,
                variableRefUUID: variableName.flatMap {
                    variableByName[$0.lowercased()]?.uuid
                },
                instanceOf: box.instanceOf,
                enumSelection: box.enumSelection,
                dynamicConnectorSettings: box.dynamicConnectorSettings,
                materialSettings: box.materialSettings,
                entityParameterSettings: box.entityParameterSettings
            )
        }
        let snapshotWires = connections.map { connection in
            RCP3ScriptGraph.Wire(
                id: connection.id,
                from: connection.from.nodeID,
                to: connection.to.nodeID,
                fromPin: Self.connectorHash(from: connection.from.pinID),
                toPin: Self.connectorHash(from: connection.to.pinID)
            )
        }
        let modeledData = literals.map { key, value in
            RCP3ScriptGraph.DataLiteral(
                id: "snapshot.\(key.nodeID).\(TMHash.hex(key.pinConnectorHash))",
                toNode: key.nodeID,
                toPin: key.pinConnectorHash,
                value: value
            )
        }
        let modeledKeys = Set(literals.keys)
        let preservedData = unmodeledLiterals.filter {
            !modeledKeys.contains(LiteralKey(nodeID: $0.toNode, pinConnectorHash: $0.toPin))
        }
        return RCP3ScriptGraph(
            id: sourceGraphID,
            nodes: snapshotNodes,
            wires: snapshotWires,
            data: preservedData + modeledData,
            variables: variables
        )
    }

    private static func connectorHash(from pinID: String) -> UInt64? {
        for prefix in ["in.", "out.", "exec.in.", "exec.out."] where pinID.hasPrefix(prefix) {
            return UInt64(pinID.dropFirst(prefix.count), radix: 16)
        }
        return nil
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
        guard outputPin.isExec
            || !outputPin.typeConstraint.isKnownIncompatible(with: inputPin.typeConstraint)
        else { return nil }
        return (output, input, outputPin.isExec)
    }
}
