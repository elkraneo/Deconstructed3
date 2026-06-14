import Foundation
import TMFormat

/// A clean-room, *observed* declaration of script-graph node interfaces.
///
/// An RCP 3 node always presents its **full** named pin set — every input and
/// output the node type defines, named and ordered, whether or not a given pin is
/// wired. The on-disk graph, by contrast, only records the pins that are actually
/// connected (as `connector_hash`es on wires/literals). To reach parity the editor
/// needs to know each node type's whole interface up front; that is what this
/// library provides.
///
/// Every entry here was transcribed from RCP 3's editor UI (the pin names and
/// values it draws on the canvas), then re-derived into the camelCase connector
/// name whose `murmur64a` hash matches the on-disk `connector_hash`. So a spec's
/// `PinSpec.connectorName` hashes to the same value the bridge computes for a
/// wired pin, which is what lets unwired pins and wired pins share one handle id.
///
/// The library is intentionally partial: only node types we have observed are
/// listed, and ``spec(for:)`` returns `nil` for everything else so the bridge can
/// fall back to its wire-derived pins (unknown node types still render).
public enum ScriptGraphNodeLibrary {

    /// One named pin in a node's declared interface.
    public struct PinSpec: Sendable, Hashable {
        /// The camelCase connector name whose `murmur64a` hash is the on-disk
        /// `connector_hash` (e.g. `"sceneTranslation"`). For an exec pin this is the
        /// sentinel `"exec"`; the bridge maps it to the fixed `exec.in`/`exec.out`
        /// handle ids rather than to a hash.
        public let connectorName: String
        /// The Title Case name RCP 3 shows for this pin (e.g. `"Scene Translation"`).
        public let displayName: String
        /// `true` for a control-flow (exec) pin, `false` for a data pin.
        public let isExec: Bool

        public init(connectorName: String, displayName: String, isExec: Bool) {
            self.connectorName = connectorName
            self.displayName = displayName
            self.isExec = isExec
        }

        /// The `murmur64a` hash of `connectorName` — the data pin's `connector_hash`.
        /// (Meaningless for exec pins, which use fixed handle ids.)
        public var connectorHash: UInt64 { TMHash.murmur64a(connectorName) }

        /// Convenience for a data pin (`isExec: false`). Used by the per-category
        /// component definitions in `ScriptGraphComponentLibrary+*.swift`.
        public static func data(_ connectorName: String, _ displayName: String) -> PinSpec {
            PinSpec(connectorName: connectorName, displayName: displayName, isExec: false)
        }
    }

    /// A RealityKit component type the script graph's Set/Get Component nodes can
    /// target, with the editable property pins it exposes. Component types are named
    /// exactly as the public RealityKit / RealityKitScripting schema names them
    /// (e.g. `"Transform"`, `"ModelComponent"`); the on-disk `component_type` literal
    /// stores `murmur64a(name)`.
    public struct ComponentSpec: Sendable, Hashable {
        /// The component's schema name (e.g. `"ModelComponent"`).
        public let name: String
        /// The component's editable properties, exposed as data input pins on a
        /// Set Component node once this type is selected.
        public let properties: [PinSpec]

        public init(name: String, properties: [PinSpec]) {
            self.name = name
            self.properties = properties
        }

        /// `murmur64a(name)` — the value stored in the `component_type` literal.
        public var typeHash: UInt64 { TMHash.murmur64a(name) }
    }

    /// A node type's full interface: its declared input and output pins, in display
    /// order. The bridge emits a handle/pin for every entry, wired or not.
    public struct NodeSpec: Sendable, Hashable {
        public let inputs: [PinSpec]
        public let outputs: [PinSpec]

        public init(inputs: [PinSpec], outputs: [PinSpec]) {
            self.inputs = inputs
            self.outputs = outputs
        }
    }

    // MARK: - Node specs

    /// The declared interface for a node `type`, or `nil` for an unknown type (the
    /// bridge then derives pins from the wired connectors instead).
    public static func spec(for type: String) -> NodeSpec? { specsByType[type] }

    private static let exec = PinSpec(connectorName: "exec", displayName: "exec", isExec: true)

    /// A data pin, named by its camelCase connector and Title Case display name.
    private static func data(_ connector: String, _ display: String) -> PinSpec {
        PinSpec(connectorName: connector, displayName: display, isExec: false)
    }

    private static let specsByType: [String: NodeSpec] = [
        // Drag gesture — an event *source*: no inputs, an exec output plus the full
        // set of drag readouts RCP shows on the node.
        "tm_gesture_event_drag": NodeSpec(
            inputs: [],
            outputs: [
                exec,
                data("entity", "Entity"),
                data("location", "Location"),
                data("startLocation", "Start Location"),
                data("translation", "Translation"),
                data("sceneLocation", "Scene Location"),
                data("sceneStartLocation", "Scene Start Location"),
                data("sceneTranslation", "Scene Translation"),
                data("sceneInputDeviceRotation", "Scene Input Device Rotation"),
                data("didEnd", "Did End"),
            ]
        ),
        // Tap gesture — best-effort observed subset.
        "tm_gesture_event_tap": NodeSpec(
            inputs: [],
            outputs: [
                exec,
                data("entity", "Entity"),
                data("location", "Location"),
                data("sceneLocation", "Scene Location"),
            ]
        ),
        // Set Component — a passthrough action: exec in/out, a `source` target and a
        // `component_type` selector. The chosen component type's property pins are
        // added *dynamically* by the bridge (see `componentProperties(forComponentTypeHash:)`).
        "tm_set_component": NodeSpec(
            inputs: [
                exec,
                data("source", "Source"),
                data("component_type", "Component Type"),
            ],
            outputs: [exec]
        ),
    ]

    // MARK: - Component types (registry)

    /// All component types the editor knows, aggregated from the per-category
    /// definitions in `ScriptGraphComponentLibrary+*.swift`. Each category is a
    /// standalone `[ComponentSpec]` in its own file so they can be authored
    /// independently; this is the single place they are merged.
    static let registeredComponents: [ComponentSpec] =
        spatialComponents

    /// `componentSpec` keyed by `murmur64a(name)` for O(1) lookup from a
    /// `component_type` literal hash.
    private static let componentSpecsByHash: [UInt64: ComponentSpec] = {
        var map: [UInt64: ComponentSpec] = [:]
        for spec in registeredComponents { map[spec.typeHash] = spec }
        return map
    }()

    /// The display name for a RealityKit component type, keyed by the `murmur64a`
    /// hash of its name. `nil` for component types not in the registry.
    public static func componentTypeName(forHash hash: UInt64) -> String? {
        componentSpecsByHash[hash]?.name
    }

    /// The property pins a `tm_set_component` node exposes once its component type is
    /// resolved — i.e. the editable fields of that component. Returned as data
    /// *inputs* (they sit on the leading edge of the set node). `nil` for component
    /// types not in the registry.
    public static func componentProperties(forComponentTypeHash hash: UInt64) -> [PinSpec]? {
        componentSpecsByHash[hash]?.properties
    }

    /// Spatial components. (Other categories are added as separate
    /// `ScriptGraphComponentLibrary+<Category>.swift` files and merged into
    /// `registeredComponents`.)
    static let spatialComponents: [ComponentSpec] = [
        // The Transform component, as RCP shows it on a "Set Transform" node.
        ComponentSpec(name: "Transform", properties: [
            .data("translation", "Translation"),
            .data("rotation", "Rotation"),
            .data("scale", "Scale"),
            .data("matrix", "Matrix"),
        ]),
    ]
}
