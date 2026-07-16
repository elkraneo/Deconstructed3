import Foundation
import RCP3Document

/// The per-node payload carried through the SwiftUI canvas.
///
/// `RCP3GraphEditor` renders an `RCP3ScriptGraph` on its own SwiftUI `Canvas`. The
/// *resolver* (`ScriptGraphPinResolver`) maps each `RCP3ScriptGraph.Node` to a
/// `ScriptGraphNodePayload` whose `pins` mirror the node's interface, and wires
/// become connections between those pins (keyed by pin `id`). The *node view*
/// (`ScriptGraphCanvasNodeView`) renders this payload — title, type, role
/// tint/icon, and a labelled port per pin.
///
/// This is the stable contract between the resolver (data) and the view (visual),
/// so the two can evolve independently. It is `Sendable & Hashable`.
public struct ScriptGraphNodePayload: Sendable, Hashable, Identifiable {
    /// The node's `__uuid` (matches `RCP3ScriptGraph.Node.id`).
    public let id: String
    /// The node `type` (e.g. `tm_gesture_event_drag`, `tm_set_component`).
    public let type: String
    /// The author-given label, when present (e.g. `"Set Transform"`). Mutable so the
    /// editor can rename a node in place; write-back mirrors it to the on-disk `label`.
    public var label: String?
    /// The node's clean-room role, used for tint/icon and grouping.
    public let role: ScriptGraphNodeRole
    /// The node's pins (exec + data, input + output), in display order. Each pin's
    /// `id` is the stable handle id connections reference.
    public let pins: [Pin]

    public init(
        id: String,
        type: String,
        label: String? = nil,
        role: ScriptGraphNodeRole,
        pins: [Pin]
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.role = role
        self.pins = pins
    }

    /// The heading shown on the node: the author label, else a humanized type.
    public var title: String { label ?? Self.humanize(type) }

    /// Input pins (rendered on the leading edge).
    public var inputPins: [Pin] { pins.filter(\.isInput) }
    /// Output pins (rendered on the trailing edge).
    public var outputPins: [Pin] { pins.filter { !$0.isInput } }

    /// A single pin (connection point) on a node.
    public struct Pin: Sendable, Hashable, Identifiable {
        /// The stable handle id (what a connection's source/target reference).
        public let id: String
        /// A readable label (resolved pin name, or hex hash, or "exec").
        public let label: String
        /// `true` for an input (target) pin, `false` for an output (source) pin.
        public let isInput: Bool
        /// `true` for a control-flow (exec) pin, `false` for a data pin.
        public let isExec: Bool
        /// Resolved value contract used by canvas and agent connection gating.
        /// Wire-derived fallback pins remain `.unknown` and stay lossless.
        public let typeConstraint: ScriptGraphNodeLibrary.PinTypeConstraint
        /// The exposed literal value bound to this pin, when one is set — e.g.
        /// `"(Self)"` for a `source` pin, `"Transform"` for a `component_type` pin.
        /// `nil` when the pin carries no constant value (it is wired, or empty).
        public let valueLabel: String?

        public init(
            id: String,
            label: String,
            isInput: Bool,
            isExec: Bool,
            valueLabel: String? = nil,
            typeConstraint: ScriptGraphNodeLibrary.PinTypeConstraint = .unknown
        ) {
            self.id = id
            self.label = label
            self.isInput = isInput
            self.isExec = isExec
            self.valueLabel = valueLabel
            self.typeConstraint = isExec ? .any : typeConstraint
        }
    }

    /// Turns a `tm_snake_case_type` into a "Title Case" heading for display.
    static func humanize(_ type: String) -> String {
        var name = type
        if name.hasPrefix("tm_") { name.removeFirst(3) }
        let words = name.split(separator: "_").map { word -> String in
            guard let first = word.first else { return String(word) }
            return first.uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ")
    }
}

/// A clean-room categorization of a script-graph node, derived purely from its
/// `type` naming conventions (no external metadata). Drives the node's tint and
/// icon and lets the editor group the palette. Intentionally coarse — it only
/// improves legibility, it is not authoritative semantics.
public enum ScriptGraphNodeRole: String, Sendable, Hashable, CaseIterable {
    /// Events / triggers — gesture, collision, lifecycle (`tm_gesture_event_*`,
    /// `tm_update`, `tm_did_*`, `tm_will_*`, `*_event_*`).
    case event
    /// State-mutating actions (`tm_set_*`, `tm_add_*`, `tm_remove_*`,
    /// `tm_send_*`, `tm_play_*`, …).
    case action
    /// Value producers / readers (`tm_get_*`, `tm_break_*`, constants, `tm_make_*`).
    case value
    /// Pure logic / math (`tm_and`, `tm_or`, `tm_not`, comparisons, math ops).
    case logic
    /// Control flow (branch, loop, sequence, delay).
    case flow
    /// Unclassified.
    case other

    /// Classifies a node `type` into a role from its naming convention.
    public static func role(forType type: String) -> ScriptGraphNodeRole {
        let t = type.hasPrefix("tm_") ? String(type.dropFirst(3)) : type

        // Events: gesture/collision/audio/animation events + entity lifecycle.
        if t.contains("event") || t.hasPrefix("gesture")
            || ["update", "did_add", "did_activate", "will_remove", "will_deactivate",
                "script_changed"].contains(t)
            || t.hasPrefix("did_") || t.hasPrefix("will_") {
            return .event
        }
        // Control flow.
        if ["branch", "sequence", "for_each", "while", "delay", "cancel_delay",
            "gate", "switch"].contains(where: { t.hasPrefix($0) || t == $0 }) {
            return .flow
        }
        // Logic / boolean / comparison / math.
        if ["and", "or", "not", "xor", "equal", "greater", "less", "compare"].contains(t)
            || t.hasPrefix("math_") || t.hasPrefix("compare") {
            return .logic
        }
        // Actions: state mutation.
        if ["set", "add", "remove", "clone", "send", "play", "stop", "enable",
            "disable", "destroy", "spawn", "apply", "trigger"]
            .contains(where: { t.hasPrefix($0 + "_") || t == $0 }) {
            return .action
        }
        // Values: getters / destructure / constructors / constants.
        if t.hasPrefix("get") || t.hasPrefix("break_") || t.hasPrefix("make_")
            || t.hasPrefix("constant") || t.contains("_get") {
            return .value
        }
        return .other
    }
}
