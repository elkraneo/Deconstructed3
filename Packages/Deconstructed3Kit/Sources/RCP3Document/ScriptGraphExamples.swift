import Foundation
import TMFormat

/// A curated, clean-room gallery of canonical script-graph examples the editor can
/// LOAD onto the canvas (see + edit) and PLAY on Apple's real `RealityKitScripting`
/// runtime, driving the box geometry.
///
/// Every example is built **only** from node types that already exist in the app's
/// node library (`ScriptGraphNodeLibrary`) — parity with RCP 3, no invented nodes —
/// and wires their pins by the faithful `murmur64a` connector hashes (so a loaded
/// example presents exactly the named pins the editor draws, and the canonical
/// compiler resolves them the same way it resolves a real captured graph).
///
/// ## Runs today vs. needs variables
///
/// `runsToday == true` examples are wired so the canonical
/// `CanonicalScriptGraphCompiler` lowers the whole wired path to faithful runtime JS
/// with **no `unsupported` note on that path** — the backing compiler tests assert
/// exactly that. Press ▶ Play and the box moves.
///
/// `runsToday == false` examples need a graph **variable** (an accumulator like
/// `$angle` or `$t`). The variable get/set nodes exist in the library and the
/// example authors + compiles, but the canonical compiler can't yet resolve the
/// variable's *name* (it lives in node settings, not the wire graph), so it emits a
/// placeholder for the variable read/write — the example loads and edits fine, but
/// won't run correctly until variable-name authoring lands. Each says so in its
/// `summary`.
///
/// ## A note on scalar literals
///
/// A few examples want a scalar literal on a `make_vector3` component or a math
/// operand (e.g. an offset of `0.5`). These are carried as graph `data` literals
/// (`RCP3ScriptGraph.DataLiteral.scalarValue`) and the canonical compiler now reads
/// them, so the example shows a real result on Play. Authoring such literals in the
/// editor UI — and round-tripping them to the on-disk `.tm_` `data` array — is the
/// next step; an unwired pin with no literal still lowers to a safe `0` (NOT an
/// `unsupported` note).
public struct ScriptGraphExample: Identifiable, Sendable {
    /// A stable id (also the synthetic `openScriptGraphID` the editor uses to key the
    /// canvas when this example is loaded).
    public let id: String
    /// The gallery display name (e.g. `"Drag to Move"`).
    public let name: String
    /// A one-line description, shown as help in the gallery. For a `runsToday == false`
    /// example it explains what the example needs; for the honest-literal cases it
    /// notes the literal caveat.
    public let summary: String
    /// The example graph, built from library node types with faithful pins.
    public let graph: RCP3ScriptGraph
    /// `true` when the canonical compiler lowers the wired path to working runtime JS
    /// today (no `unsupported` on that path); `false` when it needs variable-name
    /// authoring first (see the type doc).
    public let runsToday: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        graph: RCP3ScriptGraph,
        runsToday: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.graph = graph
        self.runsToday = runsToday
    }
}

/// The curated example gallery. Public, ordered (runs-today first, then the
/// needs-variables ports), and built once.
public enum ScriptGraphExamples {

    /// All examples, in gallery order.
    public static let all: [ScriptGraphExample] = [
        dragToMove,
        dragWithOffset,
        drift,
        tapToGrow,
        snapOnAdd,
        squashBySin,
        spin,
        sineBob,
        orbit,
        dragMomentum,
    ]

    /// Look up an example by id (the synthetic open-graph key).
    public static func example(id: String) -> ScriptGraphExample? {
        all.first { $0.id == id }
    }

    // MARK: Pin-hash helpers (faithful connectors)

    private static func pin(_ name: String) -> UInt64 { TMHash.murmur64a(name) }

