import Foundation
import TMFormat

public enum ScriptGraphExampleProvenance: String, Sendable, CaseIterable {
    case nativeRCP3
    case appleSample
    case unityPattern
    case unrealPattern
}

public enum ScriptGraphExampleCertificationStatus: Sendable, Equatable {
    /// Static graph, compiler, and host-runtime checks pass.
    case automated
    /// Automated checks pass; the documented RCP3 manual procedure is still pending.
    case manualPending
    /// The materialized graph was opened, saved, and executed in this RCP3 build.
    case rcp3Certified(build: String, date: String)
}

public enum ScriptGraphExampleKind: String, Sendable, CaseIterable {
    case pattern
    case functionalDemo
}

public struct ScriptGraphExampleCertification: Sendable {
    public let provenance: ScriptGraphExampleProvenance
    public let capabilities: [String]
    public let expectedOutcome: String
    public let manualSteps: [String]
    public let status: ScriptGraphExampleCertificationStatus

    public init(
        provenance: ScriptGraphExampleProvenance,
        capabilities: [String],
        expectedOutcome: String,
        manualSteps: [String],
        status: ScriptGraphExampleCertificationStatus = .manualPending
    ) {
        self.provenance = provenance
        self.capabilities = capabilities
        self.expectedOutcome = expectedOutcome
        self.manualSteps = manualSteps
        self.status = status
    }
}

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
    /// Whether this is a focused node pattern or a composed, product-like demo.
    public let kind: ScriptGraphExampleKind
    /// A one-line description, shown as help in the gallery. For a `runsToday == false`
    /// example it explains what the example needs; for the honest-literal cases it
    /// notes the literal caveat.
    public let summary: String
    /// The example graph, built from library node types with faithful pins.
    public let graph: RCP3ScriptGraph
    /// Provenance, coverage intent, observable result, and RCP3 certification state.
    public let certification: ScriptGraphExampleCertification
    /// `true` when the canonical compiler lowers the wired path to working runtime JS
    /// today (no `unsupported` on that path); `false` when it needs variable-name
    /// authoring first (see the type doc).
    public let runsToday: Bool

    /// Node types this example contributes to corpus coverage.
    public var requiredNodeTypes: Set<String> {
        Set(graph.nodes.map(\.type))
    }

    public init(
        id: String,
        name: String,
        kind: ScriptGraphExampleKind = .pattern,
        summary: String,
        certification: ScriptGraphExampleCertification,
        graph: RCP3ScriptGraph,
        runsToday: Bool
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.summary = summary
        self.certification = certification
        let augmentedData = Self.addRequiredComponentTypeLiterals(to: graph)
        let augmentedVariables = Self.addRequiredVariableDeclarations(to: graph, namespace: id)
        let augmentedNodes = Self.addRequiredVariableRefs(to: graph.nodes, variables: augmentedVariables)
        // Stamp the example's stable id onto its graph identity, so the editor can key
        // the canvas on the SHOWN graph's identity (not a coupled selection) and a loaded
        // example reads back its own id from `graph.id`. The example graphs are built with
        // the memberwise init (no `__uuid`), so this is the graph's identity.
        self.graph = RCP3ScriptGraph(
            id: id,
            nodes: augmentedNodes,
            wires: graph.wires,
            data: augmentedData,
            variables: augmentedVariables
        )
        self.runsToday = runsToday
    }

    private static func addRequiredComponentTypeLiterals(to graph: RCP3ScriptGraph) -> [RCP3ScriptGraph.DataLiteral] {
        var data = graph.data
        let componentTypePin = TMHash.murmur64a("component_type")
        let transformHash = TMHash.murmur64a("Transform")
        let nodesNeedingTransform = graph.nodes
            .filter { ["tm_set_component", "tm_get_component"].contains($0.type) }
            .filter { node in
                !data.contains { $0.toNode == node.id && $0.toPin == componentTypePin }
            }

        for node in nodesNeedingTransform {
            data.append(RCP3ScriptGraph.DataLiteral(
                id: "component_type.\(node.id)",
                toNode: node.id,
                toPin: componentTypePin,
                valueType: "re_scripting_graph_component_type",
                valueHash: transformHash
            ))
        }
        return data
    }

    private static func addRequiredVariableDeclarations(to graph: RCP3ScriptGraph, namespace: String) -> [RCP3ScriptGraph.Variable] {
        var variables = graph.variables
        var declared = Set(variables.map { $0.name.lowercased() })
        let neededNames = graph.nodes.compactMap(\.variableName)
        for name in neededNames where !declared.contains(name.lowercased()) {
            variables.append(RCP3ScriptGraph.Variable(uuid: deterministicUUID(namespace: namespace, name: name), name: name))
            declared.insert(name.lowercased())
        }
        return variables
    }

    private static func addRequiredVariableRefs(
        to nodes: [RCP3ScriptGraph.Node],
        variables: [RCP3ScriptGraph.Variable]
    ) -> [RCP3ScriptGraph.Node] {
        let refByName = Dictionary(uniqueKeysWithValues: variables.map { ($0.name.lowercased(), $0.uuid) })
        return nodes.map { node in
            guard let name = node.variableName, node.variableRefUUID == nil else { return node }
            var node = node
            node.variableRefUUID = refByName[name.lowercased()]
            return node
        }
    }

    private static func deterministicUUID(namespace: String, name: String) -> String {
        let input = "\(namespace.lowercased())|\(name.lowercased())"
        let first = TMHash.hex(TMHash.murmur64a(input))
        let second = TMHash.hex(TMHash.murmur64a("variable|\(input)"))
        let hex = first + second
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    }
}

