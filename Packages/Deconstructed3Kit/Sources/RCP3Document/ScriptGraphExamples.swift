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
/// ## Runs today
///
/// `runsToday == true` examples are wired so the canonical
/// `CanonicalScriptGraphCompiler` lowers the whole wired path to faithful runtime JS
/// with **no `unsupported` note on that path** — the backing compiler tests assert
/// exactly that. Press ▶ Play and the box moves.
///
/// The variable-driven examples (Spin / Sine Bob / Orbit / Squash by Sin / Drag
/// Momentum) carry a LOCAL accumulator on their Get/Set variable nodes
/// (`Node.variableName`), which the canonical compiler lowers to a stable per-script
/// instance-property slot (`this.variable_<slot>`, slot =
/// `MurmurHash64A(lowercase(name))`). They compile cleanly to that real slot and
/// visibly animate: translation/scale examples write vectors, and rotation examples
/// build a quaternion before assigning orientation. DEFERRED: an authoring-UI variable
/// picker, a graph-level variable table with real defaults/types, and the on-disk
/// `.tm_` round-trip of `variableName` — all pending a captured `.tm_` graph that uses
/// a variable.
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
        // Stamp the example's stable id onto its graph identity, so the editor can key
        // the canvas on the SHOWN graph's identity (not a coupled selection) and a loaded
        // example reads back its own id from `graph.id`. The example graphs are built with
        // the memberwise init (no `__uuid`), so this is the graph's identity.
        self.graph = RCP3ScriptGraph(
            id: id,
            nodes: graph.nodes,
            wires: graph.wires,
            data: graph.data,
            variables: graph.variables
        )
        self.runsToday = runsToday
    }
}