    /// A data wire `from.<fromPin> → to.<toPin>` named by faithful connector names.
    private static func data(
        _ id: String,
        from: String, _ fromPin: String,
        to: String, _ toPin: String
    ) -> RCP3ScriptGraph.Wire {
        RCP3ScriptGraph.Wire(id: id, from: from, to: to, fromPin: pin(fromPin), toPin: pin(toPin))
    }

    /// An exec (control-flow) wire `from → to` (no pin hashes).
    private static func exec(_ id: String, from: String, to: String) -> RCP3ScriptGraph.Wire {
        RCP3ScriptGraph.Wire(id: id, from: from, to: to)
    }

    /// A scalar constant bound to `node`'s `pinName` (a graph `data` literal): the
    /// value an unwired numeric component/math pin carries, so the example shows a
    /// real result on Play.
    private static func lit(_ id: String, node: String, pin pinName: String, _ value: Double) -> RCP3ScriptGraph.DataLiteral {
        RCP3ScriptGraph.DataLiteral(id: id, toNode: node, toPin: pin(pinName), scalarValue: value)
    }

    // MARK: - RUNS TODAY

    /// On Drag → Set Transform.translation = `sceneTranslation`. The documented
    /// reference drag handler — drag the box and it follows in scene space.
    public static let dragToMove = ScriptGraphExample(
        id: "example.drag-to-move",
        name: "Drag to Move",
        summary: "Drag the box and it follows your pointer in scene space.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "drag", type: "tm_gesture_event_drag", x: 0, y: 0),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 320, y: 0),
            ],
            wires: [
                exec("e", from: "drag", to: "set"),
                data("d", from: "drag", "sceneTranslation", to: "set", "translation"),
            ],
            data: []
        ),
        runsToday: true
    )

    /// On Drag → Set translation = `add(sceneTranslation, Vector3(x, 0, 0))`. Same
    /// follow-the-pointer drag, but offset along X. (The offset's magnitude is a
    /// scalar literal, which isn't authorable yet, so the X component lowers to 0 — the
    /// add + Vector3 structure is faithful and compiles cleanly.)
    public static let dragWithOffset = ScriptGraphExample(
        id: "example.drag-with-offset",
        name: "Drag with Offset",
        summary: "Drag, plus a baked +0.5 X offset via add(sceneTranslation, Vector3). (The offset is a baked data literal; in-editor literal authoring is next.)",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "drag", type: "tm_gesture_event_drag", x: 0, y: 0),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 320, y: 0),
                .init(id: "vec", type: "tm_make_vector3", label: "Vector3", x: 320, y: 160),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 640, y: 0),
            ],
            wires: [
                exec("e", from: "drag", to: "set"),
                data("d1", from: "drag", "sceneTranslation", to: "add", "a"),
                data("d2", from: "vec", "vec3", to: "add", "b"),
                data("d3", from: "add", "result", to: "set", "translation"),
            ],
            data: [
                lit("lit.x", node: "vec", pin: "x", 0.5),
            ]
        ),
        runsToday: true
    )

    /// On Update → Set translation = `add(Get Transform.translation, Vector3(deltaTime, 0, 0))`.
    /// Each frame the box drifts along X by `deltaTime`, reading its own current
    /// position back via Get Transform.
    public static let drift = ScriptGraphExample(
        id: "example.drift",
        name: "Drift",
        summary: "Each frame, move the box along X by deltaTime, reading its current position via Get Transform.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "get", type: "tm_get_component", label: "Get Transform", x: 0, y: 200),
                .init(id: "vec", type: "tm_make_vector3", label: "Vector3", x: 320, y: 200),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 640, y: 0),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 960, y: 0),
            ],
            wires: [
                exec("e", from: "update", to: "set"),
                data("d1", from: "get", "translation", to: "add", "a"),
                data("d2", from: "update", "deltaTime", to: "vec", "x"),
                data("d3", from: "vec", "vec3", to: "add", "b"),
                data("d4", from: "add", "result", to: "set", "translation"),
            ],
            data: []
        ),
        runsToday: true
    )

    /// On Tap → Set scale = `add(Get Transform.scale, Vector3(s, s, s))`. Tap the box
    /// to grow it. (The per-tap growth `s` is a scalar literal — not authorable yet, so
    /// it reads 0 and scale holds; the Get + add + Vector3 structure is faithful.)
    public static let tapToGrow = ScriptGraphExample(
        id: "example.tap-to-grow",
        name: "Tap to Grow",
        summary: "Tap the box to grow it by 0.2 each tap: scale = Get scale + Vector3(0.2, 0.2, 0.2). (Growth is a baked data literal; in-editor authoring is next.)",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "tap", type: "tm_gesture_event_tap", x: 0, y: 0),
                .init(id: "get", type: "tm_get_component", label: "Get Transform", x: 0, y: 200),
                .init(id: "vec", type: "tm_make_vector3", label: "Vector3", x: 320, y: 200),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 640, y: 0),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 960, y: 0),
            ],
            wires: [
                exec("e", from: "tap", to: "set"),
                data("d1", from: "get", "scale", to: "add", "a"),
                data("d2", from: "vec", "vec3", to: "add", "b"),
                data("d3", from: "add", "result", to: "set", "scale"),
            ],
            data: [
                lit("lit.x", node: "vec", pin: "x", 0.2),
                lit("lit.y", node: "vec", pin: "y", 0.2),
                lit("lit.z", node: "vec", pin: "z", 0.2),
            ]
        ),
        runsToday: true
    )

    /// On Added → Set translation = `Vector3(x, y, z)`. When the box is added it snaps
    /// to a fixed position. (The position is a Vector3 of scalar literals — not
    /// authorable yet, so it snaps to the origin; the Set translation = Vector3
    /// structure is faithful and compiles cleanly.)
    public static let snapOnAdd = ScriptGraphExample(
        id: "example.snap-on-add",
        name: "Snap on Add",
        summary: "When the box is added, snap its position to (0.3, 0.3, 0). (Coordinates are baked data literals; in-editor authoring is next.)",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "added", type: "tm_did_add", x: 0, y: 0),
                .init(id: "vec", type: "tm_make_vector3", label: "Vector3", x: 320, y: 0),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 640, y: 0),
            ],
            wires: [
                exec("e", from: "added", to: "set"),
                data("d", from: "vec", "vec3", to: "set", "translation"),
            ],
            data: [
                lit("lit.x", node: "vec", pin: "x", 0.3),
                lit("lit.y", node: "vec", pin: "y", 0.3),
            ]
        ),
        runsToday: true
    )

    /// On Update → Set scale = `Vector3(1, add(1, multiply(scale, sin(deltaTime))), 1)`.
    /// A sin-driven vertical squash. Honest caveat: it reads `deltaTime` (the per-frame
    /// step) directly, NOT an accumulated time, so without a `$t` accumulator it can't
    /// smoothly animate — but it compiles and runs cleanly (it's marked runs-today).
    public static let squashBySin = ScriptGraphExample(
        id: "example.squash-by-sin",
        name: "Squash by Sin",
        summary: "Vertical scale = 1 + 0.5·sin(deltaTime), from baked literals. Runs without collapsing, but uses deltaTime directly (no time accumulator), so it won't smoothly animate — see 'Sine Bob' for the variable-driven version.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "sin", type: "tm_math_sin", label: "Sin", x: 200, y: 240),
                .init(id: "mul", type: "tm_math_multiply", label: "Multiply", x: 420, y: 240),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 640, y: 200),
                .init(id: "vec", type: "tm_make_vector3", label: "Vector3", x: 860, y: 100),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 1080, y: 0),
            ],
            wires: [
                exec("e", from: "update", to: "set"),
                // sin(deltaTime)
                data("d1", from: "update", "deltaTime", to: "sin", "a"),
                // amp * sin(deltaTime) — amp is a scalar literal (reads 0), so this is
                // the wired path the compiler must lower without an `unsupported` note.
                data("d2", from: "sin", "result", to: "mul", "b"),
                // 1 + (amp * sin(deltaTime)) — the `1` is a scalar literal (reads 0).
                data("d3", from: "mul", "result", to: "add", "b"),
                // Vector3(x, <squash>, z) → scale
                data("d4", from: "add", "result", to: "vec", "y"),
                data("d5", from: "vec", "vec3", to: "set", "scale"),
            ],
            data: [
                lit("lit.vx", node: "vec", pin: "x", 1),
                lit("lit.vz", node: "vec", pin: "z", 1),
                lit("lit.base", node: "add", pin: "a", 1),
                lit("lit.amp", node: "mul", pin: "a", 0.5),
            ]
        ),
        runsToday: true
    )

    // MARK: - NEEDS VARIABLES (author / compile only)

    /// On Update → `$angle += deltaTime`; Set rotation from `$angle`. A continuous
    /// spin. Needs a graph variable (`$angle`) the compiler can't name yet.
    public static let spin = ScriptGraphExample(
        id: "example.spin",
        name: "Spin",
        summary: "Continuously rotate the box by accumulating $angle += deltaTime each frame. NEEDS VARIABLES: the $angle accumulator's name isn't authorable yet, so it loads + compiles but won't run correctly.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "getAngle", type: "tm_get_variable_node", label: "Get $angle", x: 0, y: 220),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 320, y: 120),
                .init(id: "setAngle", type: "tm_set_variable_node", label: "Set $angle", x: 640, y: 0),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 960, y: 0),
            ],
            wires: [
                exec("e1", from: "update", to: "setAngle"),
                exec("e2", from: "setAngle", to: "set"),
                data("d1", from: "getAngle", "value", to: "add", "a"),
                data("d2", from: "update", "deltaTime", to: "add", "b"),
                data("d3", from: "add", "result", to: "setAngle", "value"),
                data("d4", from: "getAngle", "value", to: "set", "rotation"),
            ],
            data: []
        ),
        runsToday: false
    )

    /// On Update → `$t += deltaTime`; Set translation.y from `sin($t)`. A vertical bob.
    /// Needs a graph variable (`$t`) the compiler can't name yet.
    public static let sineBob = ScriptGraphExample(
        id: "example.sine-bob",
        name: "Sine Bob",
        summary: "Bob the box up and down with sin($t), accumulating $t += deltaTime. NEEDS VARIABLES: the $t accumulator isn't authorable yet, so it loads + compiles but won't run correctly.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "getT", type: "tm_get_variable_node", label: "Get $t", x: 0, y: 220),
                .init(id: "addT", type: "tm_math_add", label: "Add", x: 320, y: 120),
                .init(id: "setT", type: "tm_set_variable_node", label: "Set $t", x: 640, y: 0),
                .init(id: "sin", type: "tm_math_sin", label: "Sin", x: 320, y: 320),
                .init(id: "vec", type: "tm_make_vector3", label: "Vector3", x: 640, y: 320),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 960, y: 0),
            ],
            wires: [
                exec("e1", from: "update", to: "setT"),
                exec("e2", from: "setT", to: "set"),
                data("d1", from: "getT", "value", to: "addT", "a"),
                data("d2", from: "update", "deltaTime", to: "addT", "b"),
                data("d3", from: "addT", "result", to: "setT", "value"),
                data("d4", from: "getT", "value", to: "sin", "a"),
                data("d5", from: "sin", "result", to: "vec", "y"),
                data("d6", from: "vec", "vec3", to: "set", "translation"),
            ],
            data: []
        ),
        runsToday: false
    )

    /// On Update → `$t += deltaTime`; Set translation = `Vector3(cos($t), 0, sin($t))`.
    /// An orbit in the XZ plane. Needs a graph variable (`$t`) the compiler can't name
    /// yet.
    public static let orbit = ScriptGraphExample(
        id: "example.orbit",
        name: "Orbit",
        summary: "Orbit the box in the XZ plane with Vector3(cos($t), 0, sin($t)), accumulating $t += deltaTime. NEEDS VARIABLES: $t isn't authorable yet, so it loads + compiles but won't run correctly.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "getT", type: "tm_get_variable_node", label: "Get $t", x: 0, y: 240),
                .init(id: "addT", type: "tm_math_add", label: "Add", x: 320, y: 140),
                .init(id: "setT", type: "tm_set_variable_node", label: "Set $t", x: 640, y: 0),
                .init(id: "cos", type: "tm_math_cos", label: "Cos", x: 320, y: 360),
                .init(id: "sin", type: "tm_math_sin", label: "Sin", x: 320, y: 460),
                .init(id: "vec", type: "tm_make_vector3", label: "Vector3", x: 640, y: 400),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 960, y: 0),
            ],
            wires: [
                exec("e1", from: "update", to: "setT"),
                exec("e2", from: "setT", to: "set"),
                data("d1", from: "getT", "value", to: "addT", "a"),
                data("d2", from: "update", "deltaTime", to: "addT", "b"),
                data("d3", from: "addT", "result", to: "setT", "value"),
                data("d4", from: "getT", "value", to: "cos", "a"),
                data("d5", from: "getT", "value", to: "sin", "a"),
                data("d6", from: "cos", "result", to: "vec", "x"),
                data("d7", from: "sin", "result", to: "vec", "z"),
                data("d8", from: "vec", "vec3", to: "set", "translation"),
            ],
            data: []
        ),
        runsToday: false
    )

    /// Two handlers: On Drag → `$angVel = sceneTranslation.x` (a kick); On Update →
    /// `$angle += $angVel` and Set rotation from `$angle`. Flick to spin, with momentum.
    /// Needs two graph variables (`$angVel`, `$angle`) the compiler can't name yet.
    public static let dragMomentum = ScriptGraphExample(
        id: "example.drag-momentum",
        name: "Drag Momentum",
        summary: "Flick the box to spin it with momentum: drag sets $angVel, and each frame $angle += $angVel drives rotation. NEEDS VARIABLES: the two accumulators ($angVel, $angle) aren't authorable yet, so it loads + compiles but won't run correctly.",
        graph: RCP3ScriptGraph(
            nodes: [
                // Handler 1: a drag kick sets the angular velocity.
                .init(id: "drag", type: "tm_gesture_event_drag", x: 0, y: 0),
                .init(id: "setVel", type: "tm_set_variable_node", label: "Set $angVel", x: 320, y: 0),
                // Handler 2: per-frame integrate angle += angVel and drive rotation.
                .init(id: "update", type: "tm_update", x: 0, y: 320),
                .init(id: "getVel", type: "tm_get_variable_node", label: "Get $angVel", x: 0, y: 540),
                .init(id: "getAngle", type: "tm_get_variable_node", label: "Get $angle", x: 0, y: 640),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 320, y: 440),
                .init(id: "setAngle", type: "tm_set_variable_node", label: "Set $angle", x: 640, y: 320),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 960, y: 320),
            ],
            wires: [
                // Handler 1
                exec("e1", from: "drag", to: "setVel"),
                data("d1", from: "drag", "sceneTranslation", to: "setVel", "value"),
                // Handler 2
                exec("e2", from: "update", to: "setAngle"),
                exec("e3", from: "setAngle", to: "set"),
                data("d2", from: "getAngle", "value", to: "add", "a"),
                data("d3", from: "getVel", "value", to: "add", "b"),
                data("d4", from: "add", "result", to: "setAngle", "value"),
                data("d5", from: "getAngle", "value", to: "set", "rotation"),
            ],
            data: []
        ),
        runsToday: false
    )
}
