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

    /// The palette section a node type belongs to. Groups the insert palette into
    /// readable, ordered sections; the `order` drives section ordering in the UI.
    public enum Category: String, Sendable, Hashable, CaseIterable {
        case events = "Events"
        case controlFlow = "Control Flow"
        case logic = "Logic"
        case entity = "Entity"
        case components = "Components"
        case math = "Math"
        case make = "Make"
        case string = "String"
        case variables = "Variables"

        /// Display order of the sections in the palette (lower comes first).
        public var order: Int {
            switch self {
            case .events:     return 0
            case .controlFlow: return 1
            case .logic:      return 2
            case .entity:     return 3
            case .math:       return 4
            case .make:       return 5
            case .string:     return 6
            case .components: return 7
            case .variables:  return 8
            }
        }

        /// The section header shown in the palette.
        public var displayName: String { rawValue }
    }

    /// A node type's full interface: its declared input and output pins, in display
    /// order (plus the palette section it belongs to). The bridge emits a handle/pin
    /// for every entry, wired or not.
    public struct NodeSpec: Sendable, Hashable {
        public let inputs: [PinSpec]
        public let outputs: [PinSpec]
        /// The palette section this node type is grouped under.
        public let category: Category

        public init(inputs: [PinSpec], outputs: [PinSpec], category: Category) {
            self.inputs = inputs
            self.outputs = outputs
            self.category = category
        }
    }

    // MARK: - Palette (insertable node types)

    /// One entry in the node-insert palette: a node type the editor can author onto
    /// the canvas. `id` IS the type, so the palette is keyed by node type.
    public struct PaletteItem: Identifiable, Sendable {
        /// The node type id (e.g. `"tm_set_component"`); identical to `type`.
        public let id: String
        /// The on-disk node type to instantiate.
        public let type: String
        /// The human-readable name shown in the palette (e.g. `"Set Component"`).
        public let displayName: String
        /// The palette section this item is grouped under.
        public let category: Category

        public init(id: String, type: String, displayName: String, category: Category) {
            self.id = id
            self.type = type
            self.displayName = displayName
            self.category = category
        }
    }

    /// One palette section: a category and the items grouped under it, sorted by
    /// display name. Sections are returned in `Category.order`.
    public struct PaletteSection: Identifiable, Sendable {
        public var id: String { category.rawValue }
        public let category: Category
        public let items: [PaletteItem]

        public init(category: Category, items: [PaletteItem]) {
            self.category = category
            self.items = items
        }
    }

    /// The node types the user can INSERT — exactly the types that have a `NodeSpec`,
    /// so every inserted node arrives with its full named interface (pins). Sorted by
    /// display name for a stable, readable palette. Data-driven: it grows automatically
    /// as node specs are added to ``specsByType``.
    public static var paletteItems: [PaletteItem] {
        specsByType
            .map { type, spec in
                PaletteItem(
                    id: type, type: type,
                    displayName: paletteDisplayName(for: type),
                    category: spec.category
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The insertable node types grouped into palette sections, one per ``Category``,
    /// ordered by `Category.order`. Items within a section are sorted by display name.
    /// Empty sections are omitted. Data-driven: sections grow as specs are added.
    public static var paletteSections: [PaletteSection] {
        sections(of: paletteItems)
    }

    /// Palette sections filtered by a free-text `query`, matched case-insensitively
    /// against each item's display name AND its raw `type` (so "drag", "gesture", or
    /// "tm_gesture_event_drag" all find the drag event). A blank query returns the
    /// full palette. Pure + data-driven — unit-tested — so the canvas search field is a
    /// thin wrapper. With 250+ node types, search is how the palette stays usable.
    public static func paletteSections(matching query: String) -> [PaletteSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return paletteSections }
        let matches = paletteItems.filter {
            $0.displayName.lowercased().contains(q) || $0.type.lowercased().contains(q)
        }
        return sections(of: matches)
    }

    /// Groups palette items into category sections, ordered by `Category.order`,
    /// dropping empty categories.
    private static func sections(of items: [PaletteItem]) -> [PaletteSection] {
        let grouped = Dictionary(grouping: items, by: \.category)
        return Category.allCases
            .sorted { $0.order < $1.order }
            .compactMap { category in
                guard let items = grouped[category], !items.isEmpty else { return nil }
                return PaletteSection(category: category, items: items)
            }
    }

    /// A readable palette name for a node `type`: the curated label where we have one,
    /// else a humanized form of the raw type (drop a leading `tm_`, split on `_`,
    /// Title Case the words).
    static func paletteDisplayName(for type: String) -> String {
        if let curated = paletteDisplayNames[type] { return curated }
        var name = type
        if name.hasPrefix("tm_") { name.removeFirst(3) }
        return name
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Curated, RCP-matching display names for the insertable node types. (Node specs
    /// describe a node's pins, not the node's own title, so the title lives here.)
    private static let paletteDisplayNames: [String: String] = [
        // Events
        "tm_gesture_event_drag": "On Drag",
        "tm_gesture_event_tap": "On Tap",
        "tm_collision_event_began": "On Collision Began",
        "tm_collision_event_ended": "On Collision Ended",
        "tm_collision_event_updated": "On Collision Updated",
        "tm_physics_event_will_simulate": "On Physics Will Simulate",
        "tm_physics_event_did_simulate": "On Physics Did Simulate",
        "tm_animation_event_playback_started": "On Animation Started",
        "tm_animation_event_playback_completed": "On Animation Completed",
        "tm_animation_event_playback_looped": "On Animation Looped",
        "tm_animation_event_playback_terminated": "On Animation Terminated",
        "tm_audio_event_playback_completed": "On Audio Ended",
        "tm_update": "On Update",
        "tm_did_add": "On Added",
        "tm_did_activate": "On Activated",
        "tm_will_remove": "Will Remove",
        "tm_will_deactivate": "Will Deactivate",
        "tm_script_changed": "Script Changed",
        // Control Flow
        "tm_sequence": "Sequence",
        "tm_if": "If",
        "tm_switch": "Switch",
        "tm_loop": "Loop",
        "tm_delay": "Delay",
        "tm_cancel_delay": "Cancel Delay",
        "tm_do_once": "Do Once",
        // Entity
        "tm_entity_set_relative_transform": "Set Relative Transform",
        "tm_entity_get_world_transform": "Get World Transform",
        "tm_entity_set_world_transform": "Set World Transform",
        "tm_entity_look_at": "Look At",
        "tm_set_entity_enable": "Set Enabled",
        "tm_find_entity": "Find Entity",
        "tm_find_parent_entity": "Find Parent Entity",
        "tm_find_entity_with_component": "Find Entity With Component",
        "tm_has_component": "Has Component",
        "tm_get_parent": "Get Parent",
        "tm_get_children": "Get Children",
        "tm_set_parent": "Set Parent",
        "tm_add_child": "Add Child",
        "tm_remove_child": "Remove Child",
        "tm_remove_from_parent": "Remove From Parent",
        "tm_self": "Self",
        "tm_scene": "Scene",
        // Components
        "tm_set_component": "Set Component",
        "tm_get_component": "Get Component",
        // Math — Comparison
        "tm_math_greater": "Greater",
        "tm_math_greater_equal": "Greater or Equal",
        "tm_math_less": "Less",
        "tm_math_less_equal": "Less or Equal",
        "tm_math_within_range": "Within Range",
        "tm_math_random": "Random",
        // Math — Rotation
        "tm_math_quaternion_to_euler": "Quaternion to Euler",
        "tm_math_euler_to_quaternion": "Euler to Quaternion",
        "tm_make_rotation": "Rotation",
        "tm_make_look_at_rotation": "Look-at Rotation",
        "tm_math_deg_to_rad": "Degrees to Radians",
        "tm_math_rad_to_deg": "Radians to Degrees",
        // Math — Constant
        "tm_constant_pi": "π",
        "tm_constant_e": "e",
        "tm_constant_ln2": "Ln(2)",
        "tm_constant_ln10": "Ln(10)",
        "tm_constant_log10e": "Log10(e)",
        "tm_constant_log2e": "Log2(e)",
        "tm_constant_sqrt2": "Sqrt(2)",
        "tm_constant_sqrt1_2": "Sqrt(0.5)",
        // Make
        "tm_make_vector2": "Vector2",
        "tm_make_vector3": "Vector3",
        "tm_make_vector4": "Vector4",
        "tm_make_vector4_with_vector3": "Vector4 from Vector3",
        "tm_make_matrix2x2": "Matrix 2x2",
        "tm_make_matrix3x3": "Matrix 3x3",
        "tm_make_matrix4x4": "Matrix 4x4",
        "tm_make_cgcolor": "CGColor",
        "tm_make_color": "Color",
        "tm_make_cgsize": "CGSize",
        "tm_make_edge_insets": "Edge Insets",
        // String
        "tm_string_has_prefix": "Has Prefix",
        "tm_string_has_suffix": "Has Suffix",
        "tm_string_contains": "Contains",
        "tm_string_length": "String Length",
        "tm_string_prefix": "Prefix",
        "tm_string_suffix": "Suffix",
        "tm_string_substring": "Substring",
        // Logic
        "tm_and": "And",
        "tm_or": "Or",
        "tm_equals": "Equals",
        "tm_not_equals": "Not Equals",
        "tm_not": "Not",
        // Math — Arithmetic & trig
        "tm_math_add": "Add",
        "tm_math_subtract": "Subtract",
        "tm_math_multiply": "Multiply",
        "tm_math_divide": "Divide",
        "tm_math_mod": "Modulo",
        "tm_math_min": "Min",
        "tm_math_max": "Max",
        "tm_math_dot": "Dot Product",
        "tm_math_cross": "Cross Product",
        "tm_math_reflect": "Reflect",
        "tm_math_bitwise_and": "Bitwise And",
        "tm_math_bitwise_or": "Bitwise Or",
        "tm_math_bitwise_xor": "Bitwise Xor",
        "tm_math_sin": "Sin",
        "tm_math_cos": "Cos",
        "tm_math_tan": "Tan",
        "tm_math_asin": "Asin",
        "tm_math_acos": "Acos",
        "tm_math_atan": "Atan",
        "tm_math_sqrt": "Square Root",
        "tm_math_log": "Log",
        "tm_math_log2": "Log2",
        "tm_math_abs": "Abs",
        "tm_math_ceil": "Ceil",
        "tm_math_floor": "Floor",
        "tm_math_round": "Round",
        "tm_math_trunc": "Truncate",
        "tm_math_length": "Length",
        "tm_math_normal": "Normalize",
        "tm_math_bitwise_not": "Bitwise Not",
        "tm_math_pow": "Power",
        "tm_math_clamp": "Clamp",
        "tm_math_multiply_by_scalar": "Multiply by Scalar",
        "tm_math_multiply_by_quaternion": "Multiply by Quaternion",
        "tm_math_multiply_by_matrix": "Multiply by Matrix",
        // Math — Constant (literal)
        "tm_constant": "Constant",
        // Variables
        "tm_get_variable_node": "Get Variable",
        "tm_set_variable_node": "Set Variable",
        "tm_clear_variable_node": "Clear Variable",
        "tm_get_remote_variable_node": "Get Remote Variable",
        "tm_set_remote_variable_node": "Set Remote Variable",
        "tm_clear_remote_variable_node": "Clear Remote Variable",
    ]

    // MARK: - Node specs

    /// The declared interface for a node `type`, or `nil` for an unknown type (the
    /// bridge then derives pins from the wired connectors instead).
    public static func spec(for type: String) -> NodeSpec? { specsByType[type] }

    private static let exec = PinSpec(connectorName: "", displayName: "exec", isExec: true)

    /// A data pin, named by its camelCase connector and Title Case display name.
    private static func data(_ connector: String, _ display: String) -> PinSpec {
        PinSpec(connectorName: connector, displayName: display, isExec: false)
    }

    /// A named control-flow pin. The unnamed event connector is `exec` above.
    private static func event(_ connector: String, _ display: String) -> PinSpec {
        PinSpec(connectorName: connector, displayName: display, isExec: true)
    }

    private static func collisionEventNode(outputsContacts: Bool) -> NodeSpec {
        var outputs = [
            exec,
            data("entity", "Entity"),
            data("otherEntity", "Other Entity"),
            data("position", "Position"),
            data("impulse", "Impulse"),
            data("impulseDirection", "Impulse Direction"),
            data("penetrationDistance", "Penetration Distance"),
        ]
        if outputsContacts {
            outputs.append(data("contacts", "Contacts"))
        }
        return NodeSpec(inputs: [], outputs: outputs, category: .events)
    }

    private static let physicsSimulateEventNode = NodeSpec(
        inputs: [],
        outputs: [
            exec,
            data("deltaTime", "Delta Time"),
            data("simulationRootEntity", "Simulation Root Entity"),
        ],
        category: .events
    )

    private static let playbackEventNode = NodeSpec(
        inputs: [],
        outputs: [
            exec,
            data("playbackController", "Playback Controller"),
        ],
        category: .events
    )

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
            ],
            category: .events
        ),
        // Tap gesture — best-effort observed subset.
        "tm_gesture_event_tap": NodeSpec(
            inputs: [],
            outputs: [
                exec,
                data("entity", "Entity"),
                data("location", "Location"),
                data("sceneLocation", "Scene Location"),
            ],
            category: .events
        ),
        "tm_collision_event_began": collisionEventNode(outputsContacts: true),
        "tm_collision_event_updated": collisionEventNode(outputsContacts: true),
        "tm_collision_event_ended": NodeSpec(
            inputs: [],
            outputs: [
                exec,
                data("entity", "Entity"),
                data("otherEntity", "Other Entity"),
            ],
            category: .events
        ),
        "tm_physics_event_will_simulate": physicsSimulateEventNode,
        "tm_physics_event_did_simulate": physicsSimulateEventNode,
        "tm_animation_event_playback_started": playbackEventNode,
        "tm_animation_event_playback_completed": playbackEventNode,
        "tm_animation_event_playback_looped": playbackEventNode,
        "tm_animation_event_playback_terminated": playbackEventNode,
        "tm_audio_event_playback_completed": playbackEventNode,
        // Set Component — a passthrough action: exec in/out, a `source` target and a
        // `component_type` selector. The chosen component type's property pins are
        // added *dynamically* by the bridge (see `componentProperties(forComponentTypeHash:)`).
        "tm_set_component": NodeSpec(
            inputs: [
                exec,
                data("source", "Source"),
                data("component_type", "Component Type"),
            ],
            outputs: [exec],
            category: .components
        ),
        // On Update — per-frame event source. exec out + readouts. (entity is the
        // script's self.) NOTE: the `deltaTime`/`scene` connector names here are
        // best-effort — they are *not* yet murmur-verified against a real capture, so a
        // wired `deltaTime`/`scene` from a true RCP graph may not coincide with these
        // hashed handle ids until confirmed. (`entity` mirrors the verified drag/tap
        // `entity` connector.)
        "tm_update": NodeSpec(inputs: [], outputs: [exec, data("deltaTime", "Delta Time"), data("scene", "Scene"), data("entity", "Entity")], category: .events),
        // Lifecycle events — simple exec-output event sources (each carries only a
        // hidden self entity). Exec-only, so these are faithful: no data connector
        // names to verify.
        "tm_did_add":         NodeSpec(inputs: [], outputs: [exec], category: .events),
        "tm_did_activate":    NodeSpec(inputs: [], outputs: [exec], category: .events),
        "tm_will_remove":     NodeSpec(inputs: [], outputs: [exec], category: .events),
        "tm_will_deactivate": NodeSpec(inputs: [], outputs: [exec], category: .events),
        "tm_script_changed":  NodeSpec(inputs: [], outputs: [exec], category: .events),

        // MARK: Control Flow
        "tm_sequence": NodeSpec(inputs: [exec], outputs: [], category: .controlFlow),
        "tm_if": NodeSpec(
            inputs: [exec, data("condition", "Condition")],
            outputs: [event("always", "Always"), event("true", "True"), event("false", "False")],
            category: .controlFlow
        ),
        "tm_switch": NodeSpec(
            inputs: [exec, data("condition", "Condition"), data("continuous", "Continuous"), data("first", "First"), data("count", "Count")],
            outputs: [],
            category: .controlFlow
        ),
        "tm_loop": NodeSpec(
            inputs: [exec, data("begin", "Begin"), data("end", "End"), data("step", "Step"), data("inclusive", "Inclusive")],
            outputs: [event("step", "Step"), event("end", "End"), data("index", "Index")],
            category: .controlFlow
        ),
        "tm_delay": NodeSpec(
            inputs: [exec, data("seconds", "Seconds"), data("is unique", "Is Unique")],
            outputs: [event("always", "Always"), event("once", "Once"), data("cancelID", "Cancel ID")],
            category: .controlFlow
        ),
        "tm_cancel_delay": NodeSpec(inputs: [exec, data("cancelID", "Cancel ID")], outputs: [exec], category: .controlFlow),
        "tm_do_once": NodeSpec(inputs: [exec], outputs: [event("always", "Always"), event("once", "Once")], category: .controlFlow),

        // MARK: Entity
        "tm_entity_set_relative_transform": NodeSpec(
            inputs: [
                exec,
                data("entity", "Entity"),
                data("scale", "Scale"),
                data("orientation", "Orientation"),
                data("position", "Position"),
                data("matrix", "Matrix"),
                data("relativeTo", "Relative To"),
            ],
            outputs: [exec],
            category: .entity
        ),
        "tm_entity_get_world_transform": NodeSpec(
            inputs: [data("entity", "Entity")],
            outputs: [
                data("scale", "Scale"),
                data("orientation", "Orientation"),
                data("position", "Position"),
                data("matrix", "Matrix"),
            ],
            category: .entity
        ),
        "tm_entity_set_world_transform": NodeSpec(
            inputs: [
                exec,
                data("entity", "Entity"),
                data("scale", "Scale"),
                data("orientation", "Orientation"),
                data("position", "Position"),
                data("matrix", "Matrix"),
            ],
            outputs: [exec],
            category: .entity
        ),
        "tm_entity_look_at": NodeSpec(
            inputs: [
                exec,
                data("entity", "Entity"),
                data("at", "At"),
                data("from", "From"),
                data("upVector", "Up Vector"),
                data("relativeTo", "Relative To"),
                data("positiveZForward", "Positive Z Forward"),
            ],
            outputs: [exec],
            category: .entity
        ),
        "tm_set_entity_enable": NodeSpec(
            inputs: [
                exec,
                data("entity", "Entity"),
                data("isEnabled", "Is Enabled"),
            ],
            outputs: [exec],
            category: .entity
        ),
        "tm_find_entity": NodeSpec(
            inputs: [
                data("entity", "Entity"),
                data("name", "Name"),
                data("recursive", "Recursive"),
            ],
            outputs: [data("entity", "Entity")],
            category: .entity
        ),
        "tm_find_parent_entity": NodeSpec(
            inputs: [
                data("entity", "Entity"),
                data("name", "Name"),
            ],
            outputs: [data("entity", "Entity")],
            category: .entity
        ),
        "tm_find_entity_with_component": NodeSpec(
            inputs: [
                data("entity", "Entity"),
                data("component_type", "Component Type"),
            ],
            outputs: [data("entity", "Entity")],
            category: .entity
        ),
        "tm_has_component": NodeSpec(
            inputs: [
                data("source", "Source"),
                data("component_type", "Component Type"),
            ],
            outputs: [data("result", "Result")],
            category: .entity
        ),
        "tm_get_parent": NodeSpec(
            inputs: [data("source", "Source")],
            outputs: [data("parent", "Parent")],
            category: .entity
        ),
        "tm_get_children": NodeSpec(
            inputs: [data("source", "Source")],
            outputs: [data("children", "Children")],
            category: .entity
        ),
        "tm_set_parent": NodeSpec(
            inputs: [
                exec,
                data("entity", "Entity"),
                data("parent", "Parent"),
                data("preservingWorldTransform", "Preserving World Transform"),
            ],
            outputs: [exec],
            category: .entity
        ),
        "tm_add_child": NodeSpec(
            inputs: [
                exec,
                data("entity", "Entity"),
                data("child", "Child"),
                data("preservingWorldTransform", "Preserving World Transform"),
            ],
            outputs: [exec],
            category: .entity
        ),
        "tm_remove_child": NodeSpec(
            inputs: [
                exec,
                data("entity", "Entity"),
                data("child", "Child"),
                data("preservingWorldTransform", "Preserving World Transform"),
            ],
            outputs: [exec],
            category: .entity
        ),
        "tm_remove_from_parent": NodeSpec(
            inputs: [
                exec,
                data("entity", "Entity"),
                data("preservingWorldTransform", "Preserving World Transform"),
            ],
            outputs: [exec],
            category: .entity
        ),
        "tm_self": NodeSpec(inputs: [], outputs: [data("entity", "Entity")], category: .entity),
        "tm_scene": NodeSpec(inputs: [], outputs: [data("scene", "Scene")], category: .entity),

        // Get Component — mirror of Set Component, but the component's properties are
        // OUTPUTS (you read them). Its `source`/`component_type` connector names mirror
        // the verified `tm_set_component` names, so this node is faithful. The chosen
        // component type's property pins are added *dynamically* by the resolver as
        // data OUTPUTS (see `ScriptGraphPinResolver`).
        "tm_get_component": NodeSpec(inputs: [exec, data("source", "Source"), data("component_type", "Component Type")], outputs: [exec], category: .components),

        // MARK: Math — Comparison
        //
        // Data-only value nodes: no exec/self pins. Each compares (or samples) its
        // inputs and yields a single `result`. Pin connector names are faithful to the
        // observed node definitions.
        "tm_math_greater":       NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_greater_equal": NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_less":          NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_less_equal":    NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_within_range":  NodeSpec(inputs: [data("val", "Value"), data("min", "Min"), data("max", "Max")], outputs: [data("result", "Result")], category: .math),
        "tm_math_random":        NodeSpec(inputs: [data("min", "Min"), data("max", "Max")], outputs: [data("result", "Result")], category: .math),

        // MARK: Math — Rotation
        "tm_math_quaternion_to_euler": NodeSpec(inputs: [data("quaternion", "Quaternion")], outputs: [data("angles", "Angles")], category: .math),
        "tm_math_euler_to_quaternion": NodeSpec(inputs: [data("angles", "Angles")], outputs: [data("quaternion", "Quaternion")], category: .math),
        "tm_make_rotation":            NodeSpec(inputs: [data("angle", "Angle"), data("axis", "Axis")], outputs: [data("new", "New")], category: .math),
        "tm_make_look_at_rotation":    NodeSpec(inputs: [data("at", "At"), data("from", "From"), data("upVector", "Up Vector")], outputs: [data("new", "New")], category: .math),
        "tm_math_deg_to_rad":          NodeSpec(inputs: [data("degrees", "Degrees")], outputs: [data("result", "Result")], category: .math),
        "tm_math_rad_to_deg":          NodeSpec(inputs: [data("rad", "Radians")], outputs: [data("result", "Result")], category: .math),

        // MARK: Math — Constant
        //
        // No inputs; a single output whose connector name is the UPPERCASE constant
        // name (faithful — e.g. `PI`, `SQRT1_2`).
        "tm_constant_pi":      NodeSpec(inputs: [], outputs: [data("PI", "π")], category: .math),
        "tm_constant_e":       NodeSpec(inputs: [], outputs: [data("E", "e")], category: .math),
        "tm_constant_ln2":     NodeSpec(inputs: [], outputs: [data("LN2", "Ln(2)")], category: .math),
        "tm_constant_ln10":    NodeSpec(inputs: [], outputs: [data("LN10", "Ln(10)")], category: .math),
        "tm_constant_log10e":  NodeSpec(inputs: [], outputs: [data("LOG10E", "Log10(e)")], category: .math),
        "tm_constant_log2e":   NodeSpec(inputs: [], outputs: [data("LOG2E", "Log2(e)")], category: .math),
        "tm_constant_sqrt2":   NodeSpec(inputs: [], outputs: [data("SQRT2", "Sqrt(2)")], category: .math),
        "tm_constant_sqrt1_2": NodeSpec(inputs: [], outputs: [data("SQRT1_2", "Sqrt(0.5)")], category: .math),

        // MARK: Make
        //
        // Data-only constructors: assemble a value from its component inputs. Output
        // connector names are faithful to the observed node definitions.
        "tm_make_vector2": NodeSpec(inputs: [data("x", "X"), data("y", "Y")], outputs: [data("vec2", "Vector2")], category: .make),
        "tm_make_vector3": NodeSpec(inputs: [data("x", "X"), data("y", "Y"), data("z", "Z")], outputs: [data("vec3", "Vector3")], category: .make),
        "tm_make_vector4": NodeSpec(inputs: [data("x", "X"), data("y", "Y"), data("z", "Z"), data("w", "W")], outputs: [data("vector", "Vector")], category: .make),
        "tm_make_vector4_with_vector3": NodeSpec(inputs: [data("xyz", "XYZ"), data("w", "W")], outputs: [data("vector", "Vector")], category: .make),
        "tm_make_matrix2x2": NodeSpec(inputs: [data("col0", "Column 0"), data("col1", "Column 1")], outputs: [data("source", "Source")], category: .make),
        "tm_make_matrix3x3": NodeSpec(inputs: [data("col0", "Column 0"), data("col1", "Column 1"), data("col2", "Column 2")], outputs: [data("source", "Source")], category: .make),
        "tm_make_matrix4x4": NodeSpec(inputs: [data("col0", "Column 0"), data("col1", "Column 1"), data("col2", "Column 2"), data("col3", "Column 3")], outputs: [data("source", "Source")], category: .make),
        "tm_make_cgcolor": NodeSpec(inputs: [data("red", "Red"), data("green", "Green"), data("blue", "Blue"), data("alpha", "Alpha")], outputs: [data("source", "Source")], category: .make),
        "tm_make_color": NodeSpec(inputs: [data("red", "Red"), data("green", "Green"), data("blue", "Blue"), data("alpha", "Alpha")], outputs: [data("color", "Color")], category: .make),
        "tm_make_cgsize": NodeSpec(inputs: [data("width", "Width"), data("height", "Height")], outputs: [data("size", "Size")], category: .make),
        "tm_make_edge_insets": NodeSpec(inputs: [data("top", "Top"), data("left", "Left"), data("bottom", "Bottom"), data("right", "Right")], outputs: [data("insets", "Insets")], category: .make),

        // MARK: String
        //
        // Data-only string predicates and slicing. `result`/`length` outputs are
        // faithful to the observed node definitions.
        "tm_string_has_prefix": NodeSpec(inputs: [data("string", "String"), data("prefix", "Prefix")], outputs: [data("result", "Result")], category: .string),
        "tm_string_has_suffix": NodeSpec(inputs: [data("string", "String"), data("suffix", "Suffix")], outputs: [data("result", "Result")], category: .string),
        "tm_string_contains":   NodeSpec(inputs: [data("string", "String"), data("substring", "Substring")], outputs: [data("result", "Result")], category: .string),
        "tm_string_length":     NodeSpec(inputs: [data("string", "String")], outputs: [data("length", "Length")], category: .string),
        "tm_string_prefix":     NodeSpec(inputs: [data("string", "String"), data("length", "Length")], outputs: [data("result", "Result")], category: .string),
        "tm_string_suffix":     NodeSpec(inputs: [data("string", "String"), data("length", "Length")], outputs: [data("result", "Result")], category: .string),
        "tm_string_substring":  NodeSpec(inputs: [data("string", "String"), data("index", "Index"), data("length", "Length")], outputs: [data("result", "Result")], category: .string),

        // MARK: Logic
        //
        // Data-only boolean reducers → a single `result`. The inputs are variadic
        // (`a`, `b`, `c`, …); we seed the first two faithful pins. The editor's
        // "add more inputs (+)" affordance is a deferred follow-up.
        "tm_and": NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .logic),
        "tm_or":  NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .logic),
        // Equality / negation. Data-only (no exec); `result` is a Bool. `tm_equals` /
        // `tm_not_equals` take two equal-typed operands `a`/`b`; `tm_not` takes a single
        // Bool `a`. The observed node definitions register these under a "Control"
        // category; our catalog groups them with the other boolean operators under
        // "Logic" for palette readability (a cosmetic divergence from the source label).
        "tm_equals":     NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .logic),
        "tm_not_equals": NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .logic),
        "tm_not":        NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .logic),

        // MARK: Math — Arithmetic & trig
        //
        // Data-only value nodes → a single `result`. Binary operators take a variadic
        // input list (`a`, `b`, …; we seed `a`, `b`, "+" deferred); unary operators take
        // a single `a`; a few take a named auxiliary input. Pin connector names are
        // faithful to the observed node definitions.
        "tm_math_add":          NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_subtract":     NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_multiply":     NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_divide":       NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_mod":          NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_min":          NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_max":          NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_dot":          NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_cross":        NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_reflect":      NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_bitwise_and":  NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_bitwise_or":   NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_bitwise_xor":  NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_sin":          NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_cos":          NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_tan":          NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_asin":         NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_acos":         NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_atan":         NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_sqrt":         NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_log":          NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_log2":         NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_abs":          NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_ceil":         NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_floor":        NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_round":        NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_trunc":        NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_length":       NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_normal":       NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_bitwise_not":  NodeSpec(inputs: [data("a", "A")], outputs: [data("result", "Result")], category: .math),
        "tm_math_pow":          NodeSpec(inputs: [data("a", "A"), data("exponent", "Exponent")], outputs: [data("result", "Result")], category: .math),
        "tm_math_clamp":        NodeSpec(inputs: [data("a", "A"), data("min", "Min"), data("max", "Max")], outputs: [data("result", "Result")], category: .math),
        "tm_math_multiply_by_scalar":     NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_multiply_by_quaternion": NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),
        "tm_math_multiply_by_matrix":     NodeSpec(inputs: [data("a", "A"), data("b", "B")], outputs: [data("result", "Result")], category: .math),

        // MARK: Math — Constant (literal)
        //
        // No inputs; a single `value` output. The literal value is a node *settings*
        // field, not a pin (a future literal-editing UI).
        "tm_constant": NodeSpec(inputs: [], outputs: [data("value", "Value")], category: .math),

        // MARK: Variables
        //
        // Get/Set/Clear a named graph variable. For the LOCAL variants the referenced
        // variable is a node *settings* field (a future variable-reference UI), not a
        // pin — only the `value` data pin and exec pins are declared. The REMOTE variants
        // take the referenced variable as an Entity input pin (`Variable`). Set/Clear are
        // control-flow actions (exec in + exec out); Get is data-only.
        "tm_get_variable_node":          NodeSpec(inputs: [], outputs: [data("value", "Value")], category: .variables),
        "tm_set_variable_node":          NodeSpec(inputs: [exec, data("value", "Value")], outputs: [exec], category: .variables),
        "tm_clear_variable_node":        NodeSpec(inputs: [exec], outputs: [exec], category: .variables),
        "tm_get_remote_variable_node":   NodeSpec(inputs: [data("Variable", "Variable")], outputs: [data("value", "Value")], category: .variables),
        "tm_set_remote_variable_node":   NodeSpec(inputs: [exec, data("Variable", "Variable"), data("value", "Value")], outputs: [exec], category: .variables),
        "tm_clear_remote_variable_node": NodeSpec(inputs: [exec, data("Variable", "Variable")], outputs: [exec], category: .variables),
    ]

    // MARK: - Component types (registry)

    /// All component types the editor knows, aggregated from the per-category
    /// definitions in `ScriptGraphComponentLibrary+*.swift`. Each category is a
    /// standalone `[ComponentSpec]` in its own file so they can be authored
    /// independently; this is the single place they are merged.
    static let registeredComponents: [ComponentSpec] =
        spatialComponents
            + renderingComponents
            + physicsComponents
            + lightingComponents
            + anchoringComponents
            + audioAnimationComponents

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