/// The curated example gallery. Public, ordered (the literal-driven examples first,
/// then the local-variable-driven ones), and built once.
public enum ScriptGraphExamples {

    /// Composed programs intended to be tested and presented as product demos.
    public static let functionalDemos: [ScriptGraphExample] = [
        comboTarget,
        floorSelector,
        batchBuilder,
    ]

    /// Small, focused recipes useful while authoring a larger graph.
    public static let patterns: [ScriptGraphExample] = [
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
        lookAtTarget,
        delayedMove,
        oneShotTap,
        tapToggle,
        growByLoop,
    ]

    /// All examples, in gallery order.
    public static let all: [ScriptGraphExample] = functionalDemos + patterns

    /// Look up an example by id (the synthetic open-graph key).
    public static func example(id: String) -> ScriptGraphExample? {
        all.first { $0.id == id }
    }

    /// Union of node types exercised by at least one curated scenario.
    public static var coveredNodeTypes: Set<String> {
        all.reduce(into: []) { $0.formUnion($1.requiredNodeTypes) }
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

    private static func certification(
        _ provenance: ScriptGraphExampleProvenance,
        capabilities: [String],
        expected: String,
        action: String
    ) -> ScriptGraphExampleCertification {
        ScriptGraphExampleCertification(
            provenance: provenance,
            capabilities: capabilities,
            expectedOutcome: expected,
            manualSteps: [
                "Create a Script Graph from this sample and save the project.",
                "Open the graph in Reality Composer Pro 3; confirm all nodes, pins, literals, and wires load without repair.",
                action,
                "Save in Reality Composer Pro 3, reopen in Deconstructed3, and confirm the graph remains structurally intact.",
            ]
        )
    }

    // MARK: - FUNCTIONAL DEMOS

    /// A complete three-hit interaction: taps update persistent state, branch on a
    /// threshold, show progress spatially, celebrate success, then reset the streak.
    public static let comboTarget = ScriptGraphExample(
        id: "demo.combo-target",
        name: "Combo Target",
        kind: .functionalDemo,
        summary: "Land three taps: the target advances for hits one and two, then jumps, grows, and resets the streak on hit three.",
        certification: certification(
            .unityPattern,
            capabilities: ["gesture.tap", "state.counter", "math.threshold", "control.branch", "transform.feedback"],
            expected: "Tap one moves to X = 0.25, tap two to X = 0.5, and tap three moves to Y = 0.8 at 1.5× scale; the next tap starts the streak again.",
            action: "Enter preview and dispatch four taps, checking the position and scale after every tap."
        ),
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "tap", type: "tm_gesture_event_tap", x: 0, y: 0),
                .init(id: "increment", type: "tm_variable_add", label: "Hits += 1", x: 280, y: 0, variableName: "hits"),
                .init(id: "hits", type: "tm_get_variable_node", label: "Get Hits", x: 280, y: 260, variableName: "hits"),
                .init(id: "won", type: "tm_math_greater_equal", label: "Hits ≥ 3", x: 560, y: 220),
                .init(id: "branch", type: "tm_if", label: "Combo Complete?", x: 840, y: 0),
                .init(id: "progressX", type: "tm_math_multiply", label: "Progress × 0.25", x: 840, y: 300),
                .init(id: "progressPosition", type: "tm_make_vector3", label: "Progress Position", x: 1120, y: 300),
                .init(id: "progressScale", type: "tm_make_vector3", label: "Normal Scale", x: 1120, y: 460),
                .init(id: "showProgress", type: "tm_set_component", label: "Show Progress", x: 1400, y: 220),
                .init(id: "successPosition", type: "tm_make_vector3", label: "Success Position", x: 1120, y: 520),
                .init(id: "successScale", type: "tm_make_vector3", label: "Success Scale", x: 1120, y: 700),
                .init(id: "celebrate", type: "tm_set_component", label: "Celebrate", x: 1400, y: 0),
                .init(id: "reset", type: "tm_clear_variable_node", label: "Reset Hits", x: 1680, y: 0, variableName: "hits"),
            ],
            wires: [
                exec("e1", from: "tap", to: "increment"),
                exec("e2", from: "increment", to: "branch"),
                RCP3ScriptGraph.Wire(id: "e3", from: "branch", to: "celebrate", fromPin: pin("true"), toPin: nil),
                RCP3ScriptGraph.Wire(id: "e4", from: "branch", to: "showProgress", fromPin: pin("false"), toPin: nil),
                exec("e5", from: "celebrate", to: "reset"),
                data("d1", from: "hits", "value", to: "won", "a"),
                data("d2", from: "won", "result", to: "branch", "condition"),
                data("d3", from: "hits", "value", to: "progressX", "a"),
                data("d4", from: "progressX", "result", to: "progressPosition", "x"),
                data("d5", from: "progressPosition", "vec3", to: "showProgress", "translation"),
                data("d6", from: "progressScale", "vec3", to: "showProgress", "scale"),
                data("d7", from: "successPosition", "vec3", to: "celebrate", "translation"),
                data("d8", from: "successScale", "vec3", to: "celebrate", "scale"),
            ],
            data: [
                lit("increment.value", node: "increment", pin: "value", 1),
                lit("won.threshold", node: "won", pin: "b", 3),
                lit("progress.factor", node: "progressX", pin: "b", 0.25),
                lit("progress.sx", node: "progressScale", pin: "x", 1),
                lit("progress.sy", node: "progressScale", pin: "y", 1),
                lit("progress.sz", node: "progressScale", pin: "z", 1),
                lit("success.y", node: "successPosition", pin: "y", 0.8),
                lit("success.sx", node: "successScale", pin: "x", 1.5),
                lit("success.sy", node: "successScale", pin: "y", 1.5),
                lit("success.sz", node: "successScale", pin: "z", 1.5),
            ]
        ),
        runsToday: true
    )

    /// A compact cyclic state machine: each tap advances a floor, modulo four,
    /// computes a position, and branches to a distinct arrival treatment at floor 0.
    public static let floorSelector = ScriptGraphExample(
        id: "demo.floor-selector",
        name: "Four-floor Elevator",
        kind: .functionalDemo,
        summary: "Each tap advances one floor (0–3), computes its height, and highlights the lobby when the cycle wraps.",
        certification: certification(
            .unrealPattern,
            capabilities: ["gesture.tap", "state.machine", "math.modulo", "control.branch", "transform.computed"],
            expected: "Successive taps move to Y = 0.4, 0.8, 1.2, then return to Y = 0 with a wider lobby-arrival scale.",
            action: "Enter preview, dispatch four taps, and verify the elevator cycles through all four heights."
        ),
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "tap", type: "tm_gesture_event_tap", x: 0, y: 0),
                .init(id: "increment", type: "tm_variable_add", label: "Floor += 1", x: 280, y: 0, variableName: "floor"),
                .init(id: "modulo", type: "tm_math_mod", label: "Modulo 4", x: 560, y: 240),
                .init(id: "setFloor", type: "tm_set_variable_node", label: "Set Floor", x: 840, y: 0, variableName: "floor"),
                .init(id: "floor", type: "tm_get_variable_node", label: "Get Floor", x: 840, y: 300, variableName: "floor"),
                .init(id: "height", type: "tm_math_multiply", label: "Floor × 0.4", x: 1120, y: 300),
                .init(id: "position", type: "tm_make_vector3", label: "Floor Position", x: 1400, y: 300),
                .init(id: "isLobby", type: "tm_equals", label: "Floor = 0", x: 1120, y: 500),
                .init(id: "branch", type: "tm_if", label: "Lobby?", x: 1120, y: 0),
                .init(id: "normalScale", type: "tm_make_vector3", label: "Normal Scale", x: 1400, y: 520),
                .init(id: "lobbyScale", type: "tm_make_vector3", label: "Lobby Scale", x: 1400, y: 700),
                .init(id: "normal", type: "tm_set_component", label: "Move Elevator", x: 1680, y: 220),
                .init(id: "lobby", type: "tm_set_component", label: "Lobby Arrival", x: 1680, y: 0),
            ],
            wires: [
                exec("e1", from: "tap", to: "increment"),
                exec("e2", from: "increment", to: "setFloor"),
                exec("e3", from: "setFloor", to: "branch"),
                RCP3ScriptGraph.Wire(id: "e4", from: "branch", to: "lobby", fromPin: pin("true"), toPin: nil),
                RCP3ScriptGraph.Wire(id: "e5", from: "branch", to: "normal", fromPin: pin("false"), toPin: nil),
                data("d1", from: "increment", "result", to: "modulo", "a"),
                data("d2", from: "modulo", "result", to: "setFloor", "value"),
                data("d3", from: "floor", "value", to: "height", "a"),
                data("d4", from: "height", "result", to: "position", "y"),
                data("d5", from: "floor", "value", to: "isLobby", "a"),
                data("d6", from: "isLobby", "result", to: "branch", "condition"),
                data("d7", from: "position", "vec3", to: "normal", "translation"),
                data("d8", from: "position", "vec3", to: "lobby", "translation"),
                data("d9", from: "normalScale", "vec3", to: "normal", "scale"),
                data("d10", from: "lobbyScale", "vec3", to: "lobby", "scale"),
            ],
            data: [
                lit("increment.value", node: "increment", pin: "value", 1),
                lit("modulo.count", node: "modulo", pin: "b", 4),
                lit("height.factor", node: "height", pin: "b", 0.4),
                lit("lobby.zero", node: "isLobby", pin: "b", 0),
                lit("normal.sx", node: "normalScale", pin: "x", 1),
                lit("normal.sy", node: "normalScale", pin: "y", 1),
                lit("normal.sz", node: "normalScale", pin: "z", 1),
                lit("lobby.sx", node: "lobbyScale", pin: "x", 1.6),
                lit("lobby.sy", node: "lobbyScale", pin: "y", 0.8),
                lit("lobby.sz", node: "lobbyScale", pin: "z", 1),
            ]
        ),
        runsToday: true
    )

    /// A batch-workflow graph: clear state, execute five loop steps, accumulate the
    /// result, and use the loop's End scope to commit one final transform.
    public static let batchBuilder = ScriptGraphExample(
        id: "demo.batch-builder",
        name: "Five-step Batch Builder",
        kind: .functionalDemo,
        summary: "One tap runs a five-step batch, accumulates progress, then commits the finished scale and position only when the loop ends.",
        certification: certification(
            .unrealPattern,
            capabilities: ["gesture.tap", "state.reset", "control.loop", "state.accumulator", "control.loop-end"],
            expected: "Every tap performs five 0.2 accumulation steps and finishes at scale 1 with X = 1, demonstrating Step versus End flow.",
            action: "Enter preview, tap once, and verify the final transform is committed after the bounded loop."
        ),
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "tap", type: "tm_gesture_event_tap", x: 0, y: 0),
                .init(id: "clear", type: "tm_clear_variable_node", label: "Clear Progress", x: 280, y: 0, variableName: "progress"),
                .init(id: "loop", type: "tm_loop", label: "Five Steps", x: 560, y: 0),
                .init(id: "accumulate", type: "tm_variable_add", label: "Progress += 0.2", x: 840, y: 220, variableName: "progress"),
                .init(id: "progress", type: "tm_get_variable_node", label: "Get Progress", x: 840, y: 460, variableName: "progress"),
                .init(id: "position", type: "tm_make_vector3", label: "Result Position", x: 1120, y: 420),
                .init(id: "scale", type: "tm_make_vector3", label: "Result Scale", x: 1120, y: 620),
                .init(id: "commit", type: "tm_set_component", label: "Commit Batch", x: 1400, y: 0),
            ],
            wires: [
                exec("e1", from: "tap", to: "clear"),
                exec("e2", from: "clear", to: "loop"),
                RCP3ScriptGraph.Wire(id: "e3", from: "loop", to: "accumulate", fromPin: pin("step"), toPin: nil),
                RCP3ScriptGraph.Wire(id: "e4", from: "loop", to: "commit", fromPin: pin("end"), toPin: nil),
                data("d1", from: "progress", "value", to: "position", "x"),
                data("d2", from: "progress", "value", to: "scale", "x"),
                data("d3", from: "progress", "value", to: "scale", "y"),
                data("d4", from: "progress", "value", to: "scale", "z"),
                data("d5", from: "position", "vec3", to: "commit", "translation"),
                data("d6", from: "scale", "vec3", to: "commit", "scale"),
            ],
            data: [
                lit("loop.begin", node: "loop", pin: "begin", 0),
                lit("loop.end", node: "loop", pin: "end", 5),
                lit("loop.step", node: "loop", pin: "step", 1),
                lit("accumulate.value", node: "accumulate", pin: "value", 0.2),
            ]
        ),
        runsToday: true
    )

    // MARK: - RUNS TODAY

    /// On Drag → Set Transform.translation = `sceneTranslation`. The documented
    /// reference drag handler — drag the box and it follows in scene space.
    public static let dragToMove = ScriptGraphExample(
        id: "example.drag-to-move",
        name: "Drag to Move",
        summary: "Drag the box and it follows your pointer in scene space.",
        certification: certification(
            .nativeRCP3,
            capabilities: ["gesture.drag", "transform.translation"],
            expected: "The entity follows the drag position in scene space.",
            action: "Enter preview, drag the entity, and verify it follows continuously."
        ),
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
        certification: certification(
            .unityPattern,
            capabilities: ["gesture.drag", "math.vector-add", "literal.scalar"],
            expected: "The entity follows the drag position with a constant +0.5 X offset.",
            action: "Enter preview, drag the entity, and verify the center remains offset along X."
        ),
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
        certification: certification(
            .unrealPattern,
            capabilities: ["event.update", "component.get", "transform.translation"],
            expected: "The entity moves steadily along positive X using frame delta time.",
            action: "Enter preview and verify smooth frame-rate-independent movement along X."
        ),
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
        certification: certification(
            .unityPattern,
            capabilities: ["gesture.tap", "component.get", "transform.scale"],
            expected: "Each tap increases all three scale components by 0.2.",
            action: "Enter preview, tap three times, and verify monotonic uniform growth."
        ),
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
        certification: certification(
            .nativeRCP3,
            capabilities: ["lifecycle.did-add", "transform.translation"],
            expected: "The entity moves to (0.3, 0.3, 0) when added.",
            action: "Enter preview or re-add the entity and verify its initial position."
        ),
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
        certification: certification(
            .unrealPattern,
            capabilities: ["event.update", "variable.local", "math.sin", "transform.scale"],
            expected: "The entity repeatedly squashes and stretches along Y without drift.",
            action: "Enter preview and observe at least two complete scale oscillations."
        ),
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
        certification: certification(
            .unityPattern,
            capabilities: ["event.update", "variable.local", "rotation.axis-angle"],
            expected: "The entity rotates continuously around its Y axis.",
            action: "Enter preview and verify continuous stable rotation around Y."
        ),
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
        certification: certification(
            .unrealPattern,
            capabilities: ["event.update", "variable.local", "math.sin", "transform.translation"],
            expected: "The entity oscillates vertically around its origin.",
            action: "Enter preview and observe at least two complete vertical oscillations."
        ),
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
        certification: certification(
            .unityPattern,
            capabilities: ["event.update", "variable.local", "math.sin-cos", "transform.translation"],
            expected: "The entity follows a stable circular path in the XZ plane.",
            action: "Enter preview and observe one complete orbit without vertical movement."
        ),
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
        summary: "Flick the box to spin it: drag sets angularVelocity; each frame angle += angVel and angVel *= 0.95 friction, so it coasts to a stop (inertia) after you let go.",
        certification: certification(
            .unityPattern,
            capabilities: ["gesture.drag", "event.update", "variable.local", "math.decay", "rotation.axis-angle"],
            expected: "Dragging starts rotation that decays smoothly after release.",
            action: "Enter preview, drag once, release, and verify rotation coasts and slows."
        ),
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
                // Friction: each frame decay angVel toward 0 so the spin coasts to a stop.
                .init(id: "frictionMul", type: "tm_math_multiply", label: "Multiply", x: 320, y: 760),
                .init(id: "setVelDecay", type: "tm_set_variable_node", label: "Set $angVel", x: 640, y: 760, variableName: "angularVelocity"),
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
                // After this frame's rotation, decay angVel: angVel = angVel * friction.
                exec("e4", from: "set", to: "setVelDecay"),
                data("d8", from: "getVel", "value", to: "frictionMul", "a"),
                data("d9", from: "frictionMul", "result", to: "setVelDecay", "value"),
            ],
            data: [
                lit("lit.angularVelocity", node: "setVel", pin: "value", 0.05),
                lit("lit.axisY", node: "axis", pin: "y", 1),
                lit("lit.friction", node: "frictionMul", pin: "b", 0.95),
            ]
        ),
        runsToday: true
    )

    /// A common camera/turret recipe: continuously orient from one point toward
    /// another using the runtime's three-argument look-at quaternion constructor.
    public static let lookAtTarget = ScriptGraphExample(
        id: "example.look-at-target",
        name: "Look At Target",
        summary: "Continuously orient from the origin toward a fixed target using Look-at Rotation.",
        certification: certification(
            .unrealPattern,
            capabilities: ["event.update", "rotation.look-at", "transform.rotation"],
            expected: "The entity faces the fixed target at (1, 0, -1) with Y as up.",
            action: "Enter preview and verify the entity faces the target without rolling."
        ),
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "update", type: "tm_update", x: 0, y: 0),
                .init(id: "target", type: "tm_make_vector3", label: "Target", x: 0, y: 220),
                .init(id: "origin", type: "tm_make_vector3", label: "Origin", x: 0, y: 360),
                .init(id: "up", type: "tm_make_vector3", label: "Up", x: 0, y: 500),
                .init(id: "rotation", type: "tm_make_look_at_rotation", label: "Look-at Rotation", x: 360, y: 260),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 720, y: 0),
            ],
            wires: [
                exec("e", from: "update", to: "set"),
                data("d1", from: "target", "vec3", to: "rotation", "at"),
                data("d2", from: "origin", "vec3", to: "rotation", "from"),
                data("d3", from: "up", "vec3", to: "rotation", "upVector"),
                data("d4", from: "rotation", "new", to: "set", "rotation"),
            ],
            data: [
                lit("target.x", node: "target", pin: "x", 1),
                lit("target.z", node: "target", pin: "z", -1),
                lit("up.y", node: "up", pin: "y", 1),
            ]
        ),
        runsToday: true
    )

    /// A delayed interaction recipe commonly used for doors, pickups, and staged
    /// feedback: tap, wait, then apply the visible state change.
    public static let delayedMove = ScriptGraphExample(
        id: "example.delayed-move",
        name: "Delayed Move",
        summary: "Tap the entity; after half a second it moves upward.",
        certification: certification(
            .unrealPattern,
            capabilities: ["gesture.tap", "control.delay", "transform.translation"],
            expected: "Nothing moves immediately; after 0.5 seconds the entity moves to Y = 0.5.",
            action: "Enter preview, tap once, and verify the move occurs after the visible delay."
        ),
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "tap", type: "tm_gesture_event_tap", x: 0, y: 0),
                .init(id: "delay", type: "tm_delay", x: 280, y: 0),
                .init(id: "position", type: "tm_make_vector3", label: "Position", x: 560, y: 180),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 840, y: 0),
            ],
            wires: [
                exec("e1", from: "tap", to: "delay"),
                // Named exec out → the UNNAMED exec in: the unnamed pin's connector
                // hash is the serializer's default (omitted on disk), so it is
                // authored as nil — the same shape the parser reads back.
                RCP3ScriptGraph.Wire(
                    id: "e2",
                    from: "delay",
                    to: "set",
                    fromPin: pin("once"),
                    toPin: nil
                ),
                data("d", from: "position", "vec3", to: "set", "translation"),
            ],
            data: [
                lit("seconds", node: "delay", pin: "seconds", 0.5),
                lit("position.y", node: "position", pin: "y", 0.5),
            ]
        ),
        runsToday: true
    )

    /// A Do Once gate adapted from common Unity/Unreal pickup and tutorial-trigger
    /// graphs. Repeated taps reach the gate, but only the first changes the transform.
    public static let oneShotTap = ScriptGraphExample(
        id: "example.one-shot-tap",
        name: "One-shot Tap",
        summary: "Only the first tap moves the entity; later taps are ignored by Do Once.",
        certification: certification(
            .unityPattern,
            capabilities: ["gesture.tap", "control.do-once", "transform.translation"],
            expected: "The first tap moves the entity to X = 0.5; subsequent taps do not execute the move again.",
            action: "Enter preview, tap at least three times, and verify only the first tap changes state."
        ),
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "tap", type: "tm_gesture_event_tap", x: 0, y: 0),
                .init(id: "once", type: "tm_do_once", x: 280, y: 0),
                .init(id: "position", type: "tm_make_vector3", label: "Position", x: 560, y: 180),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 840, y: 0),
            ],
            wires: [
                exec("e1", from: "tap", to: "once"),
                // Named exec out → the unnamed exec in (see Delayed Move).
                RCP3ScriptGraph.Wire(
                    id: "e2",
                    from: "once",
                    to: "set",
                    fromPin: pin("once"),
                    toPin: nil
                ),
                data("d", from: "position", "vec3", to: "set", "translation"),
            ],
            data: [
                lit("position.x", node: "position", pin: "x", 0.5),
            ]
        ),
        runsToday: true
    )

    /// The toggle-switch pattern (light switches, doors): every activation flips a
    /// Bool variable through Not and a Branch routes to one of two outcomes.
    public static let tapToggle = ScriptGraphExample(
        id: "example.tap-toggle",
        name: "Tap Toggle",
        summary: "Each tap flips a Bool variable via Not, then If teleports the box to alternating sides.",
        certification: certification(
            .unityPattern,
            capabilities: ["gesture.tap", "variable.local", "logic.not", "control.branch", "transform.translation"],
            expected: "Taps alternate the entity between X = 0.5 and X = -0.5.",
            action: "Enter preview, tap four times, and verify the entity switches sides on every tap."
        ),
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "tap", type: "tm_gesture_event_tap", x: 0, y: 0),
                .init(id: "getFlag", type: "tm_get_variable_node", label: "Get $flag", x: 0, y: 220, variableName: "flag"),
                .init(id: "not", type: "tm_not", label: "Not", x: 280, y: 220),
                .init(id: "setFlag", type: "tm_set_variable_node", label: "Set $flag", x: 560, y: 0, variableName: "flag"),
                .init(id: "branch", type: "tm_if", label: "If", x: 840, y: 0),
                .init(id: "right", type: "tm_make_vector3", label: "Right", x: 840, y: 260),
                .init(id: "left", type: "tm_make_vector3", label: "Left", x: 840, y: 420),
                .init(id: "setRight", type: "tm_set_component", label: "Set Transform", x: 1120, y: 0),
                .init(id: "setLeft", type: "tm_set_component", label: "Set Transform", x: 1120, y: 220),
            ],
            wires: [
                exec("e1", from: "tap", to: "setFlag"),
                exec("e2", from: "setFlag", to: "branch"),
                // The Branch's named exec outputs → unnamed exec ins (see Delayed Move).
                RCP3ScriptGraph.Wire(id: "e3", from: "branch", to: "setRight", fromPin: pin("true"), toPin: nil),
                RCP3ScriptGraph.Wire(id: "e4", from: "branch", to: "setLeft", fromPin: pin("false"), toPin: nil),
                data("d1", from: "getFlag", "value", to: "not", "a"),
                data("d2", from: "not", "result", to: "setFlag", "value"),
                data("d3", from: "getFlag", "value", to: "branch", "condition"),
                data("d4", from: "right", "vec3", to: "setRight", "translation"),
                data("d5", from: "left", "vec3", to: "setLeft", "translation"),
            ],
            data: [
                lit("lit.rightX", node: "right", pin: "x", 0.5),
                lit("lit.leftX", node: "left", pin: "x", -0.5),
            ]
        ),
        runsToday: true
    )

    /// A bounded Loop driving a repeated state change from a single activation —
    /// the batch-effect recipe (spawners, staged growth, repeated pulses).
    public static let growByLoop = ScriptGraphExample(
        id: "example.grow-by-loop",
        name: "Grow by Loop",
        summary: "One tap runs Loop over 0..<5; every Step grows the scale by 0.1: five compounding steps per tap.",
        certification: certification(
            .unrealPattern,
            capabilities: ["gesture.tap", "control.loop", "component.get", "transform.scale"],
            expected: "A single tap grows the entity by 0.5 on every axis (five 0.1 steps applied in one activation).",
            action: "Enter preview, tap once, and verify the entity grows in a single 0.5 jump; tap again for another."
        ),
        graph: RCP3ScriptGraph(
            nodes: [
                .init(id: "tap", type: "tm_gesture_event_tap", x: 0, y: 0),
                .init(id: "loop", type: "tm_loop", label: "Loop", x: 280, y: 0),
                .init(id: "get", type: "tm_get_component", label: "Get Transform", x: 280, y: 260),
                .init(id: "step", type: "tm_make_vector3", label: "Step", x: 280, y: 440),
                .init(id: "add", type: "tm_math_add", label: "Add", x: 560, y: 300),
                .init(id: "set", type: "tm_set_component", label: "Set Transform", x: 840, y: 0),
            ],
            wires: [
                exec("e1", from: "tap", to: "loop"),
                // The Loop's named Step output → the unnamed exec in (see Delayed Move).
                RCP3ScriptGraph.Wire(id: "e2", from: "loop", to: "set", fromPin: pin("step"), toPin: nil),
                data("d1", from: "get", "scale", to: "add", "a"),
                data("d2", from: "step", "vec3", to: "add", "b"),
                data("d3", from: "add", "result", to: "set", "scale"),
            ],
            data: [
                lit("lit.begin", node: "loop", pin: "begin", 0),
                lit("lit.end", node: "loop", pin: "end", 5),
                lit("lit.step", node: "loop", pin: "step", 1),
                lit("lit.stepX", node: "step", pin: "x", 0.1),
                lit("lit.stepY", node: "step", pin: "y", 0.1),
                lit("lit.stepZ", node: "step", pin: "z", 0.1),
            ]
        ),
        runsToday: true
    )
}