/// The curated example gallery. Public, ordered (the literal-driven examples first,
/// then the local-variable-driven ones), and built once.
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

    /// On Update → `$t += deltaTime`; Set scale = `Vector3(1, 1 + 0.5·sin($t), 1)`. A
    /// sin-driven vertical squash that oscillates for real, driven by the local `t` time
    /// accumulator (mirroring `sineBob`) rather than the per-frame `deltaTime` — so the
    /// box visibly pulses. The base `1` and amplitude `0.5` are baked literals; x/z = 1.
    public static let squashBySin = ScriptGraphExample(
        id: "example.squash-by-sin",
        name: "Squash by Sin",
        summary: "Vertical scale = 1 + 0.5·sin(t), accumulating t += deltaTime each frame so the box pulses smoothly. Compiles to a real local variable slot (this.variable_<slot>); runtime is user-confirmed on Play.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "getT", type: "tm_get_variable_node", label: "Get $t", x: 0, y: 240, variableName: "t"),
                .init(id: "addT", type: "tm_math_add", label: "Add", x: 320, y: 140),
                .init(id: "setT", type: "tm_set_variable_node", label: "Set $t", x: 640, y: 0, variableName: "t"),
                .init(id: "sin", type: "tm_math_sin", label: "Sin", x: 320, y: 360),
                .init(id: "mul", type: "tm_math_multiply", label: "Multiply", x: 540, y: 360),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 760, y: 300),
                .init(id: "vec", type: "tm_make_vector3", label: "Vector3", x: 980, y: 200),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 1200, y: 0),
            ],
            wires: [
                exec("e1", from: "update", to: "setT"),
                exec("e2", from: "setT", to: "set"),
                // t += deltaTime (the accumulator), mirroring Sine Bob.
                data("d1", from: "getT", "value", to: "addT", "a"),
                data("d2", from: "update", "deltaTime", to: "addT", "b"),
                data("d3", from: "addT", "result", to: "setT", "value"),
                // sin(t) — reads the ACCUMULATED time, not deltaTime, so it oscillates.
                data("d4", from: "getT", "value", to: "sin", "a"),
                // amp * sin(t) — amp is the baked 0.5 literal.
                data("d5", from: "sin", "result", to: "mul", "b"),
                // 1 + (amp * sin(t)) — the base 1 is a baked literal.
                data("d6", from: "mul", "result", to: "add", "b"),
                // Vector3(1, <squash>, 1) → scale
                data("d7", from: "add", "result", to: "vec", "y"),
                data("d8", from: "vec", "vec3", to: "set", "scale"),
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

    // MARK: - VARIABLE-DRIVEN (local accumulators)

    /// On Update → `$angle += deltaTime`; build `Quaternion(angle, Vector3(0, 1, 0))`;
    /// Set rotation from that quaternion. The `angle` accumulator compiles to a real
    /// local variable slot and the orientation write now receives a quaternion.
    public static let spin = ScriptGraphExample(
        id: "example.spin",
        name: "Spin",
        summary: "Accumulate angle += deltaTime each frame, build a quaternion around the Y axis, and assign orientation.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "getAngle", type: "tm_get_variable_node", label: "Get $angle", x: 0, y: 220, variableName: "angle"),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 320, y: 120),
                .init(id: "setAngle", type: "tm_set_variable_node", label: "Set $angle", x: 640, y: 0, variableName: "angle"),
                .init(id: "axis", type: "tm_make_vector3", label: "Vector3", x: 640, y: 240),
                .init(id: "rotation", type: "tm_make_rotation", label: "Rotation", x: 960, y: 120),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 1280, y: 0),
            ],
            wires: [
                exec("e1", from: "update", to: "setAngle"),
                exec("e2", from: "setAngle", to: "set"),
                data("d1", from: "getAngle", "value", to: "add", "a"),
                data("d2", from: "update", "deltaTime", to: "add", "b"),
                data("d3", from: "add", "result", to: "setAngle", "value"),
                data("d4", from: "getAngle", "value", to: "rotation", "angle"),
                data("d5", from: "axis", "vec3", to: "rotation", "axis"),
                data("d6", from: "rotation", "new", to: "set", "rotation"),
            ],
            data: [
                lit("lit.axisY", node: "axis", pin: "y", 1),
            ]
        ),
        runsToday: true
    )

    /// On Update → `$t += deltaTime`; Set translation.y from `sin($t)`. A vertical bob,
    /// driven by the local `t` time accumulator.
    public static let sineBob = ScriptGraphExample(
        id: "example.sine-bob",
        name: "Sine Bob",
        summary: "Bob the box up and down with sin(t), accumulating t += deltaTime. Compiles to a real local variable slot (this.variable_<slot>); runtime is user-confirmed on Play.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "getT", type: "tm_get_variable_node", label: "Get $t", x: 0, y: 220, variableName: "t"),
                .init(id: "addT", type: "tm_math_add", label: "Add", x: 320, y: 120),
                .init(id: "setT", type: "tm_set_variable_node", label: "Set $t", x: 640, y: 0, variableName: "t"),
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
        runsToday: true
    )

    /// On Update → `$t += deltaTime`; Set translation = `Vector3(cos($t), 0, sin($t))`.
    /// An orbit in the XZ plane, driven by the local `t` time accumulator.
    public static let orbit = ScriptGraphExample(
        id: "example.orbit",
        name: "Orbit",
        summary: "Orbit the box in the XZ plane with Vector3(cos(t), 0, sin(t)), accumulating t += deltaTime. Compiles to a real local variable slot (this.variable_<slot>); runtime is user-confirmed on Play.",
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "getT", type: "tm_get_variable_node", label: "Get $t", x: 0, y: 240, variableName: "t"),
                .init(id: "addT", type: "tm_math_add", label: "Add", x: 320, y: 140),
                .init(id: "setT", type: "tm_set_variable_node", label: "Set $t", x: 640, y: 0, variableName: "t"),
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
        runsToday: true
    )

    /// Two handlers: On Drag → `$angVel = 0.05`; On Update →
    /// `$angle += $angVel`, build `Quaternion(angle, Vector3(0, 1, 0))`, and set
    /// rotation from that quaternion.
    public static let dragMomentum = ScriptGraphExample(
        id: "example.drag-momentum",
        name: "Drag Momentum",
        summary: "Flick the box to spin it with momentum: drag sets angularVelocity, then angle drives a Y-axis quaternion.",
        graph: RCP3ScriptGraph(
            nodes: [
                // Handler 1: a drag kick sets the angular velocity.
                .init(id: "drag", type: "tm_gesture_event_drag", x: 0, y: 0),
                .init(id: "setVel", type: "tm_set_variable_node", label: "Set $angVel", x: 320, y: 0, variableName: "angularVelocity"),
                // Handler 2: per-frame integrate angle += angVel and drive rotation.
                .init(id: "update", type: "tm_update", x: 0, y: 320),
                .init(id: "getVel", type: "tm_get_variable_node", label: "Get $angVel", x: 0, y: 540, variableName: "angularVelocity"),
                .init(id: "getAngle", type: "tm_get_variable_node", label: "Get $angle", x: 0, y: 640, variableName: "angle"),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 320, y: 440),
                .init(id: "setAngle", type: "tm_set_variable_node", label: "Set $angle", x: 640, y: 320, variableName: "angle"),
                .init(id: "axis", type: "tm_make_vector3", label: "Vector3", x: 640, y: 560),
                .init(id: "rotation", type: "tm_make_rotation", label: "Rotation", x: 960, y: 440),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 1280, y: 320),
            ],
            wires: [
                // Handler 1
                exec("e1", from: "drag", to: "setVel"),
                // Handler 2
                exec("e2", from: "update", to: "setAngle"),
                exec("e3", from: "setAngle", to: "set"),
                data("d2", from: "getAngle", "value", to: "add", "a"),
                data("d3", from: "getVel", "value", to: "add", "b"),
                data("d4", from: "add", "result", to: "setAngle", "value"),
                data("d5", from: "getAngle", "value", to: "rotation", "angle"),
                data("d6", from: "axis", "vec3", to: "rotation", "axis"),
                data("d7", from: "rotation", "new", to: "set", "rotation"),
            ],
            data: [
                lit("lit.angularVelocity", node: "setVel", pin: "value", 0.05),
                lit("lit.axisY", node: "axis", pin: "y", 1),
            ]
        ),
        runsToday: true
    )
}
